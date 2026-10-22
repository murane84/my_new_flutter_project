import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'package:flutter/physics.dart' show SpringSimulation, SpringDescription;

import '../services/fcm_service.dart' show ActiveChat;
import '../services/notif_service.dart' show cancelConversationNotifications;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, compute, kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/rendering.dart' show RendererBinding;
import 'package:pasteboard/pasteboard.dart';
import 'package:image/image.dart' as img;
// Hide intl's TextDirection so the unprefixed name resolves to dart:ui's
// (needed by the ShapeBorder overrides below).
import 'package:intl/intl.dart' hide TextDirection;
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:video_player/video_player.dart';
import '../widgets/glimpse_video.dart';
import '../widgets/animated_reaction.dart';
import 'package:video_compress/video_compress.dart';
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
import '../services/web_paste.dart' as webpaste;
import '../utils/net_image.dart';
import '../utils/chat_background.dart';
import '../utils/bubble_theme.dart';
import '../utils/romantic_pattern.dart';
import '../services/media_store.dart';
import 'package:photo_manager/photo_manager.dart';
import '../widgets/chat_wallpaper_sheet.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'user_profile_sheet.dart';
import 'home_page.dart' show playlistNotifier, playbackBus;
import '../state/playback_state.dart' show providerContainer, nowPlayingProvider;
import 'relationship_space_page.dart' show spaceEventBus;
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'chat/formatted_text.dart';
import 'chat/heart_message.dart';
import '../widgets/aluta_watermark.dart';
import 'chat/conversation_media.dart';
import '../services/keystroke_sounds.dart';
import '../services/upload_manager.dart';
import '../services/heart_lock.dart';
import '../services/download_manager.dart';
import '../main.dart' show scaffoldMessengerKey;
import 'package:float_column/float_column.dart';
import 'package:linkify/linkify.dart' show linkify;
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart' as geocoding;
import 'package:open_filex/open_filex.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import '../utils/app_config.dart';
import '../utils/loose_url_linkifier.dart';
import '../services/app_busy.dart';
import '../services/aluta_mood.dart';
import '../services/moment_prefs.dart';
import '../data/glow_cards.dart';
import 'chat/attach_sheet.dart';
import 'chat/contact_picker_sheet.dart';
import 'stories/camera_capture.dart';
import '../widgets/genie_menu.dart';
import '../widgets/aluta_composer_field.dart';
import '../widgets/pixel_snap.dart';
import '../utils/readable.dart';

// Split out for maintainability (Dart parts — same library, shared
// imports & privacy, zero behaviour change):
part 'chat/chat_bubble_parts.dart';   // wallpaper, action tile, bubble
                                       // border, voice note, swipe-to-reply
