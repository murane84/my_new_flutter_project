import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
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
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../utils/app_config.dart';

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
  String _friendPhone = '';
  bool _friendTyping = false;

  List<Map<String, dynamic>> _messages = [];

  // reply
  Map<String, dynamic>? _replyTo;

  // edit-in-place: the message currently being edited, plus any reply-quote
  // prefix to preserve when saving.
  Map<String, dynamic>? _editing;
  String _editQuotePrefix = '';

  // Per-message keys + highlight id, used to scroll to a quoted original.
  final Map<String, GlobalKey> _msgKeys = {};
  String? _highlightedId;

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

  // ── Media sharing / voice recording ─────────────────────────────────
  final _recorder = AudioRecorder();
  bool _isRecording = false;
  bool _uploadingMedia = false;
  Timer? _recordTimer;
  int _recordMs = 0;
  String _apiBase = ''; // resolved server base for building attachment URLs

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppConfig.baseUrl.then((b) {
      if (mounted) setState(() => _apiBase = b);
    });
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
    _recordTimer?.cancel();
    _recorder.dispose();
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
    // Clone existing entries so merged items have fresh identities — that lets
    // _listEq detect in-place field changes (edits, reactions, tombstones,
    // read/delivered) every poll and trigger a rebuild.
    for (final m in existing) {
      map[m['id'].toString()] = Map<String, dynamic>.from(m);
    }
    for (final m in fetched) {
      final id = m['id'].toString();
      if (map.containsKey(id)) {
        final ex = map[id]!;
        ex['delivered'] = m['delivered'];
        ex['is_read'] = m['is_read'];
        ex['content'] = m['content'];
        ex['edited'] = m['edited'];
        ex['is_deleted'] = m['is_deleted'];
        ex['reactions'] = m['reactions'];
        ex['message_type'] = m['message_type'];
        ex['media_url'] = m['media_url'];
        ex['media_name'] = m['media_name'];
        ex['media_mime'] = m['media_mime'];
        ex['media_size'] = m['media_size'];
        ex['media_duration'] = m['media_duration'];
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
          a[i]['delivered'] != b[i]['delivered'] ||
          a[i]['content'] != b[i]['content'] ||
          a[i]['edited'] != b[i]['edited'] ||
          a[i]['is_deleted'] != b[i]['is_deleted'] ||
          a[i]['reactions'] != b[i]['reactions']) { return false; }
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
    } else if (type == 'delete' || type == 'message_deleted') {
      // Delete-for-everyone now leaves a tombstone; mark it rather than remove.
      setState(() {
        final data = event['data'] as Map<String, dynamic>?;
        final mid = event['message_id'] ?? data?['message_id'];
        final idx = _messages.indexWhere((m) => m['id'] == mid);
        if (idx != -1) {
          _messages[idx]['is_deleted'] = true;
          _messages[idx]['content'] = '';
          _messages[idx]['message_type'] = 'text';
          _messages[idx]['media_url'] = null;
          _messages[idx]['reactions'] = null;
        }
      });
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
    _friendPhone = (status['phone'] as String?) ?? '';
    if (online != _isFriendOnline || lastSeen != _lastSeen) {
      setState(() {
        _isFriendOnline = online;
        _lastSeen = lastSeen;
      });
      widget.onFriendOnlineStatusChanged?.call(online, lastSeen);
    }
  }

  // Direct call to the friend's saved phone number (tel: dialer).
  Future<void> _callFriend() async {
    final phone = _friendPhone.trim();
    if (phone.isEmpty) {
      if (mounted) {
        showToast(context, '${widget.friendName} has no phone number saved',
            type: ToastType.info);
      }
      return;
    }
    try {
      await launchUrl(Uri(scheme: 'tel', path: phone));
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not start the call', type: ToastType.error);
      }
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

  // ── Media sharing ───────────────────────────────────────────────────────
  /// Build a full URL from a relative attachment path (/attachments/<id>).
  String fullMediaUrl(String rel) =>
      rel.startsWith('http') ? rel : '$_apiBase$rel';

  void _openAttachSheet() {
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.onSurfaceVariant.withAlpha(80),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            _attachTile(ctx, Icons.photo_rounded, 'Photo', const Color(0xFF7C4DFF),
                () => _pickImage(ImageSource.gallery)),
            _attachTile(ctx, Icons.insert_drive_file_rounded, 'Document',
                const Color(0xFF3D5AFE), _pickDocument),
            _attachTile(ctx, Icons.headphones_rounded, 'Listen together',
                scheme.primary, _startListenTogether),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _attachTile(BuildContext ctx, IconData icon, String label, Color color,
      VoidCallback onTap) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color.withAlpha(32),
        child: Icon(icon, color: color),
      ),
      title: Text(label),
      onTap: () {
        Navigator.pop(ctx);
        onTap();
      },
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final x = await ImagePicker()
          .pickImage(source: source, imageQuality: 74, maxWidth: 1600);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      await _uploadAndSend(
          bytes: bytes, filename: x.name, mime: 'image/jpeg', type: 'image');
    } catch (_) {
      if (mounted) showToast(context, 'Could not pick image', type: ToastType.error);
    }
  }

  Future<void> _pickDocument() async {
    try {
      final res = await FilePicker.pickFiles(withData: true);
      if (res == null || res.files.isEmpty) return;
      final f = res.files.first;
      final bytes = f.bytes;
      if (bytes == null) {
        if (mounted) showToast(context, 'Could not read file', type: ToastType.error);
        return;
      }
      final ext = (f.extension ?? '').toLowerCase();
      const imgExt = ['jpg', 'jpeg', 'png', 'gif', 'webp'];
      await _uploadAndSend(
        bytes: bytes,
        filename: f.name,
        mime: _mimeForExt(ext),
        type: imgExt.contains(ext) ? 'image' : 'file',
      );
    } catch (_) {
      if (mounted) showToast(context, 'Could not pick file', type: ToastType.error);
    }
  }

  String _mimeForExt(String ext) {
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'pdf':
        return 'application/pdf';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
      case 'aac':
        return 'audio/mp4';
      case 'wav':
        return 'audio/wav';
      case 'mp4':
        return 'video/mp4';
      default:
        return 'application/octet-stream';
    }
  }

  // ── Voice notes ─────────────────────────────────────────────────────────
  Future<void> _startRecording() async {
    try {
      if (!await _recorder.hasPermission()) {
        if (mounted) {
          showToast(context, 'Microphone permission needed',
              type: ToastType.error);
        }
        return;
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(
            encoder: AudioEncoder.aacLc, bitRate: 128000, sampleRate: 44100),
        path: path,
      );
      _recordMs = 0;
      setState(() => _isRecording = true);
      _recordTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (mounted) setState(() => _recordMs += 200);
      });
    } catch (_) {
      if (mounted) showToast(context, 'Could not start recording', type: ToastType.error);
    }
  }

  Future<void> _cancelRecording() async {
    _recordTimer?.cancel();
    try {
      final p = await _recorder.stop();
      if (p != null) {
        try {
          await File(p).delete();
        } catch (_) {}
      }
    } catch (_) {}
    if (mounted) setState(() {
      _isRecording = false;
      _recordMs = 0;
    });
  }

  Future<void> _stopAndSendRecording() async {
    _recordTimer?.cancel();
    final durationMs = _recordMs;
    setState(() => _isRecording = false);
    try {
      final path = await _recorder.stop();
      if (path == null) return;
      final bytes = await File(path).readAsBytes();
      try {
        await File(path).delete();
      } catch (_) {}
      if (bytes.isEmpty || durationMs < 700) {
        if (mounted) showToast(context, 'Hold longer to record');
        return;
      }
      await _uploadAndSend(
        bytes: bytes,
        filename: 'voice_$durationMs.m4a',
        mime: 'audio/mp4',
        type: 'audio',
        durationMs: durationMs,
      );
    } catch (_) {
      if (mounted) showToast(context, 'Could not send recording', type: ToastType.error);
    } finally {
      if (mounted) setState(() => _recordMs = 0);
    }
  }

  Future<void> _uploadAndSend({
    required List<int> bytes,
    required String filename,
    required String mime,
    required String type,
    int? durationMs,
  }) async {
    setState(() => _uploadingMedia = true);
    try {
      final up = await ApiService()
          .uploadMedia(bytes: bytes, filename: filename, mime: mime);
      if (up == null || up['url'] == null) {
        if (mounted) showToast(context, 'Upload failed', type: ToastType.error);
        return;
      }
      final sent = await ApiService().sendMessage(
        widget.friendId,
        '',
        messageType: type,
        mediaUrl: up['url'] as String,
        mediaName: (up['name'] ?? filename) as String?,
        mediaMime: (up['mime'] ?? mime) as String?,
        mediaSize: (up['size'] as num?)?.toInt(),
        mediaDuration: durationMs,
      );
      if (sent != null && mounted) {
        setState(() {
          if (!_messages.any((m) => m['id'] == sent['id'])) {
            _messages.insert(0, sent);
          }
        });
        _scrollToBottom();
        _saveMessagesCache();
      } else if (mounted) {
        showToast(context, 'Could not send', type: ToastType.error);
      }
    } finally {
      if (mounted) setState(() => _uploadingMedia = false);
    }
  }

  String _fmtBytes(int? n) {
    if (n == null || n <= 0) return '';
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _fmtDur(int ms) {
    final s = ms ~/ 1000;
    final m = s ~/ 60;
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$m:$ss';
  }

  // The composer, while a voice note is recording: cancel · timer · send.
  Widget _buildRecordingBar(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Cancel',
            icon: Icon(Icons.delete_outline_rounded, color: scheme.error),
            onPressed: _cancelRecording,
          ),
          Container(
            width: 10,
            height: 10,
            decoration:
                BoxDecoration(color: scheme.error, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Text(
            _fmtDur(_recordMs),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Recording voice note…',
              style:
                  TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: _stopAndSendRecording,
            child: Container(
              width: 46,
              height: 46,
              decoration:
                  BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
              child:
                  const Icon(Icons.send_rounded, color: Colors.white, size: 22),
            ),
          ),
        ],
      ),
    );
  }

  // ── Media message rendering ─────────────────────────────────────────────
  Widget _mediaContent(String type, String rel, Map<String, dynamic> msg,
      bool isMe, Color textColor, ColorScheme scheme) {
    final url = fullMediaUrl(rel);
    switch (type) {
      case 'image':
        return _imageBubble(url);
      case 'audio':
        return _VoiceNotePlayer(
          url: url,
          durationMs: (msg['media_duration'] as num?)?.toInt() ?? 0,
          accent: scheme.primary,
          onColor: textColor,
        );
      default:
        return _fileBubble(url, msg, textColor, scheme);
    }
  }

  Widget _imageBubble(String url) {
    return GestureDetector(
      onTap: () => _openImageViewer(url),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
              maxWidth: 240, maxHeight: 300, minWidth: 120, minHeight: 80),
          child: CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            placeholder: (_, __) => Container(
              width: 200,
              height: 150,
              color: Colors.black.withAlpha(20),
              child: const Center(
                child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            ),
            errorWidget: (_, __, ___) => Container(
              width: 180,
              height: 120,
              color: Colors.black.withAlpha(20),
              child: const Icon(Icons.broken_image_rounded),
            ),
          ),
        ),
      ),
    );
  }

  void _openImageViewer(String url) {
    showDialog(
      context: context,
      barrierColor: Colors.black.withAlpha(235),
      builder: (ctx) => Stack(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(ctx),
            child: Center(
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 4,
                child: CachedNetworkImage(imageUrl: url, fit: BoxFit.contain),
              ),
            ),
          ),
          Positioned(
            top: 40,
            right: 12,
            child: IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white),
              onPressed: () => Navigator.pop(ctx),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fileBubble(String url, Map<String, dynamic> msg, Color textColor,
      ColorScheme scheme) {
    final name = (msg['media_name'] as String?) ?? 'File';
    final size = (msg['media_size'] as num?)?.toInt();
    return GestureDetector(
      onTap: () => _openUrl(url),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 244),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(20),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: scheme.primary.withAlpha(40),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(_fileIcon(name), color: scheme.primary, size: 22),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: textColor,
                          fontWeight: FontWeight.w600,
                          fontSize: 13)),
                  if (size != null && size > 0)
                    Text(_fmtBytes(size),
                        style: TextStyle(
                            color: textColor.withAlpha(150), fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.download_rounded,
                size: 18, color: textColor.withAlpha(160)),
          ],
        ),
      ),
    );
  }

  IconData _fileIcon(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.pdf')) return Icons.picture_as_pdf_rounded;
    if (n.endsWith('.doc') || n.endsWith('.docx')) {
      return Icons.description_rounded;
    }
    if (n.endsWith('.xls') || n.endsWith('.xlsx') || n.endsWith('.csv')) {
      return Icons.table_chart_rounded;
    }
    if (n.endsWith('.zip') || n.endsWith('.rar')) return Icons.folder_zip_rounded;
    if (n.endsWith('.mp3') || n.endsWith('.wav') || n.endsWith('.m4a')) {
      return Icons.audiotrack_rounded;
    }
    if (n.endsWith('.mp4') || n.endsWith('.mov')) return Icons.movie_rounded;
    return Icons.insert_drive_file_rounded;
  }

  Future<void> _openUrl(String url) async {
    try {
      final ok = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        showToast(context, 'Could not open file', type: ToastType.error);
      }
    } catch (_) {
      if (mounted) showToast(context, 'Could not open file', type: ToastType.error);
    }
  }

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
                if ((msg['message_type'] ?? 'text') == 'text' &&
                    msg['is_deleted'] != true)
                  _ActionTile(
                    icon: Icons.edit_rounded,
                    label: 'Edit',
                    onTap: () {
                      Navigator.pop(ctx);
                      _startEditing(msg);
                    },
                  ),
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

  // Parse the server reactions JSON ({"<uid>":"<emoji>"}) into a unique,
  // display-ready list of emojis.
  List<String> _reactionsOf(Map<String, dynamic> msg) {
    final raw = msg['reactions'];
    if (raw == null || (raw is String && raw.isEmpty)) return const [];
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is Map) {
        return decoded.values.map((e) => e.toString()).toSet().toList();
      }
    } catch (_) {}
    return const [];
  }

  // Toggle my reaction on a message: optimistic local update, then persist and
  // sync via the API (poll reconciles the peer's reactions).
  Future<void> _addReaction(Map<String, dynamic> msg, String emoji) async {
    final id = msg['id'];
    if (id == null) return;
    final myId = _myId;
    setState(() {
      Map<String, dynamic> map = {};
      try {
        final raw = msg['reactions'];
        if (raw is String && raw.isNotEmpty) {
          map = Map<String, dynamic>.from(jsonDecode(raw));
        }
      } catch (_) {}
      if (myId != null) {
        if (map[myId] == emoji) {
          map.remove(myId);
        } else {
          map[myId] = emoji;
        }
      }
      msg['reactions'] = map.isEmpty ? null : jsonEncode(map);
    });
    try {
      final updated = await ApiService()
          .reactToMessage(id is int ? id : int.parse(id.toString()), emoji);
      if (mounted && updated != null) {
        setState(() => msg['reactions'] = updated);
      }
    } catch (_) {
      // Poll will reconcile the true server state.
    }
  }

  // ── Edit in place ──────────────────────────────────────────────────────────

  void _startEditing(Map<String, dynamic> msg) {
    final raw = (msg['content'] as String?) ?? '';
    final lines = raw.split('\n');
    final qc = lines.takeWhile((l) => l.startsWith('> ')).length;
    // Keep any reply-quote prefix (quote lines + blank separator) so editing
    // only touches the actual message text.
    _editQuotePrefix = qc > 0 ? '${lines.take(qc + 1).join('\n')}\n' : '';
    final editable = qc > 0 ? lines.skip(qc + 1).join('\n') : raw;
    setState(() {
      _replyTo = null;
      _editing = msg;
      _showEmoji = false;
      _ctrl.text = editable;
      _ctrl.selection =
          TextSelection.fromPosition(TextPosition(offset: _ctrl.text.length));
    });
  }

  void _cancelEditing() {
    setState(() {
      _editing = null;
      _editQuotePrefix = '';
      _ctrl.clear();
    });
  }

  Future<void> _saveEdit() async {
    final editing = _editing;
    if (editing == null) return;
    final newText = _ctrl.text.trim();
    if (newText.isEmpty) return;
    final id = editing['id'];
    final newContent = '$_editQuotePrefix$newText';
    setState(() {
      final idx = _messages.indexWhere((m) => m['id'] == id);
      if (idx != -1) {
        _messages[idx]['content'] = newContent;
        _messages[idx]['edited'] = true;
      }
      _editing = null;
      _editQuotePrefix = '';
      _ctrl.clear();
    });
    try {
      await ApiService()
          .editMessage(id is int ? id : int.parse(id.toString()), newContent);
    } catch (_) {
      if (mounted) {
        showToast(context, "Couldn't edit message", type: ToastType.error);
      }
    }
  }

  // ── Jump to a quoted original ───────────────────────────────────────────────

  Map<String, dynamic>? _findQuotedMessage(String quoted) {
    final q = quoted.trim();
    if (q.isEmpty) return null;
    for (final m in _messages) {
      if (m['is_deleted'] == true) continue;
      final c = _stripQuote((m['content'] as String?) ?? '').trim();
      if (c.isNotEmpty && c == q) return m;
    }
    return null;
  }

  void _jumpToQuoted(String quoted) {
    final target = _findQuotedMessage(quoted);
    if (target == null) return;
    final ctx = _msgKeys[target['id'].toString()]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 320),
      alignment: 0.3,
      curve: Curves.easeInOut,
    );
    HapticFeedback.selectionClick();
    setState(() => _highlightedId = target['id'].toString());
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightedId = null);
    });
  }

  Future<void> _deleteMessage(int id, bool forAll) async {
    if (forAll) {
      // Optimistic tombstone: keep the bubble, blank its content.
      final backup = Map<String, dynamic>.from(
          _messages.firstWhere((m) => m['id'] == id));
      setState(() {
        final idx = _messages.indexWhere((m) => m['id'] == id);
        if (idx != -1) {
          _messages[idx]['is_deleted'] = true;
          _messages[idx]['content'] = '';
          _messages[idx]['message_type'] = 'text';
          _messages[idx]['media_url'] = null;
          _messages[idx]['reactions'] = null;
        }
      });
      try {
        await ApiService().deleteSingleMessage(id, deleteForAll: true);
        if (mounted) {
          showToast(context, 'Deleted for everyone', type: ToastType.info);
        }
      } catch (_) {
        if (mounted) {
          setState(() {
            final idx = _messages.indexWhere((m) => m['id'] == id);
            if (idx != -1) _messages[idx] = backup;
          });
        }
      }
      return;
    }
    // Delete for me: remove locally.
    final backup = Map<String, dynamic>.from(
        _messages.firstWhere((m) => m['id'] == id));
    setState(() => _messages.removeWhere((m) => m['id'] == id));
    try {
      await ApiService().deleteSingleMessage(id, deleteForAll: false);
      if (mounted) {
        showToast(context, 'Deleted for you', type: ToastType.info);
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

    // Tombstone: delete-for-everyone keeps the row but blanks its content.
    final tomb = msg['is_deleted'] == true;
    final reactions = tomb ? const <String>[] : _reactionsOf(msg);
    // Media attachment?
    final msgType = (msg['message_type'] as String?) ?? 'text';
    final mediaRel = msg['media_url'] as String?;
    final isMedia = !tomb &&
        msgType != 'text' && mediaRel != null && mediaRel.isNotEmpty;
    final emojiOnly =
        !tomb && !hasQuote && !isMedia && _isEmojiOnly(mainText);

    // ── Bubble colours ──────────────────────────────────────────────────────
    // Sent messages use the brand red family (not WhatsApp green): a soft warm
    // rose on light, a deep muted maroon on dark — both easy on the eyes and
    // clearly "mine". Received bubbles stay a clean neutral (white / charcoal).
    final sentBubble =
        isDark ? const Color(0xFF4C2328) : const Color(0xFFFBDCDB);
    final recvBubble =
        isDark ? const Color(0xFF241E20) : Colors.white;
    final bubbleColor = isMe ? sentBubble : recvBubble;
    // Warm near-white text on the dark maroon; deep maroon text on the rose.
    final onSent = isDark ? const Color(0xFFF6E1E1) : const Color(0xFF4A141A);
    final textColor = isMe ? onSent : scheme.onSurface;
    final quoteBarColor = isMe
        ? (isDark ? const Color(0xFFFF8A93) : scheme.primary)
        : scheme.primary;
    // Muted + "read" accent for the timestamp/ticks, tuned per bubble.
    final sentMuted = onSent.withAlpha(isDark ? 160 : 150);
    final sentRead =
        isDark ? const Color(0xFFFF8A93) : scheme.primary;
    // Delivery ticks: neutral gray while sent/delivered, brand red once read.
    final tickGray =
        isDark ? const Color(0xFFB3ACAE) : const Color(0xFF8C8A8E);
    // Subtle border to lift each bubble off the wallpaper.
    final bubbleBorder = isMe
        ? (isDark
            ? Colors.white.withAlpha(16)
            : scheme.primary.withAlpha(46))
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

    final msgId = msg['id'].toString();
    final key = _msgKeys.putIfAbsent(msgId, () => GlobalKey());
    return AnimatedContainer(
      key: key,
      duration: const Duration(milliseconds: 300),
      color: _highlightedId == msgId
          ? scheme.primary.withAlpha(30)
          : Colors.transparent,
      padding: EdgeInsets.only(
        top: topPad,
        left: isMe ? 56 : 6,
        right: isMe ? 6 : 56,
      ),
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          _SwipeToReply(
            isMe: isMe,
            onReply: () {
              HapticFeedback.selectionClick();
              setState(() => _replyTo = msg);
              FocusScope.of(context).requestFocus(FocusNode());
            },
            child: GestureDetector(
              onLongPress: () => _showMessageMenu(context, msg),
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
                        // ── Deleted tombstone ─────────────────────────
                        if (tomb)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.do_not_disturb_alt_rounded,
                                  size: 15, color: textColor.withAlpha(120)),
                              const SizedBox(width: 6),
                              Text(
                                'This message was deleted',
                                style: TextStyle(
                                  color: textColor.withAlpha(160),
                                  fontStyle: FontStyle.italic,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                        // ── Quoted reply (tap to jump to original) ─────
                        if (!tomb && quotedText != null)
                          GestureDetector(
                            onTap: () => _jumpToQuoted(quotedText!),
                            child: Container(
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
                          ),

                        // ── Message body (media and/or text) ──────────
                        if (isMedia)
                          _mediaContent(
                              msgType, mediaRel!, msg, isMe, textColor, scheme),
                        if (!tomb && mainText.trim().isNotEmpty)
                          Padding(
                            padding: EdgeInsets.only(top: isMedia ? 6 : 0),
                            child: Text(
                              mainText,
                              style: TextStyle(
                                color: textColor,
                                fontSize: 15,
                                height: 1.38,
                              ),
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
                                if (msg['edited'] == true && !tomb) ...[
                                  Text(
                                    'edited',
                                    style: TextStyle(
                                      fontSize: 9.5,
                                      fontStyle: FontStyle.italic,
                                      color: isMe
                                          ? sentMuted
                                          : scheme.onSurface.withAlpha(110),
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                ],
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
                                      muted: tickGray, read: sentRead),
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

  Widget _buildEditBanner() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(left: BorderSide(color: scheme.primary, width: 3)),
      ),
      child: Row(
        children: [
          Icon(Icons.edit_rounded, size: 15, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Editing message',
                  style: TextStyle(
                    color: scheme.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  _stripQuote((_editing?['content'] as String?) ?? ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: scheme.onSurface.withAlpha(160), fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            onPressed: _cancelEditing,
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
          if (_editing != null) _buildEditBanner(),
          if (_replyTo != null) _buildReplyPreview(_replyTo!),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: _isRecording
                ? _buildRecordingBar(scheme)
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // Rounded input field: emoji · text · attach · camera.
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
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
                              // Text field. Desktop: Enter=send, Shift+Enter=newline.
                              Expanded(
                                child: Focus(
                                  onKeyEvent: (node, event) {
                                    if (event is KeyDownEvent &&
                                        event.logicalKey ==
                                            LogicalKeyboardKey.enter &&
                                        !HardwareKeyboard
                                            .instance.isShiftPressed &&
                                        !HardwareKeyboard
                                            .instance.isControlPressed) {
                                      if (_ctrl.text.trim().isNotEmpty) {
                                        if (_editing != null) {
                                          _saveEdit();
                                        } else {
                                          _sendMessage();
                                        }
                                      }
                                      return KeyEventResult.handled;
                                    }
                                    return KeyEventResult.ignored;
                                  },
                                  child: TextField(
                                    controller: _ctrl,
                                    minLines: 1,
                                    maxLines: 5,
                                    textInputAction: TextInputAction.newline,
                                    keyboardType: TextInputType.multiline,
                                    decoration: InputDecoration(
                                      // Desktop keyboards benefit from the
                                      // Shift+Enter hint; on mobile it just
                                      // clutters the compact field, so there
                                      // we show a plain "Message" placeholder.
                                      hintText: (defaultTargetPlatform ==
                                                  TargetPlatform.windows ||
                                              defaultTargetPlatform ==
                                                  TargetPlatform.macOS ||
                                              defaultTargetPlatform ==
                                                  TargetPlatform.linux)
                                          ? 'Message   (Shift+Enter for new line)'
                                          : 'Message',
                                      isDense: true,
                                      border: InputBorder.none,
                                      contentPadding: const EdgeInsets.symmetric(
                                          vertical: 10),
                                    ),
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Attach',
                                icon: Icon(Icons.attach_file_rounded,
                                    color: scheme.onSurfaceVariant),
                                onPressed:
                                    _uploadingMedia ? null : _openAttachSheet,
                                visualDensity: VisualDensity.compact,
                              ),
                              IconButton(
                                tooltip: 'Camera',
                                icon: Icon(Icons.camera_alt_rounded,
                                    color: scheme.onSurfaceVariant),
                                onPressed: _uploadingMedia
                                    ? null
                                    : () => _pickImage(ImageSource.camera),
                                visualDensity: VisualDensity.compact,
                              ),
                              const SizedBox(width: 4),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      // Mic (idle) ↔ Send (typing). Uploading shows a spinner.
                      // Sized to match the input pill so the two read as one
                      // unit. The idle mic wears only a faint brand tint (soft
                      // pink fill + red icon) so it complements — rather than
                      // competes with — the solid-red player FAB in the footer.
                      // Send is an action, so it keeps the solid red for
                      // emphasis while the user is typing.
                      _uploadingMedia
                          ? const SizedBox(
                              width: 42,
                              height: 42,
                              child: Padding(
                                padding: EdgeInsets.all(11),
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            )
                          : Tooltip(
                              message: hasText
                                  ? (_editing != null ? 'Save edit' : 'Send')
                                  : 'Record voice note',
                              child: GestureDetector(
                                onTap: hasText
                                    ? (_editing != null
                                        ? _saveEdit
                                        : _sendMessage)
                                    : _startRecording,
                                child: Container(
                                  width: 42,
                                  height: 42,
                                  decoration: BoxDecoration(
                                    color: hasText
                                        ? scheme.primary
                                        : scheme.primary
                                            .withAlpha(isDark ? 48 : 30),
                                    shape: BoxShape.circle,
                                    border: hasText
                                        ? null
                                        : Border.all(
                                            color: scheme.primary
                                                .withAlpha(isDark ? 90 : 64),
                                            width: 1,
                                          ),
                                  ),
                                  child: Icon(
                                    hasText
                                        ? Icons.send_rounded
                                        : Icons.mic_rounded,
                                    color: hasText
                                        ? Colors.white
                                        : (isDark
                                            ? const Color(0xFFFF8A93)
                                            : scheme.primary),
                                    size: 20,
                                  ),
                                ),
                              ),
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
                      // Tapping the conversation drops the text-field focus so
                      // the cursor leaves and the keyboard slides away smoothly,
                      // and closes the emoji sheet.
                      onTap: () {
                        FocusScope.of(context).unfocus();
                        setState(() => _showEmoji = false);
                      },
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

                          // In a reversed list, older messages sit ABOVE newer
                          // ones and each item lays its Column out top→bottom.
                          // The separator marks the boundary between this
                          // (newer) message and the older one below it in the
                          // data, so it must render ABOVE this bubble — i.e.
                          // FIRST in the Column — otherwise "Today" appears
                          // beneath the first message of the day and that
                          // message looks grouped under "Yesterday".
                          return Column(
                            children: [
                              if (showDate)
                                _buildDateSeparator(dateLabel),
                              _buildBubble(msg, isMe, isDark, showAvatar,
                                  isFirst, showTail),
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
            tooltip: 'Call ${widget.friendName}',
            icon: const Icon(Icons.call_rounded),
            onPressed: _callFriend,
          ),
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

// ─── Voice note player ───────────────────────────────────────────────────────
/// Plays a voice note from a remote URL on demand (lazy-loads on first tap so
/// the chat list stays light). Shows a play/pause button, a progress bar and
/// the elapsed / total time.
class _VoiceNotePlayer extends StatefulWidget {
  const _VoiceNotePlayer({
    required this.url,
    required this.durationMs,
    required this.accent,
    required this.onColor,
  });

  final String url;
  final int durationMs;
  final Color accent;
  final Color onColor;

  @override
  State<_VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<_VoiceNotePlayer> {
  final ja.AudioPlayer _player = ja.AudioPlayer();
  bool _prepared = false;
  bool _loading = false;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  StreamSubscription? _posSub;
  StreamSubscription? _stateSub;

  @override
  void initState() {
    super.initState();
    _dur = Duration(milliseconds: widget.durationMs);
    _posSub = _player.positionStream.listen((p) {
      if (mounted) setState(() => _pos = p);
    });
    _stateSub = _player.playerStateStream.listen((s) {
      if (!mounted) return;
      if (s.processingState == ja.ProcessingState.completed) {
        _player.pause();
        _player.seek(Duration.zero);
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (!_prepared) {
      setState(() => _loading = true);
      try {
        final d = await _player.setUrl(widget.url);
        if (d != null && mounted) _dur = d;
        _prepared = true;
      } catch (_) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      if (mounted) setState(() => _loading = false);
    }
    if (_player.playing) {
      await _player.pause();
    } else {
      if (_player.processingState == ja.ProcessingState.completed) {
        await _player.seek(Duration.zero);
      }
      await _player.play();
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final playing = _player.playing;
    final total =
        _dur.inMilliseconds > 0 ? _dur.inMilliseconds : widget.durationMs;
    final frac =
        total > 0 ? (_pos.inMilliseconds / total).clamp(0.0, 1.0) : 0.0;
    final label = (playing || _pos > Duration.zero) ? _pos : _dur;
    return SizedBox(
      width: 216,
      child: Row(
        children: [
          GestureDetector(
            onTap: _toggle,
            child: Container(
              width: 38,
              height: 38,
              decoration:
                  BoxDecoration(color: widget.accent, shape: BoxShape.circle),
              child: _loading
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: Colors.white, size: 22),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: widget.onColor.withAlpha(45),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    FractionallySizedBox(
                      widthFactor: frac == 0 ? 0.001 : frac,
                      child: Container(
                        height: 4,
                        decoration: BoxDecoration(
                          color: widget.accent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Icon(Icons.mic_rounded,
                        size: 12, color: widget.onColor.withAlpha(150)),
                    const SizedBox(width: 3),
                    Text(_fmt(label),
                        style: TextStyle(
                            fontSize: 10.5,
                            color: widget.onColor.withAlpha(165))),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// WhatsApp-style swipe-to-reply. The bubble follows the finger to the right,
/// a reply glyph fades and scales in from the left edge, a single haptic fires
/// when the trigger distance is crossed, and on release the bubble springs
/// smoothly back to rest (instead of the old snap/on-off behaviour). If the
/// pull passed the trigger, [onReply] is invoked.
class _SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback onReply;
  final bool isMe;

  const _SwipeToReply({
    required this.child,
    required this.onReply,
    required this.isMe,
  });

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply>
    with SingleTickerProviderStateMixin {
  static const double _maxDrag = 72;
  static const double _trigger = 50;

  late final AnimationController _spring;
  Animation<double>? _springAnim;
  double _dx = 0;
  bool _armed = false;

  @override
  void initState() {
    super.initState();
    _spring = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    )..addListener(() {
        if (_springAnim != null) setState(() => _dx = _springAnim!.value);
      });
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  void _settle() {
    _springAnim = Tween<double>(begin: _dx, end: 0).animate(
      CurvedAnimation(parent: _spring, curve: Curves.easeOutCubic),
    );
    _spring
      ..reset()
      ..forward();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final progress = (_dx / _trigger).clamp(0.0, 1.0);

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: (d) {
        // Reply is a rightward pull only; resist and cap the travel.
        final next = (_dx + d.delta.dx).clamp(0.0, _maxDrag);
        if (!_armed && next >= _trigger) {
          _armed = true;
          HapticFeedback.selectionClick();
        } else if (_armed && next < _trigger) {
          _armed = false;
        }
        setState(() => _dx = next);
      },
      onHorizontalDragEnd: (_) {
        if (_dx >= _trigger) widget.onReply();
        _armed = false;
        _settle();
      },
      onHorizontalDragCancel: () {
        _armed = false;
        _settle();
      },
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          Positioned(
            left: 14,
            child: Opacity(
              opacity: progress,
              child: Transform.scale(
                scale: 0.5 + 0.5 * progress,
                child: Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: scheme.primary.withAlpha(30),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.reply_rounded,
                      size: 18, color: scheme.primary),
                ),
              ),
            ),
          ),
          Transform.translate(
            offset: Offset(_dx, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}
