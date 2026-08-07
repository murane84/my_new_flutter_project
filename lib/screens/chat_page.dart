import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
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
import 'gif_picker.dart';
import '../services/call_service.dart';
import 'home_page.dart' show playlistNotifier, playbackBus;
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
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
  final String friendAvatar;
  final Color textColor;
  final bool showAppBar;
  final Function(bool, String?)? onFriendOnlineStatusChanged;

  const ChatPage({
    super.key,
    required this.friendId,
    required this.friendName,
    this.friendAvatar = '',
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
  String _friendAvatar = '';
  String _myName = '';
  String? _myAvatar;
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
  // Dedicated controller so the Listen-together picker's scrollbar can auto-hide
  // (show only while scrolling) instead of sitting over the row icons.
  final _pickerScrollCtrl = ScrollController();
  bool _showEmoji = false;
  // Which tab is showing in the emoji panel: 0 = emoji, 1 = GIF stickers.
  int _emojiTab = 0;
  bool _isAtBottom = true;
  bool _hasNewMsg = false;

  Timer? _statusTimer;
  // Debounces persisting the message cache after bursts of realtime WS updates
  // (delivered/read ticks, reactions) so we don't hammer storage on every event.
  Timer? _cacheSaveTimer;
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
    // Seed the friend's avatar from the caller (which already knows it, e.g.
    // the friend list / header) so the per-message bubble avatars show the DP
    // immediately; the /status poll may later refresh it.
    _friendAvatar = widget.friendAvatar;
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
      onConnected: _onWsConnected,
      onDisconnected: _onWsGaveUp,
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
    _cacheSaveTimer?.cancel();
    _typingTimer?.cancel();
    _keepAliveTimer?.cancel();
    _connectivitySub?.cancel();
    _recordTimer?.cancel();
    _recorder.dispose();
    _ctrl.dispose();
    _scrollCtrl.dispose();
    _pickerScrollCtrl.dispose();
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Coming back to the foreground: the OS may have frozen or dropped the
    // socket while backgrounded, so any events in that window were missed.
    _markActivity();
    if (_ws.isConnected) {
      // Socket survived → just catch up.
      _reconcile();
    } else {
      // Socket is down → revive it; its onConnected fires _reconcile for us,
      // so we don't double-fetch here.
      _ws.ensureConnected();
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
    _myName = (user['username'] ?? '').toString();
    _myAvatar = (user['avatar_url'] as String?)?.trim();

    await _loadCachedMessages(); // show cached messages instantly
    await _loadMessages();        // then fetch fresh from network
    _checkOnlineStatus();
    _startKeepAlive();
    _startConnectivityWatch();

    if (_myId?.isNotEmpty == true) {
      // Close any prior socket (the initState placeholder, or the previous
      // friend's socket when the thread changes) so we never leave a stray
      // connection alive in the background.
      _ws.close();
      _ws = WebSocketManager(
        userId: _myId!,
        onEventReceived: _handleWsEvent,
        // On every (re)connect, run one reconciliation fetch to close any gap
        // between the last event we saw and the socket coming (back) up.
        onConnected: _onWsConnected,
        onDisconnected: _onWsGaveUp,
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
        skip: 0, limit: _reconcileLimit,
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

  // ── Realtime lifecycle ────────────────────────────────────────────────────
  //
  // The WebSocket is the single source of truth for live updates. We no longer
  // poll every 2s; instead we run ONE reconciliation fetch whenever the realtime
  // link is (re)established or the app returns to the foreground. See _reconcile.

  void _onWsConnected() {
    // The socket just came (back) up. Events that fired while it was down were
    // never delivered, so do a single catch-up fetch, then trust WS events.
    _reconcile();
  }

  void _onWsGaveUp() {
    // The manager exhausted its internal retries (a prolonged outage). Don't
    // fall back to tight polling — the 60s keepalive, the connectivity watcher,
    // and app-resume all call _ws.ensureConnected() to revive the socket, and
    // each successful revive triggers _onWsConnected → _reconcile.
    if (mounted) setState(() => _isReconnecting = false);
  }

  // Persist the cache shortly after a burst of WS updates settles, instead of
  // writing on every single delivered/read/reaction event.
  void _scheduleCacheSave() {
    _cacheSaveTimer?.cancel();
    _cacheSaveTimer =
        Timer(const Duration(milliseconds: 500), _saveMessagesCache);
  }

  // ── Keepalive: ping the server every 60s while chat is open and active ──
  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
      if (!mounted) return;
      // Cheap no-op if the socket is healthy; revives it if a prolonged outage
      // made the manager give up. This is the safety net that keeps realtime
      // alive without a 2s poll.
      _ws.ensureConnected();
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
      // Bring the realtime socket back if it had given up; a successful revive
      // also fires _onWsConnected → _reconcile. We still do an explicit fetch
      // below so the "N new messages" toast is accurate on this manual path.
      _ws.ensureConnected();

      // Fetch any messages that arrived while offline
      final uid = int.tryParse(_myId ?? '');
      if (uid != null) {
        final fresh = await ApiService().fetchMessagesBetween(
          uid, widget.friendId, skip: 0, limit: _reconcileLimit);
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

  // How many recent messages a reconciliation fetch pulls. Sized to the WHOLE
  // currently-loaded window rather than a fixed 60, so status changes (edited /
  // reaction / read / delivered / tombstone) on ANY loaded message reconcile
  // after the socket was down — not just the newest 60. Safe because the
  // endpoint returns newest-first and the loaded list is always the newest
  // contiguous run: fetching this many refreshes exactly what's already loaded
  // (plus any brand-new messages) and never pulls older history into view.
  // Floored at 60 (initial page size) and capped so a marathon session can't
  // trigger a pathologically large fetch.
  int get _reconcileLimit {
    final n = _messages.length;
    if (n < 60) return 60;
    if (n > 300) return 300;
    return n;
  }

  // Reconciliation fetch. Runs on (re)connect and app-resume — NOT on a timer.
  //
  // Usually a SINGLE fetch: pull the loaded window, merge it over the current
  // list (so status changes — is_read/delivered/edited/reactions/tombstones —
  // are picked up) and mark anything freshly received as delivered/read.
  //
  // The one wrinkle: if messages arrived while the socket was down, that first
  // fetch spends part of its window on those new arrivals and may not reach the
  // oldest loaded messages, leaving their status stale for a cycle. So when a
  // pass ADDS messages (the window shifted), we run one more — the window is now
  // sized to include them, so the stragglers get refreshed immediately instead
  // of waiting for the next reconnect. Bounded so a burst of live traffic during
  // reconnect can't loop us indefinitely; the WS delivers the rest live anyway.
  Future<void> _reconcile() async {
    for (var pass = 0; pass < 3; pass++) {
      final addedNew = await _reconcileOnce();
      if (!addedNew) break; // window fully covered → nothing left to catch up
    }
  }

  // A single reconciliation fetch+merge+mark. Returns true iff it ADDED new
  // messages to the list (which means the window shifted and a follow-up pass
  // should refresh any now-uncovered stragglers).
  Future<bool> _reconcileOnce() async {
    final uid = int.tryParse(_myId ?? '');
    if (uid == null) return false;

    List<Map<String, dynamic>> fetched;
    try {
      fetched = await ApiService().fetchMessagesBetween(
        uid, widget.friendId,
        skip: 0, limit: _reconcileLimit,
      );
    } catch (_) {
      // A single fetch failure is not proof the whole server is down — leave the
      // connection status to the app-wide heartbeat so indicators stay in sync.
      return false;
    }
    if (fetched.isEmpty || !mounted) return false;

    final before = _messages.length;
    final merged = _merge(_messages, fetched, markRead: _isAtBottom);
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

    return _messages.length > before;
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
        ex['pinned_until'] = m['pinned_until'];
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
          a[i]['pinned_until'] != b[i]['pinned_until'] ||
          a[i]['reactions'] != b[i]['reactions']) { return false; }
    }
    return true;
  }

  // ── WebSocket events ──────────────────────────────────────────────────────

  void _handleWsEvent(Map<String, dynamic> event) {
    final type = event['type'];
    if (!mounted) return;

    if (type == 'new_message' || type == 'message_sent') {
      // The server sends the serialized message under 'data' (older builds used
      // 'message' — accept either so a version skew never drops messages).
      // 'new_message' is the peer's message to us; 'message_sent' is our own
      // copy echoed back, normally already inserted optimistically by the send
      // path, so the upsert below just dedupes it.
      final msg = (event['data'] ?? event['message']) as Map<String, dynamic>?;
      if (msg == null) return;

      // Scope to THIS conversation. The per-user socket also carries events for
      // our OTHER threads, and these two types INSERT, so without this guard a
      // message from a different chat would leak into this list.
      final sender = msg['sender_id']?.toString();
      final receiver = msg['receiver_id']?.toString();
      final fid = widget.friendId.toString();
      final inThisThread = (sender == fid && receiver == _myId) ||
          (sender == _myId && receiver == fid);
      if (!inThisThread) return;

      final id = msg['id'].toString();
      final incoming = type == 'new_message';
      final existed = _messages.any((m) => m['id'].toString() == id);
      if (!existed) {
        setState(() => _messages.insert(0, msg));
      }

      if (incoming && !existed &&
          msg['receiver_id'].toString() == _myId &&
          msg['delivered'] == false) {
        // We now hold the message without ever hitting the fetch endpoint that
        // auto-marks delivery, so mark it explicitly. The server then emits
        // message_delivered back to the sender → their tick turns double.
        ApiService().markMessageAsDelivered(msg['id']);
      }

      if (_isAtBottom) {
        _scrollToBottom();
        if (incoming) ApiService().markMessagesAsReadPatch(widget.friendId);
      } else if (incoming) {
        setState(() => _hasNewMsg = true);
      }
      _scheduleCacheSave();
    } else if (type == 'message_delivered') {
      // Server marks our message delivered once the friend fetches it → the
      // single tick becomes a double (gray) tick.
      final data = event['data'] as Map<String, dynamic>?;
      final mid = data?['id'];
      if (mid != null) {
        setState(() {
          final idx = _messages.indexWhere((m) => m['id'] == mid);
          if (idx != -1) _messages[idx]['delivered'] = true;
        });
        _scheduleCacheSave();
      }
    } else if (type == 'messages_read') {
      // Friend opened the thread and read our messages → flip the double ticks
      // from gray to red. Server sends the batch of read message_ids.
      final data = event['data'] as Map<String, dynamic>?;
      final ids = (data?['message_ids'] as List?)
              ?.map((e) => e.toString())
              .toSet() ??
          <String>{};
      if (ids.isNotEmpty) {
        setState(() {
          for (final m in _messages) {
            if (ids.contains(m['id'].toString())) {
              m['is_read'] = true;
              m['delivered'] = true;
            }
          }
        });
        _scheduleCacheSave();
      }
    } else if (type == 'message_edited') {
      // Sender edited a text message → update the body in place and flag it
      // edited. Payload is the full serialized message under 'data'.
      final data = event['data'] as Map<String, dynamic>?;
      final id = data?['id'];
      if (id != null) {
        setState(() {
          final idx = _messages.indexWhere((m) => m['id'] == id);
          if (idx != -1) {
            _messages[idx]['content'] = data?['content'];
            _messages[idx]['edited'] = true;
          }
        });
        _scheduleCacheSave();
      }
    } else if (type == 'message_reaction') {
      // Peer reacted or cleared a reaction → replace the message's reactions
      // blob (a JSON string, or null when empty), matching what the API and the
      // reconcile merge store, so _reactionsOf renders it identically.
      final data = event['data'] as Map<String, dynamic>?;
      final mid = data?['message_id'];
      if (mid != null) {
        setState(() {
          final idx = _messages.indexWhere((m) => m['id'] == mid);
          if (idx != -1) _messages[idx]['reactions'] = data?['reactions'];
        });
        _scheduleCacheSave();
      }
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
      _scheduleCacheSave();
    } else if (type == 'message_pinned') {
      // The other participant pinned a message. Single active pin per
      // conversation, so clear any others, then mark this one.
      final data = event['data'] as Map<String, dynamic>?;
      final mid = data?['id'];
      if (mid != null) {
        setState(() {
          for (final m in _messages) {
            m['pinned_until'] = null;
          }
          final idx = _messages.indexWhere((m) => m['id'] == mid);
          if (idx != -1) {
            _messages[idx]['pinned_until'] = data?['pinned_until'];
          }
        });
        _scheduleCacheSave();
      }
    } else if (type == 'message_unpinned') {
      final data = event['data'] as Map<String, dynamic>?;
      final mid = data?['message_id'];
      if (mid != null) {
        setState(() {
          final idx = _messages.indexWhere((m) => m['id'] == mid);
          if (idx != -1) _messages[idx]['pinned_until'] = null;
        });
        _scheduleCacheSave();
      }
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
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: scheme.primary.withAlpha(130)),
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
                    child: ScrollConfiguration(
                      // Drop the always-on desktop scrollbar and use one that
                      // fades out shortly after scrolling stops, so it never
                      // sits over the row's broadcast icons.
                      behavior: ScrollConfiguration.of(ctx)
                          .copyWith(scrollbars: false),
                      child: Scrollbar(
                        controller: _pickerScrollCtrl,
                        thumbVisibility: false,
                        child: ListView.builder(
                      controller: _pickerScrollCtrl,
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(top: 6, bottom: 6, right: 8),
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
    final avatar = (status['avatar_url'] as String?) ?? '';
    // Only override the seeded avatar when /status actually returns one, so we
    // never blank out a DP the caller already supplied.
    if (avatar.isNotEmpty && avatar != _friendAvatar && mounted) {
      setState(() => _friendAvatar = avatar);
    }
    if (online != _isFriendOnline || lastSeen != _lastSeen) {
      setState(() {
        _isFriendOnline = online;
        _lastSeen = lastSeen;
      });
      widget.onFriendOnlineStatusChanged?.call(online, lastSeen);
    }
  }

  /// Ask whether to call over the internet (Aluta) or via the device dialer.
  void _showCallChoice() {
    final scheme = Theme.of(context).colorScheme;
    final online = ConnectionStatus.instance.isOnline;
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
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: Text('Call ${widget.friendName}',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface)),
              ),
              const Divider(height: 1),
              _ActionTile(
                icon: Icons.wifi_calling_3_rounded,
                label: online
                    ? 'Aluta call (over the internet)'
                    : 'Aluta call — you’re offline',
                color: online ? scheme.primary : scheme.onSurfaceVariant,
                onTap: () {
                  Navigator.pop(ctx);
                  _startAlutaCall();
                },
              ),
              _ActionTile(
                icon: Icons.phone_rounded,
                label: 'Phone call (uses your carrier)',
                onTap: () {
                  Navigator.pop(ctx);
                  _callFriend();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// Start an in-app WebRTC voice call. If we're offline, fall back to the
  /// device dialer, honouring "out of service → normal call".
  Future<void> _startAlutaCall() async {
    if (!ConnectionStatus.instance.isOnline) {
      if (mounted) {
        showToast(context, 'No internet — starting a phone call instead',
            type: ToastType.info);
      }
      _callFriend();
      return;
    }
    final myId = int.tryParse(_myId ?? '');
    if (myId == null) {
      if (mounted) {
        showToast(context, 'Please wait — still signing you in…',
            type: ToastType.error);
      }
      return;
    }
    final ok = await CallService.instance.startCall(
      peerId: widget.friendId,
      peerName: widget.friendName,
      peerAvatar: _friendAvatar,
      myName: _myName.isNotEmpty ? _myName : 'Aluta user',
      myAvatar: _myAvatar,
      fallbackPhone: _friendPhone,
    );
    if (!ok && mounted) {
      showToast(context, 'You’re already in a call', type: ToastType.info);
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

  // ── Forward a message to another contact ──────────────────────────────────
  Future<void> _showForwardPicker(Map<String, dynamic> msg) async {
    List<Map<String, dynamic>> friends;
    try {
      friends = await ApiService().getFriends();
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not load contacts', type: ToastType.error);
      }
      return;
    }
    // Don't offer to forward to yourself.
    friends =
        friends.where((f) => f['id'].toString() != _myId).toList();
    if (!mounted) return;
    if (friends.isEmpty) {
      showToast(context, 'No contacts to forward to', type: ToastType.info);
      return;
    }
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(10),
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.6),
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
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Forward to',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface)),
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: friends.length,
                  itemBuilder: (_, i) {
                    final f = friends[i];
                    final name = (f['username'] ?? 'Friend').toString();
                    final rawA = f['avatar_url'] as String?;
                    final avatarUrl =
                        (rawA != null && rawA.isNotEmpty) ? fullMediaUrl(rawA) : null;
                    return ListTile(
                      leading: CircleAvatar(
                        radius: 20,
                        backgroundColor: scheme.primary.withAlpha(38),
                        backgroundImage: avatarUrl != null
                            ? CachedNetworkImageProvider(avatarUrl)
                            : null,
                        child: avatarUrl == null
                            ? Text(
                                name.isNotEmpty ? name[0].toUpperCase() : '?',
                                style: TextStyle(color: scheme.primary))
                            : null,
                      ),
                      title: Text(name),
                      onTap: () {
                        Navigator.pop(ctx);
                        _forwardTo(msg, f);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _forwardTo(
      Map<String, dynamic> msg, Map<String, dynamic> friend) async {
    final fid = friend['id'];
    final fidInt = fid is int ? fid : int.tryParse(fid.toString());
    if (fidInt == null) return;
    final type = (msg['message_type'] as String?) ?? 'text';
    final content = _stripQuote((msg['content'] as String?) ?? '');
    try {
      final sent = await ApiService().sendMessage(
        fidInt,
        content,
        messageType: type,
        mediaUrl: msg['media_url'] as String?,
        mediaName: msg['media_name'] as String?,
        mediaMime: msg['media_mime'] as String?,
        mediaSize: (msg['media_size'] as num?)?.toInt(),
        mediaDuration: (msg['media_duration'] as num?)?.toInt(),
      );
      if (!mounted) return;
      if (sent != null) {
        showToast(context, 'Forwarded to ${friend['username'] ?? 'contact'}',
            type: ToastType.success);
        // If forwarding into the currently-open thread, show it immediately.
        if (fidInt == widget.friendId) {
          setState(() {
            if (!_messages.any((m) => m['id'] == sent['id'])) {
              _messages.insert(0, sent);
            }
          });
          _scrollToBottom();
          _saveMessagesCache();
        }
      } else {
        showToast(context, 'Could not forward', type: ToastType.error);
      }
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not forward', type: ToastType.error);
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
      final quoted = _replyQuoteText(_replyTo!);
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
  /// Build a full URL from a relative attachment path (`/attachments/<id>`).
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

  /// Send a GIF sticker chosen from the GIF tab. The GIF lives on GIPHY's CDN,
  /// so we send its remote URL as an image message — no upload needed, and the
  /// bubble's CachedNetworkImage animates it. Closes the panel afterwards.
  Future<void> _sendGif(String url) async {
    setState(() => _showEmoji = false);
    try {
      final sent = await ApiService().sendMessage(
        widget.friendId,
        '',
        messageType: 'image',
        mediaUrl: url,
        mediaName: 'sticker.gif',
        mediaMime: 'image/gif',
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
        showToast(context, 'Could not send GIF', type: ToastType.error);
      }
    } catch (_) {
      if (mounted) showToast(context, 'Could not send GIF', type: ToastType.error);
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final x = await ImagePicker()
          .pickImage(source: source, imageQuality: 74, maxWidth: 1600);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      await _previewAndSendImage(bytes, x.name, 'image/jpeg');
    } catch (_) {
      if (mounted) showToast(context, 'Could not pick image', type: ToastType.error);
    }
  }

  /// Show a full-screen preview of the picked image with a caption box, so the
  /// user can add a message and send image + text as ONE bubble. Returns
  /// without sending if the user backs out of the preview.
  Future<void> _previewAndSendImage(
      Uint8List bytes, String filename, String mime) async {
    if (!mounted) return;
    final result = await Navigator.of(context).push<Map<String, dynamic>?>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _ImagePreviewScreen(
          imageBytes: bytes,
          friendName: widget.friendName,
        ),
      ),
    );
    // null → the user cancelled/backed out. Otherwise the map carries the
    // (possibly annotated) bytes, its mime, and the caption.
    if (result == null || !mounted) return;
    final outBytes = (result['bytes'] as Uint8List?) ?? bytes;
    final outMime = (result['mime'] as String?) ?? mime;
    final caption = ((result['caption'] as String?) ?? '').trim();
    // If the editor flattened to PNG, make the filename match so the server
    // stores the right extension/content-type.
    var outName = filename;
    if (outMime == 'image/png' && !outName.toLowerCase().endsWith('.png')) {
      final dot = outName.lastIndexOf('.');
      outName = '${dot > 0 ? outName.substring(0, dot) : outName}.png';
    }
    await _uploadAndSend(
      bytes: outBytes,
      filename: outName,
      mime: outMime,
      type: 'image',
      caption: caption,
    );
  }

  Future<void> _pickDocument() async {
    try {
      final res = await FilePicker.pickFiles();
      if (res == null || res.files.isEmpty) return;
      final f = res.files.first;
      // readAsBytes() supersedes the deprecated withData/.bytes pair: it reads
      // from the file path on native (no eager whole-file load) while still
      // returning the in-memory bytes on web. A read failure throws and is
      // caught by the surrounding try/catch below.
      final bytes = await f.readAsBytes();
      final ext = (f.extension ?? '').toLowerCase();
      const imgExt = ['jpg', 'jpeg', 'png', 'gif', 'webp'];
      if (imgExt.contains(ext)) {
        // Images get the caption preview too, so a document-picked photo can
        // still be sent with a message in a single bubble.
        await _previewAndSendImage(bytes, f.name, _mimeForExt(ext));
      } else {
        await _uploadAndSend(
          bytes: bytes,
          filename: f.name,
          mime: _mimeForExt(ext),
          type: 'file',
        );
      }
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
    if (mounted) {
      setState(() {
      _isRecording = false;
      _recordMs = 0;
    });
    }
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
    String caption = '',
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
        // Caption travels as the message content, so an image + text render in
        // ONE bubble (the bubble builder shows the image, then this text below).
        caption,
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
            placeholder: (_, _) => Container(
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
            errorWidget: (_, _, _) => Container(
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
              // Dark translucent disc behind the icon so it stays visible over
              // light/white images (a bare white icon vanished on them).
              style: IconButton.styleFrom(
                backgroundColor: Colors.black.withAlpha(115),
              ),
              icon: const Icon(Icons.close_rounded, color: Colors.white),
              onPressed: () => Navigator.pop(ctx),
            ),
          ),
          Positioned(
            top: 40,
            left: 12,
            child: IconButton(
              tooltip: 'Save image',
              style: IconButton.styleFrom(
                backgroundColor: Colors.black.withAlpha(115),
              ),
              icon: const Icon(Icons.download_rounded, color: Colors.white),
              onPressed: () => _saveImage(url),
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

  /// Download a shared image and hand it to the system sheet so the user can
  /// save it to their gallery / Files. Reused by the image viewer's Save button.
  Future<void> _saveImage(String url) async {
    try {
      if (mounted) showToast(context, 'Downloading…');
      final res = await http.get(Uri.parse(url));
      if (res.statusCode != 200) {
        if (mounted) showToast(context, 'Download failed', type: ToastType.error);
        return;
      }
      // Derive a sensible filename + extension from the URL.
      var name = Uri.parse(url).pathSegments.isNotEmpty
          ? Uri.parse(url).pathSegments.last
          : '';
      if (name.isEmpty || !name.contains('.')) {
        name = 'aluta_image_${DateTime.now().millisecondsSinceEpoch}.jpg';
      }
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(res.bodyBytes, flush: true);
      await SharePlus.instance
          .share(ShareParams(files: [XFile(file.path)]));
    } catch (_) {
      if (mounted) showToast(context, 'Could not save image', type: ToastType.error);
    }
  }

  // ── Message actions ───────────────────────────────────────────────────────

  void _showMessageMenu(BuildContext context, Map<String, dynamic> msg) {
    final isMe = msg['sender_id'].toString() == _myId;
    final content = msg['content'] as String? ?? '';
    final scheme = Theme.of(context).colorScheme;
    // A tombstone (deleted for everyone, or locally deleted for me) has no
    // content to react to / reply to / edit — gate those actions off.
    final deleted = msg['is_deleted'] == true || msg['deleted_for_me'] == true;

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
              // Quick emoji reactions + a "+" that opens the FULL emoji picker
              // so any emoji can be used as a reaction, not just these six.
              if (!deleted)
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ...['👍', '❤️', '😂', '😮', '😢', '🙏'].map((e) {
                        return GestureDetector(
                          onTap: () {
                            Navigator.pop(ctx);
                            _addReaction(msg, e);
                          },
                          child: Text(e, style: const TextStyle(fontSize: 28)),
                        );
                      }),
                      GestureDetector(
                        onTap: () {
                          Navigator.pop(ctx);
                          _showReactionEmojiPicker(msg);
                        },
                        child: Container(
                          width: 38,
                          height: 38,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerHighest,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.add_rounded,
                              size: 22, color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
              if (!deleted) const Divider(height: 1),
              _ActionTile(
                icon: Icons.reply_rounded,
                label: 'Reply',
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() => _replyTo = msg);
                  FocusScope.of(context).requestFocus(FocusNode());
                },
              ),
              if (!deleted)
                _ActionTile(
                  icon: _isPinned(msg)
                      ? Icons.push_pin
                      : Icons.push_pin_outlined,
                  label: _isPinned(msg) ? 'Unpin message' : 'Pin message',
                  onTap: () {
                    Navigator.pop(ctx);
                    if (_isPinned(msg)) {
                      _unpinMessage(msg);
                    } else {
                      _showPinDurationSheet(msg);
                    }
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
              if (!deleted)
                _ActionTile(
                  icon: Icons.forward_rounded,
                  label: 'Forward',
                  onTap: () {
                    Navigator.pop(ctx);
                    _showForwardPicker(msg);
                  },
                ),
              if (isMe) ...[
                if ((msg['message_type'] ?? 'text') == 'text' && !deleted)
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

  // Full emoji picker for reactions — react with ANY emoji, not just the six
  // quick ones. Opens as its own sheet; picking one adds the reaction.
  void _showReactionEmojiPicker(Map<String, dynamic> msg) {
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: 320,
          child: EmojiPicker(
            // No textEditingController → the tapped emoji comes back here so we
            // add it as a reaction instead of inserting it into the composer.
            onEmojiSelected: (category, emoji) {
              Navigator.pop(ctx);
              _addReaction(msg, emoji.emoji);
            },
            config: Config(
              height: 320,
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
                  style:
                      TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                ),
              ),
              categoryViewConfig: CategoryViewConfig(
                backgroundColor: scheme.surfaceContainerHighest,
                indicatorColor: scheme.primary,
                iconColor: scheme.onSurfaceVariant,
                iconColorSelected: scheme.primary,
                dividerColor: scheme.outlineVariant.withAlpha(80),
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

  /// The name to show on a reply-quote header — the author of the ORIGINAL
  /// quoted message, not of the reply. (Previously it used the reply's own
  /// sender, so a friend replying to your message showed her name instead of
  /// "You".) [replyIsMe] is only used as a fallback if the original isn't
  /// loaded, where a reply almost always quotes the other person.
  String _quotedAuthor(String quotedText, bool replyIsMe) {
    final orig = _findQuotedMessage(quotedText);
    if (orig != null) {
      return orig['sender_id'].toString() == _myId ? 'You' : widget.friendName;
    }
    return replyIsMe ? widget.friendName : 'You';
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
    // Delete for me: leave a LOCAL tombstone ("You deleted this message") so I
    // can see I deleted it, instead of the bubble silently vanishing. The
    // backend hides the message from my future fetches (visible_to_* = false),
    // and _merge keeps this local entry (it's never in a fetch again), so the
    // tombstone persists across reconciles and restarts (it's cached too).
    final backup = Map<String, dynamic>.from(
        _messages.firstWhere((m) => m['id'] == id));
    setState(() {
      final idx = _messages.indexWhere((m) => m['id'] == id);
      if (idx != -1) {
        _messages[idx]['deleted_for_me'] = true;
        _messages[idx]['content'] = '';
        _messages[idx]['message_type'] = 'text';
        _messages[idx]['media_url'] = null;
        _messages[idx]['reactions'] = null;
      }
    });
    _scheduleCacheSave();
    try {
      await ApiService().deleteSingleMessage(id, deleteForAll: false);
      if (mounted) {
        showToast(context, 'Deleted for you', type: ToastType.info);
      }
    } catch (_) {
      // Revert the tombstone if the server rejected the delete.
      if (mounted) {
        setState(() {
          final idx = _messages.indexWhere((m) => m['id'] == id);
          if (idx != -1) _messages[idx] = backup;
        });
      }
    }
  }

  // ── Pin a message (for a duration) ────────────────────────────────────────

  /// True if [msg] is currently pinned (pinned_until is in the future).
  bool _isPinned(Map<String, dynamic> msg) {
    final p = msg['pinned_until'];
    if (p == null) return false;
    final dt = DateTime.tryParse(p.toString());
    return dt != null && dt.isAfter(DateTime.now());
  }

  /// The message that should show in the pinned banner: the one with the
  /// latest still-active pin (single-pin-per-conversation), or null.
  Map<String, dynamic>? _activePinned() {
    Map<String, dynamic>? best;
    DateTime? bestUntil;
    for (final m in _messages) {
      if (m['is_deleted'] == true) continue;
      final p = m['pinned_until'];
      if (p == null) continue;
      final dt = DateTime.tryParse(p.toString());
      if (dt == null || !dt.isAfter(DateTime.now())) continue;
      if (bestUntil == null || dt.isAfter(bestUntil)) {
        best = m;
        bestUntil = dt;
      }
    }
    return best;
  }

  int _asId(dynamic id) => id is int ? id : int.tryParse(id.toString()) ?? -1;

  /// WhatsApp-style duration chooser, then pins for the chosen span.
  void _showPinDurationSheet(Map<String, dynamic> msg) {
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
              Padding(
                padding:
                    const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: Row(
                  children: [
                    Icon(Icons.push_pin_rounded,
                        size: 20, color: scheme.primary),
                    const SizedBox(width: 10),
                    Text('Pin this message for…',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface)),
                  ],
                ),
              ),
              const Divider(height: 1),
              _ActionTile(
                icon: Icons.schedule_rounded,
                label: '24 hours',
                onTap: () {
                  Navigator.pop(ctx);
                  _pinMessage(msg, 24);
                },
              ),
              _ActionTile(
                icon: Icons.schedule_rounded,
                label: '7 days',
                onTap: () {
                  Navigator.pop(ctx);
                  _pinMessage(msg, 24 * 7);
                },
              ),
              _ActionTile(
                icon: Icons.schedule_rounded,
                label: '30 days',
                onTap: () {
                  Navigator.pop(ctx);
                  _pinMessage(msg, 24 * 30);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pinMessage(Map<String, dynamic> msg, int hours) async {
    final id = msg['id'];
    // Optimistic: single active pin, so clear any other local pins first.
    final optimisticUntil =
        DateTime.now().toUtc().add(Duration(hours: hours)).toIso8601String();
    setState(() {
      for (final m in _messages) {
        m['pinned_until'] = null;
      }
      final idx = _messages.indexWhere((m) => m['id'] == id);
      if (idx != -1) _messages[idx]['pinned_until'] = optimisticUntil;
    });
    final res = await ApiService().pinMessage(_asId(id), hours);
    if (!mounted) return;
    if (res != null && res['pinned_until'] != null) {
      setState(() {
        final idx = _messages.indexWhere((m) => m['id'] == id);
        if (idx != -1) _messages[idx]['pinned_until'] = res['pinned_until'];
      });
      showToast(context, 'Message pinned');
    } else {
      showToast(context, 'Could not pin message', type: ToastType.error);
    }
    _saveMessagesCache();
  }

  Future<void> _unpinMessage(Map<String, dynamic> msg) async {
    final id = msg['id'];
    setState(() {
      final idx = _messages.indexWhere((m) => m['id'] == id);
      if (idx != -1) _messages[idx]['pinned_until'] = null;
    });
    final ok = await ApiService().unpinMessage(_asId(id));
    if (mounted) {
      showToast(context, ok ? 'Message unpinned' : 'Could not unpin',
          type: ok ? ToastType.info : ToastType.error);
    }
    _saveMessagesCache();
  }

  /// Scroll to a message by id and briefly highlight it.
  void _jumpToMessage(String id) {
    final ctx = _msgKeys[id]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 320),
      alignment: 0.3,
      curve: Curves.easeInOut,
    );
    HapticFeedback.selectionClick();
    setState(() => _highlightedId = id);
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightedId = null);
    });
  }

  /// The banner shown at the top of the thread for the active pinned message.
  Widget _buildPinnedBanner() {
    final pinned = _activePinned();
    if (pinned == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: InkWell(
        onTap: () => _jumpToMessage(pinned['id'].toString()),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: scheme.primary, width: 3),
              bottom:
                  BorderSide(color: scheme.outlineVariant.withAlpha(80)),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              Icon(Icons.push_pin_rounded, size: 18, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Pinned message',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: scheme.primary)),
                    const SizedBox(height: 2),
                    Text(
                      _replyQuoteText(pinned),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurface),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Unpin',
                icon: Icon(Icons.close_rounded,
                    size: 18, color: scheme.onSurfaceVariant),
                onPressed: () => _unpinMessage(pinned),
              ),
            ],
          ),
        ),
      ),
    );
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

    // Tombstone: delete-for-everyone (is_deleted) or delete-for-me
    // (deleted_for_me, local) keeps the row but blanks its content.
    final deletedForMe = msg['deleted_for_me'] == true;
    final tomb = msg['is_deleted'] == true || deletedForMe;
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
                            backgroundImage: _friendAvatar.isNotEmpty
                                ? CachedNetworkImageProvider(
                                    fullMediaUrl(_friendAvatar))
                                : null,
                            child: _friendAvatar.isNotEmpty
                                ? null
                                : Text(
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
                                deletedForMe
                                    ? 'You deleted this message'
                                    : 'This message was deleted',
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
                                  _quotedAuthor(quotedText, isMe),
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
                              msgType, mediaRel, msg, isMe, textColor, scheme),
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
      // Top gap gives the indicator room to breathe below the last bubble
      // (the list is reversed, so this padding sits ABOVE the indicator,
      // between it and the most recent message). Was tight before.
      padding: const EdgeInsets.only(left: 44, top: 12, bottom: 6),
      child: Builder(builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        // Match the incoming-message bubble: clean white on light, charcoal on
        // dark, with the same soft drop-shadow — so the dots read as a real
        // "received" bubble rather than a flat grey pill.
        final recvBubble =
            isDark ? const Color(0xFF241E20) : Colors.white;
        return Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: recvBubble,
              // Rounded like a bubble, with a slightly tighter bottom-left
              // corner echoing the received-bubble tail side.
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomRight: Radius.circular(18),
                bottomLeft: Radius.circular(6),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(isDark ? 46 : 20),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
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
        );
      }),
    );
  }

  // Short label describing a message for a reply quote/preview — media messages
  // get a typed label (📷 Photo / 🎤 Voice message / 📎 name) instead of blank.
  String _replyQuoteText(Map<String, dynamic> msg) {
    final caption = _stripQuote((msg['content'] as String?) ?? '').trim();
    final type = (msg['message_type'] as String?) ?? 'text';
    final isMedia =
        type != 'text' && (msg['media_url'] as String? ?? '').isNotEmpty;
    if (isMedia && caption.isEmpty) {
      switch (type) {
        case 'image':
          return '📷 Photo';
        case 'audio':
          return '🎤 Voice message';
        default:
          return '📎 ${(msg['media_name'] as String?) ?? 'File'}';
      }
    }
    return caption;
  }

  Widget _buildReplyPreview(Map<String, dynamic> msg) {
    final scheme = Theme.of(context).colorScheme;
    final isFromMe = msg['sender_id'].toString() == _myId;
    final msgType = (msg['message_type'] as String?) ?? 'text';
    final mediaRel = msg['media_url'] as String?;
    final isMedia =
        msgType != 'text' && mediaRel != null && mediaRel.isNotEmpty;
    final caption = _stripQuote(msg['content'] as String? ?? '');

    IconData? typeIcon;
    String label = caption;
    if (isMedia) {
      switch (msgType) {
        case 'image':
          typeIcon = Icons.photo_rounded;
          label = caption.isNotEmpty ? caption : 'Photo';
          break;
        case 'audio':
          typeIcon = Icons.mic_rounded;
          label = caption.isNotEmpty ? caption : 'Voice message';
          break;
        default:
          typeIcon = Icons.insert_drive_file_rounded;
          label = caption.isNotEmpty
              ? caption
              : (msg['media_name'] as String? ?? 'File');
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(left: BorderSide(color: scheme.primary, width: 3)),
      ),
      child: Row(
        children: [
          // Thumbnail preview so an image reply is instantly recognisable.
          if (isMedia && msgType == 'image')
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: CachedNetworkImage(
                  imageUrl: fullMediaUrl(mediaRel),
                  width: 36,
                  height: 36,
                  fit: BoxFit.cover,
                  placeholder: (_, _) => Container(
                      width: 36, height: 36, color: scheme.surfaceContainerHigh),
                  errorWidget: (_, _, _) => Container(
                      width: 36,
                      height: 36,
                      color: scheme.surfaceContainerHigh,
                      child: Icon(Icons.photo_rounded,
                          size: 18, color: scheme.onSurfaceVariant)),
                ),
              ),
            ),
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
                Row(
                  children: [
                    if (typeIcon != null) ...[
                      Icon(typeIcon,
                          size: 13, color: scheme.onSurface.withAlpha(150)),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: scheme.onSurface.withAlpha(160),
                            fontSize: 12),
                      ),
                    ),
                  ],
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
      // When embedded on the phone home layout (no app bar), the player bar +
      // footer below already handle the bottom safe area — adding it here just
      // opens a gap between the composer and that module.
      bottom: widget.showAppBar,
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
                                tooltip: 'Listen together',
                                icon: Icon(Icons.headphones_rounded,
                                    color: scheme.primary),
                                onPressed: _uploadingMedia
                                    ? null
                                    : _startListenTogether,
                                visualDensity: VisualDensity.compact,
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
              height: 306,
              decoration: BoxDecoration(
                color: scheme.surface,
                border: Border(
                  top: BorderSide(color: scheme.outlineVariant.withAlpha(90)),
                ),
              ),
              child: Column(
                children: [
                  // Emoji / GIFs switcher.
                  _emojiTabBar(scheme),
                  Expanded(
                    child: _emojiTab == 0
                        ? _buildEmojiPicker(scheme)
                        : GifPicker(onSelected: (g) => _sendGif(g.fullUrl)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Segmented Emoji / GIFs header for the panel.
  Widget _emojiTabBar(ColorScheme scheme) {
    Widget tab(String label, IconData icon, int index) {
      final selected = _emojiTab == index;
      return Expanded(
        child: InkWell(
          onTap: () => setState(() => _emojiTab = index),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: selected ? scheme.primary : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon,
                    size: 18,
                    color: selected
                        ? scheme.primary
                        : scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight:
                        selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      color: scheme.surfaceContainerHighest,
      child: Row(
        children: [
          tab('Emoji', Icons.emoji_emotions_rounded, 0),
          tab('GIFs', Icons.gif_box_rounded, 1),
        ],
      ),
    );
  }

  Widget _buildEmojiPicker(ColorScheme scheme) {
    return EmojiPicker(
                // When `textEditingController` is provided, EmojiPicker already
                // inserts the tapped emoji into it (at the cursor). Do NOT also
                // append it here — doing both made every emoji appear twice.
                onEmojiSelected: (_, _) {},
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
        // Pinned-message banner (empty widget when nothing is pinned).
        _buildPinnedBanner(),
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
              backgroundImage: _friendAvatar.isNotEmpty
                  ? CachedNetworkImageProvider(fullMediaUrl(_friendAvatar))
                  : null,
              child: _friendAvatar.isNotEmpty
                  ? null
                  : Text(
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
            onPressed: _showCallChoice,
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
              // Soft brand tint (like the composer mic) so it complements the
              // solid-red Send/FAB instead of competing with it.
              decoration: BoxDecoration(
                color: widget.accent.withAlpha(isDark ? 48 : 30),
                shape: BoxShape.circle,
                border: Border.all(
                    color: widget.accent.withAlpha(isDark ? 90 : 70),
                    width: 1),
              ),
              child: _loading
                  ? Padding(
                      padding: const EdgeInsets.all(10),
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: widget.accent),
                    )
                  : Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: isDark ? const Color(0xFFFF8A93) : widget.accent,
                      size: 20),
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

// ─────────────────────────────────────────────────────────────────────────────
// Image preview + lightweight annotation editor.
//
// Shown before an image is sent so the user can (a) draw freehand, (b) circle
// something, (c) draw a focus box, (d) drop draggable emoji stickers, and add a
// caption. All marks are stored in FRACTIONAL (0..1) canvas coordinates so they
// stay aligned when the editor is captured at high resolution. On send, if any
// edit exists the annotated image is flattened via RepaintBoundary → PNG so the
// recipient sees exactly what the sender drew; otherwise the original bytes are
// sent untouched. Returns a map {caption, bytes, mime} (or null if cancelled).
// ─────────────────────────────────────────────────────────────────────────────
enum _EditTool { move, pen, circle, box }

class _PenStroke {
  _PenStroke(this.color, this.width);
  final Color color;
  final double width;
  final List<Offset> points = []; // fractional (0..1)
}

class _ShapeMark {
  _ShapeMark(this.color, this.width, this.oval, this.start, this.end);
  final Color color;
  final double width;
  final bool oval; // true = circle/oval, false = rectangle focus box
  Offset start; // fractional
  Offset end; // fractional
}

class _EmojiMark {
  _EmojiMark(this.emoji, this.pos, this.size);
  final String emoji;
  Offset pos; // fractional centre (0..1)
  double size; // logical font size
}

class _ImagePreviewScreen extends StatefulWidget {
  const _ImagePreviewScreen({
    required this.imageBytes,
    required this.friendName,
  });
  final Uint8List imageBytes;
  final String friendName;

  @override
  State<_ImagePreviewScreen> createState() => _ImagePreviewScreenState();
}

class _ImagePreviewScreenState extends State<_ImagePreviewScreen> {
  final GlobalKey _boundaryKey = GlobalKey();
  final TextEditingController _captionCtrl = TextEditingController();
  // The editor canvas's on-screen size, captured in the LayoutBuilder. Used to
  // scale strokes/emoji from display units up to the ORIGINAL image resolution
  // when flattening, so the sent image stays sharp (not a blurry screen grab).
  double _canvasW = 1;

  final List<_PenStroke> _strokes = [];
  final List<_ShapeMark> _shapes = [];
  final List<_EmojiMark> _emojis = [];
  // Chronological undo stack: which list the last-added mark went to.
  final List<String> _history = [];

  _EditTool _tool = _EditTool.move;
  Color _color = const Color(0xFFFF3B30);
  double _aspect = 1;
  bool _busy = false;
  bool _showEmojiTray = false;
  _ShapeMark? _drafting; // shape being dragged out right now

  static const List<Color> _palette = [
    Color(0xFFFF3B30), // red
    Color(0xFFFFCC00), // yellow
    Color(0xFF34C759), // green
    Color(0xFF0A84FF), // blue
    Color(0xFFFFFFFF), // white
    Color(0xFF1C1C1E), // near-black
  ];
  static const List<String> _emojiTray = [
    '😀', '😂', '😍', '😎', '🥳', '👍', '🙏', '🔥', '❤️', '⭐',
    '✅', '❌', '❗', '➡️', '⬅️', '⬆️', '⬇️', '⚡', '💯', '🎯',
  ];

  @override
  void initState() {
    super.initState();
    // Learn the image's aspect ratio so the editor canvas matches it exactly
    // (no letterbox baked into the flattened result).
    ui.decodeImageFromList(widget.imageBytes, (img) {
      if (!mounted) return;
      setState(() => _aspect = img.width / img.height);
    });
  }

  @override
  void dispose() {
    _captionCtrl.dispose();
    super.dispose();
  }

  void _addEmoji(String e) {
    setState(() {
      _emojis.add(_EmojiMark(e, const Offset(0.5, 0.5), 44));
      _history.add('emoji');
      _showEmojiTray = false;
    });
  }

  void _undo() {
    if (_history.isEmpty) return;
    setState(() {
      final last = _history.removeLast();
      if (last == 'pen' && _strokes.isNotEmpty) {
        _strokes.removeLast();
      } else if (last == 'shape' && _shapes.isNotEmpty) {
        _shapes.removeLast();
      } else if (last == 'emoji' && _emojis.isNotEmpty) {
        _emojis.removeLast();
      }
    });
  }

  bool get _hasEdits =>
      _strokes.isNotEmpty || _shapes.isNotEmpty || _emojis.isNotEmpty;

  Future<void> _send() async {
    setState(() => _busy = true);
    Uint8List outBytes = widget.imageBytes;
    String mime = 'image/jpeg';
    if (_hasEdits) {
      final rendered = await _renderAnnotated();
      if (rendered != null) {
        outBytes = rendered;
        mime = 'image/png';
      }
    }
    if (!mounted) return;
    Navigator.of(context).pop(<String, dynamic>{
      'caption': _captionCtrl.text,
      'bytes': outBytes,
      'mime': mime,
    });
  }

  /// Flatten the annotations onto the ORIGINAL full-resolution image (rather
  /// than screen-grabbing the small on-screen editor, which lost detail and
  /// looked blurry). All marks are stored as fractional (0..1) coordinates, so
  /// they map cleanly onto the real pixel dimensions; stroke/emoji sizes are
  /// scaled by (imageWidth / canvasWidth) so the result matches what was drawn.
  Future<Uint8List?> _renderAnnotated() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.imageBytes);
      final frame = await codec.getNextFrame();
      final ui.Image src = frame.image;
      final w = src.width.toDouble();
      final h = src.height.toDouble();
      final scale = _canvasW > 0 ? w / _canvasW : 1.0;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));
      canvas.drawImageRect(
        src,
        Rect.fromLTWH(0, 0, w, h),
        Rect.fromLTWH(0, 0, w, h),
        Paint(),
      );

      for (final st in _strokes) {
        if (st.points.isEmpty) continue;
        final paint = Paint()
          ..color = st.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = st.width * scale
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
        final path = Path();
        for (var i = 0; i < st.points.length; i++) {
          final o = Offset(st.points[i].dx * w, st.points[i].dy * h);
          if (i == 0) {
            path.moveTo(o.dx, o.dy);
          } else {
            path.lineTo(o.dx, o.dy);
          }
        }
        canvas.drawPath(path, paint);
      }

      void drawShape(_ShapeMark sh) {
        final paint = Paint()
          ..color = sh.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = sh.width * scale;
        final rect = Rect.fromPoints(
          Offset(sh.start.dx * w, sh.start.dy * h),
          Offset(sh.end.dx * w, sh.end.dy * h),
        );
        if (sh.oval) {
          canvas.drawOval(rect, paint);
        } else {
          canvas.drawRRect(
              RRect.fromRectAndRadius(rect, Radius.circular(8 * scale)), paint);
        }
      }

      for (final sh in _shapes) {
        drawShape(sh);
      }

      for (final em in _emojis) {
        final tp = TextPainter(
          text: TextSpan(
              text: em.emoji, style: TextStyle(fontSize: em.size * scale)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas,
            Offset(em.pos.dx * w - tp.width / 2, em.pos.dy * h - tp.height / 2));
      }

      final picture = recorder.endRecording();
      final outImg = await picture.toImage(w.toInt(), h.toInt());
      final bd = await outImg.toByteData(format: ui.ImageByteFormat.png);
      return bd?.buffer.asUint8List();
    } catch (_) {
      return null; // fall back to the original bytes
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text('Send to ${widget.friendName}',
            style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            tooltip: 'Undo',
            onPressed: _history.isEmpty ? null : _undo,
            icon: Icon(Icons.undo_rounded,
                color: _history.isEmpty ? Colors.white30 : Colors.white),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Canvas ──────────────────────────────────────────────────────
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: _aspect,
                child: RepaintBoundary(
                  key: _boundaryKey,
                  child: LayoutBuilder(builder: (ctx, c) {
                    final w = c.maxWidth, h = c.maxHeight;
                    _canvasW = w;
                    Offset frac(Offset local) => Offset(
                        (local.dx / w).clamp(0.0, 1.0),
                        (local.dy / h).clamp(0.0, 1.0));
                    final drawing = _tool != _EditTool.move;
                    return Stack(
                      children: [
                        Positioned.fill(
                          child: Image.memory(widget.imageBytes,
                              fit: BoxFit.fill),
                        ),
                        // Drawing layer (pen / circle / box).
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanStart: !drawing
                                ? null
                                : (d) {
                                    final f = frac(d.localPosition);
                                    setState(() {
                                      if (_tool == _EditTool.pen) {
                                        final st = _PenStroke(_color, 3);
                                        st.points.add(f);
                                        _strokes.add(st);
                                        _history.add('pen');
                                      } else {
                                        _drafting = _ShapeMark(
                                            _color,
                                            3,
                                            _tool == _EditTool.circle,
                                            f,
                                            f);
                                      }
                                    });
                                  },
                            onPanUpdate: !drawing
                                ? null
                                : (d) {
                                    final f = frac(d.localPosition);
                                    setState(() {
                                      if (_tool == _EditTool.pen &&
                                          _strokes.isNotEmpty) {
                                        _strokes.last.points.add(f);
                                      } else if (_drafting != null) {
                                        _drafting!.end = f;
                                      }
                                    });
                                  },
                            onPanEnd: !drawing
                                ? null
                                : (_) {
                                    setState(() {
                                      if (_drafting != null) {
                                        _shapes.add(_drafting!);
                                        _history.add('shape');
                                        _drafting = null;
                                      }
                                    });
                                  },
                            child: CustomPaint(
                              painter: _AnnotationPainter(
                                  _strokes, _shapes, _drafting),
                            ),
                          ),
                        ),
                        // Emoji stickers (draggable).
                        ..._emojis.map((em) => Positioned(
                              left: em.pos.dx * w - em.size / 2,
                              top: em.pos.dy * h - em.size / 2,
                              child: GestureDetector(
                                onPanUpdate: (d) {
                                  setState(() {
                                    em.pos += Offset(
                                        d.delta.dx / w, d.delta.dy / h);
                                    em.pos = Offset(em.pos.dx.clamp(0.0, 1.0),
                                        em.pos.dy.clamp(0.0, 1.0));
                                  });
                                },
                                child: Text(em.emoji,
                                    style: TextStyle(fontSize: em.size)),
                              ),
                            )),
                      ],
                    );
                  }),
                ),
              ),
            ),
          ),
          // ── Emoji tray (toggled) ────────────────────────────────────────
          if (_showEmojiTray)
            Container(
              height: 52,
              color: Colors.black,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: _emojiTray.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (_, i) => GestureDetector(
                  onTap: () => _addEmoji(_emojiTray[i]),
                  child: Center(
                    child: Text(_emojiTray[i],
                        style: const TextStyle(fontSize: 26)),
                  ),
                ),
              ),
            ),
          // ── Tool + colour bar ───────────────────────────────────────────
          Container(
            color: Colors.black,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                _toolBtn(Icons.pan_tool_alt_rounded, _EditTool.move, 'Move'),
                _toolBtn(Icons.edit_rounded, _EditTool.pen, 'Draw'),
                _toolBtn(Icons.circle_outlined, _EditTool.circle, 'Circle'),
                _toolBtn(
                    Icons.crop_square_rounded, _EditTool.box, 'Focus box'),
                IconButton(
                  tooltip: 'Emoji',
                  onPressed: () =>
                      setState(() => _showEmojiTray = !_showEmojiTray),
                  icon: Icon(Icons.emoji_emotions_rounded,
                      color: _showEmojiTray
                          ? scheme.primary
                          : Colors.white70),
                ),
                const Spacer(),
                // Colour swatches.
                for (final col in _palette)
                  GestureDetector(
                    onTap: () => setState(() => _color = col),
                    child: Container(
                      width: 22,
                      height: 22,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: col,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _color == col
                              ? Colors.white
                              : Colors.white24,
                          width: _color == col ? 2.5 : 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // ── Caption + send ──────────────────────────────────────────────
          Container(
            color: Colors.black,
            padding: EdgeInsets.only(
              left: 12,
              right: 12,
              top: 6,
              bottom: MediaQuery.of(context).viewInsets.bottom + 10,
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _captionCtrl,
                    minLines: 1,
                    maxLines: 4,
                    style: const TextStyle(color: Colors.white),
                    cursorColor: scheme.primary,
                    decoration: InputDecoration(
                      hintText: 'Add a caption…',
                      hintStyle: const TextStyle(color: Colors.white54),
                      filled: true,
                      fillColor: Colors.white10,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _busy ? null : _send,
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: _busy
                        ? const Padding(
                            padding: EdgeInsets.all(13),
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.send_rounded,
                            color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolBtn(IconData icon, _EditTool tool, String tip) {
    final selected = _tool == tool;
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tip,
      onPressed: () => setState(() => _tool = tool),
      icon: Icon(icon, color: selected ? scheme.primary : Colors.white70),
    );
  }
}

class _AnnotationPainter extends CustomPainter {
  _AnnotationPainter(this.strokes, this.shapes, this.draft);
  final List<_PenStroke> strokes;
  final List<_ShapeMark> shapes;
  final _ShapeMark? draft;

  @override
  void paint(Canvas canvas, Size size) {
    for (final st in strokes) {
      if (st.points.isEmpty) continue;
      final paint = Paint()
        ..color = st.color
        ..strokeWidth = st.width
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      for (var i = 0; i < st.points.length; i++) {
        final o = Offset(
            st.points[i].dx * size.width, st.points[i].dy * size.height);
        if (i == 0) {
          path.moveTo(o.dx, o.dy);
        } else {
          path.lineTo(o.dx, o.dy);
        }
      }
      canvas.drawPath(path, paint);
    }
    void drawShape(_ShapeMark sh) {
      final paint = Paint()
        ..color = sh.color
        ..strokeWidth = sh.width
        ..style = PaintingStyle.stroke;
      final rect = Rect.fromPoints(
        Offset(sh.start.dx * size.width, sh.start.dy * size.height),
        Offset(sh.end.dx * size.width, sh.end.dy * size.height),
      );
      if (sh.oval) {
        canvas.drawOval(rect, paint);
      } else {
        canvas.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(8)), paint);
      }
    }

    for (final sh in shapes) {
      drawShape(sh);
    }
    if (draft != null) drawShape(draft!);
  }

  @override
  bool shouldRepaint(covariant _AnnotationPainter old) => true;
}