part 'chat/chat_image_editor.dart';    // image preview + annotation editor
part 'chat/chat_composer_parts.dart';  // recording bar, edit + offline banners
part 'chat/chat_page_helpers_1.dart'; // _ChatPageState helpers (30 methods)
part 'chat/chat_page_helpers_2.dart'; // _ChatPageState helpers (38 methods)
part 'chat/chat_page_helpers_3.dart'; // _ChatPageState helpers (42 methods)
part 'chat/mention_overlay.dart';     // @-mentions picker (group chats)
part 'chat/heart_composer.dart';      // secret-heart tray + receipts
part 'chat/chat_unread.dart';         // "N new messages" divider + last-seen
part 'chat/chat_search.dart';         // in-chat search pill + hit stepping
part 'chat/chat_mentions_seen.dart';  // "@" stepper + DM seen avatar
part 'chat/chat_polls_admin.dart';    // group admins + polls
part 'chat/chat_rituals.dart';        // good night + on this day
part 'chat/chat_music_moments.dart';  // song reactions, dedications, voice-over-music

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
  // When set (opened from a message notification), scroll to + highlight this
  // message once the thread has loaded.
  final String? initialJumpMessageId;

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
    this.initialJumpMessageId,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  // True when this screen is showing a GROUP conversation (vs a 1:1 DM).
  bool get _isGroup => widget.isGroup && widget.conversationId != null;
  int get _cid => widget.conversationId ?? 0;

  // Key the backend uses to skip a redundant push for the chat on screen.
  String get _activeConvKey => _isGroup ? 'grp:$_cid' : 'dm:${widget.friendId}';

  void _sendActivePresence(bool active) {
    try {
      _ws.sendEvent(
          {'type': 'active_conv', 'conv': active ? _activeConvKey : null});
    } catch (_) {}
  }

  // Per-conversation wallpaper key: 'd<friendId>' for a DM, 'g<cid>' for a group.
  String get _convKey => _isGroup
      ? chatConvKey(conversationId: _cid)
      : chatConvKey(friendId: widget.friendId);

  String? _myId;
  bool _isLoading = true;
  bool _isFriendOnline = false;
  String _lastSeen = '';
  String _friendPhone = '';
  String _friendAvatar = '';
  String _myName = '';
  Timer? _draftTimer;
  String? _myAvatar;

  /// The name to show for this friend in live-session labels (banner / pill /
  /// now-playing), resolved the SAME way as the friend list: if their number is
  /// saved in the user's phone book, use that saved name; otherwise fall back to
  /// the display name we were opened with. Keeps the "streaming to …" label
  /// consistent with everything else the user sees for this contact.
  String get _livePeerLabel =>
      ContactNames.instance.nameFor(_friendPhone) ?? widget.friendName;
  // In-thread presence: avatar-anchored dots (typing) or a mic (recording),
  // no names. DM tracks the friend; groups track each member.
  bool _friendTyping = false;
  String _friendPresenceKind = 'typing'; // 'typing' | 'recording'
  Timer? _dmTypingTimer;
  // Choreography between an incoming message and the typing indicator: when a
  // message lands we hand the indicator's spot to the bubble, and if the friend
  // keeps typing the indicator rises back BELOW it a beat later.
  DateTime? _lastRxAt;
  Timer? _typingReshowTimer;
  final Map<int, ({String avatar, String kind})> _groupTypers = {};
  final Map<int, Timer> _groupTyperTimers = {};
  Timer? _recordPresenceTimer;
  bool get _showTyping =>
      _friendTyping || (_isGroup && _groupTypers.isNotEmpty);

  // Emit my presence (typing / recording) to the thread's peers. Groups also
  // carry my avatar so the indicator can show who it is without a name.
  void _sendPresence(String kind) {
    try {
      if (_isGroup) {
        _ws.sendEvent({
          'type': 'typing',
          'conv': _cid,
          'kind': kind,
          'avatar': _myAvatar ?? '',
        });
      } else {
        _ws.sendEvent({'type': 'typing', 'to': widget.friendId, 'kind': kind});
      }
    } catch (_) {}
  }

  // Drop whoever just sent a message from the "typing" state (pure mutation —
  // call inside a setState) so their indicator fades out as the bubble arrives.
  void _clearTypist(String? senderId) {
    if (_isGroup) {
      final tid = int.tryParse(senderId ?? '');
      if (tid != null && _groupTypers.remove(tid) != null) {
        _groupTyperTimers[tid]?.cancel();
        _groupTyperTimers.remove(tid);
      }
    } else {
      _friendTyping = false;
      _dmTypingTimer?.cancel();
    }
  }

  // Show the DM typing indicator — but if it arrives right on the heels of an
  // incoming message, wait a beat so it rises below the new bubble instead of
  // flashing in lock-step with it.
  void _showDmTyping(String kind) {
    void apply() {
      if (!mounted) return;
      setState(() {
        _friendTyping = true;
        _friendPresenceKind = kind;
      });
      _dmTypingTimer?.cancel();
      _dmTypingTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _friendTyping = false);
      });
    }

    final since = _lastRxAt == null
        ? const Duration(hours: 1)
        : DateTime.now().difference(_lastRxAt!);
    _typingReshowTimer?.cancel();
    if (!_friendTyping && since < const Duration(milliseconds: 400)) {
      _typingReshowTimer = Timer(const Duration(milliseconds: 280), apply);
    } else {
      apply();
    }
  }

  // One-shot fade+rise for a freshly-arrived bubble, so it eases into the spot
  // the typing indicator just vacated rather than snapping in.
  Widget _animateInWrap(Map<String, dynamic> msg, Widget child) {
    if (msg['__animateIn'] != true) return child;
    return TweenAnimationBuilder<double>(
      key: ValueKey('in-${msg['id']}'),
      tween: Tween<double>(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      builder: (_, t, c) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.translate(offset: Offset(0, (1 - t) * 8), child: c),
      ),
      child: child,
    );
  }

  String get _draftKey => 'draft_$_convKey';

  // Restore the unsent draft for this conversation (survives leaving the chat
  // or the app). Only fills an empty composer so it never clobbers live typing.
  Future<void> _loadDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final d = prefs.getString(_draftKey) ?? '';
      if (d.isNotEmpty && _ctrl.text.isEmpty && mounted) {
        _ctrl.text = d;
        _ctrl.selection = TextSelection.collapsed(offset: d.length);
        setState(() {});
      }
    } catch (_) {}
  }

  Future<void> _saveDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final t = _ctrl.text;
      if (t.trim().isEmpty) {
        await prefs.remove(_draftKey);
      } else {
        await prefs.setString(_draftKey, t);
      }
    } catch (_) {}
  }

  List<Map<String, dynamic>> _messages = [];

  // reply
  Map<String, dynamic>? _replyTo;

  // Inline "add a caption" bar for a pasted/attached file. While a
  // request is pending, the composer is replaced by a compact caption
  // panel docked in the chat view (not a full-screen modal), so it stays
  // within the conversation and never covers the mini player.
  String? _captionFileName;
  TextEditingController? _captionCtrl;
  Completer<String?>? _captionCompleter;

  // Outbox for optimistic sends: tempId -> a closure that (re)attempts the
  // send. Kept until the send succeeds so a failed bubble can retry.
  final Map<String, Future<void> Function()> _outbox = {};

  // Attachment keys (media_url) that have been saved to THIS device, so a file
  // bubble can show a "downloaded" icon instead of the fresh download arrow.
  // Persisted across restarts in SharedPreferences.
  final Set<String> _savedMediaKeys = <String>{};

  // edit-in-place: the message currently being edited, plus any reply-quote
  // prefix to preserve when saving.
  Map<String, dynamic>? _editing;
  String _editQuotePrefix = '';

  // Per-message keys + highlight id, used to scroll to a quoted original.
  final Map<String, GlobalKey> _msgKeys = {};
  String? _highlightedId;
  // Jump-to-message flash: pulse phase + a sequence id so a newer jump
  // cancels an older one mid-flash.
  bool _flashOn = false;
  int _flashSeq = 0;

  // Styles *bold* _italic_ etc. live in the composer as you type.
  final _ctrl = FormattingTextController();
  // Smart-list continuation state (bullets / numbers).
  String _lastComposerText = '';
  bool _applyingListEdit = false;
  // ── @-mentions (group tagging) — see chat/mention_overlay.dart ──────────
  List<Map<String, dynamic>> _groupMembers = [];
  String? _mentionQuery;
  int _mentionStart = -1;
  final Set<int> _mentionTicked = {};
  final _scrollCtrl = ScrollController();
  // Dedicated controller so the Listen-together picker's scrollbar can auto-hide
  // (show only while scrolling) instead of sitting over the row icons.
  final _pickerScrollCtrl = ScrollController();
  bool _showEmoji = false;
  // Compose the next message as a secret heart (message_type 'heart').
  bool _heartMode = false;
  // Secret-heart composer choices (see _buildHeartTray): the mood it's sent
  // with and, for a timed heart, the moment it opens. Reset after each send.
  String _heartMood = 'love';
  DateTime? _heartUnlockAt;
  // Server ids of hearts I just sent → their bubble plays the seal stamp once.
  final Set<String> _freshHearts = {};
  // Reply-author memory: quote first-line → {id, u(sername), p(hone)} of the
  // quoted message's author, per conversation (see chat_page_helpers_3).
  final Map<String, Map<String, String>> _quoteAuthors = {};
  // Which tab is showing in the emoji panel: 0 = emoji, 1 = GIF stickers.
  int _emojiTab = 0;
  bool _isAtBottom = true;
  bool _hasNewMsg = false;
  // Scrolled well up (e.g. after jumping to a quoted message) → show the
  // round "back to latest" button.
  bool _farFromBottom = false;
  // ── In-chat search (see chat/chat_search.dart) ─────────────────────────
  bool _searchOpen = false;
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  // The message field (rituals focus it: "keep the streak going").
  final FocusNode _composerFocus = FocusNode();
  List<String> _searchHits = const [];
  int _searchIdx = 0;
  Timer? _searchDebounce;
  bool _searchDeepLoaded = false;
  // ── "@" stepper + seen avatar (see chat/chat_mentions_seen.dart) ───────
  int? _mentionBase;
  // Group settings mirrored from the server (chat/chat_polls_admin.dart).
  bool _adminsOnly = false;
  // Rituals (chat/chat_rituals.dart): already shown/used today.
  bool _gnDoneToday = false;
  bool _memoryDoneToday = false;
  bool _annivToday = false;
  int _streakDays = 0;
  bool _streakAlive = false;
  bool _streakNudged = false;
  bool _ritualsFlagsLoaded = false;
  bool _bondRitualsRan = false;
  // Song playing when the current voice note started (its caption).
  String? _recordSong;
  bool _amAdmin = false;
  final Set<String> _mentionCleared = {};
  List<Map<String, dynamic>>? _mentionCacheOf;
  List<String> _mentionCache = const [];
  List<Map<String, dynamic>>? _seenCacheOf;
  String? _seenCache;
  // The message field has focus → the composer pill shows its brand ring.
  bool _composerFocused = false;
  // ── Unread divider (chat/chat_unread.dart) ─────────────────────────────────
  // The newest message id I'd SEEN (reached the bottom with) last time, the
  // first incoming message after it (the divider goes above it), and how many
  // arrived since. Snapshotted when the chat opens.
  int? _lastSeenAtOpen;
  String? _unreadAnchorId;
  int _unreadCount = 0;
  int _seenSavedId = 0; // last id written (avoids a prefs write per frame)

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
  Timer? _recordTimer;
  int _recordMs = 0;
  // Ticks the recording timer label WITHOUT rebuilding the whole page.
  final ValueNotifier<int> _recordMsVN = ValueNotifier<int>(0);
  String _apiBase = ''; // resolved server base for building attachment URLs

  // The caller's own bonded Our Spaces (active bonds). Keepsake / Dedicate /
  // Add-to-Playlist bring a bubble from ANY chat — a non-bonded friend's DM or
  // a group — into one of THESE, the user's own couple space, for the two of
  // them to react to privately. The destination is the user's bond, never this
  // chat's partner; when this chat IS a bonded partner's DM that space is the
  // natural default in the picker.
  List<Map<String, dynamic>> _mySpaces = const [];
  bool get _canHarmony => _mySpaces.isNotEmpty;

  // Ambient quick-stars: hidden while reading/scrolling, revealed by a genuine
  // tap for a few seconds, then they gently dissolve. Driven by a notifier so
  // only the little star buttons repaint — not the whole message list.
  final ValueNotifier<bool> _quickStarsOn = ValueNotifier<bool>(false);
  Timer? _starTimer;
  Offset? _starDownPos;

  /// Load the caller's own bonded Our Spaces so the bubble menu can offer to
  /// keep content into one of them from ANY chat. Silent + best-effort: on
  /// failure the Harmony actions simply stay hidden. Runs for DMs AND groups.
  Future<void> _loadMySpaces() async {
    try {
      final spaces = await ApiService().listSpaces();
      final bonds = spaces
          .where((s) => (s['status'] ?? 'active').toString() == 'active')
          .toList();
      if (mounted) setState(() => _mySpaces = bonds);
      _bondRituals();
    } catch (_) {
      // Leave _mySpaces empty — the Harmony actions just won't show.
    }
  }

  /// The bonded space to pre-select, if this DM happens to be with one of my
  /// bonded partners (so keeping from your partner's own chat is one tap).
  int? get _defaultKeepSpaceId {
    if (widget.isGroup || widget.friendId <= 0) return null;
    for (final s in _mySpaces) {
      final members = (s['members'] as List?) ?? const [];
      final hasPartner = members.any(
          (m) => m is Map && (m['id'] as num?)?.toInt() == widget.friendId);
      if (hasPartner) return (s['id'] as num?)?.toInt();
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    // Web: files pasted (Ctrl/Cmd+V) arrive through the browser paste event.
    if (kIsWeb) webpaste.registerClipboardPaste(_onWebPaste);
    // Seed the friend's avatar from the caller (which already knows it, e.g.
    // the friend list / header) so the per-message bubble avatars show the DP
    // immediately; the /status poll may later refresh it.
    _friendAvatar = widget.friendAvatar;
    WidgetsBinding.instance.addObserver(this);
    _viewerDismissCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220));
    AppConfig.baseUrl.then((b) {
      if (mounted) setState(() => _apiBase = b);
    });
    _ctrl.addListener(_onTextChanged);
    _loadDraft();
    _scrollCtrl.addListener(_onScroll);
    chatSearchRequest.addListener(_onSearchRequest);
    chatMediaRequest.addListener(_onMediaRequest);
    chatComposeRequest.addListener(_consumeCompose);
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumeCompose());
    // Mirror the app-wide connection status so this banner never disagrees
    // with the home footer dot / header badge.
    _isUserOffline = !ConnectionStatus.instance.isOnline;
    ConnectionStatus.instance.online.addListener(_onConnStatusChanged);
    _initChat();
    _loadMySpaces();
    _loadRitualFlags();
    _loadSavedMediaKeys();
    KeystrokeSounds.instance.init();
    HeartLock.instance.init();
    UploadManager.instance.rev.addListener(_onUploadsChanged);
    // Attachment downloads live app-wide; repaint bubbles as they progress.
    DownloadManager.instance.init();
    DownloadManager.instance.rev.addListener(_onDownloadsChanged);
    // Phone book (re)loaded → re-render @mentions with my saved names.
    ContactNames.instance.revision.addListener(_onContactNamesChanged);
    // Tell the notifier which conversation is on screen, so a foreground push
    // for THIS chat doesn't pop a redundant banner while the user reads it.
    if (_isGroup) {
      ActiveChat.instance.enterGroup(_cid.toString());
    } else {
      ActiveChat.instance.enterDm(widget.friendId.toString());
    }
    // Opening the chat clears any pending banners for it (you're reading it now).
    if (_isGroup) {
      cancelConversationNotifications(conversationId: _cid.toString());
    } else {
      cancelConversationNotifications(senderId: widget.friendId.toString());
    }

    _statusTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) {
        _checkOnlineStatus();
        // Refresh presence so the backend keeps suppressing this chat's push
        // while it's open (short TTL; leaving lets it expire quickly).
        _sendActivePresence(true);
      },
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
        _consumeSharedMedia(shared);
      });
    }
  }

  /// Send each shared-in file (works for both DMs and groups). Images go
  /// through the preview → caption → upload path; videos go straight through the
  /// video upload path (compressing big clips), mirroring the in-chat pickers.
  /// Called once, from initState.
  static const _videoExts = {
    'mp4', 'mov', 'm4v', 'webm', 'mkv', '3gp', 'avi', 'ts'
  };
  Future<void> _consumeSharedMedia(List<String> paths) async {
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
        final ext =
            name.contains('.') ? name.split('.').last.toLowerCase() : '';
        const imgExts = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'};
        if (_videoExts.contains(ext)) {
          await _sendSharedVideo(
              bytes, name.isNotEmpty ? name : 'shared.mp4', ext, p);
        } else if (imgExts.contains(ext)) {
          await _previewAndSendImage(
              bytes, name.isNotEmpty ? name : 'shared.jpg', 'image/jpeg');
        } else {
          // Any other file (pdf, audio, apk, doc, zip …) — send as a document.
          await _uploadAndSend(
            bytes: bytes,
            filename: name.isNotEmpty ? name : 'shared_file',
            mime: _mimeForExt(ext),
            type: 'file',
            ephemeral: bytes.length > 15 * 1024 * 1024,
          );
        }
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
    if (_isAtBottom) _markSeenUpToNewest();
    chatSearchRequest.removeListener(_onSearchRequest);
    chatMediaRequest.removeListener(_onMediaRequest);
    _browserAnim.dispose();
    if (_mediaBrowser != null) {
      // Not mid-teardown: let the host's header button settle next frame.
      WidgetsBinding.instance
          .addPostFrameCallback((_) => chatMediaOpen.value = false);
    }
    chatComposeRequest.removeListener(_consumeCompose);
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _composerFocus.dispose();
    _recordMsVN.dispose();
    WidgetsBinding.instance.removeObserver(this);
    if (kIsWeb) webpaste.unregisterClipboardPaste();
    // Release any in-flight caption request so its awaiter unwinds.
    if (_captionCompleter != null && !_captionCompleter!.isCompleted) {
      _captionCompleter!.complete(null);
    }
    ConnectionStatus.instance.online.removeListener(_onConnStatusChanged);
    _statusTimer?.cancel();
    _pollTimer?.cancel();
    _typingTimer?.cancel();
    for (final t in _groupTyperTimers.values) {
      t.cancel();
    }
    _dmTypingTimer?.cancel();
    _typingReshowTimer?.cancel();
    _draftTimer?.cancel();
    _saveDraft();
    _keepAliveTimer?.cancel();
    _connectivitySub?.cancel();
    _recordTimer?.cancel();
    _recordPresenceTimer?.cancel();
    _recorder.dispose();
    _ctrl.dispose();
    _scrollCtrl.dispose();
    _pickerScrollCtrl.dispose();
    _viewerPageCtrl?.dispose();
    _viewerDismissCtrl?.dispose();
    _starTimer?.cancel();
    _quickStarsOn.dispose();
    if (_isGroup) {
      ActiveChat.instance.leaveGroup(_cid.toString());
    } else {
      ActiveChat.instance.leaveDm(widget.friendId.toString());
    }
    _sendActivePresence(false);
    _ws.close();
    UploadManager.instance.rev.removeListener(_onUploadsChanged);
    DownloadManager.instance.rev.removeListener(_onDownloadsChanged);
    ContactNames.instance.revision.removeListener(_onContactNamesChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _saveDraft();
    }
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
        _groupMembers = []; // reloaded by _initChat for the new group
        _closeMentionPicker();
        _resetRituals();
      });
      _initChat(); // _initChat runs _maybeInitialJump after the load
      _loadRitualFlags();
      WidgetsBinding.instance.addPostFrameCallback((_) => _consumeCompose());
    } else if (widget.initialJumpMessageId != null &&
        widget.initialJumpMessageId != old.initialJumpMessageId) {
      // Same thread already open + a notification for a NEW message tapped →
      // jump to it (no reload needed).
      _maybeInitialJump(widget.initialJumpMessageId);
    }
  }

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> _initChat() async {
    // OFFLINE-FIRST: recover my user id and the cached messages WITHOUT touching
    // the network, so a chat opened offline shows instantly and never spins
    // forever. The user id is the crux — it's part of the cache key, so without
    // a locally-cached copy an offline open would look under the wrong key and
    // find nothing.
    try {
      final prefs = await SharedPreferences.getInstance();
      _myId ??= prefs.getString('my_user_id');
    } catch (_) {}
    // Reply-author memory first, so the first paint of quote headers uses it
    // (and doesn't overwrite it with only the currently-loaded originals).
    await _loadQuoteAuthors();
    await _loadLastSeen(); // where I left off → the "N new messages" divider
    await _loadCachedMessages(); // show cached messages instantly (clears loader)
    if (mounted && _isLoading) setState(() => _isLoading = false);
    _syncUploads(); // re-attach any media upload still running for this chat

    // Best-effort refresh from the network. On success this also re-caches the
    // user id (see ApiService.getUserData); offline it simply no-ops.
    final token = await getToken();
    if (token != null) {
      final user = await ApiService().getCurrentUser(token);
      final freshId = user['id']?.toString();
      if (freshId != null && freshId.isNotEmpty) _myId = freshId;
      final un = (user['username'] ?? '').toString();
      if (un.isNotEmpty) _myName = un;
      final av = (user['avatar_url'] as String?)?.trim();
      if (av != null && av.isNotEmpty) _myAvatar = av;
    }

    await _loadMessages();        // fetch fresh from network (best-effort)
    if (_isGroup) unawaited(_loadGroupMembers()); // for the @-mention picker
    _placeUnreadDivider();        // "N new messages" + open where I left off
    if (_isGroup) {
      // Mentions already on screen at open don't need the "@" stepper.
      Future.delayed(const Duration(milliseconds: 700), () {
        if (mounted) _clearVisibleMentions();
      });
    }
    _maybeInitialJump();          // opened from a notification → jump to it
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
    if (uid == null) {
      // No id yet (offline before ever loading online) — don't sit on a
      // spinner; show whatever the cache has (possibly empty) instead.
      if (mounted && _isLoading) setState(() => _isLoading = false);
      return;
    }

    try {
      final msgs = await appBusy.run(() => _isGroup
          ? ApiService().fetchConversationMessages(_cid, skip: 0, limit: 60)
          : ApiService().fetchMessagesBetween(
              uid, widget.friendId,
              skip: 0, limit: 60,
            ));

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

  // ── Chat wallpaper (photo reused from Our Space, or the motif pattern) ────
  String? _chatBgUrl;
  Future<File?>? _chatBgFuture;


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

  int _lastCachedAck = 0;

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

  // ── WebSocket events ──────────────────────────────────────────────────────

  // The "@" stepper / seen-avatar caches key on the _messages list identity,
  // but many paths mutate it in place — so any rebuild drops them.
  @override
  void setState(VoidCallback fn) {
    _mentionCacheOf = null;
    _seenCacheOf = null;
    super.setState(fn);
  }

  void _handleWsEvent(Map<String, dynamic> event) {
    final type = event['type'];
    if (!mounted) return;
    if (_handleGroupMetaWs(type?.toString(), event)) return;

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
          var inserted = false;
          setState(() {
            final id = msg['id'].toString();
            if (!_messages.any((m) => m['id'].toString() == id)) {
              if (incoming) {
                // Hand the typing indicator's spot to the real message: fade
                // the bubble in, and clear the typist so the indicator fades
                // out (it re-rises below the bubble if they keep typing).
                msg['__animateIn'] = true;
                _clearTypist(msg['sender_id']?.toString());
                _lastRxAt = DateTime.now();
              }
              _messages.insert(0, msg);
              inserted = true;
            }
          });
          if (incoming && inserted) {
            // Let the fade play once, then retire the flag so scrolling the
            // bubble back into view doesn't replay it.
            Timer(const Duration(milliseconds: 360),
                () => msg['__animateIn'] = false);
          }
          if (incoming) {
            // Soft ding for a new message in the chat you're looking at
            // (gated by the Message tones setting).
            if (inserted) KeystrokeSounds.instance.playReceived();
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
    } else if (type == 'heart_unsealed') {
      // A timed heart's moment came: swap its note in (server hearts.py).
      final data = event['data'] as Map<String, dynamic>?;
      final mid = data?['id']?.toString();
      if (mid != null) {
        final idx = _messages.indexWhere((m) => m['id'].toString() == mid);
        if (idx != -1) {
          setState(() {
            _messages[idx]['content'] = data!['content'];
            _messages[idx]['unlock_at'] = data['unlock_at'];
          });
        }
      }
    } else if (type == 'heart_opened') {
      // They opened the heart I sent → "Opened 2:14 PM 💗" under it.
      final data = event['data'] as Map<String, dynamic>?;
      final mid = data?['message_id']?.toString();
      if (mid != null) {
        final idx = _messages.indexWhere((m) => m['id'].toString() == mid);
        if (idx != -1) {
          setState(() {
            _messages[idx]['opened_at'] = data!['opened_at'];
            if (data['heart_opens'] != null) {
              _messages[idx]['heart_opens'] = data['heart_opens'];
            }
          });
          HapticFeedback.lightImpact();
        }
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
      final uid = event['user_id'];
      final convId = event['conversation_id']?.toString();
      final kind = (event['kind'] ?? 'typing').toString();
      if (convId != null && convId.isNotEmpty) {
        // Group presence for THIS thread (ignore my own and other conversations).
        if (_isGroup && convId == _cid.toString() && uid.toString() != _myId) {
          final tid = int.tryParse(uid.toString());
          if (tid != null) {
            final avatar = (event['avatar'] ?? '').toString();
            void apply() {
              if (!mounted) return;
              setState(() => _groupTypers[tid] = (avatar: avatar, kind: kind));
              _groupTyperTimers[tid]?.cancel();
              _groupTyperTimers[tid] = Timer(const Duration(seconds: 5), () {
                if (!mounted) return;
                setState(() => _groupTypers.remove(tid));
                _groupTyperTimers.remove(tid);
              });
            }

            final since = _lastRxAt == null
                ? const Duration(hours: 1)
                : DateTime.now().difference(_lastRxAt!);
            if (!_groupTypers.containsKey(tid) &&
                since < const Duration(milliseconds: 400)) {
              Timer(const Duration(milliseconds: 280), apply);
            } else {
              apply();
            }
          }
        }
      } else if (uid.toString() == widget.friendId.toString()) {
        _showDmTyping(kind);
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
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => LiveSessionScreen.host(
        token: token,
        myUserId: myUserId,
        receiverId: widget.friendId,
        audioBytes: bytes,
        title: _titleFromPath(chosenPath),
        peerName: _livePeerLabel,
        startPositionMs: startPositionMs,
      ),
    ));
  }

  // ── Status ────────────────────────────────────────────────────────────────

  Future<void> _checkOnlineStatus() async {
    final status = await ApiService().fetchFriendStatus(widget.friendId);
    if (!mounted) return;
    final online = status['is_online'] ?? false;
    final lastSeen = status['last_seen'] ?? '';
    final newPhone = (status['phone'] as String?) ?? '';
    if (newPhone != _friendPhone) {
      _friendPhone = newPhone;
      // Rebuild so the "Add to contacts" prompt can appear/disappear.
      if (mounted) setState(() {});
    }
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

  Future<void> _forwardTo(
      Map<String, dynamic> msg, Map<String, dynamic> friend) async {
    final fid = friend['id'];
    final fidInt = fid is int ? fid : int.tryParse(fid.toString());
    if (fidInt == null) return;
    final type = (msg['message_type'] as String?) ?? 'text';
    final content = _stripQuote((msg['content'] as String?) ?? '');
    // Forward media as a FRESH copy (cache-first, re-uploaded): the new
    // recipient was never a party to the original message, so re-uploading
    // makes them the authorized recipient and survives the original's purge.
    final rel = (msg['media_url'] as String?) ?? '';
    String? outUrl = msg['media_url'] as String?;
    if (rel.isNotEmpty) {
      outUrl =
          await _durableMediaRef(rel, (msg['media_mime'] as String?) ?? '');
      if (!mounted) return;
    }
    try {
      final sent = await ApiService().sendMessage(
        fidInt,
        content,
        messageType: type,
        mediaUrl: outUrl,
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
    // Scrolling / swiping dissolves the quick stars.
    if (_quickStarsOn.value) _quickStarsOn.value = false;
    _starTimer?.cancel();
    final atBottom = _scrollCtrl.offset <=
        _scrollCtrl.position.minScrollExtent + 40;
    final far = _scrollCtrl.offset - _scrollCtrl.position.minScrollExtent >
        _scrollCtrl.position.viewportDimension * 0.6;
    if (atBottom != _isAtBottom || far != _farFromBottom) {
      setState(() {
        _isAtBottom = atBottom;
        _farFromBottom = far;
      });
    }
    if (atBottom && _hasNewMsg) setState(() => _hasNewMsg = false);
    if (atBottom) _markSeenUpToNewest();
    if (_isGroup && _pendingMentions.isNotEmpty) _clearVisibleMentions();
  }

  /// Back to the newest message. From far up, jump most of the way first
  /// (so it doesn't scroll for seconds), then glide the last screen.
  void _jumpToLatest() {
    if (!_scrollCtrl.hasClients) return;
    HapticFeedback.selectionClick();
    final pos = _scrollCtrl.position;
    final screen = pos.viewportDimension;
    if (pos.pixels - pos.minScrollExtent > screen * 3) {
      _scrollCtrl.jumpTo(pos.minScrollExtent + screen * 1.5);
    }
    _scrollCtrl.animateTo(
      pos.minScrollExtent,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
    setState(() => _hasNewMsg = false);
  }

  void _onChatPointerDown(PointerDownEvent e) => _starDownPos = e.position;

  void _onChatPointerUp(PointerUpEvent e) {
    final d = _starDownPos;
    _starDownPos = null;
    if (d == null) return;
    // A tap (finger barely moved) reveals; a scroll / swipe does not.
    if ((e.position - d).distance < 14) _pokeStars();
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
    if (!_applyingListEdit) {
      // Optional subtle typing feedback (off by default; Appearance setting).
      final len = _ctrl.text.length;
      if (len > _lastComposerText.length) {
        KeystrokeSounds.instance.playType();
      } else if (len < _lastComposerText.length) {
        KeystrokeSounds.instance.playDelete();
      }
    }
    if (!_applyingListEdit) _maybeContinueList();
    if (!_applyingListEdit) _maybeFractionReplace();
    if (!_applyingListEdit && _isGroup) _updateMentionQuery();
    setState(() {});
    _markActivity();
    if (!_iTyping && !_isRecording) {
      _iTyping = true;
      _sendPresence('typing');
    }
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 2), () {
      _iTyping = false;
    });
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 400), _saveDraft);
    _lastComposerText = _ctrl.text;
  }

  // ── Send ──────────────────────────────────────────────────────────────────

  Future<void> _sendMessage() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;

    // @-mentions for this send (group only). Derived from the final text, so a tag deleted before sending is never
    // sent (and a restored draft's tags still count).
    final tagged = _resolveMentions(text);
    final List<int>? outMentions = tagged.ids.isEmpty ? null : tagged.ids;
    final bool? outMentionAll = tagged.all ? true : null;

    String content = text;
    // A heart carries only its note (the heart bubble has no quote area).
    if (_replyTo != null && !_heartMode) {
      final quoted = _replyQuoteText(_replyTo!);
      final lines = quoted.split('\n').take(2).join('\n');
      content = '> $lines\n\n$text';
      // I can see whose message this is right now — remember it on-device.
      _rememberQuoteAuthor(lines, _replyTo!);
    }

    final heart = _heartMode;
    final heartMood = heart ? _heartMood : null;
    final unlockAt = heart ? _heartUnlockAt : null;
    _markActivity();
    _ctrl.clear();
    setState(() {
      _replyTo = null;
      _heartMode = false;
      _heartMood = 'love';
      _heartUnlockAt = null;
    });
    _saveDraft(); // text now empty → clears the stored draft
    if (_isGroup) setState(_closeMentionPicker);

    final tempId = _newTempId();
    final optimistic =
        _optimisticMsg(tempId, heart ? 'heart' : 'text', content);
    if (heart) {
      optimistic['heart_mood'] = heartMood;
      if (unlockAt != null) {
        // Sealed for me too until it opens — mirror what the server returns.
        optimistic['unlock_at'] = unlockAt.toUtc().toIso8601String();
        optimistic['content'] = '';
      }
    }
    _insertOptimistic(optimistic);

    Future<void> attempt() async {
      try {
        final sent = await appBusy.run(() => ApiService().sendMessage(
            widget.friendId, content,
            messageType: heart ? 'heart' : 'text',
            conversationId: widget.conversationId,
            mentions: outMentions,
            mentionAll: outMentionAll,
            heartMood: heartMood,
            unlockAt: unlockAt));
        if (heart && sent != null) {
          // A server that doesn't (yet) store heart fields echoes the message
          // without them — keep what I chose so my bubble doesn't snap back to
          // red "with love" / lose its seal.
          sent['heart_mood'] ??= heartMood;
          if (unlockAt != null) {
            sent['unlock_at'] ??= unlockAt.toUtc().toIso8601String();
          }
          final sid = sent['id'].toString();
          _freshHearts.add(sid);
          Timer(const Duration(milliseconds: 1200),
              () => _freshHearts.remove(sid));
        }
        _replaceOptimistic(tempId, sent);
        if (sent == null && mounted) {
          _showErrorSnack('Message failed — tap the ! to retry.');
        }
      } catch (_) {
        _replaceOptimistic(tempId, null);
        if (mounted) _showErrorSnack('Failed to send — tap the ! to retry.');
      }
    }

    _outbox[tempId] = attempt;
    unawaited(attempt());
  }

  /// "Say hi" card for a brand-new conversation: the Aluta mark, a friendly
  /// line, and a one-tap starter that drops "Hi 👋" into the composer.
  Widget _emptyChatHello(ColorScheme scheme, bool isDark) {
    final who = _isGroup ? widget.groupTitle : _livePeerLabel;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 32),
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
      constraints: const BoxConstraints(maxWidth: 320),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: isDark ? 0.86 : 0.92),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
            color: scheme.primary.withValues(alpha: isDark ? 0.28 : 0.14)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.10),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.asset('assets/images/logo.png',
                width: 48,
                height: 48,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Icon(Icons.chat_bubble_rounded,
                    size: 40, color: scheme.primary)),
          ),
          const SizedBox(height: 12),
          Text(
            _isGroup ? 'Welcome to $who' : 'Start your story with $who',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w800,
                color: scheme.onSurface),
          ),
          const SizedBox(height: 6),
          Text(
            'Messages, songs and secret hearts you share will live here.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          Builder(builder: (_) {
            // The nudge follows the time of day (AlutaMood).
            final (label, hi) = AlutaMood.opener();
            return FilledButton.tonalIcon(
              onPressed: () {
                _ctrl.value = TextEditingValue(
                  text: hi,
                  selection: TextSelection.collapsed(offset: hi.length),
                );
                setState(() {});
              },
              icon: Text(hi.characters.last, style: const TextStyle(fontSize: 16)),
              label: Text(label),
            );
          }),
        ],
      ),
    );
  }

  void _onDownloadsChanged() {
    if (mounted) setState(() {});
  }

  void _onContactNamesChanged() {
    if (!mounted || !_isGroup) return;
    _publishMentionNames();
    setState(() {});
  }

  void _insertOptimistic(Map<String, dynamic> msg) {
    if (!mounted) return;
    setState(() => _messages.insert(0, msg));
    _scrollToBottom();
  }

  /// Rebuild hook for the part-file helper extensions, which can't call the
  /// protected [setState] directly. They mutate state inside [fn] and this
  /// triggers the repaint.
  void rebuildWith(void Function() fn) {
    if (!mounted) return;
    setState(fn);
  }

  // ── "Saved to device" memory (per attachment) ──────────────────────────────
  Future<void> _loadSavedMediaKeys() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList('chat_saved_media');
      if (list != null && list.isNotEmpty) {
        _savedMediaKeys.addAll(list);
        if (mounted) setState(() {});
      }
    } catch (_) {}
  }

  void _markMediaSaved(String? key) {
    if (key == null || key.isEmpty || _savedMediaKeys.contains(key)) return;
    _savedMediaKeys.add(key);
    if (mounted) setState(() {});
    () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        // Cap the list so it can't grow without bound.
        final keep = _savedMediaKeys.toList();
        await prefs.setStringList(
            'chat_saved_media',
            keep.length > 500 ? keep.sublist(keep.length - 500) : keep);
      } catch (_) {}
    }();
  }

  // Swap a pending bubble for the real server message (success) or flag it
  // failed (so the tick slot shows a tappable retry). Dedupes if a poll already
  // pulled the real message in.
  void _replaceOptimistic(String tempId, Map<String, dynamic>? sent) {
    if (!mounted) return;
    setState(() {
      final idx = _messages.indexWhere((m) => m['id'] == tempId);
      if (sent != null) {
        _outbox.remove(tempId);
        if (idx != -1) _messages.removeAt(idx);
        if (!_messages.any((m) => m['id'] == sent['id'])) {
          _messages.insert(0, sent);
        }
      } else if (idx != -1) {
        _messages[idx]['status'] = 'failed';
      }
    });
    if (sent != null) {
      _saveMessagesCache();
      // Light whoosh once the message is actually sent (Message tones setting).
      KeystrokeSounds.instance.playSent();
    }
  }

  // Keep this chat in sync with the persistent upload manager: show in-flight
  // uploads (incl. ones started before navigating away), live progress, and
  // swap a finished upload's optimistic bubble for the real sent message.
  void _onUploadsChanged() {
    if (mounted) _syncUploads();
  }

  void _syncUploads() {
    if (!mounted) return;
    final key = _activeConvKey;
    var changed = false;
    for (final up in UploadManager.instance.active(key)) {
      if (!_messages.any((m) => m['id'] == up.optimistic['id'])) {
        _messages.insert(0, up.optimistic);
        changed = true;
      }
    }
    for (final d in UploadManager.instance.drainDone(key)) {
      final tempId = d['tempId'];
      final sent = d['sent'] as Map<String, dynamic>?;
      final i = _messages.indexWhere((m) => m['id'].toString() == tempId);
      if (i != -1) {
        _messages.removeAt(i);
        changed = true;
      }
      if (sent != null && !_messages.any((m) => m['id'] == sent['id'])) {
        _messages.insert(0, sent);
        changed = true;
      }
    }
    // Progress mutates the shared optimistic map in place, so rebuild whenever
    // this chat has a live upload, even with no structural change.
    if (changed || UploadManager.instance.active(key).isNotEmpty) {
      setState(() {});
    }
    if (changed) _saveMessagesCache();
  }

  // Re-run a failed send (tapped from the retry marker in the tick slot).
  void _retrySend(Map<String, dynamic> msg) {
    final tempId = msg['id']?.toString();
    if (tempId == null) return;
    // A media upload's retry lives in the manager (it survives navigation).
    final key = _activeConvKey;
    if (UploadManager.instance.has(key, tempId)) {
      setState(() => msg['status'] = 'sending');
      UploadManager.instance.retry(key, tempId);
      return;
    }
    final job = _outbox[tempId];
    if (job == null) return;
    setState(() => msg['status'] = 'sending');
    unawaited(job());
  }

  // ── Media sharing ───────────────────────────────────────────────────────
  /// Build a full URL from a relative attachment path (`/attachments/<id>`).
  String fullMediaUrl(String rel) =>
      rel.startsWith('http') ? rel : '$_apiBase$rel';

  bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  void _openAttachSheet() {
    // Dismiss the keyboard and open immediately — the menu reads the "+"
    // position live (see _showGeniePanel), so it follows the composer down as
    // the keyboard retracts instead of pinning to the raised spot.
    FocusScope.of(context).unfocus();

    // Run an action after closing the menu (the close plays the genie reverse).
    void act(VoidCallback fn) {
      Navigator.of(context).pop();
      fn();
    }

    _showGeniePanel(
      anchorKey: _attachBtnKey,
      label: 'Attach',
      builder: (ctx, anchor) {
        final topInset = MediaQuery.of(ctx).padding.top;
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: (anchor.top - topInset - 24).clamp(200.0, 560.0),
          ),
          child: AttachSheet(
            isMobile: _isMobile,
            compact: true,
            onGallery: () => act(() => _pickGalleryImages()),
            onVideo: () => act(_pickVideo),
            onCamera: () => act(() => _pickImage(ImageSource.camera)),
            onLocation: () => act(_shareLocation),
            onContact: () => act(_shareContact),
            onDocument: () => act(_pickDocument),
            onListenTogether: () => act(_startListenTogether),
            onPoll: _isGroup ? () => act(_openPollComposer) : null,
            onPickPhoto: (bytes, name) =>
                act(() => _previewAndSendImage(bytes, name, 'image/jpeg')),
          ),
        );
      },
    );
  }

  // ── Location share ─────────────────────────────────────────────────────────
  /// Share the user's current location as a `location` message (content is a
  /// small JSON `{lat,lng}`). Asks for permission at share time; the bubble
  /// renders a pin card with "Open in Maps".
  Future<void> _shareLocation() async {
    if (!_isMobile) {
      if (mounted) showToast(context, 'Location sharing is available on mobile');
      return;
    }
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted) {
          showToast(context, 'Turn on location to share it',
              type: ToastType.info);
        }
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        if (mounted) {
          showToast(context, 'Location permission needed to share it',
              type: ToastType.info);
        }
        return;
      }
      if (mounted) showToast(context, 'Getting your location…');

      // A high-accuracy GPS fix can stall indoors, so try progressively: a
      // recent cached fix (instant), then a fresh high-accuracy one capped at
      // 12s, then a looser network fix. Whichever we end up with is sent.
      Position? pos;
      try {
        pos = await Geolocator.getLastKnownPosition();
      } catch (_) {}
      try {
        pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 12),
          ),
        );
      } on TimeoutException {
        // keep the cached fix if we have one
      } catch (_) {
        try {
          pos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.medium,
              timeLimit: Duration(seconds: 8),
            ),
          );
        } catch (_) {}
      }

      if (pos == null) {
        if (mounted) {
          showToast(context,
              'Could not get your location — move to open sky and retry',
              type: ToastType.error);
        }
        return;
      }

      // Best-effort reverse geocode to a readable address. Never blocks the
      // send — coordinates alone are enough if the geocoder is unavailable.
      String address = '';
      try {
        final marks = await geocoding
            .placemarkFromCoordinates(pos.latitude, pos.longitude)
            .timeout(const Duration(seconds: 5));
        if (marks.isNotEmpty) {
          final m = marks.first;
          address = [
            m.name,
            m.subLocality,
            m.locality,
            m.administrativeArea,
            m.country,
          ]
              .where((p) => p != null && p.trim().isNotEmpty)
              .map((p) => p!.trim())
              .toSet()
              .join(', ');
        }
      } catch (_) {}

      final payload = jsonEncode({
        'lat': pos.latitude,
        'lng': pos.longitude,
        if (address.isNotEmpty) 'address': address,
      });
      await _sendStructured('location', payload);
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not get your location',
            type: ToastType.error);
      }
    }
  }

  // ── Contact share ──────────────────────────────────────────────────────────
  /// Session cache of the phone book (names only) so re-opening the picker is
  /// instant after the first load.
  List<Contact>? _contactsCache;

  /// Pick a phone contact and share it as a `contact` message (content is JSON
  /// `{name, phone, phones}`). Uses an IN-APP picker that reads the phone book
  /// directly — NOT the OS "external pick" intent, which some OEMs (MIUI/Xiaomi)
  /// misroute to the file/document chooser. The picker opens instantly and loads
  /// names first (fast on large phone books); the chosen contact's number is
  /// fetched only on selection.
  Future<void> _shareContact() async {
    if (!_isMobile) {
      if (mounted) showToast(context, 'Contact sharing is available on mobile');
      return;
    }
    try {
      if (!await FlutterContacts.requestPermission(readonly: true)) {
        if (mounted) {
          showToast(context, 'Contacts permission needed to share a contact',
              type: ToastType.info);
        }
        return;
      }
      if (!mounted) return;
      // Opens immediately (spinner while it loads names only) — no UI freeze.
      final picked = await showModalBottomSheet<Contact>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => ContactPickerSheet(
          initial: _contactsCache,
          onLoaded: (list) => _contactsCache = list,
        ),
      );
      if (picked == null) return; // user backed out
      // The list was loaded names-only for speed — fetch THIS contact's
      // numbers now (a single fast lookup).
      var contact = picked;
      if (contact.phones.isEmpty) {
        final full =
            await FlutterContacts.getContact(picked.id, withProperties: true);
        if (full != null) contact = full;
      }
      final name = contact.displayName.trim();
      final phones = contact.phones
          .map((p) => p.number.trim())
          .where((n) => n.isNotEmpty)
          .toList();
      if (name.isEmpty && phones.isEmpty) {
        if (mounted) showToast(context, 'That contact had no details to share');
        return;
      }
      var phone = phones.isNotEmpty ? phones.first : '';
      // Multiple numbers → let the user pick which one to share.
      if (phones.length > 1 && mounted) {
        final chosen = await _chooseNumber(name, phones);
        if (chosen == null) return;
        phone = chosen;
      }
      final payload = jsonEncode({
        'name': name,
        'phone': phone,
        'phones': phones,
      });
      await _sendStructured('contact', payload);
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not share that contact',
            type: ToastType.error);
      }
    }
  }

  /// Send a structured (non-media) message — `location` / `contact` — whose
  /// JSON payload lives in `content`. Mirrors [_sendGif]'s optimistic insert.
  /// The one-tap answer under a status nudge: wave back, or — for a music
  /// status — say yes to listening together.
  Widget _statusNudgeAnswer(bool music, Color tint) {
    final label = music ? '🎧 Let\'s listen' : '👋 Wave back';
    final reply = music ? '🎧 Yes! Let\'s listen together' : '👋';
    return Material(
      color: tint.withValues(alpha: 0.14),
      shape: StadiumBorder(side: BorderSide(color: tint.withValues(alpha: 0.5))),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: () => _sendStructured('text', reply),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(label,
              style: TextStyle(
                  color: tint, fontWeight: FontWeight.w700, fontSize: 12.5)),
        ),
      ),
    );
  }

  Future<void> _sendStructured(String type, String content) async {
    try {
      final sent = await appBusy.run(() => ApiService().sendMessage(
            widget.friendId,
            content,
            messageType: type,
            conversationId: widget.conversationId,
          ));
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
    } catch (_) {
      if (mounted) showToast(context, 'Could not send', type: ToastType.error);
    }
  }

  /// Send a GIF sticker chosen from the GIF tab. The GIF lives on GIPHY's CDN,
  /// so we send its remote URL as an image message — no upload needed, and the
  /// bubble's CachedNetworkImage animates it. Closes the panel afterwards.
  Future<void> _sendGif(String url) async {
    setState(() => _showEmoji = false);
    try {
      final sent = await appBusy.run(() => ApiService().sendMessage(
            widget.friendId,
            '',
            messageType: 'image',
            mediaUrl: url,
            mediaName: 'sticker.gif',
            mediaMime: 'image/gif',
            conversationId: widget.conversationId,
          ));
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

  /// Pick a video from the gallery and send it. Large clips are compressed
  /// on-device (mobile only) so they fit the upload cap; desktop/web fall back
  /// to the original and a clear message if it's still too big.
  Future<void> _pickVideo() async {
    try {
      final x = await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (x == null) return;
      await _processAndSendVideo(x);
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not pick video', type: ToastType.error);
      }
    }
  }

  /// Compress (mobile), cap-check and send a video FILE as a 'video' message.
  /// Shared by the gallery picker and the in-app camera (recorded clips).
  Future<void> _processAndSendVideo(XFile x) async {
    try {
      final name0 = x.name;
      final ext =
          name0.contains('.') ? name0.split('.').last.toLowerCase() : 'mp4';
      String mime = ext == 'mov'
          ? 'video/quicktime'
          : (ext == 'webm' ? 'video/webm' : 'video/mp4');
      String filename = name0.isNotEmpty
          ? name0
          : 'video_${DateTime.now().millisecondsSinceEpoch}.mp4';

      List<int> bytes = await x.readAsBytes();
      if (bytes.isEmpty) {
        if (mounted) {
          showToast(context, 'Could not read video', type: ToastType.error);
        }
        return;
      }
      const cap = 200 * 1024 * 1024;
      const compressAbove = 12 * 1024 * 1024;

      // Large clips: shrink on-device so they fit the cap (mobile native only).
      if (!kIsWeb && _isMobile && bytes.length > compressAbove) {
        if (mounted) showToast(context, 'Compressing video…');
        try {
          final info = await VideoCompress.compressVideo(
            x.path,
            quality: VideoQuality.MediumQuality,
            deleteOrigin: false,
            includeAudio: true,
          );
          final cf = info?.file;
          if (cf != null) {
            final cb = await cf.readAsBytes();
            if (cb.isNotEmpty && cb.length < bytes.length) {
              bytes = cb;
              mime = 'video/mp4';
              final dot = filename.lastIndexOf('.');
              filename =
                  '${dot > 0 ? filename.substring(0, dot) : filename}.mp4';
            }
          }
        } catch (_) {/* keep the original bytes on any failure */}
      }

      if (bytes.length > cap) {
        if (mounted) {
          showToast(context, 'Video is too large to send (max 200 MB).',
              type: ToastType.error);
        }
        return;
      }
      await _uploadAndSend(
          bytes: bytes,
          filename: filename,
          mime: mime,
          type: 'video',
          // Big clips ride ephemeral: purged from the server once the
          // recipient caches them (GlimpseVideo caches on play) or after the
          // TTL, so a 200 MB video never lives on the server long-term.
          ephemeral: bytes.length > 15 * 1024 * 1024);
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not send video', type: ToastType.error);
      }
    } finally {
      try {
        await VideoCompress.deleteAllCache();
      } catch (_) {}
    }
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
          // Big files are purged from the server once cached (cache-then-purge).
          ephemeral: bytes.length > 15 * 1024 * 1024,
        );
      }
    } catch (_) {
      if (mounted) showToast(context, 'Could not pick file', type: ToastType.error);
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
      _recordMsVN.value = 0;
      // Recording over music → remember the song for the note's caption.
      _recordSong = _nowPlayingTitle();
      setState(() => _isRecording = true);
      // Tell peers I'm recording (refreshed so their indicator stays alive).
      _iTyping = false;
      _sendPresence('recording');
      _recordPresenceTimer?.cancel();
      _recordPresenceTimer = Timer.periodic(
          const Duration(seconds: 2), (_) => _sendPresence('recording'));
      _recordTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted) return;
        _recordMs += 200;
        _recordMsVN.value = _recordMs;
      });
    } catch (_) {
      if (mounted) showToast(context, 'Could not start recording', type: ToastType.error);
    }
  }

  Future<void> _cancelRecording() async {
    _recordTimer?.cancel();
    _recordPresenceTimer?.cancel();
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
    _recordPresenceTimer?.cancel();
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
        caption: _voiceMusicCaption(),
      );
      _recordSong = null;
    } catch (_) {
      if (mounted) showToast(context, 'Could not send recording', type: ToastType.error);
    } finally {
      if (mounted) setState(() => _recordMs = 0);
    }
  }

  // One persisted-file future per image URL (memoised so rebuilds don't
  // re-download or flicker). Persisting the moment a bubble renders is what
  // lets images survive the server's store-and-forward purge.
  final Map<String, Future<File?>> _imgFileCache = {};

  // A fixed-width portrait thumbnail for the image+caption card.
  Widget _imageThumb(String url, double w, double ar) {
    return GestureDetector(
      onTap: () => _openImageViewer(url),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: SizedBox(
          width: w,
          child: AspectRatio(aspectRatio: ar, child: _imageData(url)),
        ),
      ),
    );
  }

  // In-body photo viewer state (fills only the conversation card so the
  // header + composer stay live and the user can keep typing / replying).
  List<String>? _viewerImages;

  // Songs / Media / Links / Docs browser, shown inside the chat panel (under
  // the conversation header, above the composer) like the photo viewer.
  Widget? _mediaBrowser;
  // The history the open browser was built from (for "Show in chat").
  List<Map<String, dynamic>> _browserMsgs = const [];

  // One door, both ways: the panel slides in from the left (the way the
  // back arrow points) with a fade, and leaves back out through the same
  // side — the exit is the entry played in reverse, never a snap.
  late final AnimationController _browserAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      reverseDuration: const Duration(milliseconds: 240));
  late final Animation<double> _browserIn = CurvedAnimation(
      parent: _browserAnim,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic);
  bool _browserClosing = false;
  Key? _browserKey;

  /// [instant]: already off screen (swiped away) — just remove it.
  void _closeMediaBrowser({bool instant = false}) {
    if (_mediaBrowser == null) return;
    chatMediaOpen.value = false;
    void remove() {
      if (!mounted) return;
      setState(() {
        _mediaBrowser = null;
        _browserMsgs = const [];
        _browserKey = null;
        _browserClosing = false;
      });
    }
    if (instant) {
      _browserAnim.value = 0;
      remove();
      return;
    }
    if (_browserClosing) return;
    _browserClosing = true;
    _browserAnim.reverse().whenComplete(() {
      if (_browserClosing) remove();
    });
  }

  // From the viewer opened out of the browser: close both, land on the message.
  void _showViewerItemInChat(Map<String, dynamic> msg) {
    final id = msg['id']?.toString() ?? '';
    final src = _browserMsgs;
    _closeViewer();
    _closeMediaBrowser();
    _jumpFromBrowser(id, src);
  }

  // A shared song row in the browser plays right there, with the same player
  // the chat bubble uses.
  Widget _browserSongPlayer(Map<String, dynamic> msg) {
    final scheme = Theme.of(context).colorScheme;
    final rel = (msg['media_url'] as String?) ?? '';
    final isMe = msg['sender_id']?.toString() == _myId;
    return _SongBubble(
      assetId: SongCache.assetId(rel),
      url: fullMediaUrl(rel),
      title: (msg['content'] as String?)?.trim().isNotEmpty == true
          ? (msg['content'] as String).trim()
          : ((msg['media_name'] as String?) ?? 'Song'),
      fileName: msg['media_name'] as String?,
      mime: msg['media_mime'] as String?,
      isMe: isMe,
      accent: scheme.primary,
      onColor: scheme.onSurface,
      onDownload: () => _saveMediaToDevice(msg),
    );
  }
  List<Map<String, dynamic>?> _viewerMsgs = const <Map<String, dynamic>?>[];
  List<ImageProvider> _viewerProviders = const <ImageProvider>[];
  int _viewerIndex = 0;
  bool _viewerChrome = true;
  PageController? _viewerPageCtrl;
  // Interactive swipe/drag-to-dismiss for the in-thread media viewer: the
  // stage follows the finger (or a desktop click-drag) down and fades, then
  // settles smoothly — a spring back up, or a slide off — instead of a flip.
  double _viewerDragDy = 0;
  AnimationController? _viewerDismissCtrl;
  // Anchors the attach menu so it rises out of the composer's "+" button.
  final GlobalKey _attachBtnKey = GlobalKey();

  Future<void> _openImageViewer(String tappedUrl,
      {List<Map<String, dynamic>>? source}) async {
    // Gather EVERY image shared in this thread (chronological order) so the
    // viewer is a swipeable gallery, not a single photo. Opening any image lets
    // the user page left/right through all of them, pinch-zoom each, and save.
    final images = <String>[];
    final imgMsgs = <Map<String, dynamic>?>[];
    for (final m in source ?? _messages) {
      final t = (m['message_type'] as String?);
      // The gallery now scrolls through photos AND videos (chronological).
      if (t == 'image' || t == 'video') {
        final rel = (m['media_url'] as String?) ?? '';
        if (rel.isNotEmpty) {
          images.add(fullMediaUrl(rel));
          imgMsgs.add(m);
        }
      }
    }
    if (!images.contains(tappedUrl)) {
      images.insert(0, tappedUrl);
      imgMsgs.insert(0, null);
    }
    var initial = images.indexOf(tappedUrl);
    if (initial < 0) initial = 0;
    // Resolve each image to its on-device copy (cache-first) so the viewer and
    // download keep working after the server purges the bytes. The tapped image
    // is fetched if still missing; others use whatever is already cached.
    final providers = <ImageProvider>[];
    for (final u in images) {
      File? f;
      if (!kIsWeb) {
        try {
          f = (u == tappedUrl)
              ? await MediaStore.instance.getFile(u, mediaAuthHeaders(u))
              : await MediaStore.instance.cached(u);
        } catch (_) {}
      }
      providers.add(f != null
          ? FileImage(f)
          : authNetworkImageProvider(u, mediaAuthHeaders(u)));
    }
    if (!mounted) return;
    _viewerPageCtrl?.dispose();
    _viewerPageCtrl = PageController(initialPage: initial);
    setState(() {
      _viewerImages = images;
      _viewerMsgs = imgMsgs;
      _viewerProviders = providers;
      _viewerIndex = initial;
      _viewerChrome = true;
    });
  }

  void _closeViewer() {
    if (_viewerImages == null) return;
    setState(() {
      _viewerImages = null;
      _viewerMsgs = const <Map<String, dynamic>?>[];
      _viewerProviders = const <ImageProvider>[];
      _viewerDragDy = 0;
    });
  }

  // True when the media at viewer index [i] is a video (so the chrome can offer
  // the "watch fullscreen" control that opens the immersive theater player).
  bool _viewerIsVideo(int i) {
    final m = (i >= 0 && i < _viewerMsgs.length) ? _viewerMsgs[i] : null;
    return (m?['message_type'] as String?) == 'video';
  }

  // Release of a downward drag: animate the stage the rest of the way off to
  // close, or spring it back up — a smooth settle, never an instant flip.
  void _settleViewerDrag(bool close) {
    final ctrl = _viewerDismissCtrl;
    final startDy = _viewerDragDy;
    final target = close ? MediaQuery.of(context).size.height : 0.0;
    if (ctrl == null) {
      setState(() => _viewerDragDy = 0);
      if (close) _closeViewer();
      return;
    }
    ctrl
      ..stop()
      ..duration = Duration(milliseconds: close ? 200 : 260);
    final anim = Tween<double>(begin: startDy, end: target).animate(
        CurvedAnimation(
            parent: ctrl,
            curve: close ? Curves.easeInCubic : Curves.easeOutCubic));
    void tick() {
      if (mounted) setState(() => _viewerDragDy = anim.value);
    }
    anim.addListener(tick);
    ctrl.reset();
    ctrl.forward().whenComplete(() {
      anim.removeListener(tick);
      if (close) _closeViewer();
      if (mounted) setState(() => _viewerDragDy = 0);
    });
  }

  // A left/right page chevron for the media viewer (desktop/tablet friendly;
  // also handy on phones). Hidden at the ends and when chrome is tucked away.
  Widget _viewerArrow(IconData icon, bool enabled, VoidCallback onTap) {
    if (!enabled) return const SizedBox(width: 40);
    return IgnorePointer(
      ignoring: !_viewerChrome,
      child: AnimatedOpacity(
        opacity: _viewerChrome ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: Material(
          color: Colors.black.withAlpha(90),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(icon, color: Colors.white, size: 28),
            ),
          ),
        ),
      ),
    );
  }

  // Web: files pasted via the browser paste event arrive here already as
  // bytes (no file paths on the web). Routes them the same way as a native
  // file paste: images go through the preview, other files through the caption
  // bar + upload, with only the first file prompting for a caption.
  Future<void> _onWebPaste(List<webpaste.PastedFile> files) async {
    if (!mounted || files.isEmpty) return;
    const imgExt = ['jpg', 'jpeg', 'png', 'gif', 'webp'];
    const fileCap = 200 * 1024 * 1024;
    const ephemeralOver = 15 * 1024 * 1024;
    for (var i = 0; i < files.length; i++) {
      if (!mounted) return;
      final f = files[i];
      final bytes = f.bytes;
      if (bytes.isEmpty) continue;
      final name = f.name;
      final ext =
          name.contains('.') ? name.split('.').last.toLowerCase() : '';
      final isImage =
          f.mime.startsWith('image/') || imgExt.contains(ext);
      if (isImage) {
        final mime = f.mime.isNotEmpty ? f.mime : _mimeForExt(ext);
        await _previewAndSendImage(bytes, name, mime);
        continue;
      }
      if (bytes.length > fileCap) {
        if (mounted) {
          showToast(context, '"$name" is too large to send (max 200 MB).',
              type: ToastType.error);
        }
        continue;
      }
      String? caption = '';
      if (i == 0) {
        caption = await _askFileCaption(name);
        if (caption == null) return; // cancelled the whole paste
      }
      final mime = f.mime.isNotEmpty ? f.mime : _mimeForExt(ext);
      await _uploadAndSend(
        bytes: bytes,
        filename: name,
        mime: mime,
        type: 'file',
        caption: caption,
        ephemeral: bytes.length > ephemeralOver,
      );
    }
  }

  // A compact sheet to add a caption before sending a pasted file. Returns the
  // caption (possibly empty) on Send, or null if cancelled/dismissed.
  // Shows an inline caption bar inside the chat view and resolves once the
  // user taps Send (returns the caption, possibly empty) or Cancel (null).
  Future<String?> _askFileCaption(String filename) async {
    // Defensively resolve any previous pending request.
    if (_captionCompleter != null && !_captionCompleter!.isCompleted) {
      _captionCompleter!.complete(null);
    }
    final ctrl = TextEditingController();
    final completer = Completer<String?>();
    if (mounted) {
      setState(() {
        _captionFileName = filename;
        _captionCtrl = ctrl;
        _captionCompleter = completer;
      });
    }
    final result = await completer.future;
    if (mounted) {
      setState(() {
        _captionFileName = null;
        _captionCtrl = null;
        _captionCompleter = null;
      });
    }
    ctrl.dispose();
    return result;
  }

  void _submitFileCaption() {
    final c = _captionCompleter;
    if (c == null || c.isCompleted) return;
    c.complete(_captionCtrl?.text ?? '');
  }

  void _cancelFileCaption() {
    final c = _captionCompleter;
    if (c == null || c.isCompleted) return;
    c.complete(null);
  }

  // In-body photo viewer: fills ONLY the conversation card (header + composer
  // stay live), so the user can keep typing / reply while the photo is open.
  // Tap toggles the top bar; swipe pages; pinch zooms.
  Widget _buildInlineViewer() {
    final imgs = _viewerImages;
    if (imgs == null || imgs.isEmpty) return const SizedBox.shrink();
    final accent = Theme.of(context).colorScheme.primary;
    final i = _viewerIndex.clamp(0, imgs.length - 1);
    final msg = (i < _viewerMsgs.length) ? _viewerMsgs[i] : null;
    final name = _viewerSenderName(i);
    final avRel = _viewerSenderAvatar(i);
    final av = avRel.isEmpty
        ? ''
        : (avRel.startsWith('http') ? avRel : fullMediaUrl(avRel));
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final stageColor = isDark ? Colors.black : Colors.white;
    void toggle() => setState(() => _viewerChrome = !_viewerChrome);
    final dragProg = (_viewerDragDy / 400).clamp(0.0, 1.0);
    final stageScale = 1 - dragProg * 0.06;
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // The stage follows the finger (or a desktop click-drag) straight down
        // and fades as it goes, then settles smoothly on release — a spring
        // back up, or a slide the rest of the way off to close.
        onVerticalDragUpdate: (d) {
          final next = _viewerDragDy + d.delta.dy;
          setState(() => _viewerDragDy = next < 0 ? 0 : next);
        },
        onVerticalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          _settleViewerDrag(_viewerDragDy > 140 || v > 700);
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: ColoredBox(
                color: stageColor.withValues(alpha: 1 - dragProg * 0.92),
              ),
            ),
            Transform.translate(
              offset: Offset(0, _viewerDragDy),
              child: Transform.scale(
                scale: stageScale,
                child: Stack(
                  children: [
            PhotoViewGallery.builder(
              pageController: _viewerPageCtrl,
              itemCount: imgs.length,
              onPageChanged: (p) => setState(() => _viewerIndex = p),
              backgroundDecoration:
                  const BoxDecoration(color: Colors.transparent),
              loadingBuilder: (_, _) => Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: isDark ? Colors.white : accent),
                ),
              ),
              builder: (ctx2, p) {
                final vm = p < _viewerMsgs.length ? _viewerMsgs[p] : null;
                final isVideo =
                    (vm?['message_type'] as String?) == 'video';
                if (isVideo) {
                  return PhotoViewGalleryPageOptions.customChild(
                    child: _GalleryVideo(
                        key: ValueKey('galvid-${imgs[p]}'), url: imgs[p]),
                    minScale: PhotoViewComputedScale.contained,
                    maxScale: PhotoViewComputedScale.contained * 2,
                    initialScale: PhotoViewComputedScale.contained,
                    onTapUp: (_, _, _) => toggle(),
                  );
                }
                return PhotoViewGalleryPageOptions(
                  imageProvider: _viewerProviders[p],
                  minScale: PhotoViewComputedScale.contained,
                  maxScale: PhotoViewComputedScale.covered * 3,
                  initialScale: PhotoViewComputedScale.contained,
                  onTapUp: (_, _, _) => toggle(),
                );
              },
            ),
            // Top bar (sender · time · reply · save · close).
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                ignoring: !_viewerChrome,
                child: AnimatedOpacity(
                  opacity: _viewerChrome ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withAlpha(180),
                          Colors.black.withAlpha(0),
                        ],
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(6, 8, 4, 16),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(1.6),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: accent, width: 1.6),
                            ),
                            child: CircleAvatar(
                              radius: 15,
                              backgroundColor: Colors.white24,
                              backgroundImage: av.isNotEmpty
                                  ? authNetworkImageProvider(
                                      av, mediaAuthHeaders(av), cacheSize: 96)
                                  : null,
                              child: av.isEmpty
                                  ? Text(
                                      name.isNotEmpty
                                          ? name[0].toUpperCase()
                                          : '?',
                                      style: TextStyle(
                                          color: readableOn(accent),
                                          fontWeight: FontWeight.bold))
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  name.isEmpty ? 'Photo' : name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14),
                                ),
                                Text(
                                  _viewerSentTime(i),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: Colors.white.withAlpha(180),
                                      fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                          if (msg != null && _viewerIsVideo(i))
                            IconButton(
                              tooltip: 'Watch fullscreen',
                              onPressed: () => _openVideo(imgs[i], msg),
                              icon: const Icon(Icons.fullscreen_rounded,
                                  color: Colors.white),
                            ),
                          if (msg != null && _mediaBrowser != null)
                            IconButton(
                              tooltip: 'Show in chat',
                              onPressed: () => _showViewerItemInChat(msg),
                              icon: const Icon(Icons.forum_outlined,
                                  color: Colors.white),
                            ),
                          IconButton(
                            tooltip: 'Reply',
                            onPressed: msg == null
                                ? null
                                : () {
                                    setState(() => _replyTo = msg);
                                    _closeViewer();
                                    _closeMediaBrowser();
                                    FocusScope.of(context)
                                        .requestFocus(FocusNode());
                                  },
                            icon: const Icon(Icons.reply_rounded,
                                color: Colors.white),
                          ),
                          IconButton(
                            tooltip: 'Save',
                            onPressed: () {
                              if (msg != null) {
                                _saveMediaToDevice(msg);
                              } else {
                                _saveImage(imgs[i]);
                              }
                            },
                            icon: const Icon(Icons.download_rounded,
                                color: Colors.white),
                          ),
                          IconButton(
                            tooltip: 'Close',
                            onPressed: _closeViewer,
                            icon: const Icon(Icons.close_rounded,
                                color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Left / right page arrows (tap to page through the media).
            if (imgs.length > 1) ...[
              Positioned(
                left: 4,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _viewerArrow(
                    Icons.chevron_left_rounded,
                    i > 0,
                    () => _viewerPageCtrl?.previousPage(
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOut),
                  ),
                ),
              ),
              Positioned(
                right: 4,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _viewerArrow(
                    Icons.chevron_right_rounded,
                    i < imgs.length - 1,
                    () => _viewerPageCtrl?.nextPage(
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOut),
                  ),
                ),
              ),
            ],
            // Position counter.
            if (imgs.length > 1)
              Positioned(
                bottom: 12,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _viewerChrome ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withAlpha(120),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text('${i + 1} of ${imgs.length}',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13)),
                      ),
                    ),
                  ),
                ),
              ),
            // Pinned Keepsake "Keep" chip — follows the chrome toggle so it
            // clears away with the top bar when you tap to admire the photo
            // unobstructed, and returns with the rest of the controls.
            if (_canHarmony && msg != null)
              Positioned(
                right: 14,
                bottom: imgs.length > 1 ? 46 : 16,
                child: IgnorePointer(
                  ignoring: !_viewerChrome,
                  child: AnimatedOpacity(
                    opacity: _viewerChrome ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => _keepsakeMessage(msg),
                    borderRadius: BorderRadius.circular(24),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 9),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.auto_awesome_rounded,
                              size: 16, color: Colors.white),
                          SizedBox(width: 6),
                          Text('Keep',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13)),
                        ],
                      ),
                    ),
                  ),
                ),
                  ),
                ),
              ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Native channel that writes a file straight into the public Downloads
  // folder (Android only), bypassing the system "Save to" picker.
  static const _downloadsCh = MethodChannel('aluta/downloads');

  /// Android only: save [data] directly into the device's Downloads folder via
  /// the native MediaStore channel. Returns a label like "Download/song.apk"
  /// on success, or null if it couldn't (the caller then shows the Save
  /// dialog). On iOS / desktop / web this returns null (no public Downloads).
  Future<String?> _saveToDownloads(Uint8List data, String fname) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    // MediaStore display names can't contain path separators.
    final safe = fname.replaceAll(RegExp(r'[\\/]+'), '_').trim();
    File? tmp;
    try {
      // Android 10+ uses MediaStore (no permission). Android 9 and below write
      // straight to the public Downloads dir, which needs WRITE_EXTERNAL_STORAGE
      // — request it, and if the user declines, fall back to the Save dialog.
      final sdk = await _downloadsCh.invokeMethod<int>('sdkInt') ?? 0;
      if (sdk > 0 && sdk < 29) {
        final st = await Permission.storage.request();
        if (!st.isGranted) return null;
      }
      final dir = await getTemporaryDirectory();
      tmp = File(
          '${dir.path}/dl_${DateTime.now().millisecondsSinceEpoch}_$safe');
      await tmp.writeAsBytes(data, flush: true);
      return await _downloadsCh.invokeMethod<String>('saveToDownloads', {
        'srcPath': tmp.path,
        'fileName': safe.isEmpty ? 'aluta_file' : safe,
        'mimeType': null, // let the native side infer from the extension
      });
    } catch (_) {
      return null;
    } finally {
      try {
        await tmp?.delete();
      } catch (_) {}
    }
  }

  // ── Message actions ───────────────────────────────────────────────────────

  void _showMessageMenu(BuildContext context, Map<String, dynamic> msg,
      {Offset? anchor}) {
    final isMe = msg['sender_id'].toString() == _myId;
    final content = msg['content'] as String? ?? '';
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;

    const reactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

    final softShadow = <BoxShadow>[
      BoxShadow(
        color: Colors.black.withValues(alpha: isDark ? 0.55 : 0.20),
        blurRadius: 30,
        offset: const Offset(0, 14),
      ),
    ];

    // Capture the pressed bubble's on-screen rect so the spotlight keeps that
    // one bubble crisp while everything else is dimmed/blurred.
    Rect? bubbleRect;
    final box = _msgKeys[msg['id'].toString()]
        ?.currentContext
        ?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      bubbleRect = box.localToGlobal(Offset.zero) & box.size;
    }

    Widget reactionBar(BuildContext ctx) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.alphaBlend(
                  scheme.primary.withValues(alpha: isDark ? 0.10 : 0.06),
                  scheme.surface),
              scheme.surface,
            ],
          ),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(
              color: scheme.outlineVariant
                  .withValues(alpha: isDark ? 0.45 : 0.30),
              width: 1),
          boxShadow: softShadow,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final e in reactions)
              _ReactionButton(
                emoji: e,
                onTap: () {
                  Navigator.pop(ctx);
                  _addReaction(msg, e);
                },
              ),
          ],
        ),
      );
    }

    List<_MenuAction> buildFull(BuildContext ctx) {
      final deleted = msg['is_deleted'] == true;
      final isTextMsg = (msg['message_type'] ?? 'text') == 'text';
      final isHeart = (msg['message_type'] ?? 'text') == 'heart';
      // A sent heart nobody has opened yet can still be taken back.
      final heartUnopened = isHeart &&
          (msg['opened_at'] ?? '').toString().isEmpty &&
          _heartOpens(msg).isEmpty;
      final hasMedia = (msg['message_type'] ?? 'text') != 'text' &&
          (msg['media_url'] as String? ?? '').isNotEmpty;
      // Harmony / Our Space actions sit at the TOP of the menu (only when the
      // two are bonded), with the usual chat actions below. A song can also be
      // dedicated or pinned into the shared playlist straight from its bubble.
      final canKeep = _canHarmony;
      final isSong = (msg['message_type'] ?? 'text') == 'song';
      final harmony = <_MenuAction>[];
      if (canKeep && !deleted) {
        harmony.add(_MenuAction('keepsake', Icons.auto_awesome_rounded,
            'Keepsake', () {
          Navigator.pop(ctx);
          _keepsakeMessage(msg);
        }));
        if (isSong) {
          harmony.add(_MenuAction('dedicate', Icons.favorite_rounded,
              'Dedicate', () {
            Navigator.pop(ctx);
            _dedicateSong(msg);
          }, color: scheme.primary));
          harmony.add(_MenuAction('addpl', Icons.playlist_add_rounded,
              'Add to Our Playlist', () {
            Navigator.pop(ctx);
            _addSongToPlaylist(msg);
          }));
        }
      }
      final rest = <_MenuAction>[
        if (isHeart && !isMe && !deleted)
          _MenuAction('heartback', Icons.favorite_rounded, 'Send a heart back',
              () {
            Navigator.pop(ctx);
            _startHeartBack(msg);
          }, short: 'Heart back', color: scheme.primary),
        if (isHeart && isMe && heartUnopened && !deleted)
          _MenuAction('takeback', Icons.undo_rounded, 'Take back (unopened)',
              () {
            Navigator.pop(ctx);
            _takeBackHeart(msg);
          }, short: 'Take back'),
        _MenuAction('reply', Icons.reply_rounded, 'Reply', () {
          Navigator.pop(ctx);
          setState(() => _replyTo = msg);
          FocusScope.of(context).requestFocus(FocusNode());
        }),
        if (!deleted)
          _MenuAction(
              'pin',
              _isPinned(msg) ? Icons.push_pin : Icons.push_pin_outlined,
              _isPinned(msg) ? 'Unpin' : 'Pin', () {
            Navigator.pop(ctx);
            if (_isPinned(msg)) {
              _unpinMessage(msg);
            } else {
              _showPinDurationSheet(msg);
            }
          }),
        // Copy / Forward would lift a secret heart's note out in plain text.
        if (!isHeart)
        _MenuAction('copy', Icons.copy_rounded, 'Copy', () {
          Navigator.pop(ctx);
          Clipboard.setData(ClipboardData(text: _stripQuote(content)));
          showToast(context, 'Copied');
        }),
        if (!deleted && !isHeart)
          _MenuAction('forward', Icons.forward_rounded, 'Forward', () {
            Navigator.pop(ctx);
            _showForwardPicker(msg);
          }),
        // React with the song playing right now (a vinyl chip).
        if (!deleted && !isHeart && _nowPlayingTitle().isNotEmpty)
          _MenuAction('songreact', Icons.album_rounded,
              'React with “${_clip(_nowPlayingTitle(), 28)}”', () {
            Navigator.pop(ctx);
            _reactWithSong(msg);
          }, short: 'Song'),
        // Groups: dedicate a shared song to a member.
        if (!deleted && _isGroup && (msg['message_type'] ?? '') == 'song')
          _MenuAction('dedicate_member', Icons.card_giftcard_rounded,
              'Dedicate to a member…',
              () {
            Navigator.pop(ctx);
            _dedicateSongToMember(msg);
          }, short: 'Dedicate'),
        if (!deleted && hasMedia)
          _MenuAction('save', Icons.download_rounded, 'Save to device', () {
            Navigator.pop(ctx);
            _saveMediaToDevice(msg);
          }),
        if (isMe) ...[
          if (_isGroup && !deleted)
            _MenuAction('info', Icons.info_outline_rounded, 'Message info', () {
              Navigator.pop(ctx);
              _showMessageInfo(msg);
            }),
          if (isTextMsg && !deleted && _withinEditWindow(msg))
            _MenuAction('edit', Icons.edit_rounded, 'Edit', () {
              Navigator.pop(ctx);
              _startEditing(msg);
            }),
          _MenuAction('delme', Icons.delete_outline_rounded, 'Delete for me',
              () {
            Navigator.pop(ctx);
            _deleteMessage(msg['id'], false);
          }, short: 'Delete'),
          _MenuAction('delall', Icons.delete_forever_rounded,
              'Delete for everyone', () {
            Navigator.pop(ctx);
            _deleteMessage(msg['id'], true);
          }, color: scheme.error),
        ],
      ];
      return <_MenuAction>[
        ...harmony,
        if (harmony.isNotEmpty)
          _MenuAction('__div__', Icons.remove, '', () {}),
        ...rest,
      ];
    }

    Widget actionCard(BuildContext ctx) {
      final full = buildFull(ctx);
      _MenuAction? pick(String id) {
        for (final a in full) {
          if (a.id == id) return a;
        }
        return null;
      }
      final quick = [
        pick('reply'),
        pick('pin'),
        pick('keepsake') ?? pick('copy'),
        pick('delme'),
      ]
          .whereType<_MenuAction>()
          .toList();
      return _MsgActionMenu(
        quick: quick,
        full: full,
        scheme: scheme,
        isDark: isDark,
        shadow: softShadow,
        // Reactions live INSIDE the same card (top strip), so the menu reads
        // as one "respond to this message" surface instead of two loose pills.
        header: _ReactionStrip(
          reactions: reactions,
          mine: _myReactionOn(msg),
          isDark: isDark,
          onPick: (e) {
            Navigator.pop(ctx);
            _addReaction(msg, e);
          },
        ),
      );
    }

    final wide = MediaQuery.of(context).size.width >= 640;
    if (wide && anchor != null) {
      // Desktop / window: a dropdown anchored at the pointer (no full-screen
      // blur), WhatsApp-Web style.
      _showAnchoredDropdown(
        anchor: anchor,
        isMe: isMe,
        reactionBarBuilder: reactionBar,
        fullMenuBuilder: (ctx, maxH) => _FullMenuCard(
          actions: buildFull(ctx),
          scheme: scheme,
          isDark: isDark,
          shadow: softShadow,
          maxHeight: maxH,
        ),
      );
    } else {
      // Mobile: the spotlight (dim + hole over the bubble) with a quick-row.
      _showSpotlightPanel(
        bubbleRect: bubbleRect,
        isMe: isMe,
        reactionBarBuilder: reactionBar,
        actionCardBuilder: actionCard,
        // Reactions are part of the action card now (one unified card).
        separateBar: false,
      );
    }
  }

  /// The emoji I've already reacted with on [msg] (highlighted in the menu).
  String? _myReactionOn(Map<String, dynamic> msg) {
    final raw = msg['reactions'];
    if (raw is! String || raw.isEmpty || _myId == null) return null;
    try {
      final v = (jsonDecode(raw) as Map)[_myId];
      return v?.toString();
    } catch (_) {
      return null;
    }
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

  void _jumpToQuoted(String quoted) {
    final target = _findQuotedMessage(quoted);
    if (target == null) {
      showToast(context, 'That message isn\'t on this device anymore',
          type: ToastType.info);
      return;
    }
    _jumpToMessage(target['id'].toString());
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

  /// Opened from a message notification: scroll to + highlight that message
  /// once it's rendered. The target is usually the newest message (bottom), so
  /// after the initial load + auto-scroll its key is built; retry a few times
  /// in case the list is still settling.
  void _maybeInitialJump([String? id]) {
    final target = id ?? widget.initialJumpMessageId;
    if (target == null || target.isEmpty) return;
    var tries = 0;
    void attempt() {
      if (!mounted) return;
      if (_msgKeys[target]?.currentContext != null) {
        _jumpToMessage(target);
        return;
      }
      if (tries++ < 8) {
        Future.delayed(const Duration(milliseconds: 250), attempt);
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => attempt());
  }

  /// Scroll to a message by id, then FLASH it so the eye lands on it.
  ///
  /// The list is lazy, so a far-away message may not be built yet (no
  /// context): step the list toward it a screen at a time until it is, then
  /// centre it. The flash only starts once the scroll has settled — two soft
  /// pulses of the accent band + a little lift of the bubble, then a fade.
  Future<void> _jumpToMessage(String id, {bool flash = true}) async {
    final seq = ++_flashSeq;
    var ctx = _msgKeys[id]?.currentContext;
    if (ctx == null && _scrollCtrl.hasClients) {
      final idx = _messages.indexWhere((m) => m['id'].toString() == id);
      if (idx == -1) return;
      // reverse:true list → older messages (larger index) sit at LARGER
      // offsets. Pick the direction from what's built right now: the target
      // is newer than everything on screen → scroll down, else up.
      var minBuilt = -1;
      for (var k = 0; k < _messages.length; k++) {
        if (_msgKeys[_messages[k]['id'].toString()]?.currentContext != null) {
          minBuilt = k;
          break;
        }
      }
      final towardOlder = minBuilt == -1 || idx > minBuilt;
      for (var i = 0; i < 60 && ctx == null; i++) {
        final pos = _scrollCtrl.position;
        if (towardOlder && pos.pixels >= pos.maxScrollExtent) break;
        if (!towardOlder && pos.pixels <= pos.minScrollExtent) break;
        final step = pos.viewportDimension * 0.9 * (towardOlder ? 1 : -1);
        final next = (pos.pixels + step)
            .clamp(pos.minScrollExtent, pos.maxScrollExtent);
        _scrollCtrl.jumpTo(next);
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || seq != _flashSeq) return;
        ctx = _msgKeys[id]?.currentContext;
      }
    }
    if (ctx == null || !ctx.mounted) return;
    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 380),
      alignment: 0.4,
      curve: Curves.easeOutCubic,
    );
    if (!mounted || seq != _flashSeq) return;
    if (!flash) return;
    HapticFeedback.selectionClick();
    // Pulse: on · off · on · then fade out.
    const steps = <(bool, int)>[(true, 300), (false, 220), (true, 900)];
    for (final st in steps) {
      if (!mounted || seq != _flashSeq) return;
      setState(() {
        _highlightedId = id;
        _flashOn = st.$1;
      });
      await Future.delayed(Duration(milliseconds: st.$2));
    }
    if (mounted && seq == _flashSeq) {
      setState(() {
        _highlightedId = null;
        _flashOn = false;
      });
    }
  }

  // Open the per-conversation Media / Links / Docs browser. Pulls a window of
  // history, sorts shared items into the three tabs, and — when the user taps
  // an item — jumps back to that message in the thread so playback / saving
  // reuses the thread's own handling. Links open directly.
  // The header button toggles: open the panel, or close it if it's showing.
  void _onMediaRequest() {
    if (!mounted) return;
    if (_mediaBrowser != null && !_browserClosing) {
      _closeMediaBrowser();
    } else {
      _openMediaBrowser();
    }
  }

  Future<void> _openMediaBrowser() async {
    // Open at once from what the thread already holds (no wait, no spinner),
    // then fold in the longer history when it arrives — same panel, same tab.
    final key = UniqueKey();
    _browserKey = key;
    _browserClosing = false;
    _closeViewer();
    _showBrowserFrom(_merge(const [], _messages), key);
    chatMediaOpen.value = true;
    _browserAnim.forward();

    List<Map<String, dynamic>> msgs = const [];
    try {
      if (_isGroup) {
        msgs = await ApiService()
            .fetchConversationMessages(_cid, skip: 0, limit: 300);
      } else {
        final uid = int.tryParse(_myId ?? '') ?? 0;
        msgs = await ApiService()
            .fetchMessagesBetween(uid, widget.friendId, skip: 0, limit: 300);
      }
    } catch (_) {}
    if (!mounted || _browserKey != key || _browserClosing) return;
    // Newest first (the gallery reads top-down from now), de-duplicated,
    // plus anything newer the thread already has.
    msgs = _merge(_merge(const [], _messages), msgs);
    _showBrowserFrom(msgs, key);
  }

  void _showBrowserFrom(List<Map<String, dynamic>> msgs, Key key) {
    String shortDate(String iso) {
      final d = DateTime.tryParse(iso)?.toLocal();
      if (d == null) return '';
      const mon = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      return '${d.day} ${mon[d.month - 1]} ${d.year}';
    }

    final media = <MediaItem>[];
    final mediaMsgs = <Map<String, dynamic>>[];
    final songMsgs = <String, Map<String, dynamic>>{};
    final links = <LinkItem>[];
    final docs = <DocItem>[];
    final songs = <SongItem>[];
    final linkRe = RegExp(r'https?://[^\s]+');

    for (final m in msgs) {
      final id = m['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final type = (m['message_type'] ?? '').toString();
      final rel = (m['media_url'] ?? '').toString();
      final content = (m['content'] ?? '').toString();
      final ts = (m['timestamp'] ?? '').toString();

      if ((type == 'image' || type == 'video') && rel.isNotEmpty) {
        final full = fullMediaUrl(rel);
        final thumb = type == 'video' ? '$full/thumb' : full;
        final d = ts.isEmpty ? null : parseServerTime(ts);
        const months = [
          'January', 'February', 'March', 'April', 'May', 'June', 'July',
          'August', 'September', 'October', 'November', 'December'
        ];
        mediaMsgs.add(m);
        media.add(MediaItem(
          messageId: id,
          thumbUrl: thumb,
          headers: mediaAuthHeaders(thumb),
          isVideo: type == 'video',
          monthLabel: d == null ? '' : '${months[d.month - 1]} ${d.year}',
          dayLabel: d == null
              ? ''
              : '${d.day} ${months[d.month - 1].substring(0, 3)}',
          dateLabel: shortDate(ts),
        ));
      } else if (type == 'song') {
        final mine = m['sender_id']?.toString() == _myId;
        final sender = mine
            ? 'You'
            : _isGroup
                ? ((m['sender'] as Map?)?['username'] ?? 'Someone').toString()
                : widget.friendName.split(' ').first;
        final t = content.trim().isNotEmpty
            ? content.trim()
            : ((m['media_name'] as String?)?.trim() ?? 'Song');
        if (rel.isNotEmpty) songMsgs[id] = m;
        songs.add(SongItem(
          messageId: id,
          title: t,
          sender: sender,
          mine: mine,
          dateLabel: shortDate(ts),
        ));
        continue; // a song's title isn't a link
      } else if (type == 'file' || type == 'document') {
        final name = (m['media_name'] as String?)?.trim();
        final size = (m['media_size'] as num?)?.toInt();
        docs.add(DocItem(
          messageId: id,
          name: (name == null || name.isEmpty)
              ? (type == 'song' ? 'Song' : 'File')
              : name,
          sizeLabel: (size != null && size > 0) ? _fmtBytes(size) : '',
          icon: type == 'song'
              ? Icons.music_note_rounded
              : _fileIcon(name ?? ''),
          dateLabel: shortDate(ts),
        ));
      }
      // A link can ride on any text message or caption.
      for (final match in linkRe.allMatches(content)) {
        links.add(LinkItem(
          messageId: id,
          url: match.group(0)!,
          snippet: content.trim(),
          dateLabel: shortDate(ts),
        ));
      }
    }

    if (!mounted) return;
    setState(() {
      _browserMsgs = msgs;
      _mediaBrowser = ConversationMediaScreen(
        key: key,
        title: _isGroup ? widget.groupTitle : widget.friendName,
        media: media,
        links: links,
        docs: docs,
        songs: songs,
        // Esc closes the viewer first when one is open over the browser.
        onClose: () =>
            _viewerImages != null ? _closeViewer() : _closeMediaBrowser(),
        // A swipe already carried it off screen through the same side.
        onSwipedAway: () => _closeMediaBrowser(instant: true),
        // Photos / videos open in the in-panel viewer, paging through
        // everything shared (newest first); closing it returns here.
        onOpenMedia: (i) {
          if (i < 0 || i >= mediaMsgs.length) return;
          final rel = (mediaMsgs[i]['media_url'] ?? '').toString();
          _openImageViewer(fullMediaUrl(rel), source: mediaMsgs);
        },
        songPlayer: (id) {
          final m = songMsgs[id];
          return m == null ? null : _browserSongPlayer(m);
        },
        onJump: (id) {
          _closeMediaBrowser();
          _jumpFromBrowser(id, msgs);
        },
      );
    });
  }

  Future<void> _jumpFromBrowser(
      String jumpId, List<Map<String, dynamic>> msgs) async {
    if (jumpId.isNotEmpty && mounted) {
      // The browser reaches further back than the thread holds — fold that
      // history in first so the jump can land on older items too.
      if (!_messages.any((m) => m['id'].toString() == jumpId)) {
        final merged = _merge(
            _messages, msgs.where((m) => m['purged'] != true).toList());
        setState(() => _messages = merged);
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
      }
      _jumpToMessage(jumpId);
    }
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
    // Outcome tag stored in content (answered/declined/busy/unreachable/failed/
    // cancelled/missed). Empty on older logs → fall back to duration only.
    final outcome = (msg['content'] as String?)?.trim() ?? '';
    final IconData icon;
    final String label;
    if (connected) {
      icon = isMe ? Icons.call_made_rounded : Icons.call_received_rounded;
      label =
          '${isMe ? 'Outgoing' : 'Incoming'} call · ${_fmtCallDur(secs)}';
    } else {
      // Not connected → describe why, from the caller's and callee's viewpoint.
      switch (outcome) {
        case 'declined':
          icon = isMe ? Icons.call_end_rounded : Icons.call_missed_rounded;
          label = isMe ? 'Call declined' : 'Missed call';
          break;
        case 'busy':
          icon = Icons.phone_disabled_rounded;
          label = isMe ? 'Line busy' : 'Missed call';
          break;
        case 'unreachable':
          icon = Icons.signal_cellular_off_rounded;
          label = isMe ? 'Couldn’t reach — offline' : 'Missed call';
          break;
        case 'failed':
          icon = Icons.phone_disabled_rounded;
          label = isMe ? 'Call failed' : 'Missed call';
          break;
        case 'cancelled':
          icon = isMe ? Icons.call_made_rounded : Icons.call_missed_rounded;
          label = isMe ? 'Call cancelled' : 'Missed call';
          break;
        default: // 'missed' / unknown
          icon = isMe ? Icons.call_made_rounded : Icons.call_missed_rounded;
          label = isMe ? 'Call — no answer' : 'Missed call';
      }
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

  // Renders a "listen together" log message (message_type 'live'). The outcome
  // is stored in content: listened / declined / noanswer. media_duration holds
  // the session length in seconds.
  Widget _liveLogContent(Map<String, dynamic> msg, bool isMe, Color textColor) {
    final outcome = (msg['content'] as String?)?.trim() ?? '';
    final secs = (msg['media_duration'] as num?)?.toInt() ?? 0;
    IconData icon = Icons.headphones_rounded;
    String label;
    Color color = textColor;
    switch (outcome) {
      case 'listened':
        label = secs > 0
            ? 'Listened together · ${_fmtCallDur(secs)}'
            : 'Listened together';
        break;
      case 'declined':
        icon = Icons.headset_off_rounded;
        label = isMe ? 'Listen together declined' : 'You declined to listen';
        color = !isMe ? const Color(0xFFE53935) : textColor;
        break;
      case 'noanswer':
        icon = Icons.headset_off_rounded;
        label = isMe ? 'Listen together — no answer' : 'Missed listen invite';
        color = !isMe ? const Color(0xFFE53935) : textColor;
        break;
      default:
        label = 'Listen together ended';
    }
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

  // A secret-heart message (message_type 'heart'): the covered, pulsing heart
  // that reveals the note on tap (short → in-heart, long → genie card).
  Widget _buildHeartBubble(Map<String, dynamic> msg, bool isMe, bool isDark,
      bool showAvatar, bool isFirst) {
    final scheme = Theme.of(context).colorScheme;
    final text = (msg['content'] as String?) ?? '';
    final accent = scheme.primary;
    final msgId = msg['id'].toString();
    final Map senderMap = (msg['sender'] as Map?) ?? const {};
    final rxAvatar = _isGroup
        ? (senderMap['avatar_url'] ?? '').toString()
        : _friendAvatar;
    final rxName =
        _isGroup ? (senderMap['username'] ?? '').toString() : widget.friendName;
    // Registered like any bubble so a reply quote / pin / notification can
    // jump here and flash it.
    final key = _msgKeys.putIfAbsent(msgId, () => GlobalKey());
    final flashing = _highlightedId == msgId && _flashOn;
    return AnimatedContainer(
      key: key,
      duration: Duration(milliseconds: flashing ? 180 : 520),
      curve: Curves.easeOut,
      color: flashing
          ? scheme.primary.withValues(alpha: isDark ? 0.30 : 0.20)
          : Colors.transparent,
      padding: EdgeInsets.only(
          top: showAvatar ? 6 : 2, left: isMe ? 56 : 6, right: isMe ? 6 : 56),
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Swipe right to reply — same gesture as every other bubble.
          // (A swipe moves the finger, so it never counts as hold-to-open.)
          _SwipeToReply(
            isMe: isMe,
            onReply: () {
              HapticFeedback.selectionClick();
              setState(() => _replyTo = msg);
              FocusScope.of(context).requestFocus(FocusNode());
            },
            child: Row(
            mainAxisAlignment:
                isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!isMe)
                SizedBox(
                  width: 30,
                  child: showAvatar
                      ? CircleAvatar(
                          radius: 13,
                          backgroundColor: scheme.primaryContainer,
                          backgroundImage: rxAvatar.isNotEmpty
                              ? authNetworkImageProvider(fullMediaUrl(rxAvatar),
                                  mediaAuthHeaders(fullMediaUrl(rxAvatar)))
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
                                      fontWeight: FontWeight.bold)),
                        )
                      : const SizedBox(),
                ),
              if (!isMe) const SizedBox(width: 4),
              GestureDetector(
                // Right-click menu (desktop). Long-press is handled inside the
                // heart: on a covered heart holding is the opening ritual.
                onSecondaryTapDown: (d) =>
                    _showMessageMenu(context, msg, anchor: d.globalPosition),
                child: HeartBubble(
                  key: ValueKey('heart-$msgId'),
                  text: text,
                  isMe: isMe,
                  senderName: rxName.trim().isEmpty
                      ? null
                      : rxName.trim().split(' ').first,
                  accent: accent,
                  bonded: _canHarmony,
                  heartKeySeed: msgId,
                  mood: msg['heart_mood']?.toString(),
                  sentAt: (msg['timestamp'] ?? '').toString().isEmpty
                      ? null
                      : parseServerTime(msg['timestamp'].toString()),
                  unlockAt: (msg['unlock_at'] ?? '').toString().isEmpty
                      ? null
                      : parseServerTime(msg['unlock_at'].toString()),
                  // Sender: has anyone opened it. Receiver: have *I* (in a
                  // group someone else opening it mustn't silence my heart).
                  openedAt: isMe
                      ? ((msg['opened_at'] ?? '').toString().isEmpty
                          ? null
                          : parseServerTime(msg['opened_at'].toString()))
                      : _myHeartOpen(msg),
                  // Stays true for the stamp's 1.2s (removed by a timer, not
                  // here, so a rebuild mid-animation doesn't cut it short).
                  justSent: _freshHearts.contains(msgId),
                  onMenu: (pos) =>
                      _showMessageMenu(context, msg, anchor: pos),
                  showStatus: false, // merged into the pill below
                  // Respond from the letter card (long notes open there).
                  onReply: () {
                    setState(() => _replyTo = msg);
                    FocusScope.of(context).requestFocus(FocusNode());
                  },
                  onReact: (e) => _addReaction(msg, e),
                  onKeep: _canHarmony ? () => _keepsakeMessage(msg) : null,
                  onSendBack: () => _startHeartBack(msg),
                  onFirstOpen: () => _reportHeartOpened(msg),
                  onUnsealDue: () => _unsealHeart(msg),
                  // Bonded-space gesture: double-tap to love back (❤ reaction).
                  onLoveBack:
                      _canHarmony ? () => _addReaction(msg, '❤️') : null,
                ),
              ),
            ],
          ),
          ),
          // Reactions on a heart (❤️ 😍 … from the letter card or the menu)
          // — they were saved but never drawn under hearts.
          Builder(builder: (_) {
            final rx = _reactionsOf(msg);
            if (rx.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: EdgeInsets.only(top: 2, left: isMe ? 0 : 34),
              child: Wrap(
                spacing: 3,
                children: [
                  for (final e in rx)
                    GestureDetector(
                      onTap: () => _addReaction(msg, e),
                      child: _isSongReaction(e)
                          ? _songReactionChip(e, scheme)
                          : Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color:
                                        scheme.outlineVariant.withAlpha(80)),
                              ),
                              child: AnimatedReaction(emoji: e, size: 15),
                            ),
                    ),
                ],
              ),
            );
          }),
          // ONE frosted pill under the heart: its status (receipt / opens-at)
          // and the time + ticks, side by side. Frosted + dark so it reads
          // the same on any wallpaper, light or dark.
          Builder(builder: (_) {
            final st = heartStatus(
              isMe: isMe,
              unlockAt: (msg['unlock_at'] ?? '').toString().isEmpty
                  ? null
                  : parseServerTime(msg['unlock_at'].toString()),
              openedAt: (msg['opened_at'] ?? '').toString().isEmpty
                  ? null
                  : parseServerTime(msg['opened_at'].toString()),
              isGroup: _isGroup,
              openCount: _heartOpens(msg).length,
              openTotal: _groupMembers.length > 1
                  ? _groupMembers.length - 1
                  : null,
            );
            final showTime = showAvatar || isFirst;
            if (st == null && !showTime) return const SizedBox.shrink();
            final warm = st?.warm == true;
            // A quiet, near-colourless frosted pill (like a bubble's own
            // timestamp, not a badge): frosted glass in the page's tone with
            // neutral grey text — dark grey on light, soft white on dark — so
            // it reads on any wallpaper or theme without competing.
            final ink = isDark
                ? Colors.white.withValues(alpha: 0.78)
                : const Color(0xFF5E5A5C);
            final inkSoft = isDark
                ? Colors.white.withValues(alpha: 0.55)
                : const Color(0xFF8A8587);
            // Opened: the theme colour, toned to stay subtle.
            final rose = isDark
                ? Color.lerp(accent, Colors.white, 0.45)!
                : Color.lerp(accent, Colors.black, 0.15)!;
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Align(
                alignment:
                    isMe ? Alignment.centerRight : Alignment.centerLeft,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  // No live blur: re-blurring under the text whenever
                  // anything near it repainted made the time shimmer on
                  // desktop. A slightly firmer frost reads the same.
                  child: RepaintBoundary(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 3.5),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.black.withValues(alpha: 0.42)
                            : Colors.white.withValues(alpha: 0.74),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.08)
                                : Colors.black.withValues(alpha: 0.05)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (st != null) ...[
                            Icon(st.icon,
                                size: 11.5,
                                color: warm ? rose : inkSoft),
                            const SizedBox(width: 4),
                            Text(st.text,
                                style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.2,
                                    color: warm ? rose : ink)),
                            if (showTime)
                              Container(
                                width: 3,
                                height: 3,
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 6),
                                decoration: BoxDecoration(
                                  color: inkSoft,
                                  shape: BoxShape.circle,
                                ),
                              ),
                          ],
                          if (showTime) ...[
                            Text(_timeOnly(msg['timestamp'] ?? ''),
                                style: TextStyle(
                                    fontSize: 10.5, color: ink)),
                            if (isMe) ...[
                              const SizedBox(width: 3),
                              _buildStatusIcon(msg,
                                  muted: inkSoft,
                                  read: isDark
                                      ? const Color(0xFF9FD0FF)
                                      : const Color(0xFF1E88E5)),
                            ],
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
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
    if (!tomb && msgType == 'heart') {
      return _buildHeartBubble(msg, isMe, isDark, showAvatar, isFirst);
    }
    final mediaRel = msg['media_url'] as String?;
    // A pending (optimistic) media message has no server URL yet, but it IS a
    // media bubble — render it from its local preview / placeholder.
    final pending = msg['__pending'] == true;
    final pendingMedia = pending &&
        (msgType == 'image' ||
            msgType == 'video' ||
            msgType == 'audio' ||
            msgType == 'song' ||
            msgType == 'file');
    final isMedia = !tomb &&
        msgType != 'text' &&
        ((mediaRel != null && mediaRel.isNotEmpty) || pendingMedia);
    // A call-log entry (auto-posted when an Aluta call ends).
    final isCall = !tomb && msgType == 'call';
    // A "listen together" log entry (posted when a live session ends/declines).
    final isLive = !tomb && msgType == 'live';
    // Shared location / contact cards (attach sheet). Their JSON lives in
    // `content`; the card renders it, so the raw text is suppressed below.
    final isLocation = !tomb && msgType == 'location';
    final isContact = !tomb && msgType == 'contact';
    final isPoll = !tomb && msgType == 'poll';
    // A lone fraction — the auto-converted glyph "½" OR a still-raw "1/2" —
    // renders big and bubble-less too, like a single emoji. Apply fraction
    // glyphs first so the test (and the big Text below) use the glyph form
    // regardless of whether the composer already converted it or the platform
    // fired the auto-convert at all.
    final emojiMain = applyFractions(mainText);
    final emojiOnly =
        !tomb && !hasQuote && !isMedia && _isEmojiOnly(emojiMain);
    // Image + caption: _imageCaption adapts per caption length — float (photo
    // left, text beside then below) when the text is long enough to fill the
    // side, else stacked under the photo — so there is never a blank gap. Both
    // render text through FloatColumn/WrappableText for a consistent font.
    final imgCap = isMedia &&
        !pending &&
        msgType == 'image' &&
        mainText.trim().isNotEmpty;

    // ── Bubble colours ──────────────────────────────────────────────────────
    // Sent messages use the brand red family (not WhatsApp green): a soft warm
    // rose on light, a deep muted maroon on dark — both easy on the eyes and
    // clearly "mine". Received bubbles stay a clean neutral (white / charcoal).
    // Honour the user's custom bubble theme (Appearance → Message bubbles):
    // their picks apply to every chat, with text/links derived for contrast so
    // the same colour reads well in both light and dark mode.
    final bool customBubbles = bubbleCustomEnabled;
    final bool onPhoto = chatBackgroundSmart(_convKey,
            isGroup: _isGroup, bonded: _canHarmony)
        .isPhoto;
    final Color sentBubble = customBubbles
        ? bubbleSentColor
        : (isDark ? const Color(0xFF4C2328) : const Color(0xFFFBDCDB));
    final Color recvBubble = customBubbles
        ? bubbleRecvColor
        : (isDark ? const Color(0xFF241E20) : Colors.white);
    final bubbleColor = isMe ? sentBubble : recvBubble;
    // Warm near-white text on the dark maroon; deep maroon text on the rose.
    final Color onSent = customBubbles
        ? bubbleTextOn(sentBubble)
        : (isDark ? const Color(0xFFF6E1E1) : const Color(0xFF4A141A));
    final Color onRecv =
        customBubbles ? bubbleTextOn(recvBubble) : scheme.onSurface;
    final textColor = isMe ? onSent : onRecv;
    // Tappable links: readable + clearly a link on either bubble colour.
    final Color linkColor = customBubbles
        ? bubbleLinkOn(isMe ? sentBubble : recvBubble)
        : (isDark
            ? const Color(0xFF9FD0FF)
            : (isMe ? const Color(0xFF0B4EA2) : const Color(0xFF1565C0)));
    // Accent for the quote bar / quoted author / Glow card, kept readable on
    // this very bubble (any custom bubble theme or accent).
    final quoteBarColor = bubbleTintOn(
        isMe
            ? (isDark ? const Color(0xFFFF8A93) : scheme.primary)
            : scheme.primary,
        isMe ? sentBubble : recvBubble,
        min: 3.6);
    // Cap the quoted-reply preview so a long quote can't stretch the bubble
    // past what the actual message needs: size it to the message's own width
    // (a readable minimum, up to the bubble max). The quote truncates with an
    // ellipsis and stays tappable (via _jumpToQuoted) to read the original.
    double quoteMaxWidth = double.infinity;
    if (quotedText != null) {
      final screenW = MediaQuery.of(context).size.width;
      final bubbleMax = (screenW * 0.72).clamp(220.0, 560.0);
      final mp = TextPainter(
        text: TextSpan(text: mainText, style: _capStyle(textColor)),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      quoteMaxWidth = (mp.width + 20).clamp(160.0, bubbleMax);
    }
    // Muted + "read" accent for the timestamp/ticks, tuned per bubble.
    // Derived from the ACTUAL bubble colour (default or custom, light or dark)
    // so the time and ticks always stay readable — fixed greys/blues vanished
    // on some custom colours and after switching theme.
    final sentMuted = bubbleMutedOn(sentBubble);
    final recvMuted = bubbleMutedOn(recvBubble);
    // Read receipt: a blue double-tick that contrasts with this bubble.
    final sentRead = bubbleReadTickOn(sentBubble);
    // Sent/delivered ticks: the muted colour; read ones switch to sentRead.
    final tickGray = sentMuted;
    // Subtle border to lift each bubble off the wallpaper.
    final bubbleBorder = customBubbles
        ? bubbleBorderOn(isMe ? sentBubble : recvBubble)
        : (isMe
            ? (isDark
                ? Colors.white.withAlpha(16)
                : scheme.primary.withAlpha(46))
            : (isDark
                ? Colors.white.withAlpha(20)
                : Colors.black.withAlpha(14)));

    // ── Bubble shape: a little beak/tail on the FIRST bubble of each group
    // (top-most / oldest of the run), pointing to its sender's side. Every
    // bubble reserves the same tail-side gutter so the run aligns straight.
    const tailSize = 7.0;
    final bubbleShape = _BubbleBorder(
      radius: 18,
      tailSize: tailSize,
      tailOnRight: isMe,
      showTail: showTail,
      side: BorderSide(color: bubbleBorder, width: 0.8),
    );

    // ── Spacing: tighter between grouped messages ──────────────────────────
    // A clear breath where the sender changes; snug inside a run.
    final topPad = showAvatar ? 10.0 : 2.0;

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
    final flashing = _highlightedId == msgId && _flashOn;
    return AnimatedContainer(
      key: key,
      duration: Duration(milliseconds: flashing ? 180 : 520),
      curve: Curves.easeOut,
      // A full-width accent band behind the jumped-to message, like a marker
      // swipe — strong enough to catch the eye, gone in about a second.
      color: flashing
          ? scheme.primary.withValues(alpha: isDark ? 0.30 : 0.20)
          : Colors.transparent,
      padding: EdgeInsets.only(
        top: topPad,
        left: isMe ? 56 : 6,
        right: isMe ? 6 : 56,
      ),
      child: AnimatedScale(
        // …and the bubble itself lifts a touch while it flashes.
        scale: flashing ? 1.025 : 1.0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
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
            child: _HoverChevron(
              enabled: MediaQuery.of(context).size.width >= 640,
              isMe: isMe,
              onOpen: (pos) =>
                  _showMessageMenu(context, msg, anchor: pos),
              child: GestureDetector(
              onLongPressStart: (d) =>
                  _showMessageMenu(context, msg, anchor: d.globalPosition),
              onSecondaryTapDown: (d) =>
                  _showMessageMenu(context, msg, anchor: d.globalPosition),
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

                // Keepsake quick icon — hugs the bubble's inner side (left for
                // my bubbles): hover-revealed on desktop, persistent on phone.
                if (isMe && _canHarmony && _isQuickKeepBubble(msg)) ...[
                  _KeepSideButton(
                    isPhone: MediaQuery.of(context).size.width < 640,
                    starsOn: _quickStarsOn,
                    onKeep: () => _keepsakeMessage(msg),
                  ),
                  const SizedBox(width: 3),
                ],

                // ── Emoji-only: no bubble, just big emoji ─────────────
                if (emojiOnly)
                  Text(
                    emojiMain,
                    style: const TextStyle(fontSize: 40, height: 1.2),
                  )
                else
                // ── Normal bubble ─────────────────────────────────────
                // Capped so a long message on a wide screen stays a
                // readable column (like any chat app), not a full-width bar.
                Flexible(
                  child: ConstrainedBox(
                  constraints: BoxConstraints(
                      maxWidth: isMedia ? double.infinity : 520),
                  child: Container(
                    decoration: ShapeDecoration(
                      color: bubbleColor,
                      shape: bubbleShape,
                      // On a PHOTO wallpaper (any brightness, any busyness)
                      // lift bubbles harder so text never sinks into the
                      // picture; patterns keep the light shadow.
                      shadows: onPhoto
                          ? [
                              BoxShadow(
                                color: Colors.black.withAlpha(isDark ? 110 : 56),
                                blurRadius: 14,
                                offset: const Offset(0, 4),
                              ),
                              BoxShadow(
                                color: Colors.black.withAlpha(isDark ? 60 : 24),
                                blurRadius: 2,
                                offset: const Offset(0, 1),
                              ),
                            ]
                          : [
                              BoxShadow(
                                color: Colors.black.withAlpha(isDark ? 46 : 20),
                                blurRadius: 8,
                                offset: const Offset(0, 3),
                              ),
                            ],
                    ),
                    // Reserve the tail-side gutter on EVERY bubble (not just
                    // the one with the beak) so a grouped run aligns straight.
                    padding: EdgeInsets.only(
                        left: 11 + (!isMe ? tailSize : 0),
                        right: 11 + (isMe ? tailSize : 0),
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
                          // Sender identity gets its own zone — a coloured
                          // accent tab, a quiet label typeface, and a hairline
                          // that dissolves toward the edge — so it never reads
                          // as the first line of the message. Tap to open the
                          // member's profile.
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _openMemberProfile(
                                rxName, rxPhone, senderAvatar),
                            child: Padding(
                              padding:
                                  const EdgeInsets.only(bottom: 6, right: 6),
                              // Cap the sender header so a long name + number
                              // can't stretch a media bubble wider than its
                              // media (which leaves a blank gap on desktop).
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                    maxWidth: isMedia ? 248 : 320),
                                child: IntrinsicWidth(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.center,
                                      children: [
                                        Container(
                                          width: 3,
                                          height: 12,
                                          decoration: BoxDecoration(
                                            color: _senderColor(
                                                inPhonebook
                                                    ? headerName
                                                    : rxName,
                                                isDark,
                                                on: bubbleColor),
                                            borderRadius:
                                                BorderRadius.circular(2),
                                          ),
                                        ),
                                        const SizedBox(width: 7),
                                        Flexible(
                                          child: Text(
                                            headerName,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: 0.25,
                                              height: 1.0,
                                              color: _senderColor(
                                                  inPhonebook
                                                      ? headerName
                                                      : rxName,
                                                  isDark,
                                                  on: bubbleColor),
                                            ),
                                          ),
                                        ),
                                        if (_isMemberAdmin(
                                            msg['sender_id'])) ...[
                                          const SizedBox(width: 6),
                                          _adminTag(scheme, on: bubbleColor),
                                        ],
                                        if (!inPhonebook &&
                                            rxPhone.isNotEmpty) ...[
                                          const SizedBox(width: 10),
                                          Text(
                                            rxPhone,
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              fontWeight: FontWeight.w400,
                                              letterSpacing: 0.2,
                                              color: bubbleMutedOn(bubbleColor),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Container(
                                      height: 1,
                                      margin: const EdgeInsets.only(left: 10),
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [
                                            _senderColor(
                                                    inPhonebook
                                                        ? headerName
                                                        : rxName,
                                                    isDark,
                                                    on: bubbleColor)
                                                .withAlpha(
                                                    isDark ? 120 : 95),
                                            Colors.transparent,
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
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
                        // ── Text the server swept before THIS device saved
                        // it (older store-and-forward behaviour): say so instead
                        // of showing an empty bubble with only a time. ──
                        if (!tomb &&
                            msgType == 'text' &&
                            msg['purged'] == true &&
                            content.trim().isEmpty)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.history_toggle_off_rounded,
                                  size: 15, color: textColor.withAlpha(120)),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  'Message not saved on this device',
                                  style: TextStyle(
                                    color: textColor.withAlpha(160),
                                    fontStyle: FontStyle.italic,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        // ── Quoted reply (tap to jump to original) ─────
                        if (!tomb && quotedText != null)
                          GestureDetector(
                            onTap: () => _jumpToQuoted(quotedText!),
                            child: ConstrainedBox(
                              constraints:
                                  BoxConstraints(maxWidth: quoteMaxWidth),
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
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
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
                          ),

                        // ── Message body (media and/or text) ──────────
                        if (isCall) _callLogContent(msg, isMe, textColor),
                        if (isLive) _liveLogContent(msg, isMe, textColor),
                        if (isLocation)
                          _locationContent(msg, isMe, textColor, scheme),
                        if (isContact)
                          _contactContent(msg, isMe, textColor, scheme),
                        if (isPoll)
                          _pollContent(msg, isMe, textColor, scheme),
                        if (isMedia && !imgCap)
                          _mediaContent(msgType, mediaRel ?? '', msg, isMe,
                              textColor, scheme,
                              caption: msgType == 'video' ? mainText : null),
                        if (imgCap)
                          _imageCaption(fullMediaUrl(mediaRel ?? ''), mainText,
                              textColor, linkColor),
                        // A shared song shows its title inside the card, so skip
                        // the duplicate text line. Call/live logs store their
                        // outcome in `content` (rendered above), so skip that too.
                        if (!tomb &&
                            msgType != 'song' &&
                            msgType != 'call' &&
                            msgType != 'live' &&
                            msgType != 'location' &&
                            msgType != 'contact' &&
                            msgType != 'poll' &&
                            msgType != 'video' &&
                            !imgCap &&
                            mainText.trim().isNotEmpty)
                          Padding(
                            padding: EdgeInsets.only(top: isMedia ? 6 : 0),
                            // A Glow card shared from the Glow feed renders
                            // as a little card, not a plain paragraph.
                            child: _glowCardBubble(
                                    mainText, textColor, quoteBarColor) ??
                                _bubbleTextOnly(
                                    mainText, textColor, linkColor),
                          ),
                        // Someone nudged you about their status: answer in
                        // one tap (shown while it's the newest message).
                        if (!isMe &&
                            !tomb &&
                            quotedText != null &&
                            (quotedText.startsWith('👀 Caught you on my status') ||
                                quotedText.startsWith('👀 You viewed my status')) &&
                            _messages.isNotEmpty &&
                            _messages.first['id'] == msg['id'])
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: _statusNudgeAnswer(
                                quotedText.contains('🎵'), quoteBarColor),
                          ),

                        // ── Time + delivery status ────────────────────
                        // Shown only on last message of group (showAvatar)
                        // or standalone, to reduce visual noise.
                        if (showAvatar || isFirst || (isMe && pending))
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
                                      color: isMe ? sentMuted : recvMuted,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                ],
                                Text(
                                  _timeOnly(msg['timestamp'] ?? ''),
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: isMe ? sentMuted : recvMuted,
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
                ),
                if (!isMe && _canHarmony && _isQuickKeepBubble(msg)) ...[
                  const SizedBox(width: 3),
                  _KeepSideButton(
                    isPhone: MediaQuery.of(context).size.width < 640,
                    starsOn: _quickStarsOn,
                    onKeep: () => _keepsakeMessage(msg),
                  ),
                ],
              ],
            ),
            )),
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
                  if (_isSongReaction(e)) {
                    return GestureDetector(
                      onTap: () => _addReaction(msg, e),
                      child: _songReactionChip(e, scheme),
                    );
                  }
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
                      child: AnimatedReaction(emoji: e, size: 15),
                    ),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
      ),
    );
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
        case 'video':
          typeIcon = Icons.videocam_rounded;
          label = caption.isNotEmpty ? caption : 'Video';
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
    } else if (msgType == 'location') {
      typeIcon = Icons.location_on_rounded;
      label = 'Location';
    } else if (msgType == 'contact') {
      typeIcon = Icons.person_rounded;
      label = 'Contact';
    } else if (msgType == 'poll') {
      typeIcon = Icons.poll_rounded;
      label = 'Poll: ${(msg['content'] ?? '').toString()}';
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.45)),
        ),
      ),
      child: Row(
          children: [
            // Accent bar.
            Container(
              width: 3.5,
              height: 40,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 10),
            // Thumbnail for an image reply.
            if (isMedia && msgType == 'image')
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: authNetworkImage(
                    url: fullMediaUrl(mediaRel),
                    headers: mediaAuthHeaders(fullMediaUrl(mediaRel)),
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                    placeholder: (_) => Container(
                        width: 40,
                        height: 40,
                        color: scheme.surfaceContainerHigh),
                    error: (_) => Container(
                        width: 40,
                        height: 40,
                        color: scheme.surfaceContainerHigh,
                        child: Icon(Icons.photo_rounded,
                            size: 18, color: scheme.onSurfaceVariant)),
                  ),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(Icons.reply_rounded,
                          size: 13, color: scheme.primary),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          isFromMe
                              ? 'Replying to yourself'
                              : 'Replying to ${_isGroup && _replyTo != null ? _groupMemberLabel(_replyTo!) : widget.friendName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.primary,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
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
                              color: scheme.onSurface.withAlpha(165),
                              fontSize: 12.5),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              color: scheme.onSurfaceVariant,
              onPressed: () => setState(() => _replyTo = null),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      );
  }

  // True when we have this friend's phone number but no saved phone-book name
  // for it, so we should offer to add them (one-to-one chats only).
  bool get _needsContactSave {
    if (_isGroup || widget.friendId <= 0) return false;
    if (_friendPhone.trim().isEmpty) return false;
    if (!ContactNames.isSupported) return false;
    // Offer to save unless it's already under a real phone-book name (a contact
    // saved as just the number doesn't count).
    return !ContactNames.instance.hasRealName(_friendPhone);
  }

  // Opens the phone's native "new contact" screen pre-filled with this
  // friend's number (WhatsApp-style). After the user saves, re-read the
  // address book so the name resolves across the app right away.
  Future<void> _addFriendToContacts() async {
    final phone = _friendPhone.trim();
    if (phone.isEmpty) return;
    try {
      final contact = Contact()..phones = [Phone(phone)];
      await FlutterContacts.openExternalInsert(contact);
    } catch (e) {
      if (mounted) {
        showToast(context, "Couldn't open Contacts", type: ToastType.error);
      }
      return;
    }
    // Whether or not they saved, refresh so a new entry is picked up.
    try {
      await ContactNames.instance.refresh();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Widget _buildInput(bool isDark) {
    final scheme = Theme.of(context).colorScheme;
    // A pending file caption takes over the composer slot (only) with a
    // compact caption panel, so it never covers the chat list or player.
    if (_captionFileName != null) {
      return SafeArea(
        top: false,
        bottom: widget.showAppBar,
        child: _buildFileCaptionBar(scheme),
      );
    }
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
          // @-mention picker: inline, so it rides above the keyboard with the
          // composer instead of floating somewhere the keyboard can cover.
          // Secret heart: mood · seal-until · note starters.
          // Rituals: good night (bonded DM, late) · on this day.
          _buildRitualChips(scheme, isDark),
          if (_heartMode && !_isRecording && _editing == null)
            Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: _buildHeartTray(scheme, isDark),
              ),
            ),
          if (_isGroup && _mentionQuery != null && !_isRecording)
            Align(
              alignment: Alignment.centerLeft,
              child: _buildMentionPicker(scheme, isDark),
            ),
          if (_editing != null)
            _EditBanner(
              text: _stripQuote((_editing!['content'] as String?) ?? ''),
              onCancel: _cancelEditing,
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: _isRecording
                ? ValueListenableBuilder<int>(
                    valueListenable: _recordMsVN,
                    builder: (_, ms, _) => _RecordingBar(
                      durationLabel: _fmtDur(ms),
                      onCancel: _cancelRecording,
                      onSend: _stopAndSendRecording,
                    ),
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // Rounded input field: emoji · text · attach · camera.
                      Expanded(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOut,
                          // Matches the 48px mic/send disc beside it.
                          constraints: const BoxConstraints(minHeight: 48),
                          // Centre the 40px icon/text row in the 48px pill
                          // (it sat at the top, looking nudged upward). A
                          // multi-line message still grows the pill evenly.
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 2, vertical: 4),
                          // Solid, lifted pill: readable on ANY wallpaper (no
                          // see-through), with a soft drop shadow + hairline so
                          // it floats like a card.
                          decoration: BoxDecoration(
                            color: isDark
                                ? Color.alphaBlend(
                                    Colors.white.withValues(alpha: 0.06),
                                    scheme.surface)
                                : scheme.surface,
                            borderRadius: BorderRadius.circular(26),
                            // Focused → a clear brand ring + soft brand glow
                            // (you're typing here); idle → a quiet hairline.
                            // Subtle, like the original focus line: a thin
                            // brand hairline, no thicker than idle.
                            border: Border.all(
                                width: 1.0,
                                color: _composerFocused
                                    ? scheme.primary
                                        .withValues(alpha: isDark ? 0.55 : 0.45)
                                    : (isDark
                                        ? Colors.white.withValues(alpha: 0.10)
                                        : Colors.black.withValues(alpha: 0.06))),
                            boxShadow: [
                              if (_composerFocused)
                                BoxShadow(
                                  color: scheme.primary
                                      .withValues(alpha: isDark ? 0.14 : 0.08),
                                  blurRadius: 8,
                                ),
                              BoxShadow(
                                color: Colors.black
                                    .withValues(alpha: isDark ? 0.45 : 0.16),
                                blurRadius: 16,
                                offset: const Offset(0, 5),
                              ),
                              BoxShadow(
                                color: Colors.black
                                    .withValues(alpha: isDark ? 0.25 : 0.06),
                                blurRadius: 3,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (_replyTo != null)
                                _buildReplyPreview(_replyTo!),
                              Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              // Side actions collapse while typing so the
                              // field uses the full width; they re-appear when
                              // the text is sent / cleared.
                              // Side actions DISSOLVE (fade + collapse) when
                              // typing, leaving a clean box with just the heart
                              // (left) and send (right).
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 220),
                                switchInCurve: Curves.easeOut,
                                switchOutCurve: Curves.easeIn,
                                transitionBuilder: (child, anim) =>
                                    SizeTransition(
                                  axis: Axis.horizontal,
                                  alignment: Alignment.centerLeft,
                                  sizeFactor: anim,
                                  child:
                                      FadeTransition(opacity: anim, child: child),
                                ),
                                child: hasText
                                    ? const SizedBox.shrink(
                                        key: ValueKey('emoji-off'))
                                    : IconButton(
                                        key: const ValueKey('emoji-on'),
                                        tooltip:
                                            _showEmoji ? 'Keyboard' : 'Emoji',
                                        icon: Icon(
                                          _showEmoji
                                              ? Icons.keyboard_rounded
                                              : Icons.emoji_emotions_outlined,
                                          color: scheme.onSurfaceVariant,
                                        ),
                                        onPressed: () {
                                          FocusScope.of(context).unfocus();
                                          setState(
                                              () => _showEmoji = !_showEmoji);
                                        },
                                        visualDensity: VisualDensity.compact,
                                      ),
                              ),
                              // Secret-heart toggle — stays visible while
                              // typing so you can mark a note as a secret ❤.
                              IconButton(
                                tooltip: _heartMode
                                    ? 'Secret heart: on'
                                    : 'Send as a secret heart',
                                icon: Icon(
                                  _heartMode
                                      ? Icons.favorite_rounded
                                      : Icons.favorite_border_rounded,
                                  color: _heartMode
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                ),
                                onPressed: () => setState(() {
                                  _heartMode = !_heartMode;
                                  if (!_heartMode) {
                                    _heartMood = 'love';
                                    _heartUnlockAt = null;
                                  }
                                }),
                                visualDensity: VisualDensity.compact,
                              ),
                              // Text field. Desktop: Enter=send, Shift+Enter=newline.
                              Expanded(
                                child: Focus(
                                  // Ring the pill while you're typing.
                                  onFocusChange: (f) {
                                    if (f != _composerFocused) {
                                      setState(() => _composerFocused = f);
                                    }
                                  },
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
                                    focusNode: _composerFocus,
                                    minLines: 1,
                                    maxLines: 5,
                                    textInputAction: TextInputAction.newline,
                                    keyboardType: TextInputType.multiline,
                                    decoration: InputDecoration(
                                      // Desktop keyboards benefit from the
                                      // Shift+Enter hint; on mobile it just
                                      // clutters the compact field, so there
                                      // we show a plain "Message" placeholder.
                                      hintText: _heartMode
                                          ? 'Secret message…'
                                          : 'Message',
                                      hintMaxLines: 1,
                                      hintStyle: TextStyle(
                                          color: scheme.onSurfaceVariant
                                              .withValues(alpha: 0.7)),
                                      isDense: true,
                                      // No inner box: the pill IS the field
                                      // (overrides any app-wide filled /
                                      // outlined input theme).
                                      filled: false,
                                      border: InputBorder.none,
                                      enabledBorder: InputBorder.none,
                                      focusedBorder: InputBorder.none,
                                      disabledBorder: InputBorder.none,
                                      contentPadding: const EdgeInsets.symmetric(
                                          vertical: 10, horizontal: 4),
                                    ),
                                  ),
                                ),
                              ),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 220),
                                switchInCurve: Curves.easeOut,
                                switchOutCurve: Curves.easeIn,
                                transitionBuilder: (child, anim) =>
                                    SizeTransition(
                                  axis: Axis.horizontal,
                                  alignment: Alignment.centerRight,
                                  sizeFactor: anim,
                                  child:
                                      FadeTransition(opacity: anim, child: child),
                                ),
                                child: hasText
                                    ? const SizedBox(
                                        width: 4, key: ValueKey('trail-off'))
                                    : Padding(
                                        key: const ValueKey('trail-on'),
                                        padding:
                                            const EdgeInsets.only(right: 2),
                                        child: IconButton(
                                          key: _attachBtnKey,
                                          // One quiet "+" opens Share, which
                                          // already holds Camera, Listen
                                          // together, Gallery, Video and more —
                                          // so the resting field keeps its full
                                          // width instead of being boxed in by
                                          // a row of icons.
                                          tooltip: 'Share',
                                          icon: Icon(Icons.add_rounded,
                                              color: scheme.onSurfaceVariant),
                                          onPressed: _openAttachSheet,
                                          visualDensity: VisualDensity.compact,
                                        ),
                                      ),
                              ),
                            ],
                          ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Mic (idle) ↔ Send (typing). Sends never block here —
                      // per-bubble spinners show upload progress instead.
                      // Sized to match the input pill so the two read as one
                      // unit. The idle mic wears only a faint brand tint (soft
                      // pink fill + red icon) so it complements — rather than
                      // competes with — the solid-red player FAB in the footer.
                      // Send is an action, so it keeps the solid red for
                      // emphasis while the user is typing.
                      Tooltip(
                              message: hasText
                                  ? (_editing != null ? 'Save edit' : 'Send')
                                  : 'Record voice note',
                              child: GestureDetector(
                                onTap: hasText
                                    ? (_editing != null
                                        ? _saveEdit
                                        : _sendMessage)
                                    : _startRecording,
                                // Same height + lift as the pill, so the two
                                // read as one floating row. Idle mic: a SOLID
                                // light disc (never see-through) with a soft
                                // brand ring; typing → solid brand send.
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 180),
                                  width: 48,
                                  height: 48,
                                  decoration: BoxDecoration(
                                    color: hasText
                                        ? scheme.primary
                                        : Color.alphaBlend(
                                            scheme.primary.withValues(
                                                alpha: isDark ? 0.18 : 0.10),
                                            isDark
                                                ? Color.alphaBlend(
                                                    Colors.white.withValues(
                                                        alpha: 0.06),
                                                    scheme.surface)
                                                : scheme.surface),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: hasText
                                          ? Colors.transparent
                                          : scheme.primary.withValues(
                                              alpha: isDark ? 0.40 : 0.28),
                                      width: 1,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: (hasText
                                                ? scheme.primary
                                                : Colors.black)
                                            .withValues(
                                                alpha: hasText
                                                    ? 0.40
                                                    : (isDark ? 0.45 : 0.16)),
                                        blurRadius: 16,
                                        offset: const Offset(0, 5),
                                      ),
                                    ],
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

  // ── Main build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    // Returning from a pushed screen makes this the current route again — keep
    // the active-chat marker in sync so suppression stays correct.
    if (ModalRoute.of(context)?.isCurrent ?? true) {
      if (_isGroup) {
        ActiveChat.instance.enterGroup(_cid.toString());
      } else {
        ActiveChat.instance.enterDm(widget.friendId.toString());
      }
    }
    // On phones the conversation goes edge-to-edge and flush at the bottom (only
    // its top corners round, meeting the header); on wider screens it stays an
    // inset, fully-rounded card within the split panel.
    final isPhone = MediaQuery.of(context).size.width < 640;

    final body = Column(
      children: [
        // Pinned-message banner (empty widget when nothing is pinned).
        _buildPinnedBanner(),
        // "Add to contacts" prompt when this friend's number isn't in the
        // phone book yet (empty widget otherwise).
        _buildSaveContactBanner(),
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
            // The wallpaper fills the WHOLE card — under the composer too —
            // so the typing area floats on it. Messages stay above the
            // composer and dissolve into the wallpaper just before it.
            // PixelSnap: when the chat runs full-screen (its own route) the
            // thread still starts on a whole pixel.
            child: PixelSnap(child: Stack(
              children: [
                // ── Chat wallpaper background ─────────────────────────────
                Positioned.fill(
                  child: ValueListenableBuilder<int>(
                    valueListenable: chatBgRevision,
                    builder: (ctx, _, _) {
                      final bg = chatBackgroundSmart(_convKey,
                          isGroup: _isGroup, bonded: _canHarmony);
                      if (bg.isPhoto) {
                        return _chatPhotoWallpaper(bg, isDark);
                      }
                      if (bg.isMotif) {
                        return _chatMotifWallpaper(scheme, isDark);
                      }
                      if (bg.isWatermark) {
                        return ValueListenableBuilder<double>(
                          valueListenable: motifStrength,
                          builder: (_, v, _) => AlutaWatermarkWallpaper(
                              tint: scheme.primary,
                              isDark: isDark,
                              strength: v,
                              // The big centre mark drifts a touch with the
                              // chat — a hint of depth behind the bubbles.
                              scroll: _scrollCtrl,
                              // Centre on the message area above the
                              // floating composer (~64px incl. margins).
                              bottomInset: 64),
                        );
                      }
                      return _ChatWallpaper(
                          isDark: isDark, brand: scheme.primary);
                    },
                  ),
                ),
                // The room follows the day: a faint warm / golden / night
                // wash over whichever wallpaper is set.
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedContainer(
                      duration: const Duration(seconds: 2),
                      color: AlutaMood.wallpaperWash(isDark: isDark),
                    ),
                  ),
                ),
                Column(
                  children: [
                    Expanded(
            child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  children: [
                    // Bubbles fade out over the last ~10px above the
                    // composer instead of being cut off by a hard edge.
                    ShaderMask(
                      blendMode: BlendMode.dstIn,
                      shaderCallback: (r) {
                        final f = r.height <= 0
                            ? 0.0
                            : (10 / r.height).clamp(0.0, 0.4);
                        return LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: const [
                            Colors.white,
                            Colors.white,
                            Colors.transparent
                          ],
                          stops: [0.0, 1.0 - f, 1.0],
                        ).createShader(r);
                      },
                      child: GestureDetector(
                      // Tapping the conversation drops the text-field focus so
                      // the cursor leaves and the keyboard slides away smoothly,
                      // and closes the emoji sheet.
                      onTap: () {
                        FocusScope.of(context).unfocus();
                        setState(() => _showEmoji = false);
                      },
                      child: ValueListenableBuilder<int>(
                        valueListenable: bubbleThemeRevision,
                        builder: (_, _, _) => Listener(
                          onPointerDown: _onChatPointerDown,
                          onPointerUp: _onChatPointerUp,
                          child: ListView.builder(
                        controller: _scrollCtrl,
                        reverse: true,
                        // Bottom inset = the fade band (+ a breath), so at
                        // rest the newest bubble — footer and all — sits
                        // fully ABOVE the fade; only scrolled-away bubbles
                        // dissolve into it.
                        padding: const EdgeInsets.fromLTRB(4, 8, 4, 14),
                        itemCount: _messages.length + 1,
                        itemBuilder: (ctx, i) {
                          // Reversed list: index 0 is the bottom. A persistent
                          // slot for the typing/recording indicator, which
                          // grows in and shrinks out smoothly, sitting right
                          // after the last message.
                          if (i == 0) {
                            return AnimatedSize(
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeOutCubic,
                              alignment: Alignment.bottomLeft,
                              child: _showTyping
                                  ? _buildTypingIndicator()
                                  : const SizedBox.shrink(),
                            );
                          }
                          final msgIdx = i - 1;
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
                              if (_unreadAnchorId != null &&
                                  msg['id'].toString() == _unreadAnchorId)
                                _buildUnreadDivider(scheme, isDark),
                              _animateInWrap(
                                  msg,
                                  _buildBubble(msg, isMe, isDark, showAvatar,
                                      isFirst, showTail)),
                              if (isMe &&
                                  !_isGroup &&
                                  msg['id'].toString() == _seenByFriendId)
                                _buildSeenAvatar(scheme),
                            ],
                          );
                        },
                      ),
                      ),
                      ),
                    ),
                    ),
                    // Empty chat: a warm, branded first-message nudge.
                    if (_messages.isEmpty)
                      Positioned.fill(
                        child: Center(
                          child: _emptyChatHello(scheme, isDark),
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
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.arrow_downward_rounded,
                                      size: 14, color: readableOn(scheme.primary)),
                                  SizedBox(width: 4),
                                  Text('New messages',
                                      style: TextStyle(
                                          color: readableOn(scheme.primary),
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    // "@" stepper: unread mentions of me, stacked above ⇊.
                    if (_isGroup)
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        right: 10,
                        bottom: _farFromBottom ? 60 : 10,
                        child: _buildMentionChip(scheme),
                      ),
                    // Round "back to latest" button, bottom-right, whenever
                    // you're a good way up the thread (a dot = new messages).
                    Positioned(
                      right: 12,
                      bottom: 12,
                      child: IgnorePointer(
                        ignoring: !_farFromBottom,
                        child: AnimatedScale(
                          scale: _farFromBottom ? 1 : 0.6,
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOutBack,
                          child: AnimatedOpacity(
                            opacity: _farFromBottom ? 1 : 0,
                            duration: const Duration(milliseconds: 180),
                            child: Material(
                              color: scheme.surface,
                              shape: CircleBorder(
                                  side: BorderSide(
                                      color: scheme.outlineVariant
                                          .withValues(alpha: 0.6))),
                              elevation: 4,
                              shadowColor: Colors.black38,
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: _jumpToLatest,
                                child: SizedBox(
                                  width: 42,
                                  height: 42,
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      Icon(
                                          Icons
                                              .keyboard_double_arrow_down_rounded,
                                          color: scheme.primary,
                                          size: 24),
                                      if (_hasNewMsg)
                                        Positioned(
                                          top: 7,
                                          right: 8,
                                          child: Container(
                                            width: 9,
                                            height: 9,
                                            decoration: BoxDecoration(
                                              color: scheme.primary,
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                  color: scheme.surface,
                                                  width: 1.5),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // In-chat search pill, floating over the top of the
                    // thread (slides + fades in).
                    Positioned(
                      top: 8,
                      left: 10,
                      right: 10,
                      child: IgnorePointer(
                        ignoring: !_searchOpen,
                        child: AnimatedSlide(
                          offset: _searchOpen
                              ? Offset.zero
                              : const Offset(0, -0.6),
                          duration: const Duration(milliseconds: 240),
                          curve: Curves.easeOutCubic,
                          child: AnimatedOpacity(
                            opacity: _searchOpen ? 1 : 0,
                            duration: const Duration(milliseconds: 180),
                            child: _searchOpen
                                ? _buildSearchBar(scheme, isDark)
                                : const SizedBox(height: 48),
                          ),
                        ),
                      ),
                    ),
                    if (_mediaBrowser != null)
                      Positioned.fill(
                        child: RepaintBoundary(
                          child: AnimatedBuilder(
                            animation: _browserIn,
                            builder: (_, child) {
                              final v = _browserIn.value;
                              return IgnorePointer(
                                ignoring: _browserClosing,
                                child: FractionalTranslation(
                                  translation: Offset(-0.22 * (1 - v), 0),
                                  child: Opacity(
                                      opacity: v.clamp(0.0, 1.0),
                                      child: child),
                                ),
                              );
                            },
                            child: _mediaBrowser,
                          ),
                        ),
                      ),
                    if (_viewerImages != null) _buildInlineViewer(),
                  ],
                ),
                    ),
                    // Input — floating straight on the wallpaper (no tint
                    // band): the watermark / photo shows right through behind
                    // it. Bubbles only soften as they scroll into the edge
                    // (the list's own fade), so nothing sits there at rest.
                    _postingLocked
                        ? _buildAdminsOnlyBar(scheme, isDark)
                        : _buildInput(isDark),
                  ],
                ),
              ],
            )),
          ),
        ),
      ],
    );

    if (!widget.showAppBar) return _wrapViewerBack(_pasteWrapper(body));

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
                      : _isFriendOnline
                          ? 'online'
                          : _lastSeen.isNotEmpty
                              ? 'last seen ${formatLastSeen(_lastSeen)}'
                              : 'offline',
                  style: TextStyle(
                    fontSize: 11,
                    color: (!_isGroup && _isFriendOnline)
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
          if (!_isGroup)
            IconButton(
              tooltip: 'Call ${widget.friendName}',
              icon: const Icon(Icons.call_rounded),
              onPressed: _showCallChoice,
            ),
          if (!_isGroup)
            IconButton(
              tooltip: 'Listen together',
              icon: const Icon(Icons.headphones_rounded),
              onPressed: _startListenTogether,
            ),
          IconButton(
            tooltip: 'Search in chat',
            icon: const Icon(Icons.search_rounded),
            onPressed: _openSearch,
          ),
          GeniePopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (v) {
              if (v == 'wallpaper') {
                _openChatWallpaperSheet();
              } else if (v == 'media') {
                _openMediaBrowser();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'media',
                child: Row(
                  children: [
                    Icon(Icons.perm_media_outlined, size: 20),
                    SizedBox(width: 12),
                    Text('Songs, media & docs'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'wallpaper',
                child: Row(
                  children: [
                    Icon(Icons.wallpaper_rounded, size: 20),
                    SizedBox(width: 12),
                    Text('Wallpaper'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: _wrapViewerBack(_pasteWrapper(body)),
    );
  }
}

/// Clips a full-screen layer to everything EXCEPT a rounded-rect hole — used by
/// the message spotlight so the blur/dim covers the screen but leaves the
/// pressed bubble crisp.
class _HoleClipper extends CustomClipper<Path> {
  _HoleClipper(this.hole, this.radius);
  final Rect hole;
  final double radius;

  @override
  Path getClip(Size size) {
    return Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()
        ..addRRect(RRect.fromRectAndRadius(hole, Radius.circular(radius))),
    );
  }

  @override
  bool shouldReclip(covariant _HoleClipper old) =>
      old.hole != hole || old.radius != radius;
}

/// One entry in the message menu — reused by both the quick-action row and the
/// expanded dropdown so a button behaves identically in either place.
class _MenuAction {
  const _MenuAction(this.id, this.icon, this.label, this.onTap,
      {this.color, this.short});
  final String id;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final String? short; // compact label for the quick row
}

/// The message action menu: a compact quick-action row (Reply · Pin · Forward ·
/// Delete · More) in the house style, which expands to the full dropdown of
/// every action when "More" (⋮) is tapped. Keeps the pink frosted card look.
class _MsgActionMenu extends StatefulWidget {
  const _MsgActionMenu({
    required this.quick,
    required this.full,
    required this.scheme,
    required this.isDark,
    required this.shadow,
    this.header,
  });
  final List<_MenuAction> quick;
  final List<_MenuAction> full;
  final ColorScheme scheme;
  final bool isDark;
  final List<BoxShadow> shadow;
  final Widget? header; // the reaction strip, shown on top of the same card

  @override
  State<_MsgActionMenu> createState() => _MsgActionMenuState();
}

class _MsgActionMenuState extends State<_MsgActionMenu> {
  bool _expanded = false;

  BoxDecoration _deco(double radius) =>
      _menuDeco(widget.scheme, widget.isDark, widget.shadow, radius);

  Widget _quickItem(
      ColorScheme scheme, IconData icon, String label, VoidCallback onTap,
      Color? color) {
    final c = color ?? scheme.primary;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: c.withValues(alpha: widget.isDark ? 0.22 : 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: c, size: 18),
              ),
              const SizedBox(height: 4),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = widget.scheme;
    final header = widget.header;
    if (header == null) {
      // Legacy two-piece layout (no reactions inside).
      if (_expanded) {
        return _FullMenuCard(
          actions: widget.full,
          scheme: widget.scheme,
          isDark: widget.isDark,
          shadow: widget.shadow,
        );
      }
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        decoration: _deco(26),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            for (final a in widget.quick)
              _quickItem(scheme, a.icon, a.short ?? a.label, a.onTap, a.color),
            _quickItem(scheme, Icons.more_vert_rounded, 'More',
                () => setState(() => _expanded = true), null),
          ],
        ),
      );
    }

    // One card: reactions on top, a hairline, then the actions. "More" grows
    // the same card into the full list (reactions stay put above it).
    final hair = Divider(
      height: 1,
      thickness: 1,
      color: scheme.outlineVariant.withValues(alpha: widget.isDark ? 0.28 : 0.45),
    );
    return Container(
      decoration: _deco(22),
      clipBehavior: Clip.antiAlias,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            header,
            hair,
            if (!_expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
                child: Row(
                  children: [
                    for (final a in widget.quick)
                      _compactItem(scheme, a.icon, a.short ?? a.label, a.onTap,
                          a.color),
                    _compactItem(scheme, Icons.more_horiz_rounded, 'More',
                        () => setState(() => _expanded = true), null),
                  ],
                ),
              )
            else
              Flexible(
                child: _FullMenuCard(
                  actions: widget.full,
                  scheme: widget.scheme,
                  isDark: widget.isDark,
                  shadow: const [],
                  bare: true,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Slim icon-over-label action for the unified card (no big circles).
  Widget _compactItem(ColorScheme scheme, IconData icon, String label,
      VoidCallback onTap, Color? color) {
    final c = color ?? scheme.onSurface;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: color ?? scheme.primary),
              const SizedBox(height: 3),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: c.withValues(alpha: 0.8))),
            ],
          ),
        ),
      ),
    );
  }
}

/// The quick-reaction strip at the top of the message card: emojis pop in
/// one after another, and the one I already picked sits in a soft tinted pill.
class _ReactionStrip extends StatelessWidget {
  const _ReactionStrip({
    required this.reactions,
    required this.onPick,
    required this.isDark,
    this.mine,
  });
  final List<String> reactions;
  final ValueChanged<String> onPick;
  final bool isDark;
  final String? mine;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (var i = 0; i < reactions.length; i++)
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: Duration(milliseconds: 260 + i * 45),
              curve: Curves.easeOutBack,
              builder: (_, v, child) => Transform.scale(
                scale: (0.4 + 0.6 * ((v - i * 0.08) / (1 - i * 0.08)))
                    .clamp(0.0, 1.2),
                child: child,
              ),
              child: Container(
                decoration: reactions[i] == mine
                    ? BoxDecoration(
                        color: scheme.primary
                            .withValues(alpha: isDark ? 0.24 : 0.14),
                        shape: BoxShape.circle,
                      )
                    : null,
                child: _ReactionButton(
                  emoji: reactions[i],
                  onTap: () => onPick(reactions[i]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Shared frosted-card decoration for the message menu (house style).
BoxDecoration _menuDeco(
    ColorScheme scheme, bool isDark, List<BoxShadow> shadow, double radius) {
  return BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Color.alphaBlend(
            scheme.primary.withValues(alpha: isDark ? 0.08 : 0.05),
            scheme.surface),
        scheme.surface,
      ],
    ),
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(
        color: scheme.outlineVariant.withValues(alpha: isDark ? 0.45 : 0.30),
        width: 1),
    boxShadow: shadow,
  );
}

/// The full scrollable action list (house style) with an always-visible scroll
/// indicator so it's clear there is more below — used by the expanded mobile
/// menu and the desktop dropdown.
class _FullMenuCard extends StatefulWidget {
  const _FullMenuCard({
    required this.actions,
    required this.scheme,
    required this.isDark,
    required this.shadow,
    this.maxHeight,
    this.bare = false,
  });
  final List<_MenuAction> actions;
  final ColorScheme scheme;
  final bool isDark;
  final List<BoxShadow> shadow;
  final double? maxHeight;
  final bool bare; // no own card (it sits inside the unified message card)

  @override
  State<_FullMenuCard> createState() => _FullMenuCardState();
}

class _FullMenuCardState extends State<_FullMenuCard> {
  final ScrollController _sc = ScrollController();

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final card = Container(
      decoration: widget.bare
          ? null
          : _menuDeco(widget.scheme, widget.isDark, widget.shadow, 18),
      clipBehavior: widget.bare ? Clip.none : Clip.antiAlias,
      child: Scrollbar(
        controller: _sc,
        thumbVisibility: true,
        radius: const Radius.circular(8),
        child: SingleChildScrollView(
          controller: _sc,
          child: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final a in widget.actions)
                  if (a.id == '__div__')
                    Divider(
                      height: 9,
                      thickness: 1,
                      indent: 14,
                      endIndent: 14,
                      color: widget.scheme.outlineVariant
                          .withValues(alpha: widget.isDark ? 0.30 : 0.5),
                    )
                  else
                    _ActionTile(
                        icon: a.icon,
                        label: a.label,
                        color: a.color,
                        onTap: a.onTap),
                const SizedBox(height: 6),
              ],
            ),
          ),
        ),
      ),
    );
    if (widget.maxHeight == null) return card;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight!),
      child: card,
    );
  }
}

