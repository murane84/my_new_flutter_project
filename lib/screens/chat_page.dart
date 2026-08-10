import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, compute;
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
// Hide intl's TextDirection so the unprefixed name resolves to dart:ui's
// (needed by the ShapeBorder overrides below).
import 'package:intl/intl.dart' hide TextDirection;
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'api_service.dart';
import 'chat/song_cache.dart';
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
import '../services/contact_names.dart';
import '../utils/net_image.dart';
import 'user_profile_sheet.dart';
import 'home_page.dart' show playlistNotifier, playbackBus;
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import '../utils/app_config.dart';

// Split out for maintainability (Dart parts — same library, shared
// imports & privacy, zero behaviour change):
part 'chat/chat_bubble_parts.dart';   // wallpaper, action tile, bubble
                                       // border, voice note, swipe-to-reply
part 'chat/chat_image_editor.dart';    // image preview + annotation editor
part 'chat/chat_composer_parts.dart';  // recording bar, edit + offline banners

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

// Compress a chat image for upload: downscale to ≤1600px on the long edge and
// re-encode as JPEG q78. Runs in a background isolate (via compute) so large
// screenshots don't jank the UI. Returns the input unchanged if it can't decode.
Uint8List _compressChatImage(Uint8List input) {
  try {
    final decoded = img.decodeImage(input);
    if (decoded == null) return input;
    const maxDim = 1600;
    img.Image out = decoded;
    if (decoded.width > maxDim || decoded.height > maxDim) {
      out = decoded.width >= decoded.height
          ? img.copyResize(decoded, width: maxDim)
          : img.copyResize(decoded, height: maxDim);
    }
    return Uint8List.fromList(img.encodeJpg(out, quality: 78));
  } catch (_) {
    return input;
  }
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

  // ── Group mode ──────────────────────────────────────────────────────────
  // When [conversationId] is set and [isGroup] is true this same screen runs as
  // a GROUP chat: fetch/send/read via the /conversations endpoints, route WS by
  // conversation_id, and show sender labels + avatars. DMs leave these
  // null/false and behave exactly as before.
  final int? conversationId;
  final bool isGroup;
  final String groupTitle;
  final String groupAvatar;
  final int memberCount;

  // ── Share-into-Aluta ──────────────────────────────────────────────────────
  // Local image paths shared in from another app (e.g. a screenshot). When set,
  // the chat opens straight into the image preview/caption flow for each one.
  // [onShareConsumed] fires once they've been handed off, so the host can drop
  // them and never re-send on a later rebuild.
  final List<String>? initialSharePaths;
  final VoidCallback? onShareConsumed;

  const ChatPage({
    super.key,
    this.friendId = 0,
    required this.friendName,
    this.friendAvatar = '',
    required this.textColor,
    this.showAppBar = true,
    this.onFriendOnlineStatusChanged,
    this.conversationId,
    this.isGroup = false,
    this.groupTitle = '',
    this.groupAvatar = '',
    this.memberCount = 0,
    this.initialSharePaths,
    this.onShareConsumed,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  // True when this screen is showing a GROUP conversation (vs a 1:1 DM).
  bool get _isGroup => widget.isGroup && widget.conversationId != null;
  int get _cid => widget.conversationId ?? 0;

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
      onDisconnected: () => _startPolling(),
    );

    // Group chats show the SENDER's phonebook name when their number is saved
    // on this device. Warm that map silently (no permission prompt) and repaint
    // once it's ready so the header names resolve.
    if (widget.isGroup) {
      ContactNames.instance.ensureLoaded().then((_) {
        if (mounted) setState(() {});
      });
    }

    // If this chat was opened to receive a shared-in image (e.g. a screenshot
    // shared from another app), jump straight into the preview/caption flow.
    final shared = widget.initialSharePaths;
    if (shared != null && shared.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _consumeSharedImages(shared);
      });
    }
  }

  /// Send each shared-in image through the normal preview → caption → upload
  /// path (works for both DMs and groups). Called once, from initState.
  Future<void> _consumeSharedImages(List<String> paths) async {
    // Tell the host to drop these now so a later rebuild can't re-send them.
    widget.onShareConsumed?.call();
    for (final p in paths) {
      if (!mounted) return;
      try {
        final file = File(p);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty || !mounted) continue;
        final name = p.split(Platform.pathSeparator).last;
        await _previewAndSendImage(
            bytes, name.isNotEmpty ? name : 'shared.jpg', 'image/jpeg');
      } catch (_) {
        /* skip a bad path, continue with the rest */
      }
    }
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
    _pickerScrollCtrl.dispose();
    _ws.close();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // A rising keyboard normally means the user tapped the composer, so the
    // emoji panel yields. EXCEPT on the GIF tab (index 1): its "Search GIFs"
    // field lives INSIDE the panel and needs the keyboard — closing the panel
    // there bounced the user straight back to the thread mid-search.
    if (View.of(context).viewInsets.bottom > 0 && _showEmoji && _emojiTab != 1) {
      setState(() => _showEmoji = false);
    }
  }

  @override
  void didUpdateWidget(ChatPage old) {
    super.didUpdateWidget(old);
    if (old.friendId != widget.friendId ||
        old.conversationId != widget.conversationId) {
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
      final msgs = _isGroup
          ? await ApiService()
              .fetchConversationMessages(_cid, skip: 0, limit: 60)
          : await ApiService().fetchMessagesBetween(
              uid, widget.friendId,
              skip: 0, limit: 60,
            );

      final unread = _isGroup
          ? msgs.any((m) => m['sender_id'].toString() != _myId)
          : msgs.any((m) =>
              m['receiver_id'].toString() == _myId && m['is_read'] == false);
      if (unread && _isAtBottom) {
        if (_isGroup) {
          await ApiService().markConversationRead(_cid);
        } else {
          await ApiService().markMessagesAsReadPatch(widget.friendId);
        }
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

  String get _cacheKey => _isGroup
      ? 'chat_cache_${_myId ?? 'x'}_g$_cid'
      : 'chat_cache_${_myId ?? 'x'}_${widget.friendId}';

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
      fetched = _isGroup
          ? await ApiService()
              .fetchConversationMessages(_cid, skip: 0, limit: 60)
          : await ApiService().fetchMessagesBetween(
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

    if (_isGroup) {
      // Groups: fetching already advanced our delivered pointer server-side;
      // just keep the read pointer current while we're at the bottom.
      if (_isAtBottom) ApiService().markConversationRead(_cid);
      return;
    }

    // Mark delivered (DM)
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

    if (type == 'new_message') {
      // Backend sends the payload under `data` (a MessageWithSender), like every
      // other branch below — NOT `message`. Reading the wrong key made the live
      // insert (and the inline read-ack) silently dead when the chat was open.
      final msg = event['data'] as Map<String, dynamic>?;
      if (msg != null) {
        // The socket is per-user and carries EVERY conversation's events, so
        // only accept messages that belong to THIS thread: matching
        // conversation_id for a group, or the me↔friend pair for a DM.
        final sId = msg['sender_id']?.toString();
        final rId = msg['receiver_id']?.toString();
        final fId = widget.friendId.toString();
        final inThread = _isGroup
            ? msg['conversation_id']?.toString() == _cid.toString()
            : (sId == fId && rId == _myId) || (sId == _myId && rId == fId);
        // Incoming = from someone else (a friend in a DM, any member in a group).
        final incoming = _isGroup ? (sId != _myId) : (rId == _myId);
        if (inThread) {
          setState(() {
            final id = msg['id'].toString();
            if (!_messages.any((m) => m['id'].toString() == id)) {
              _messages.insert(0, msg);
            }
          });
          if (incoming) {
            if (_isAtBottom) {
              _scrollToBottom();
              if (_isGroup) {
                ApiService().markConversationRead(_cid);
              } else {
                ApiService().markMessagesAsReadPatch(widget.friendId);
              }
            } else {
              setState(() => _hasNewMsg = true);
            }
          }
        }
      }
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
      }
    } else if (type == 'message_unpinned') {
      final data = event['data'] as Map<String, dynamic>?;
      final mid = data?['message_id'];
      if (mid != null) {
        setState(() {
          final idx = _messages.indexWhere((m) => m['id'] == mid);
          if (idx != -1) _messages[idx]['pinned_until'] = null;
        });
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
  /// Open a group member's profile card (tapped from their message header).
  void _openMemberProfile(String name, String phone, String avatarRel) {
    showUserProfile(
      context,
      username: name,
      phone: phone,
      avatarUrl: avatarRel.isNotEmpty ? fullMediaUrl(avatarRel) : null,
    );
  }

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
                            ? authNetworkImageProvider(avatarUrl, mediaAuthHeaders(avatarUrl))
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
    if (!_iTyping && !_isGroup) {
      // Typing indicators are DM-only for now (group typing needs per-member
      // fan-out — deferred).
      _iTyping = true;
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
      final sent = await ApiService().sendMessage(widget.friendId, content,
          conversationId: widget.conversationId);
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
        conversationId: widget.conversationId,
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
      // Pick at high quality; the compress-on-upload step (or the HD toggle in
      // the preview) decides final size, so HD can send near-original quality.
      final x = await ImagePicker()
          .pickImage(source: source, imageQuality: 92, maxWidth: 2560);
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
    final hd = (result['hd'] as bool?) ?? false;
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
      hd: hd,
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
      if (bytes.isEmpty) {
        if (mounted) showToast(context, 'Could not read file', type: ToastType.error);
        return;
      }
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
    bool hd = false,
  }) async {
    setState(() => _uploadingMedia = true);
    try {
      // Compress images before upload to keep server storage + bandwidth down.
      // This covers gallery/camera, document-picked and shared-in images
      // (e.g. big screenshots). Skipped when HD is on (send the original) — but
      // still forced if the original exceeds the 15 MB upload cap. GIFs and
      // small images pass through untouched.
      final tooBigForRaw = bytes.length > 15 * 1024 * 1024;
      if (type == 'image' &&
          mime != 'image/gif' &&
          (!hd || tooBigForRaw) &&
          bytes.length > 350 * 1024) {
        try {
          final compressed =
              await compute(_compressChatImage, Uint8List.fromList(bytes));
          if (compressed.isNotEmpty && compressed.length < bytes.length) {
            bytes = compressed;
            mime = 'image/jpeg';
            final dot = filename.lastIndexOf('.');
            filename =
                '${dot > 0 ? filename.substring(0, dot) : filename}.jpg';
            if (hd && tooBigForRaw && mounted) {
              showToast(context, 'Original too large — sent compressed',
                  type: ToastType.info);
            }
          }
        } catch (_) {/* keep the original bytes on any failure */}
      }
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
        conversationId: widget.conversationId,
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
      case 'song':
        return _SongBubble(
          assetId: SongCache.assetId(rel),
          url: url,
          title: (msg['content'] as String?)?.trim().isNotEmpty == true
              ? (msg['content'] as String).trim()
              : ((msg['media_name'] as String?) ?? 'Song'),
          fileName: msg['media_name'] as String?,
          mime: msg['media_mime'] as String?,
          isMe: isMe,
          accent: scheme.primary,
          onColor: textColor,
          onDownload: () => _saveMediaToDevice(msg),
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
          child: authNetworkImage(
            url: url,
            headers: mediaAuthHeaders(url),
            fit: BoxFit.cover,
            placeholder: (_) => Container(
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
            error: (_) => Container(
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
                child: authNetworkImage(
                    url: url,
                    headers: mediaAuthHeaders(url),
                    fit: BoxFit.contain),
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
            const SizedBox(width: 2),
            // Explicit "Save to device" (Save As…). Tapping the rest of the
            // bubble still opens/previews the file.
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              tooltip: 'Save to device',
              icon: Icon(Icons.download_rounded,
                  size: 20, color: textColor.withAlpha(180)),
              onPressed: () => _saveMediaToDevice(msg),
            ),
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
    // Attachments are auth-protected now, so an external browser can't fetch
    // them. Download the bytes WITH our token, then hand the file to the system
    // sheet (open / save / share) — same pattern as saving an image.
    try {
      if (mounted) showToast(context, 'Opening…');
      final res = await http.get(Uri.parse(url), headers: mediaAuthHeaders(url));
      if (res.statusCode != 200) {
        if (mounted) {
          showToast(context, 'Could not open file', type: ToastType.error);
        }
        return;
      }
      var name = Uri.parse(url).pathSegments.isNotEmpty
          ? Uri.parse(url).pathSegments.last
          : '';
      if (name.isEmpty) {
        name = 'aluta_file_${DateTime.now().millisecondsSinceEpoch}';
      }
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(res.bodyBytes, flush: true);
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    } catch (_) {
      if (mounted) showToast(context, 'Could not open file', type: ToastType.error);
    }
  }

  /// Download a shared image and hand it to the system sheet so the user can
  /// save it to their gallery / Files. Reused by the image viewer's Save button.
  Future<void> _saveImage(String url) async {
    try {
      if (mounted) showToast(context, 'Downloading…');
      final res = await http.get(Uri.parse(url), headers: mediaAuthHeaders(url));
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

  /// Save ANY received media message (shared song, PDF, doc, image, voice note)
  /// out to the user's own device storage. For ephemeral songs the server copy
  /// may already be purged, so we read from the LOCAL CACHE first and only fall
  /// back to the network while the bytes still live there. The bytes are then
  /// handed to [_saveBytesToDevice], which shows a real "Save As…" dialog.
  Future<void> _saveMediaToDevice(Map<String, dynamic> msg) async {
    final rel = msg['media_url'] as String?;
    if (rel == null || rel.isEmpty) return;
    final name = (msg['media_name'] as String?)?.trim();
    final mime = msg['media_mime'] as String?;
    final type = (msg['message_type'] as String?) ?? 'file';
    try {
      if (mounted) showToast(context, 'Preparing download…');
      List<int>? bytes;
      // Ephemeral song → prefer the on-device cache (survives server purge).
      final id = SongCache.assetId(rel);
      if (id != null) {
        final cached =
            await SongCache.cachedPath(id, filename: name, mime: mime);
        if (cached != null) bytes = await File(cached).readAsBytes();
      }
      // Otherwise pull from the server while it still has the bytes.
      if (bytes == null || bytes.isEmpty) {
        final url = fullMediaUrl(rel);
        final res =
            await http.get(Uri.parse(url), headers: mediaAuthHeaders(url));
        if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
          bytes = res.bodyBytes;
        }
      }
      if (bytes == null || bytes.isEmpty) {
        if (mounted) {
          showToast(context,
              type == 'song'
                  ? 'Song is no longer available'
                  : 'File is no longer available',
              type: ToastType.error);
        }
        return;
      }
      final ext = type == 'song' ? '.mp3' : '';
      final fallback =
          'aluta_${type}_${DateTime.now().millisecondsSinceEpoch}$ext';
      await _saveBytesToDevice(
          bytes, (name == null || name.isEmpty) ? fallback : name);
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not save', type: ToastType.error);
      }
    }
  }

  /// Present a real "Save As…" flow and write [bytes] there. `FilePicker.saveFile`
  /// (v12) shows a native Save dialog on desktop and the system "Save to"
  /// location picker on mobile, and — because `bytes` is passed — writes the
  /// file itself, returning the chosen path (null if the user cancels). If the
  /// platform doesn't support the dialog, we fall back to the share/save sheet.
  Future<void> _saveBytesToDevice(List<int> bytes, String fname) async {
    final data = Uint8List.fromList(bytes);
    try {
      final saved = await FilePicker.saveFile(
        dialogTitle: 'Save to device',
        fileName: fname,
        bytes: data,
      );
      // A null result is a user cancel, not an error.
      if (saved != null && mounted) {
        showToast(context, 'Saved to device', type: ToastType.success);
      }
    } catch (_) {
      // saveFile unsupported here → fall back to the system share/save sheet.
      await _shareBytes(data, fname);
    }
  }

  /// Fallback saver: write to a temp file and open the OS share/save sheet.
  Future<void> _shareBytes(Uint8List data, String fname) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$fname');
      await file.writeAsBytes(data, flush: true);
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not save', type: ToastType.error);
      }
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
              if (msg['is_deleted'] != true)
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
              if (msg['is_deleted'] != true)
                _ActionTile(
                  icon: Icons.forward_rounded,
                  label: 'Forward',
                  onTap: () {
                    Navigator.pop(ctx);
                    _showForwardPicker(msg);
                  },
                ),
              // Save any received/sent media (song, PDF, doc, image, voice
              // note) to the device's own storage via a Save As… dialog.
              if (msg['is_deleted'] != true &&
                  (msg['message_type'] ?? 'text') != 'text' &&
                  (msg['media_url'] as String? ?? '').isNotEmpty)
                _ActionTile(
                  icon: Icons.download_rounded,
                  label: 'Save to device',
                  onTap: () {
                    Navigator.pop(ctx);
                    _saveMediaToDevice(msg);
                  },
                ),
              if (isMe) ...[
                // Group only: who has read / received / not-yet-received this.
                if (_isGroup && msg['is_deleted'] != true)
                  _ActionTile(
                    icon: Icons.info_outline_rounded,
                    label: 'Message info',
                    onTap: () {
                      Navigator.pop(ctx);
                      _showMessageInfo(msg);
                    },
                  ),
                if ((msg['message_type'] ?? 'text') == 'text' &&
                    msg['is_deleted'] != true &&
                    _withinEditWindow(msg))
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

  /// WhatsApp-style "Message info": three buckets — Read, Delivered (received
  /// but not read), and Sent (not yet delivered) — for a message I sent to the
  /// group. One scrollable sheet, one section per category.
  void _showMessageInfo(Map<String, dynamic> msg) {
    final rawId = msg['id'];
    if (rawId == null) return;
    final mid = rawId is int ? rawId : int.tryParse(rawId.toString()) ?? 0;
    final scheme = Theme.of(context).colorScheme;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.62,
        minChildSize: 0.4,
        maxChildSize: 0.94,
        expand: false,
        builder: (c, scrollCtrl) => Container(
          margin: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(20),
          ),
          clipBehavior: Clip.antiAlias,
          child: FutureBuilder<Map<String, dynamic>?>(
            future: ApiService().messageInfo(_cid, mid),
            builder: (c, snap) {
              final handle = Container(
                margin: const EdgeInsets.symmetric(vertical: 10),
                width: 36,
                height: 3,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              );
              if (snap.connectionState == ConnectionState.waiting) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    handle,
                    const Padding(
                      padding: EdgeInsets.all(40),
                      child: CircularProgressIndicator(),
                    ),
                  ],
                );
              }
              final data = snap.data;
              if (data == null) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    handle,
                    Padding(
                      padding: const EdgeInsets.all(30),
                      child: Text('Couldn\'t load message info.',
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                    ),
                  ],
                );
              }
              final read = (data['read'] as List?) ?? const [];
              final delivered = (data['delivered'] as List?) ?? const [];
              final sent = (data['sent'] as List?) ?? const [];
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  handle,
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('Message info',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface)),
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: ListView(
                      controller: scrollCtrl,
                      padding: const EdgeInsets.only(bottom: 16),
                      children: [
                        _infoSection('Read by', Icons.done_all_rounded,
                            const Color(0xFF1976D2), read, scheme),
                        _infoSection(
                            'Delivered to',
                            Icons.done_all_rounded,
                            scheme.onSurfaceVariant,
                            delivered,
                            scheme),
                        _infoSection('Not yet received', Icons.check_rounded,
                            scheme.onSurfaceVariant, sent, scheme),
                        if (read.isEmpty && delivered.isEmpty && sent.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Center(
                              child: Text('No other members in this group yet.',
                                  style: TextStyle(
                                      color: scheme.onSurfaceVariant)),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// One category block inside the Message-info sheet. Hidden when empty.
  Widget _infoSection(String title, IconData icon, Color color, List members,
      ColorScheme scheme) {
    if (members.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Text(
                '$title · ${members.length}',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: color,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
        ...members.map((m) => _infoMemberTile(m, scheme)),
      ],
    );
  }

  Widget _infoMemberTile(dynamic m, ColorScheme scheme) {
    final username = (m['username'] ?? 'User').toString();
    final phone = (m['phone'] ?? '').toString();
    // Prefer the user's phonebook-saved name over the raw DB username.
    final saved =
        phone.isNotEmpty ? ContactNames.instance.nameFor(phone) : null;
    final name = (saved != null && saved.isNotEmpty) ? saved : username;
    final avatarRel = (m['avatar_url'] ?? '').toString();
    final avatar = avatarRel.isNotEmpty ? fullMediaUrl(avatarRel) : null;
    final ts = (m['timestamp'] ?? '').toString();
    return ListTile(
      dense: true,
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: scheme.primaryContainer,
        backgroundImage: avatar != null
            ? authNetworkImageProvider(avatar, mediaAuthHeaders(avatar))
            : null,
        child: avatar == null
            ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: TextStyle(color: scheme.onPrimaryContainer))
            : null,
      ),
      title: Text(name, overflow: TextOverflow.ellipsis),
      subtitle: phone.isNotEmpty
          ? Text(phone,
              style: TextStyle(
                  fontSize: 11.5, color: scheme.onSurfaceVariant))
          : null,
      trailing: ts.isNotEmpty
          ? Text(_infoTime(ts),
              style: TextStyle(
                  fontSize: 11, color: scheme.onSurfaceVariant))
          : null,
    );
  }

  /// Compact timestamp for a Message-info row (today → time only, else date).
  String _infoTime(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return '';
    final local = t.toLocal();
    final now = DateTime.now();
    final sameDay =
        local.year == now.year && local.month == now.month && local.day == now.day;
    return sameDay
        ? DateFormat('HH:mm').format(local)
        : DateFormat('MMM d, HH:mm').format(local);
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

  // Editing is only allowed within this window after a message is posted; the
  // server enforces the same limit (returns 403 past it).
  static const Duration _editWindow = Duration(hours: 1);

  /// Whether [msg] is still within the edit window. Falls back to allowing the
  /// action when the timestamp can't be parsed, so the server has the final say.
  bool _withinEditWindow(Map<String, dynamic> msg) {
    final ts = msg['timestamp']?.toString();
    if (ts == null || ts.isEmpty) return true;
    final t = DateTime.tryParse(ts);
    if (t == null) return true;
    return DateTime.now().toUtc().difference(t.toUtc()) <= _editWindow;
  }

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

  static String _fmtCallDur(int secs) {
    final m = secs ~/ 60;
    final s = secs % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  // Renders a call-log message (message_type 'call'). media_duration holds the
  // connected length in SECONDS; 0 means the call never connected (no answer /
  // missed). isMe = I placed the call (outgoing), else incoming.
  Widget _callLogContent(Map<String, dynamic> msg, bool isMe, Color textColor) {
    final secs = (msg['media_duration'] as num?)?.toInt() ?? 0;
    final connected = secs > 0;
    final IconData icon;
    final String label;
    if (connected) {
      icon = isMe ? Icons.call_made_rounded : Icons.call_received_rounded;
      label =
          '${isMe ? 'Outgoing' : 'Incoming'} call · ${_fmtCallDur(secs)}';
    } else {
      icon = isMe ? Icons.call_made_rounded : Icons.call_missed_rounded;
      label = isMe ? 'Call — no answer' : 'Missed call';
    }
    // Highlight a genuinely missed incoming call in red; otherwise match bubble.
    final color = (!connected && !isMe) ? const Color(0xFFE53935) : textColor;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
              color: color, fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }

  // Open a tapped link from a message bubble in the external browser.
  Future<void> _openLink(String url) async {
    try {
      final uri = Uri.parse(url);
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        showToast(context, 'Could not open link', type: ToastType.error);
      }
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not open link', type: ToastType.error);
      }
    }
  }

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
  // Stable, readable colour per sender name (group sender labels) — same idea
  // as WhatsApp's per-participant name colours.
  Color _senderColor(String name, bool isDark) {
    int h = 0;
    for (final c in name.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    final hue = (h % 360).toDouble();
    return HSLColor.fromAHSL(1.0, hue, 0.55, isDark ? 0.72 : 0.42).toColor();
  }

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
    // A call-log entry (auto-posted when an Aluta call ends).
    final isCall = !tomb && msgType == 'call';
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
    // Tappable links: readable + clearly a link on either bubble colour.
    final linkColor = isDark
        ? const Color(0xFF9FD0FF)
        : (isMe ? const Color(0xFF0B4EA2) : const Color(0xFF1565C0));
    final quoteBarColor = isMe
        ? (isDark ? const Color(0xFFFF8A93) : scheme.primary)
        : scheme.primary;
    // Muted + "read" accent for the timestamp/ticks, tuned per bubble.
    final sentMuted = onSent.withAlpha(isDark ? 160 : 150);
    // Read receipt: a blue double-tick, so it stands out against the red/rose
    // sender bubble instead of blending in like the old brand-red tick did.
    final sentRead =
        isDark ? const Color(0xFF6FB1FF) : const Color(0xFF1976D2);
    // Delivery ticks: neutral gray while sent/delivered, blue once read.
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

    // In a GROUP, received bubbles carry the sender's own name + avatar (so you
    // can tell who said what). For DMs these are unused (the friend is implied).
    final Map senderMap = (msg['sender'] as Map?) ?? const {};
    final String senderName = (senderMap['username'] ?? '').toString();
    final String senderAvatar = (senderMap['avatar_url'] ?? '').toString();
    final String senderPhone = (senderMap['phone'] ?? '').toString();
    // Which avatar/name/phone to show on this received bubble.
    final String rxAvatar = _isGroup ? senderAvatar : _friendAvatar;
    final String rxName = _isGroup ? senderName : widget.friendName;
    final String rxPhone = _isGroup ? senderPhone : '';
    // Personal touch: if this sender's number is saved in the user's phone book,
    // show YOUR saved name for them (clean, no ~/number). Otherwise fall back to
    // their app username with a ~ and the number.
    final String? savedName =
        rxPhone.isNotEmpty ? ContactNames.instance.nameFor(rxPhone) : null;
    final bool inPhonebook = savedName != null && savedName.isNotEmpty;
    final String headerName = inPhonebook ? savedName : '~ $rxName';

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
                            backgroundImage: rxAvatar.isNotEmpty
                                ? authNetworkImageProvider(fullMediaUrl(rxAvatar), mediaAuthHeaders(fullMediaUrl(rxAvatar)))
                                : null,
                            child: rxAvatar.isNotEmpty
                                ? null
                                : Text(
                                    rxName.isNotEmpty
                                        ? rxName[0].toUpperCase()
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
                        // ── Group sender header INSIDE the top of the first
                        // bubble of each sender's run. If the number is saved in
                        // your phone book we show YOUR name for them; otherwise
                        // their app username (~) and number, WhatsApp-style. ──
                        if (_isGroup && !isMe && isFirst && rxName.isNotEmpty && !tomb)
                          // Tap the sender header to open their profile details.
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _openMemberProfile(
                                rxName, rxPhone, senderAvatar),
                            child: Padding(
                              padding:
                                  const EdgeInsets.only(bottom: 3, right: 8),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.baseline,
                                textBaseline: TextBaseline.alphabetic,
                                children: [
                                  Flexible(
                                    child: Text(
                                      headerName,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w700,
                                        color: _senderColor(
                                            inPhonebook ? headerName : rxName,
                                            isDark),
                                      ),
                                    ),
                                  ),
                                  // Only unsaved contacts show the raw number.
                                  if (!inPhonebook && rxPhone.isNotEmpty) ...[
                                    const SizedBox(width: 12),
                                    Text(
                                      rxPhone,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w400,
                                        color: textColor.withAlpha(150),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
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
                        if (isCall) _callLogContent(msg, isMe, textColor),
                        if (isMedia)
                          _mediaContent(
                              msgType, mediaRel, msg, isMe, textColor, scheme),
                        // A shared song shows its title inside the card, so skip
                        // the duplicate text line (content == the song label).
                        if (!tomb &&
                            msgType != 'song' &&
                            mainText.trim().isNotEmpty)
                          Padding(
                            padding: EdgeInsets.only(top: isMedia ? 6 : 0),
                            child: Linkify(
                              text: mainText,
                              onOpen: (link) => _openLink(link.url),
                              options:
                                  const LinkifyOptions(humanize: false),
                              style: TextStyle(
                                color: textColor,
                                fontSize: 15,
                                height: 1.38,
                              ),
                              linkStyle: TextStyle(
                                color: linkColor,
                                fontSize: 15,
                                height: 1.38,
                                decoration: TextDecoration.underline,
                                decorationColor: linkColor,
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
                child: authNetworkImage(
                  url: fullMediaUrl(mediaRel),
                  headers: mediaAuthHeaders(fullMediaUrl(mediaRel)),
                  width: 36,
                  height: 36,
                  fit: BoxFit.cover,
                  placeholder: (_) => Container(
                      width: 36, height: 36, color: scheme.surfaceContainerHigh),
                  error: (_) => Container(
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
          _OfflineBanner(
            isOffline: _isUserOffline,
            isReconnecting: _isReconnecting,
            onReconnect: _reconnect,
          ),
          if (_editing != null)
            _EditBanner(
              text: _stripQuote((_editing!['content'] as String?) ?? ''),
              onCancel: _cancelEditing,
            ),
          if (_replyTo != null) _buildReplyPreview(_replyTo!),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: _isRecording
                ? _RecordingBar(
                    durationLabel: _fmtDur(_recordMs),
                    onCancel: _cancelRecording,
                    onSend: _stopAndSendRecording,
                  )
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
              // GIF/sticker tab gets a taller panel so the denser grid shows
              // ~2–3 rows at a glance (was 306 → only one big row fit). The
              // emoji tab keeps 306 so the emoji picker (fixed 262 internal
              // height) doesn't leave a gap below it.
              height: _emojiTab == 1 ? 372 : 306,
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
          onTap: () {
            // Leaving the GIF tab → drop the search keyboard so it doesn't
            // hang over the emoji grid.
            if (index == 0) FocusScope.of(context).unfocus();
            setState(() => _emojiTab = index);
          },
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

    final String headerTitle = _isGroup ? widget.groupTitle : widget.friendName;
    final String headerAvatar = _isGroup ? widget.groupAvatar : _friendAvatar;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor:
                  Theme.of(context).colorScheme.primaryContainer,
              backgroundImage: headerAvatar.isNotEmpty
                  ? authNetworkImageProvider(fullMediaUrl(headerAvatar), mediaAuthHeaders(fullMediaUrl(headerAvatar)))
                  : null,
              child: headerAvatar.isNotEmpty
                  ? null
                  : (_isGroup
                      ? const Icon(Icons.groups_rounded, size: 18)
                      : Text(
                          headerTitle.isNotEmpty
                              ? headerTitle[0].toUpperCase()
                              : '?',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 13),
                        )),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(headerTitle,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold)),
                Text(
                  _isGroup
                      ? '${widget.memberCount} members'
                      : _friendTyping
                          ? 'typing…'
                          : _isFriendOnline
                              ? 'online'
                              : _lastSeen.isNotEmpty
                                  ? 'last seen ${formatLastSeen(_lastSeen)}'
                                  : 'offline',
                  style: TextStyle(
                    fontSize: 11,
                    color: (!_isGroup && (_friendTyping || _isFriendOnline))
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
        actions: _isGroup
            ? const []
            : [
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
