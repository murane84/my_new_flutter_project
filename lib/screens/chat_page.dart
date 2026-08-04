import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// Hide intl's TextDirection so the unprefixed name resolves to dart:ui's
// (needed by the ShapeBorder overrides below).
import 'package:intl/intl.dart' hide TextDirection;
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'api_service.dart';
import 'token_helper.dart';
import 'websocket_manager.dart';
import '../utils/toast_helper.dart';
import '../utils/connection_status.dart';
import '../utils/time_utils.dart';
import '../utils/file_bytes.dart';
import '../utils/marquee_text.dart';
import 'live_session_screen.dart';
import 'home_page.dart' show playlistNotifier, playbackBus;

// ─── Timestamp helpers ───────────────────────────────────────────────────────

String _timeOnly(String iso) => localTimeOnly(iso);

/// Returns the date label for a separator.
/// Uses CALENDAR day comparison (not 24-hour duration) so "Today" correctly
/// flips to "Yesterday" at midnight, not 24 hours later.
String _dateSeparator(String iso) {
  final dt = parseServerTime(iso);
  final now = DateTime.now();
  // Strip to date-only for accurate calendar comparison
  final today = DateTime(now.year, now.month, now.day);
  final msgDay = DateTime(dt.year, dt.month, dt.day);
  final daysDiff = today.difference(msgDay).inDays;

  if (daysDiff == 0) return 'Today';
  if (daysDiff == 1) return 'Yesterday';
  if (daysDiff < 7) return DateFormat('EEEE').format(dt);       // Monday
  if (dt.year == now.year) return DateFormat('MMMM d').format(dt); // June 3
  return DateFormat('MMMM d, y').format(dt);                    // June 3, 2025
}

bool _sameDay(String a, String b) {
  final da = parseServerTime(a);
  final db = parseServerTime(b);
  return da.year == db.year && da.month == db.month && da.day == db.day;
}

/// Detects messages that contain only emoji characters (no letters/numbers).
bool _isEmojiOnly(String text) {
  final s = text.trim().replaceAll(' ', '');
  if (s.isEmpty || s.length > 12) return false; // cap at ~3 emoji
  // If any ASCII letter/number/punctuation exists, it's not emoji-only
  if (RegExp(r'[a-zA-Z0-9!@#$%&*()_+=\-\[\]{};:,.<>?/\\|`~^]').hasMatch(s)) {
    return false;
  }
  return true;
}

// ─── ChatPage ────────────────────────────────────────────────────────────────

class ChatPage extends StatefulWidget {
  static const routeName = '/chat';
  final int friendId;
  final String friendName;
  final Color textColor;
  final bool showAppBar;
  final Function(bool, String?)? onFriendOnlineStatusChanged;

  const ChatPage({
    super.key,
    required this.friendId,
    required this.friendName,
    required this.textColor,
    this.showAppBar = true,
    this.onFriendOnlineStatusChanged,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  String? _myId;
  bool _isLoading = true;
  bool _isFriendOnline = false;
  String _lastSeen = '';
  bool _friendTyping = false;

  List<Map<String, dynamic>> _messages = [];

  // reply
  Map<String, dynamic>? _replyTo;

  final _ctrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _showEmoji = false;
  bool _isAtBottom = true;
  bool _hasNewMsg = false;

  Timer? _statusTimer;
  Timer? _pollTimer;
  Timer? _typingTimer;
  Timer? _keepAliveTimer;
  StreamSubscription? _connectivitySub;
  bool _iTyping = false;

  // ── Online / offline session ───────────────────────────────────────
  bool _isUserOffline = false;
  bool _isReconnecting = false;
  DateTime _lastActivityTime = DateTime.now();

  late WebSocketManager _ws;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ctrl.addListener(_onTextChanged);
    _scrollCtrl.addListener(_onScroll);
    // Mirror the app-wide connection status so this banner never disagrees
    // with the home footer dot / header badge.
    _isUserOffline = !ConnectionStatus.instance.isOnline;
    ConnectionStatus.instance.online.addListener(_onConnStatusChanged);
    _initChat();

    _statusTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _checkOnlineStatus(),
    );

    _ws = WebSocketManager(
      userId: '',
      onEventReceived: _handleWsEvent,
      onDisconnected: () => _startPolling(),
    );
  }

  void _onConnStatusChanged() {
    if (mounted) {
      setState(() => _isUserOffline = !ConnectionStatus.instance.isOnline);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ConnectionStatus.instance.online.removeListener(_onConnStatusChanged);
    _statusTimer?.cancel();
    _pollTimer?.cancel();
    _typingTimer?.cancel();
    _keepAliveTimer?.cancel();
    _connectivitySub?.cancel();
    _ctrl.dispose();
    _scrollCtrl.dispose();
    _ws.close();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (View.of(context).viewInsets.bottom > 0 && _showEmoji) {
      setState(() => _showEmoji = false);
    }
  }

  @override
  void didUpdateWidget(ChatPage old) {
    super.didUpdateWidget(old);
    if (old.friendId != widget.friendId) {
      setState(() {
        _isLoading = true;
        _messages.clear();
        _replyTo = null;
      });
      _initChat();
    }
  }

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> _initChat() async {
    final token = await getToken();
    if (token == null) return;
    final user = await ApiService().getCurrentUser(token);
    _myId = user['id']?.toString();

    await _loadCachedMessages(); // show cached messages instantly
    await _loadMessages();        // then fetch fresh from network
    _checkOnlineStatus();
    _startPolling();
    _startKeepAlive();
    _startConnectivityWatch();

    if (_myId?.isNotEmpty == true) {
      _ws = WebSocketManager(
        userId: _myId!,
        onEventReceived: _handleWsEvent,
        onDisconnected: () => _startPolling(),
      );
      _ws.connect();
    }
  }

  // ── Messages ──────────────────────────────────────────────────────────────

  Future<void> _loadMessages() async {
    final uid = int.tryParse(_myId ?? '');
    if (uid == null) return;

    try {
      final msgs = await ApiService().fetchMessagesBetween(
        uid, widget.friendId,
        skip: 0, limit: 60,
      );

      final unread = msgs.any((m) =>
          m['receiver_id'].toString() == _myId && m['is_read'] == false);
      if (unread && _isAtBottom) {
        await ApiService().markMessagesAsReadPatch(widget.friendId);
      }

      if (!mounted) return;
      setState(() {
        _messages = _merge(_messages, msgs, markRead: true);
        _isLoading = false;
      });
      _saveMessagesCache();
      if (_isAtBottom) _scrollToBottom();
    } catch (_) {
      // API error (session expired, network issue) — show cached messages.
      // Do NOT flip global offline on a single message-fetch failure; the
      // app-wide heartbeat is the authority for connection status.
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  // ── Keepalive: ping the server every 60s while chat is open and active ──
  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
      if (!mounted) return;
      final secsSinceActivity =
          DateTime.now().difference(_lastActivityTime).inSeconds;
      if (secsSinceActivity < 180) {
        // User was active in the last 3 minutes — keep them online.
        final ok = await ApiService().setOnlineStatus(true);
        ConnectionStatus.instance.set(ok);
      }
    });
  }