/// On wide/desktop layouts, shows a small chevron on a message bubble while the
/// pointer hovers it — tapping it opens the action dropdown anchored there.
/// Long-press / right-click still work via the bubble's own gestures.
/// A video page inside the fullscreen media gallery: cache-first init, tap the
/// center button to play, tap the video to pause. Lives only while its page is
/// built, so swiping away disposes the controller.
// The attach menu's background as ONE seamless bubble: a rounded card with a
// downward tail merged into its bottom edge (like a chat bubble's beak), so the
// tail never reads as a separate, broken triangle. Drawn by a Material so it
// carries the card colour, elevation shadow, and clips its content.
class _MenuBubbleBorder extends ShapeBorder {
  const _MenuBubbleBorder({
    required this.radius,
    required this.tailWidth,
    required this.tailHeight,
    required this.tailFromRight,
  });
  final double radius;
  final double tailWidth;
  final double tailHeight;
  final double tailFromRight; // tail centre, measured in from the right edge.

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.only(bottom: tailHeight);

  Path _shape(Rect rect) {
    final body = Rect.fromLTWH(
        rect.left, rect.top, rect.width, rect.height - tailHeight);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(body, Radius.circular(radius)));
    // Keep the tail on the straight part of the bottom edge so it merges
    // cleanly with the card instead of fighting a rounded corner.
    final minX = body.left + radius + tailWidth / 2;
    final maxX = body.right - radius - tailWidth / 2;
    var cx = body.right - tailFromRight;
    if (maxX >= minX) {
      cx = cx.clamp(minX, maxX);
    } else {
      cx = (body.left + body.right) / 2;
    }
    // Overlap the body edge slightly so there is no hairline seam.
    path.moveTo(cx - tailWidth / 2, body.bottom - 1);
    path.lineTo(cx + tailWidth / 2, body.bottom - 1);
    path.lineTo(cx, body.bottom + tailHeight);
    path.close();
    return path;
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => _shape(rect);
  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => _shape(rect);
  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}
  @override
  ShapeBorder scale(double t) => _MenuBubbleBorder(
        radius: radius * t,
        tailWidth: tailWidth * t,
        tailHeight: tailHeight * t,
        tailFromRight: tailFromRight * t,
      );
}

// Bumped when the immersive theater player opens, so any inline gallery video
// playing behind it pauses — only one video is ever heard at a time.
final ValueNotifier<int> _galleryVideoPauseAll = ValueNotifier<int>(0);

class _GalleryVideo extends StatefulWidget {
  const _GalleryVideo({super.key, required this.url});
  final String url;
  @override
  State<_GalleryVideo> createState() => _GalleryVideoState();
}

class _GalleryVideoState extends State<_GalleryVideo> {
  VideoPlayerController? _c;
  bool _error = false;
  bool _duckedMusic = false; // we paused the song to play this clip's sound.

  @override
  void initState() {
    super.initState();
    _galleryVideoPauseAll.addListener(_onPauseSignal);
    _init();
  }

  // The theater player is opening in front of us — step aside so we're not
  // heard underneath it, and hand the song back.
  void _onPauseSignal() {
    _c?.pause();
    _resumeMusicIfDucked();
    if (mounted) setState(() {});
  }

  Future<void> _init() async {
    try {
      VideoPlayerController c;
      if (!kIsWeb) {
        File? f = await MediaStore.instance.cached(widget.url);
        f ??= await MediaStore.instance
            .getFile(widget.url, mediaAuthHeaders(widget.url));
        c = f != null
            ? VideoPlayerController.file(f,
                videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true))
            : VideoPlayerController.networkUrl(Uri.parse(widget.url),
                httpHeaders: mediaAuthHeaders(widget.url),
                videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true));
      } else {
        c = VideoPlayerController.networkUrl(Uri.parse(widget.url),
            httpHeaders: mediaAuthHeaders(widget.url),
            videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true));
      }
      await c.initialize();
      if (!mounted) {
        c.dispose();
        return;
      }
      c.addListener(() {
        if (mounted) setState(() {});
      });
      c.setLooping(true);
      setState(() => _c = c);
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  void dispose() {
    _galleryVideoPauseAll.removeListener(_onPauseSignal);
    _resumeMusicIfDucked();
    _c?.dispose();
    super.dispose();
  }

  // Watching a clip with sound pauses the user's song and gives it back from
  // the same spot when the clip is paused or this page goes away.
  void _pauseMusicForVideo() {
    try {
      if (!_duckedMusic && (playbackBus.isPlaying?.call() ?? false)) {
        playbackBus.onPause?.call();
        _duckedMusic = true;
      }
    } catch (_) {}
  }

  void _resumeMusicIfDucked() {
    if (!_duckedMusic) return;
    _duckedMusic = false;
    try {
      playbackBus.onPlay?.call();
    } catch (_) {}
  }

  void _toggle() {
    final c = _c;
    if (c == null) return;
    if (c.value.isPlaying) {
      c.pause();
      _resumeMusicIfDucked();
    } else {
      _pauseMusicForVideo();
      c.play();
    }
  }

  String _fmtDur(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  // A slim play/scrub bar at the bottom of the clip — ticking time + a
  // draggable seek slider — the same transport the fullscreen player has.
  Widget _galleryControls(VideoPlayerController c) {
    final dur = c.value.duration;
    final pos = c.value.position;
    final totalMs =
        dur.inMilliseconds <= 0 ? 1.0 : dur.inMilliseconds.toDouble();
    final curMs = pos.inMilliseconds.toDouble().clamp(0.0, totalMs);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 22, 8, 6),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xCC000000), Color(0x00000000)],
        ),
      ),
      child: Row(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggle,
            child: Icon(
                c.value.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                color: Colors.white,
                size: 24),
          ),
          const SizedBox(width: 6),
          Text(_fmtDur(pos),
              style: const TextStyle(color: Colors.white, fontSize: 11)),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2.5,
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white30,
                thumbColor: Colors.white,
                overlayColor: Colors.white24,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                min: 0,
                max: totalMs,
                value: curMs,
                onChanged: (v) {
                  c.seekTo(Duration(milliseconds: v.round()));
                  setState(() {});
                },
              ),
            ),
          ),
          Text(_fmtDur(dur),
              style: const TextStyle(color: Colors.white, fontSize: 11)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (_error) {
      return const Center(
        child: Icon(Icons.broken_image_rounded,
            color: Colors.white54, size: 48),
      );
    }
    if (c == null || !c.value.isInitialized) {
      return const Center(
        child: SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: Colors.white),
        ),
      );
    }
    return Center(
      child: AspectRatio(
        aspectRatio:
            c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
        child: Stack(
          alignment: Alignment.center,
          children: [
            VideoPlayer(c),
            // Full-area tap pauses while playing (lets the center button and
            // the gallery's chrome-toggle work when paused).
            if (c.value.isPlaying)
              Positioned.fill(
                child: GestureDetector(
                    onTap: _toggle, behavior: HitTestBehavior.opaque),
              ),
            AnimatedOpacity(
              opacity: c.value.isPlaying ? 0.0 : 1.0,
              duration: const Duration(milliseconds: 200),
              child: GestureDetector(
                onTap: _toggle,
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.45)),
                  child: const Icon(Icons.play_arrow_rounded,
                      color: Colors.white, size: 40),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _galleryControls(c),
            ),
          ],
        ),
      ),
    );
  }
}