  void _markActivity() {
    _lastActivityTime = DateTime.now();
    if (_isUserOffline && mounted) {
      // Quietly try to go back online when user resumes activity
      ApiService().setOnlineStatus(true).then((ok) {
        if (ok) ConnectionStatus.instance.set(true);
      });
    }
  }

  // ── Message cache (offline persistence) ──────────────────────────────────

  String get _cacheKey =>
      'chat_cache_${_myId ?? 'x'}_${widget.friendId}';

  Future<void> _loadCachedMessages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null || !mounted) return;
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      if (list.isEmpty) return;
      setState(() {
        _messages = list;
        _isLoading = false;
      });
    } catch (_) {}
  }

  Future<void> _saveMessagesCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Only cache the latest 100 messages to keep storage small
      final toCache = _messages.take(100).toList();
      await prefs.setString(_cacheKey, jsonEncode(toCache));
    } catch (_) {}
  }

  // ── Connectivity watcher (WhatsApp-style auto-reconnect) ──────────────────

  void _startConnectivityWatch() {
    _connectivitySub?.cancel();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final hasNet = results.any((r) => r != ConnectivityResult.none);
      if (hasNet && _isUserOffline) {
        _autoReconnect();
      } else if (!hasNet) {
        ConnectionStatus.instance.set(false);
      }
    });
  }

  Future<void> _autoReconnect() async {
    if (_isReconnecting || !mounted) return;
    setState(() => _isReconnecting = true);

    final ok = await ApiService().setOnlineStatus(true);
    if (!mounted) return;

    if (ok) {
      final wasOffline = _isUserOffline;
      ConnectionStatus.instance.set(true);
      setState(() => _isReconnecting = false);
      _startPolling();

      // Fetch any messages that arrived while offline
      final uid = int.tryParse(_myId ?? '');
      if (uid != null) {
        final fresh = await ApiService().fetchMessagesBetween(
          uid, widget.friendId, skip: 0, limit: 60);
        if (!mounted) return;
        final before = _messages.length;
        final merged = _merge(_messages, fresh, markRead: _isAtBottom);
        final newCount = merged.length - before;
        setState(() => _messages = merged);
        await _saveMessagesCache();

        if (!mounted) return;
        if (wasOffline && newCount > 0) {
          showToast(
            context,
            '$newCount new message${newCount == 1 ? '' : 's'} received',
            type: ToastType.info,
            duration: const Duration(seconds: 3),
          );
        } else if (wasOffline) {
          showToast(context, 'Back online', type: ToastType.success);
        }
        if (_isAtBottom) _scrollToBottom();
      }
    } else {
      ConnectionStatus.instance.set(false);
      setState(() => _isReconnecting = false);
      showToast(context, 'Network error — check your connection',
          type: ToastType.error);
    }
  }

  // Manual reconnect (tap "Go Online" banner)
  Future<void> _reconnect() => _autoReconnect();

  Future<void> _poll() async {
    final uid = int.tryParse(_myId ?? '');
    if (uid == null) return;

    // Always fetch without lastTimestamp so status changes (is_read, delivered)
    // on already-visible messages are captured every cycle — no manual refresh needed.
    List<Map<String, dynamic>> fetched;
    try {
      fetched = await ApiService().fetchMessagesBetween(
        uid, widget.friendId,
        skip: 0, limit: 60,
      );
    } catch (_) {
      // A single poll failure is not proof the whole server is down — leave the
      // connection status to the app-wide heartbeat so indicators stay in sync.
      return;
    }
    if (fetched.isEmpty) return;

    final merged = _merge(_messages, fetched, markRead: _isAtBottom);
    if (!mounted) return;
    if (!_listEq(_messages, merged)) {
      setState(() => _messages = merged);
      _saveMessagesCache();
      if (_isAtBottom) {
        _scrollToBottom();
      } else {
        setState(() => _hasNewMsg = true);
      }
    }

    // Mark delivered
    for (final m in fetched) {
      if (m['receiver_id'].toString() == _myId &&
          m['delivered'] == false) {
        ApiService().markMessageAsDelivered(m['id']);
      }
    }
    if (_isAtBottom) {
      final needsRead = fetched.any((m) =>
          m['receiver_id'].toString() == _myId && m['is_read'] == false);
      if (needsRead) ApiService().markMessagesAsReadPatch(widget.friendId);
    }
  }

  List<Map<String, dynamic>> _merge(
    List<Map<String, dynamic>> existing,
    List<Map<String, dynamic>> fetched, {
    bool markRead = false,
  }) {
    final map = <String, Map<String, dynamic>>{};
    for (final m in existing) {
      map[m['id'].toString()] = m;
    }
    for (final m in fetched) {
      final id = m['id'].toString();
      if (map.containsKey(id)) {
        map[id]!['delivered'] = m['delivered'];
        map[id]!['is_read'] = m['is_read'];
      } else {
        map[id] = m;
      }
    }
    return map.values.toList()
      ..sort((a, b) {
        final ta = DateTime.tryParse(a['timestamp'] ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final tb = DateTime.tryParse(b['timestamp'] ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return tb.compareTo(ta);
      });
  }

  bool _listEq(List<Map<String, dynamic>> a, List<Map<String, dynamic>> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i]['id'] != b[i]['id'] ||
          a[i]['is_read'] != b[i]['is_read'] ||
          a[i]['delivered'] != b[i]['delivered']) { return false; }
    }
    return true;
  }

  // ── WebSocket events ──────────────────────────────────────────────────────

  void _handleWsEvent(Map<String, dynamic> event) {
    final type = event['type'];
    if (!mounted) return;

    if (type == 'new_message') {
      final msg = event['message'] as Map<String, dynamic>?;
      if (msg != null) {
        setState(() {
          final id = msg['id'].toString();
          if (!_messages.any((m) => m['id'].toString() == id)) {
            _messages.insert(0, msg);
          }
        });
        if (_isAtBottom) {
          _scrollToBottom();
          ApiService().markMessagesAsReadPatch(widget.friendId);
        } else {
          setState(() => _hasNewMsg = true);
        }
      }
    } else if (type == 'status_update') {
      setState(() {
        final idx = _messages
            .indexWhere((m) => m['id'] == event['message_id']);
        if (idx != -1) {
          _messages[idx]['delivered'] = event['delivered'];
          _messages[idx]['is_read'] = event['is_read'];
        }
      });
    } else if (type == 'delete') {
      setState(() =>
          _messages.removeWhere((m) => m['id'] == event['message_id']));
    } else if (type == 'typing') {
      if (event['user_id'].toString() == widget.friendId.toString()) {
        setState(() => _friendTyping = true);
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) setState(() => _friendTyping = false);
        });
      }
    }
    // NOTE: `live_invite` is handled globally in HomePage's notification socket
    // so invites reach the user on any screen (not just an open chat).
  }

  // ── Listen Together ─────────────────────────────────────────────────────────

  /// HOST: start a live session with this friend, choosing a song from the
  /// music player's already-loaded playlist (falling back to the file browser
  /// only when nothing is loaded yet).
  Future<void> _startListenTogether() async {
    final token = await getToken();
    final myUserId = int.tryParse(_myId ?? '');
    if (token == null || myUserId == null) {
      if (mounted) {
        showToast(context, 'Please wait — still signing you in…',
            type: ToastType.error);
      }
      return;
    }

    final loaded = playlistNotifier.value;
    if (loaded.isEmpty) {
      // Nothing loaded in the player yet — fall back to picking a file.
      await _startListenTogetherFromFile(token, myUserId);
      return;
    }

    // Choose from the songs already loaded in the music player.
    final chosenPath = await _pickFromLoadedPlaylist(loaded);
    if (chosenPath == null || !mounted) return;

    Uint8List bytes;
    try {
      bytes = Uint8List.fromList(await readFileBytes(chosenPath));
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not read that track.',
            type: ToastType.error);
      }
      return;
    }
    if (bytes.isEmpty) {
      if (mounted) {
        showToast(context, 'That track appears to be empty.',
            type: ToastType.error);
      }
      return;
    }

    // If the DJ picked the song already playing locally, blend into the live
    // stream at its current position (no restart). A different song starts at
    // the beginning. Either way, pause the local player so nothing plays twice.
    final localPath = playbackBus.currentPath?.call();
    final localPlaying = playbackBus.isPlaying?.call() ?? false;
    final startPositionMs = (chosenPath == localPath && localPlaying)
        ? (playbackBus.currentPositionMs?.call() ?? 0)
        : 0;
    playbackBus.onPause?.call();

    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => LiveSessionScreen.host(
        token: token,
        myUserId: myUserId,
        receiverId: widget.friendId,
        audioBytes: bytes,
        title: _titleFromPath(chosenPath),
        peerName: widget.friendName,
        startPositionMs: startPositionMs,
      ),
    );
  }

  /// Bottom-sheet picker over the player's loaded songs. Returns the chosen
  /// file path, or null if dismissed.
  Future<String?> _pickFromLoadedPlaylist(List<String> paths) {
    final scheme = Theme.of(context).colorScheme;
    // Surface the currently-playing track first, flagged, so the DJ can share
    // what they're already listening to in one tap.
    final nowPath = playbackBus.currentPath?.call();
    final ordered = <String>[
      if (nowPath != null && paths.contains(nowPath)) nowPath,
      ...paths.where((p) => p != nowPath),
    ];
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header — headphones badge + title + subtitle.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 2, 18, 10),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: scheme.primary.withAlpha(28),
                          ),
                          child: Icon(Icons.headphones_rounded,
                              color: scheme.primary, size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'Listen together',
                                style: TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 16),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                'Pick a song to stream to ${widget.friendName}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(
                      height: 1,
                      color: scheme.outlineVariant.withAlpha(60)),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: ordered.length,
                      itemBuilder: (_, i) {
                        final p = ordered[i];
                        final isNow = p == nowPath;
                        final tile = ListTile(
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 8),
                          leading: CircleAvatar(
                            radius: 18,
                            backgroundColor: isNow
                                ? scheme.primary
                                : scheme.primaryContainer,
                            child: Icon(
                              isNow
                                  ? Icons.graphic_eq_rounded
                                  : Icons.music_note_rounded,
                              size: 17,
                              color: isNow
                                  ? Colors.white
                                  : scheme.onPrimaryContainer,
                            ),
                          ),
                          title: MarqueeText(
                            text: _titleFromPath(p),
                            height: 18,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: isNow
                                  ? FontWeight.bold
                                  : FontWeight.w500,
                              color:
                                  isNow ? scheme.primary : scheme.onSurface,
                            ),
                          ),
                          subtitle: isNow
                              ? Text('Now playing — share from here',
                                  style: TextStyle(
                                      fontSize: 11, color: scheme.primary))
                              : null,
                          trailing: Icon(Icons.sensors_rounded,
                              size: 18,
                              color: isNow
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant.withAlpha(120)),
                          onTap: () => Navigator.pop(ctx, p),
                        );
                        if (!isNow) return tile;
                        // Highlight the now-playing row as a rounded chip.
                        return Container(
                          margin: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: scheme.primary.withAlpha(22),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                                color: scheme.primary.withAlpha(90)),
                          ),
                          child: tile,
                        );
                      },
                    ),
                  ),
                  Divider(
                      height: 1,
                      color: scheme.outlineVariant.withAlpha(60)),
                  // Let the user still browse files if the song isn't loaded.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonalIcon(
                        onPressed: () => Navigator.pop(ctx, '__browse__'),
                        icon: const Icon(Icons.folder_open_rounded, size: 18),
                        label: const Text('Choose a file instead'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
              ),
            ),
          ),
        );
      },
    ).then((choice) async {
      if (choice == '__browse__') {
        // Deferred: reopen via the file browser path.
        final token = await getToken();
        final myUserId = int.tryParse(_myId ?? '');
        if (token != null && myUserId != null && mounted) {
          await _startListenTogetherFromFile(token, myUserId);
        }
        return null;
      }
      return choice;
    });
  }

  /// Fallback: pick a song from the device's file browser and start the
  /// session (used when the player has no loaded songs, or on the user's
  /// explicit request).
  Future<void> _startListenTogetherFromFile(String token, int myUserId) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'wav', 'm4a', 'aac', 'ogg', 'flac'],
    );
    if (result == null || result.files.isEmpty) return;

    final picked = result.files.single;
    final Uint8List bytes = await picked.readAsBytes();
    if (bytes.isEmpty) {
      if (mounted) {
        showToast(context, 'Could not read that audio file.',
            type: ToastType.error);
      }
      return;
    }
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => LiveSessionScreen.host(
        token: token,
        myUserId: myUserId,
        receiverId: widget.friendId,
        audioBytes: bytes,
        title: picked.name,
        peerName: widget.friendName,
      ),
    );
  }

  /// Derive a clean display title from a file path (basename without extension).
  String _titleFromPath(String path) {
    var name = path;
    final slash = name.lastIndexOf(RegExp(r'[\\/]'));
    if (slash >= 0) name = name.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    return name.trim().isEmpty ? 'Live song' : name.trim();
  }

  // ── Status ────────────────────────────────────────────────────────────────

  Future<void> _checkOnlineStatus() async {
    final status = await ApiService().fetchFriendStatus(widget.friendId);
    if (!mounted) return;
    final online = status['is_online'] ?? false;
    final lastSeen = status['last_seen'] ?? '';
    if (online != _isFriendOnline || lastSeen != _lastSeen) {
      setState(() {
        _isFriendOnline = online;
        _lastSeen = lastSeen;
      });
      widget.onFriendOnlineStatusChanged?.call(online, lastSeen);
    }
  }

  // ── Scroll ────────────────────────────────────────────────────────────────

  void _onScroll() {
    final atBottom = _scrollCtrl.offset <=
        _scrollCtrl.position.minScrollExtent + 40;
    setState(() => _isAtBottom = atBottom);
    if (atBottom && _hasNewMsg) setState(() => _hasNewMsg = false);
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 150), () {
      if (!mounted || !_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.minScrollExtent,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
      );
      setState(() => _hasNewMsg = false);
    });
  }

  // ── Typing indicator ──────────────────────────────────────────────────────

  void _onTextChanged() {
    setState(() {});
    _markActivity();
    if (!_iTyping) {
      _iTyping = true;
      // Send typing event via WS
      try {
        _ws.sendEvent({'type': 'typing', 'to': widget.friendId});
      } catch (_) {}
    }
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 2), () {
      _iTyping = false;
    });
  }

  // ── Send ──────────────────────────────────────────────────────────────────

  Future<void> _sendMessage() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;

    String content = text;
    if (_replyTo != null) {
      final quoted = (_replyTo!['content'] as String? ?? '').trim();
      final lines = quoted.split('\n').take(2).join('\n');
      content = '> $lines\n\n$text';
    }

    _markActivity();
    _ctrl.clear();
    setState(() => _replyTo = null);
    _scrollToBottom();

    try {
      final sent = await ApiService().sendMessage(widget.friendId, content);
      if (sent == null) {
        if (mounted) {
          _showErrorSnack('Message failed to send. Tap to retry.');
        }
        return;
      }
      if (!mounted) return;
      setState(() {
        if (!_messages.any((m) => m['id'] == sent['id'])) {
          _messages.insert(0, sent);
        }
      });
    } catch (e) {
      if (mounted) _showErrorSnack('Failed to send: $e');
    }
  }

  void _showErrorSnack(String msg) =>
      showToast(context, msg, type: ToastType.error);

  // ── Message actions ───────────────────────────────────────────────────────

  void _showMessageMenu(BuildContext context, Map<String, dynamic> msg) {
    final isMe = msg['sender_id'].toString() == _myId;
    final content = msg['content'] as String? ?? '';
    final scheme = Theme.of(context).colorScheme;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.symmetric(vertical: 10),
                width: 36,
                height: 3,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Quick emoji reactions
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: ['👍', '❤️', '😂', '😮', '😢', '🙏'].map((e) {
                    return GestureDetector(
                      onTap: () {
                        Navigator.pop(ctx);
                        _addReaction(msg, e);
                      },
                      child: Text(e, style: const TextStyle(fontSize: 28)),
                    );
                  }).toList(),
                ),
              ),
              const Divider(height: 1),
              _ActionTile(
                icon: Icons.reply_rounded,
                label: 'Reply',
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() => _replyTo = msg);
                  FocusScope.of(context).requestFocus(FocusNode());
                },
              ),
              _ActionTile(
                icon: Icons.copy_rounded,
                label: 'Copy',
                onTap: () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: _stripQuote(content)));
                  showToast(context, 'Copied');
                },
              ),
              _ActionTile(
                icon: Icons.forward_rounded,
                label: 'Forward',
                onTap: () {
                  Navigator.pop(ctx);
                  _ctrl.text = _stripQuote(content);
                },
              ),
              if (isMe) ...[
                _ActionTile(
                  icon: Icons.delete_outline_rounded,
                  label: 'Delete for me',
                  onTap: () {
                    Navigator.pop(ctx);
                    _deleteMessage(msg['id'], false);
                  },
                ),
                _ActionTile(
                  icon: Icons.delete_forever_rounded,
                  label: 'Delete for everyone',
                  color: scheme.error,
                  onTap: () {
                    Navigator.pop(ctx);
                    _deleteMessage(msg['id'], true);
                  },
                ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  void _addReaction(Map<String, dynamic> msg, String emoji) {
    setState(() {
      final reactions = List<String>.from(
          msg['_reactions'] as List? ?? []);
      if (reactions.contains(emoji)) {
        reactions.remove(emoji);
      } else {
        reactions.add(emoji);
      }
      msg['_reactions'] = reactions;
    });
  }

  Future<void> _deleteMessage(int id, bool forAll) async {
    final backup = Map<String, dynamic>.from(
        _messages.firstWhere((m) => m['id'] == id));
    setState(() => _messages.removeWhere((m) => m['id'] == id));
    try {
      await ApiService().deleteSingleMessage(id, deleteForAll: forAll);
      if (mounted) {
        showToast(
          context,
          forAll ? 'Deleted for everyone' : 'Deleted for you',
          type: ToastType.info,
        );
      }
    } catch (_) {
      if (mounted) setState(() => _messages.insert(0, backup));
    }
  }

  // ── Strip reply quote ─────────────────────────────────────────────────────

  String _stripQuote(String content) {
    final lines = content.split('\n');
    final skip = lines.takeWhile((l) => l.startsWith('> ')).length;
    if (skip == 0) return content;
    return lines.skip(skip + 1).join('\n').trim();
  }

  // ── Build helpers ─────────────────────────────────────────────────────────

  // [muted] tints "sending / sent / delivered"; [read] highlights the read
  // receipt. Both are passed in so the ticks stay legible on either the dark
  // teal-green or the pale-mint sent bubble.
  Widget _buildStatusIcon(Map<String, dynamic> msg,
      {required Color muted, required Color read}) {
    final status = msg['status']?.toString();
    if (status == 'sending') {
      return Icon(Icons.access_time, size: 12, color: muted);
    }
    if (msg['is_read'] == true) {
      return Icon(Icons.done_all, size: 13, color: read);
    }
    if (msg['delivered'] == true) {
      return Icon(Icons.done_all, size: 13, color: muted);
    }
    return Icon(Icons.done, size: 13, color: muted);
  }

  // Checks if two adjacent messages (list is reversed = newer first) should
  // be grouped: same sender, within 3 minutes of each other.
  bool _grouped(int index) {
    if (index + 1 >= _messages.length) return false;
    final curr = _messages[index];
    final prev = _messages[index + 1]; // older
    if (curr['sender_id'] != prev['sender_id']) return false;
    final tc = DateTime.tryParse(curr['timestamp'] ?? '');
    final tp = DateTime.tryParse(prev['timestamp'] ?? '');
    if (tc == null || tp == null) return false;
    return tc.difference(tp).inMinutes < 3;
  }

  Widget _buildBubble(Map<String, dynamic> msg, bool isMe, bool isDark,
      bool showAvatar, bool isFirst, bool showTail) {
    final scheme = Theme.of(context).colorScheme;
    final content = msg['content'] as String? ?? '';
    final hasQuote = content.startsWith('> ');
    String? quotedText;
    String mainText = content;

    if (hasQuote) {
      final lines = content.split('\n');
      final quoteLines = lines
          .takeWhile((l) => l.startsWith('> '))
          .map((l) => l.substring(2))
          .toList();
      quotedText = quoteLines.join('\n');
      mainText = lines.skip(quoteLines.length + 1).join('\n').trim();
    }

    final reactions = List<String>.from(msg['_reactions'] as List? ?? []);
    final emojiOnly = !hasQuote && _isEmojiOnly(mainText);

    // ── Bubble colours ──────────────────────────────────────────────────────
    // Sent messages use a green/mint family in BOTH themes, so the sender's
    // identity stays consistent: a deep teal-green on dark, a soft pale mint on
    // light. Received bubbles are a clean neutral (warm charcoal / white).
    final sentBubble =
        isDark ? const Color(0xFF12634A) : const Color(0xFFCFEFDD);
    final recvBubble =
        isDark ? const Color(0xFF241E20) : Colors.white;
    final bubbleColor = isMe ? sentBubble : recvBubble;
    // Pale mint needs dark text; the deep green (and received) keep their own.
    final onSent = isDark ? Colors.white : const Color(0xFF063825);
    final textColor = isMe ? onSent : scheme.onSurface;
    final quoteBarColor = isMe
        ? (isDark ? Colors.white54 : const Color(0xFF0B7A4C))
        : scheme.primary;
    // Muted + "read" accent for the timestamp/ticks, tuned per bubble.
    final sentMuted = onSent.withAlpha(isDark ? 150 : 140);
    final sentRead =
        isDark ? const Color(0xFF53D8FB) : const Color(0xFF0B7A4C);
    // Subtle border to lift each bubble off the wallpaper.
    final bubbleBorder = isMe
        ? (isDark
            ? Colors.white.withAlpha(18)
            : const Color(0xFF0B7A4C).withAlpha(46))
        : (isDark ? Colors.white.withAlpha(20) : Colors.black.withAlpha(14));

    // ── Bubble shape: a little beak/tail on the bottom-most bubble of each
    // group, pointing to its sender's side (avatar for received, edge for me).
    const tailSize = 7.0;
    final bubbleShape = _BubbleBorder(
      radius: 18,
      tailSize: tailSize,
      tailOnRight: isMe,
      showTail: showTail,
      side: BorderSide(color: bubbleBorder, width: 0.8),
    );

    // ── Spacing: tighter between grouped messages ──────────────────────────
    final topPad = showAvatar ? 6.0 : 2.0; // gap before new group

    return Padding(
      padding: EdgeInsets.only(
        top: topPad,
        left: isMe ? 56 : 6,
        right: isMe ? 6 : 56,
      ),
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onLongPress: () => _showMessageMenu(context, msg),
            // Swipe right = reply
            onHorizontalDragEnd: (d) {
              if (d.primaryVelocity != null && d.primaryVelocity! > 180) {
                HapticFeedback.selectionClick();
                setState(() => _replyTo = msg);
                FocusScope.of(context).requestFocus(FocusNode());
              }
            },
            child: Row(
              mainAxisAlignment:
                  isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Avatar (friend only, last message in each group)
                if (!isMe)
                  SizedBox(
                    width: 30,
                    child: showAvatar
                        ? CircleAvatar(
                            radius: 13,
                            backgroundColor: scheme.primaryContainer,
                            child: Text(
                              widget.friendName.isNotEmpty
                                  ? widget.friendName[0].toUpperCase()
                                  : '?',
                              style: TextStyle(
                                color: scheme.onPrimaryContainer,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          )
                        : const SizedBox(),
                  ),
                if (!isMe) const SizedBox(width: 4),

                // ── Emoji-only: no bubble, just big emoji ─────────────
                if (emojiOnly)
                  Text(
                    mainText,
                    style: const TextStyle(fontSize: 40, height: 1.2),
                  )
                else
                // ── Normal bubble ─────────────────────────────────────
                Flexible(
                  child: Container(
                    decoration: ShapeDecoration(
                      color: bubbleColor,
                      shape: bubbleShape,
                      shadows: [
                        BoxShadow(
                          color: Colors.black.withAlpha(isDark ? 46 : 20),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    // Extra padding on the tail side so text clears the beak.
                    padding: EdgeInsets.only(
                        left: 11 + (showTail && !isMe ? tailSize : 0),
                        right: 11 + (showTail && isMe ? tailSize : 0),
                        top: 8,
                        bottom: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // ── Quoted reply ──────────────────────────────
                        if (quotedText != null)
                          Container(
                            margin: const EdgeInsets.only(bottom: 7),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.black.withAlpha(30),
                              borderRadius: BorderRadius.circular(10),
                              border: Border(
                                left: BorderSide(
                                    color: quoteBarColor, width: 3),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isMe ? 'You' : widget.friendName,
                                  style: TextStyle(
                                    color: quoteBarColor,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  quotedText,
                                  style: TextStyle(
                                    color: textColor.withAlpha(175),
                                    fontSize: 12,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),

                        // ── Message body ──────────────────────────────
                        Text(
                          mainText,
                          style: TextStyle(
                            color: textColor,
                            fontSize: 15,
                            height: 1.38,
                          ),
                        ),

                        // ── Time + delivery status ────────────────────
                        // Shown only on last message of group (showAvatar)
                        // or standalone, to reduce visual noise.
                        if (showAvatar || isFirst)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: isMe
                                  ? MainAxisAlignment.end
                                  : MainAxisAlignment.start,
                              children: [
                                Text(
                                  _timeOnly(msg['timestamp'] ?? ''),
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: isMe
                                        ? sentMuted
                                        : scheme.onSurface.withAlpha(120),
                                  ),
                                ),
                                if (isMe) ...[
                                  const SizedBox(width: 3),
                                  _buildStatusIcon(msg,
                                      muted: sentMuted, read: sentRead),
                                ],
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Reactions
          if (reactions.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(
                top: 2,
                left: isMe ? 0 : 36,
              ),
              child: Wrap(
                spacing: 2,
                children: reactions.map((e) {
                  return GestureDetector(
                    onTap: () => _addReaction(msg, e),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color:
                            scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: scheme.outlineVariant.withAlpha(80)),
                      ),
                      child:
                          Text(e, style: const TextStyle(fontSize: 14)),
                    ),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDateSeparator(String label) {
    final scheme = Theme.of(context).colorScheme;
    final lineColor = scheme.onSurface.withAlpha(35);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      child: Row(
        children: [
          Expanded(child: Divider(height: 1, color: lineColor)),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 10),
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              // Slightly translucent — sits on top of wallpaper
              color: scheme.surface.withAlpha(220),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: lineColor),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
          ),
          Expanded(child: Divider(height: 1, color: lineColor)),
        ],
      ),
    );
  }

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.only(left: 44, bottom: 4),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (i) => _Dot(delay: i * 200)),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${widget.friendName} is typing…',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withAlpha(130),
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReplyPreview(Map<String, dynamic> msg) {
    final scheme = Theme.of(context).colorScheme;
    final content = _stripQuote(msg['content'] as String? ?? '');
    final isFromMe = msg['sender_id'].toString() == _myId;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(
            left: BorderSide(color: scheme.primary, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isFromMe ? 'You' : widget.friendName,
                  style: TextStyle(
                    color: scheme.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  content,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: scheme.onSurface.withAlpha(160),
                      fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            onPressed: () => setState(() => _replyTo = null),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildOfflineBanner() {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      height: _isUserOffline ? 38 : 0,
      color: scheme.errorContainer,
      child: _isUserOffline
          ? Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(Icons.wifi_off_rounded,
                      size: 15, color: scheme.onErrorContainer),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'You are offline — messages are read-only',
                      style: TextStyle(
                          fontSize: 12,
                          color: scheme.onErrorContainer),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Reconnect button
                  _isReconnecting
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: scheme.onErrorContainer,
                          ),
                        )
                      : GestureDetector(
                          onTap: _reconnect,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: scheme.error,
                              borderRadius:
                                  BorderRadius.circular(12),
                            ),
                            child: Text(
                              'Go Online',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: scheme.onError,
                              ),
                            ),
                          ),
                        ),
                ],
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  Widget _buildInput(bool isDark) {
    final scheme = Theme.of(context).colorScheme;
    final hasText = _ctrl.text.trim().isNotEmpty;

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildOfflineBanner(),
          if (_replyTo != null) _buildReplyPreview(_replyTo!),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Emoji button
                IconButton(
                  tooltip: _showEmoji ? 'Keyboard' : 'Emoji',
                  icon: Icon(
                    _showEmoji
                        ? Icons.keyboard_rounded
                        : Icons.emoji_emotions_outlined,
                    color: scheme.onSurfaceVariant,
                  ),
                  onPressed: () {
                    FocusScope.of(context).unfocus();
                    setState(() => _showEmoji = !_showEmoji);
                  },
                  visualDensity: VisualDensity.compact,
                ),

                // Listen together — play a local song live with this friend.
                // Lives in the composer so it's always visible, including when
                // the chat is embedded in a panel (showAppBar == false).
                IconButton(
                  tooltip: 'Listen together — share a local song live',
                  icon: const Icon(Icons.headphones_rounded),
                  color: scheme.primary,
                  onPressed: _startListenTogether,
                  visualDensity: VisualDensity.compact,
                ),
                // Text field
                // On desktop: Enter (no Shift) = send; Shift+Enter = newline.
                // On mobile:  send button / keyboard action sends.
                Expanded(
                  child: Focus(
                    onKeyEvent: (node, event) {
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.enter &&
                          !HardwareKeyboard.instance.isShiftPressed &&
                          !HardwareKeyboard.instance.isControlPressed) {
                        if (_ctrl.text.trim().isNotEmpty) {
                          _sendMessage();
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.handled; // suppress empty newline
                      }
                      return KeyEventResult.ignored;
                    },
                    child: TextField(
                      controller: _ctrl,
                      minLines: 1,
                      maxLines: 5,
                      // Send action on mobile soft keyboard
                      textInputAction: TextInputAction.send,
                      keyboardType: TextInputType.multiline,
                      decoration: InputDecoration(
                        hintText: 'Message… (Shift+Enter for newline)',
                        isDense: true,
                        filled: true,
                        fillColor: scheme.surfaceContainerHighest,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: (v) {
                        // Mobile soft-keyboard send key
                        if (v.trim().isNotEmpty) _sendMessage();
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Send button
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: hasText
                      ? Tooltip(
                          message: 'Send',
                          child: GestureDetector(
                            key: const ValueKey('send'),
                            onTap: _sendMessage,
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.send_rounded,
                                  color: Colors.white, size: 20),
                            ),
                          ),
                        )
                      : const SizedBox(key: ValueKey('empty'), width: 44),
                ),
              ],
            ),
          ),
          // Emoji picker — themed to the brand (no stock blue), rounded top,
          // sitting flush on the input like a sheet.
          Offstage(
            offstage: !_showEmoji,
            child: Container(
              height: 262,
              decoration: BoxDecoration(
                color: scheme.surface,
                border: Border(
                  top: BorderSide(color: scheme.outlineVariant.withAlpha(90)),
                ),
              ),
              child: EmojiPicker(
                onEmojiSelected: (_, emoji) {
                  _ctrl
                    ..text += emoji.emoji
                    ..selection = TextSelection.fromPosition(
                        TextPosition(offset: _ctrl.text.length));
                },
                textEditingController: _ctrl,
                config: Config(
                  height: 262,
                  emojiViewConfig: EmojiViewConfig(
                    emojiSizeMax: 26,
                    columns: 8,
                    backgroundColor: scheme.surface,
                    gridPadding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    recentsLimit: 40,
                    buttonMode: ButtonMode.MATERIAL,
                    noRecents: Text(
                      'No recent emoji yet',
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant),
                    ),
                  ),
                  categoryViewConfig: CategoryViewConfig(
                    backgroundColor: scheme.surfaceContainerHighest,
                    indicatorColor: scheme.primary,
                    iconColor: scheme.onSurfaceVariant,
                    iconColorSelected: scheme.primary,
                    dividerColor: scheme.outlineVariant.withAlpha(80),
                  ),
                  bottomActionBarConfig: BottomActionBarConfig(
                    backgroundColor: scheme.surfaceContainerHighest,
                    buttonColor: scheme.surfaceContainerHighest,
                    buttonIconColor: scheme.primary,
                  ),
                  searchViewConfig: SearchViewConfig(
                    backgroundColor: scheme.surfaceContainerHighest,
                    buttonIconColor: scheme.primary,
                    hintText: 'Search emoji',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Main build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    // On phones the conversation goes edge-to-edge and flush at the bottom (only
    // its top corners round, meeting the header); on wider screens it stays an
    // inset, fully-rounded card within the split panel.
    final isPhone = MediaQuery.of(context).size.width < 640;

    final body = Column(
      children: [
        // Message list
        Expanded(
          // Rounded, bordered conversation card — consistent with the app's
          // other cards/boxes instead of a sharp-cornered full-bleed panel.
          child: Container(
            margin: isPhone
                ? EdgeInsets.zero
                : const EdgeInsets.fromLTRB(6, 6, 6, 6),
            decoration: BoxDecoration(
              borderRadius: isPhone
                  ? const BorderRadius.vertical(top: Radius.circular(18))
                  : BorderRadius.circular(18),
              border: isPhone
                  ? Border(
                      top: BorderSide(
                          color: scheme.outlineVariant.withAlpha(70)))
                  : Border.all(color: scheme.outlineVariant.withAlpha(70)),
            ),
            clipBehavior: Clip.antiAlias,
            child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  children: [
                    // ── Chat wallpaper background ─────────────────────────
                    Positioned.fill(
                      child: _ChatWallpaper(
                          isDark: isDark, brand: scheme.primary),
                    ),
                    GestureDetector(
                      onTap: () => setState(() => _showEmoji = false),
                      child: ListView.builder(
                        controller: _scrollCtrl,
                        reverse: true,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 8),
                        itemCount: _messages.length + (_friendTyping ? 1 : 0),
                        itemBuilder: (ctx, i) {
                          // Typing indicator at top (index 0 in reversed list)
                          if (_friendTyping && i == 0) {
                            return _buildTypingIndicator();
                          }
                          final msgIdx = _friendTyping ? i - 1 : i;
                          final msg = _messages[msgIdx];
                          final isMe =
                              msg['sender_id'].toString() == _myId;
                          // showAvatar = last message in a group (bottom-most)
                          final showAvatar = !isMe && !_grouped(msgIdx);
                          // The bottom-most bubble of each group (either side)
                          // gets the little tail/beak pointing to its sender.
                          final showTail = !_grouped(msgIdx);
                          // isFirst = first message in group (top-most, newest)
                          final isFirst = msgIdx == 0 ||
                              !_grouped(msgIdx - 1);

                          // Date separator: show when next older message is different day
                          final nextIdx = msgIdx + 1;
                          bool showDate = false;
                          String dateLabel = '';
                          if (nextIdx < _messages.length) {
                            final curr = msg['timestamp'] ?? '';
                            final next =
                                _messages[nextIdx]['timestamp'] ?? '';
                            if (curr.isNotEmpty &&
                                next.isNotEmpty &&
                                !_sameDay(curr, next)) {
                              showDate = true;
                              dateLabel = _dateSeparator(curr);
                            }
                          } else if (msgIdx == _messages.length - 1) {
                            // Oldest message
                            showDate = true;
                            dateLabel =
                                _dateSeparator(msg['timestamp'] ?? '');
                          }

                          return Column(
                            children: [
                              _buildBubble(msg, isMe, isDark, showAvatar,
                                  isFirst, showTail),
                              if (showDate)
                                _buildDateSeparator(dateLabel),
                            ],
                          );
                        },
                      ),
                    ),
                    // New messages chip
                    if (_hasNewMsg)
                      Positioned(
                        bottom: 8,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: GestureDetector(
                            onTap: _scrollToBottom,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 7),
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: [
                                  BoxShadow(
                                    color: scheme.primary.withAlpha(80),
                                    blurRadius: 8,
                                  ),
                                ],
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.arrow_downward_rounded,
                                      size: 14, color: Colors.white),
                                  SizedBox(width: 4),
                                  Text('New messages',
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
          ),
        ),
        // Input
        _buildInput(isDark),
      ],
    );

    if (!widget.showAppBar) return body;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor:
                  Theme.of(context).colorScheme.primaryContainer,
              child: Text(
                widget.friendName.isNotEmpty
                    ? widget.friendName[0].toUpperCase()
                    : '?',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.friendName,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold)),
                Text(
                  _friendTyping
                      ? 'typing…'
                      : _isFriendOnline
                          ? 'online'
                          : _lastSeen.isNotEmpty
                              ? 'last seen ${formatLastSeen(_lastSeen)}'
                              : 'offline',
                  style: TextStyle(
                    fontSize: 11,
                    color: _friendTyping || _isFriendOnline
                        ? Colors.green
                        : Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Listen together',
            icon: const Icon(Icons.headphones_rounded),
            onPressed: _startListenTogether,
          ),
        ],
      ),
      body: body,
    );
  }
}

// ─── Chat wallpaper background ───────────────────────────────────────────────

class _ChatWallpaper extends StatelessWidget {
  final bool isDark;
  final Color brand;
  const _ChatWallpaper({required this.isDark, required this.brand});

  @override
  Widget build(BuildContext context) {
    return Container(
      // Warm brand-neutral base — near-black on dark, soft warm off-white on
      // light — with a faint music-motif pattern painted over it.
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF141011) : const Color(0xFFF3ECEA),
      ),
      child: CustomPaint(
        painter: _WallpaperPainter(isDark: isDark, brand: brand),
        size: Size.infinite,
      ),
    );
  }
}

/// A faint, tiled music-motif wallpaper (notes, headphones, hearts, discs…) in
/// the brand colour — like WhatsApp's doodle background, tuned to Aluta. Only
/// repaints when the theme/brand changes, so it's effectively free after first
/// layout.
class _WallpaperPainter extends CustomPainter {
  final bool isDark;
  final Color brand;
  const _WallpaperPainter({required this.isDark, required this.brand});

  static const List<IconData> _icons = [
    Icons.music_note_rounded,
    Icons.headphones_rounded,
    Icons.favorite_rounded,
    Icons.album_rounded,
    Icons.graphic_eq_rounded,
    Icons.queue_music_rounded,
    Icons.radio_rounded,
    Icons.audiotrack_rounded,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    // Very low alpha keeps it a whisper behind the bubbles.
    final color =
        (isDark ? Colors.white : brand).withAlpha(isDark ? 12 : 15);
    const cell = 66.0;
    var i = 0;
    for (double y = 0; y < size.height + cell; y += cell) {
      final row = (y / cell).floor();
      final xOff = row.isEven ? 0.0 : cell / 2; // brick-lay for organic feel
      for (double x = xOff; x < size.width + cell; x += cell) {
        final icon = _icons[(i * 5 + row * 3) % _icons.length];
        final tilt = (((i * 7 + row * 11) % 7) - 3) * 0.16; // small varied tilt
        final glyphSize = 18.0 + ((i + row) % 3) * 5.0;
        _glyph(canvas, icon, Offset(x, y), glyphSize, color, tilt);
        i++;
      }
    }
  }

  void _glyph(Canvas canvas, IconData icon, Offset c, double glyphSize,
      Color color, double tilt) {
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: glyphSize,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(tilt);
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WallpaperPainter old) =>
      old.isDark != isDark || old.brand != brand;
}

// ─── Typing dot animation ────────────────────────────────────────────────────

class _Dot extends StatefulWidget {
  final int delay;
  const _Dot({required this.delay});

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _ctrl.repeat(reverse: true);
    });
    _anim = Tween<double>(begin: 0, end: -5).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (ctx2, child2) => Transform.translate(
        offset: Offset(0, _anim.value),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

// ─── Action tile ─────────────────────────────────────────────────────────────

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurface;
    return ListTile(
      leading: Icon(icon, color: c, size: 22),
      title: Text(label, style: TextStyle(color: c)),
      dense: true,
      onTap: onTap,
    );
  }
}

// ─── Chat bubble with a WhatsApp-style beak/tail ─────────────────────────────
/// A rounded-rectangle bubble whose bottom-outer corner grows a small triangular
/// tail pointing toward the sender. Drawn as ONE continuous path so the fill,
/// border and shadow all follow the beak seamlessly (via [ShapeDecoration]).
///   • [tailOnRight] true  → tail at the bottom-right (my messages)
///   • [tailOnRight] false → tail at the bottom-left  (the friend's messages)
///   • [showTail] false    → a plain rounded rectangle (grouped messages)
class _BubbleBorder extends ShapeBorder {
  const _BubbleBorder({
    this.radius = 18,
    this.tailSize = 7,
    required this.tailOnRight,
    required this.showTail,
    this.side = BorderSide.none,
  });

  final double radius;
  final double tailSize;
  final bool tailOnRight;
  final bool showTail;
  final BorderSide side;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    final r = radius;
    final path = Path();

    if (!showTail) {
      path.addRRect(RRect.fromRectAndRadius(rect, Radius.circular(r)));
      return path;
    }

    final t = tailSize;
    final top = rect.top;
    final bottom = rect.bottom;

    if (tailOnRight) {
      // Body inset from the right by [t]; beak protrudes into that gap.
      final left = rect.left;
      final bodyR = rect.right - t;
      path.moveTo(left + r, top);
      path.lineTo(bodyR - r, top);
      path.arcToPoint(Offset(bodyR, top + r), radius: Radius.circular(r));
      path.lineTo(bodyR, bottom - t); // down the right edge to the beak base
      path.lineTo(rect.right, bottom); // out to the beak tip
      path.lineTo(bodyR, bottom); // back to the body's bottom-right
      path.lineTo(left + r, bottom);
      path.arcToPoint(Offset(left, bottom - r), radius: Radius.circular(r));
      path.lineTo(left, top + r);
      path.arcToPoint(Offset(left + r, top), radius: Radius.circular(r));
      path.close();
    } else {
      // Body inset from the left by [t]; beak protrudes into that gap.
      final right = rect.right;
      final bodyL = rect.left + t;
      path.moveTo(bodyL + r, top);
      path.lineTo(right - r, top);
      path.arcToPoint(Offset(right, top + r), radius: Radius.circular(r));
      path.lineTo(right, bottom - r);
      path.arcToPoint(Offset(right - r, bottom), radius: Radius.circular(r));
      path.lineTo(bodyL, bottom); // along the bottom to the body's bottom-left
      path.lineTo(rect.left, bottom); // out to the beak tip
      path.lineTo(bodyL, bottom - t); // back up to the body's left edge
      path.lineTo(bodyL, top + r);
      path.arcToPoint(Offset(bodyL + r, top), radius: Radius.circular(r));
      path.close();
    }
    return path;
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none) return;
    canvas.drawPath(
      getOuterPath(rect, textDirection: textDirection),
      side.toPaint(),
    );
  }

  @override
  ShapeBorder scale(double t) => _BubbleBorder(
        radius: radius * t,
        tailSize: tailSize * t,
        tailOnRight: tailOnRight,
        showTail: showTail,
        side: side.scale(t),
      );
}