class _HoverChevron extends StatefulWidget {
  const _HoverChevron({
    required this.enabled,
    required this.isMe,
    required this.onOpen,
    required this.child,
  });
  final bool enabled;
  final bool isMe;
  final void Function(Offset globalAnchor) onOpen;
  final Widget child;

  @override
  State<_HoverChevron> createState() => _HoverChevronState();
}

class _HoverChevronState extends State<_HoverChevron> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          _HoverScope(hovering: _hover, child: widget.child),
          if (_hover)
            Positioned(
              // Sit ON the bubble's rounded top corner (overlapping inward),
              // not floating above it — so it hugs the corner and never looks
              // like it overflows its own bubble or hits the tail above.
              top: 0,
              left: widget.isMe ? null : 42,
              right: widget.isMe ? 8 : null,
              child: GestureDetector(
                onTapDown: (d) => widget.onOpen(d.globalPosition),
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    // Its OWN solid chip (theme surface + outline + shadow), so
                    // it's immune to the bubble colour — a bright/neon bubble
                    // can't swallow it, and it reads in both light and dark.
                    color: scheme.surface,
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: scheme.outlineVariant.withValues(alpha: 0.55)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.28),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Icon(Icons.expand_more_rounded,
                      size: 18, color: scheme.primary),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Publishes a bubble's hover state (from [_HoverChevron]) to descendants, so
/// the in-row Keepsake side button can reveal on hover without the bubble
/// jumping. Absent on touch builds — hover simply stays false there.
class _HoverScope extends InheritedWidget {
  const _HoverScope({required this.hovering, required super.child});
  final bool hovering;

  static bool of(BuildContext context) {
    final s = context.dependOnInheritedWidgetOfExactType<_HoverScope>();
    return s?.hovering ?? false;
  }

  @override
  bool updateShouldNotify(_HoverScope old) => old.hovering != hovering;
}

/// A full-screen in-app video player for chat videos — plays inline (tap to
/// play/pause), with a close button and a PINNED Keepsake star while watching.
class _ChatVideoPlayer extends StatefulWidget {
  const _ChatVideoPlayer({required this.url, this.onKeep});
  final String url;
  final VoidCallback? onKeep;

  @override
  State<_ChatVideoPlayer> createState() => _ChatVideoPlayerState();
}

class _ChatVideoPlayerState extends State<_ChatVideoPlayer>
    with SingleTickerProviderStateMixin {
  VideoPlayerController? _c;
  bool _error = false;
  double _dragDy = 0; // live drag-to-dismiss offset
  AnimationController? _settleCtrl;

  @override
  void initState() {
    super.initState();
    _settleCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 200));
    _init();
  }

  // Release of a downward drag: pop to close past the threshold, else spring
  // the view back into place.
  void _settleDrag(bool close) {
    if (close) {
      Navigator.pop(context);
      return;
    }
    final ctrl = _settleCtrl;
    final start = _dragDy;
    if (ctrl == null || start == 0) {
      setState(() => _dragDy = 0);
      return;
    }
    ctrl.reset();
    final anim = Tween<double>(begin: start, end: 0.0)
        .animate(CurvedAnimation(parent: ctrl, curve: Curves.easeOut));
    void tick() {
      if (mounted) setState(() => _dragDy = anim.value);
    }
    anim.addListener(tick);
    ctrl.forward().whenComplete(() {
      anim.removeListener(tick);
      if (mounted) setState(() => _dragDy = 0);
    });
  }

  Future<void> _init() async {
    try {
      VideoPlayerController c;
      if (!kIsWeb) {
        // Cache-first, exactly like the bubble: play from the device so the
        // fullscreen view doesn't depend on streaming (which fails on some
        // platforms with "can't play on this device"). Reuse the cached copy
        // the bubble already downloaded, or fetch it once if missing.
        File? f = await MediaStore.instance.cached(widget.url);
        f ??= await MediaStore.instance
            .getFile(widget.url, mediaAuthHeaders(widget.url));
        c = f != null
            ? VideoPlayerController.file(f,
                videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true))
            : VideoPlayerController.networkUrl(
                Uri.parse(widget.url),
                httpHeaders: mediaAuthHeaders(widget.url),
                videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
              );
      } else {
        c = VideoPlayerController.networkUrl(
          Uri.parse(widget.url),
          httpHeaders: mediaAuthHeaders(widget.url),
          videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
        );
      }
      await c.initialize();
      if (!mounted) {
        c.dispose();
        return;
      }
      setState(() => _c = c);
      c.addListener(_onTick);
      c.setLooping(true);
      c.play();
      _pauseMusicForVideo();
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  // The immersive player owns the sound while it's open: pause the user's song
  // on entry and give it back (from the same spot) when the player closes.
  bool _duckedMusic = false;
  void _pauseMusicForVideo() {
    try {
      if (!_duckedMusic && (playbackBus.isPlaying?.call() ?? false)) {
        playbackBus.onPause?.call();
        _duckedMusic = true;
      }
    } catch (_) {}
  }

  void _resumeMusicIfDucked() {
    if (!_duckedMusic) return;
    _duckedMusic = false;
    try {
      playbackBus.onPlay?.call();
    } catch (_) {}
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  String _fmtDur(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  // Fullscreen playback controls: play/pause, ticking time, draggable seek bar.
  Widget _fsControls(VideoPlayerController c) {
    final dur = c.value.duration;
    final pos = c.value.position;
    final totalMs =
        dur.inMilliseconds <= 0 ? 1.0 : dur.inMilliseconds.toDouble();
    final curMs = pos.inMilliseconds.toDouble().clamp(0.0, totalMs);
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      padding: EdgeInsets.fromLTRB(
          12, 34, 12, 20 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xE6000000), Color(0x00000000)],
        ),
      ),
      child: Row(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (c.value.isPlaying) {
                c.pause();
              } else {
                final pp = c.value.position;
                final dd = c.value.duration;
                if (dd > Duration.zero &&
                    pp >= dd - const Duration(milliseconds: 250)) {
                  c.seekTo(Duration.zero);
                }
                c.play();
              }
              setState(() {});
            },
            child: Icon(
                c.value.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                color: Colors.white,
                size: 30),
          ),
          const SizedBox(width: 8),
          Text(_fmtDur(pos),
              style: const TextStyle(color: Colors.white, fontSize: 12)),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: accent,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                overlayColor: accent.withValues(alpha: 0.2),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                min: 0,
                max: totalMs,
                value: curMs,
                onChanged: (v) {
                  c.seekTo(Duration(milliseconds: v.round()));
                  setState(() {});
                },
              ),
            ),
          ),
          Text(_fmtDur(dur),
              style: const TextStyle(color: Colors.white, fontSize: 12)),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _settleCtrl?.dispose();
    _resumeMusicIfDucked();
    _c?.removeListener(_onTick);
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final accent = Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final stageColor = isDark ? Colors.black : Colors.white;
    final onStage = isDark ? Colors.white70 : Colors.black54;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (c == null || !c.value.isInitialized) return;
        if (c.value.isPlaying) {
          c.pause();
        } else {
          c.play();
        }
        setState(() {});
      },
      // Swipe down — or click-hold and drag down on desktop — to dismiss.
      onVerticalDragUpdate: (d) {
        setState(() => _dragDy = (_dragDy + d.delta.dy).clamp(-60.0, 600.0));
      },
      onVerticalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        _settleDrag(_dragDy > 120 || v > 700);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          Transform.translate(
            offset: Offset(0, _dragDy),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(color: stageColor),
          if (_error)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text("This video can't play on this device.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: onStage)),
              ),
            )
          else if (c == null || !c.value.isInitialized)
            Center(
                child: CircularProgressIndicator(
                    color: isDark ? Colors.white : accent))
          else
            Center(
              child: AspectRatio(
                aspectRatio:
                    c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
                child: VideoPlayer(c),
              ),
            ),
          if (c != null &&
              c.value.isInitialized &&
              !c.value.isPlaying &&
              !_error)
            Center(
              child: Icon(Icons.play_arrow_rounded,
                  color: onStage, size: 64),
            ),
          if (c != null && c.value.isInitialized && !_error)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _fsControls(c),
            ),
          Positioned(
            top: 40,
            right: 16,
            child: Material(
              color: Colors.black.withValues(alpha: 0.42),
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ),
          if (widget.onKeep != null && !(c?.value.isPlaying ?? false))
            Positioned(
              right: 14,
              bottom: 96,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: widget.onKeep,
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 9),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.auto_awesome_rounded,
                            size: 16, color: Colors.white),
                        SizedBox(width: 6),
                        Text('Keep',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 13)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
          ),
        ],
      ),
    );
  }
}

/// A small circular "keep to Our Space" button that floats on a bubble's inner
/// side — revealed on hover on desktop, persistent (a touch subtler) on mobile,
/// WhatsApp-forward style. Only inserted when the user has a bond; it reserves
/// its slot so the bubble never shifts when it fades in.
class _KeepSideButton extends StatelessWidget {
  const _KeepSideButton(
      {required this.isPhone, required this.starsOn, required this.onKeep});
  final bool isPhone;
  final ValueNotifier<bool> starsOn;
  final VoidCallback onKeep;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final btn = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onKeep,
      child: Tooltip(
        message: 'Keep in Our Space',
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            // A near-transparent circle with a whisper-thin themed ring and a
            // faint brand sparkle — subtle enough to never fight the bubble
            // text, but easy to catch for a one-tap Keepsake.
            color: scheme.primary.withValues(alpha: isPhone ? 0.12 : 0.14),
            shape: BoxShape.circle,
            border: Border.all(
                color: scheme.primary.withValues(alpha: 0.42), width: 1),
          ),
          child: Icon(Icons.auto_awesome_rounded,
              size: 15,
              color: scheme.primary.withValues(alpha: 0.95)),
        ),
      ),
    );
    return ValueListenableBuilder<bool>(
      valueListenable: starsOn,
      builder: (context, on, _) {
        // Visible when the ambient stars are "on" (a recent tap) or on desktop
        // hover — a gentle, transitional dissolve, never a snap.
        final visible = on || _HoverScope.of(context);
        return AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
          child: AnimatedScale(
            scale: visible ? 1 : 0.78,
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOutBack,
            child: IgnorePointer(ignoring: !visible, child: btn),
          ),
        );
      },
    );
  }
}
