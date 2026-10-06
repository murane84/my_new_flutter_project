import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, compute, kIsWeb;
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:image/image.dart' as img;
// Hide intl's TextDirection so the unprefixed name resolves to dart:ui's
// (needed by the ShapeBorder overrides below).
import 'package:intl/intl.dart' hide TextDirection;
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:video_player/video_player.dart';
import '../widgets/glimpse_video.dart';
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
import 'relationship_space_page.dart' show spaceEventBus;
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:float_column/float_column.dart';
import 'package:linkify/linkify.dart' show linkify;
import 'package:geolocator/geolocator.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import '../utils/app_config.dart';
import '../utils/loose_url_linkifier.dart';
import '../services/app_busy.dart';
import 'chat/attach_sheet.dart';
import 'chat/contact_picker_sheet.dart';
import 'stories/camera_capture.dart';

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

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  // True when this screen is showing a GROUP conversation (vs a 1:1 DM).
  bool get _isGroup => widget.isGroup && widget.conversationId != null;
  int get _cid => widget.conversationId ?? 0;

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
  String? _myAvatar;

  /// The name to show for this friend in live-session labels (banner / pill /
  /// now-playing), resolved the SAME way as the friend list: if their number is
  /// saved in the user's phone book, use that saved name; otherwise fall back to
  /// the display name we were opened with. Keeps the "streaming to …" label
  /// consistent with everything else the user sees for this contact.
  String get _livePeerLabel =>
      ContactNames.instance.nameFor(_friendPhone) ?? widget.friendName;
  bool _friendTyping = false;

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

  // edit-in-place: the message currently being edited, plus any reply-quote
  // prefix to preserve when saving.
  Map<String, dynamic>? _editing;
  String _editQuotePrefix = '';

  // Per-message keys + highlight id, used to scroll to a quoted original.
  final Map<String, GlobalKey> _msgKeys = {};
  String? _highlightedId;

  final _ctrl = TextEditingController();
  // Smart-list continuation state (bullets / numbers).
  String _lastComposerText = '';
  bool _applyingListEdit = false;
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
  Timer? _recordTimer;
  int _recordMs = 0;
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

  Map<String, dynamic>? _otherMember(Map<String, dynamic> s) {
    final members = (s['members'] as List?) ?? const [];
    for (final m in members) {
      if (m is Map && (m['id']).toString() != _myId) {
        return Map<String, dynamic>.from(m);
      }
    }
    return null;
  }

  String _spaceTitle(Map<String, dynamic> s) {
    final name = (s['name'] ?? '').toString().trim();
    if (name.isNotEmpty) return name;
    final who = (_otherMember(s)?['username'] ?? '').toString().trim();
    return who.isNotEmpty ? 'You & $who' : 'Our Space';
  }

  String _spacePartnerName(Map<String, dynamic> s) {
    final who = (_otherMember(s)?['username'] ?? '').toString().trim();
    return who.isNotEmpty ? who : 'your partner';
  }

  /// Choose which bonded space to keep into. Auto when there's just one; a small
  /// sheet (partner's space pre-marked) when there are several. Null = cancel.
  Future<Map<String, dynamic>?> _pickKeepSpace() async {
    if (_mySpaces.isEmpty) return null;
    if (_mySpaces.length == 1) return _mySpaces.first;
    final def = _defaultKeepSpaceId;
    final chosenId = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (bctx) {
        final scheme = Theme.of(bctx).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
                child: Text('Keep to\u2026',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface)),
              ),
              for (final s in _mySpaces)
                ListTile(
                  leading: CircleAvatar(
                    radius: 20,
                    backgroundColor: scheme.primaryContainer,
                    child: Icon(Icons.favorite_rounded,
                        size: 18, color: scheme.primary),
                  ),
                  title: Text(_spaceTitle(s)),
                  trailing: (s['id'] as num?)?.toInt() == def
                      ? Icon(Icons.star_rounded,
                          size: 18, color: scheme.primary)
                      : null,
                  onTap: () =>
                      Navigator.pop(bctx, (s['id'] as num?)?.toInt()),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (chosenId == null) return null;
    for (final s in _mySpaces) {
      if ((s['id'] as num?)?.toInt() == chosenId) return s;
    }
    return null;
  }

  // ── Harmony / Our Space actions from a chat bubble ──────────────────────────
  /// A chat 'file' message that is actually a video (by mime or extension).
  bool _isVideoMsg(Map<String, dynamic> msg) {
    final mime = (msg['media_mime'] as String?)?.toLowerCase() ?? '';
    if (mime.startsWith('video/')) return true;
    final name = (msg['media_name'] as String?)?.toLowerCase() ?? '';
    return name.endsWith('.mp4') ||
        name.endsWith('.mov') ||
        name.endsWith('.webm') ||
        name.endsWith('.mkv') ||
        name.endsWith('.m4v') ||
        name.endsWith('.avi');
  }

  /// Which bubbles get the subtle quick "keep to Our Space" star on their
  /// side: real captured media — a photo, a video, a voice note / audio, or a
  /// song. GIFs/stickers (image/gif), text, call/live logs and plain files
  /// stay clean (they keep the press-and-hold menu, where Keepsake lives).
  bool _isQuickKeepBubble(Map<String, dynamic> msg) {
    if ((msg['media_url'] as String? ?? '').isEmpty) return false;
    final type = (msg['message_type'] as String?) ?? 'text';
    final mime = (msg['media_mime'] as String?)?.toLowerCase() ?? '';
    final name = (msg['media_name'] as String?)?.toLowerCase() ?? '';
    final isGif = mime.contains('gif') || name.endsWith('.gif');
    switch (type) {
      case 'audio': // voice note / audio
        return true;
      case 'song':
        return true;
      case 'video':
        return true;
      case 'image':
        return !isGif; // real photos only — GIFs/stickers stay clean
      case 'file':
        return _isVideoMsg(msg);
      default:
        return false;
    }
  }

  // A friendly song title for a 'song' bubble (its spoken title lives in
  // `content`, falling back to the file name).
  String _songTitleOf(Map<String, dynamic> msg) {
    final text = _stripQuote((msg['content'] as String?) ?? '').trim();
    if (text.isNotEmpty) return text;
    final name = (msg['media_name'] as String?)?.trim();
    return (name != null && name.isNotEmpty) ? name : 'A song';
  }

  /// Capture a DURABLE, moment-owned server copy of a kept media file so the
  /// moment survives the chat's store-and-forward purge — and so the partner,
  /// who may never have been in the source chat, can fetch it through Our Space.
  /// Reads the device's local cache first (what it already holds), falls back to
  /// a server fetch while the bytes are still there, then re-uploads them as a
  /// NON-ephemeral asset. Returns the new ref, or [rel] unchanged on any failure
  /// so keeping never hard-fails.
  Future<String> _durableMediaRef(String rel, String mime) async {
    if (rel.isEmpty || rel.startsWith('http')) return rel;
    try {
      final url = fullMediaUrl(rel);
      List<int>? bytes;
      if (!kIsWeb) {
        try {
          final f =
              await MediaStore.instance.getFile(url, mediaAuthHeaders(url));
          if (f != null) bytes = await f.readAsBytes();
        } catch (_) {}
      }
      if (bytes == null || bytes.isEmpty) {
        final res =
            await http.get(Uri.parse(url), headers: mediaAuthHeaders(url));
        if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
          bytes = res.bodyBytes;
        }
      }
      if (bytes == null || bytes.isEmpty) return rel;
      final name = rel.split('/').last;
      final up = await ApiService().uploadMedia(
        bytes: bytes,
        filename: name.isEmpty ? 'keepsake' : name,
        mime: mime.isNotEmpty ? mime : 'application/octet-stream',
        ephemeral: false,
      );
      final newUrl = (up?['url'] as String?) ?? '';
      return newUrl.isNotEmpty ? newUrl : rel;
    } catch (_) {
      return rel;
    }
  }

  /// Keep [msg] into Our Space as a PinnedMoment, mapping the bubble type to a
  /// moment kind: text→note, photo→photo, voice→voice, song→song.
  Future<void> _keepsakeMessage(Map<String, dynamic> msg) async {
    final space = await _pickKeepSpace();
    if (space == null || !mounted) return;
    final sid = (space['id'] as num).toInt();
    final type = (msg['message_type'] as String?) ?? 'text';
    final rel = (msg['media_url'] as String?) ?? '';
    final mime = (msg['media_mime'] as String?)?.toLowerCase() ?? '';
    final text = _stripQuote((msg['content'] as String?) ?? '').trim();
    String kind;
    String? ref;
    String? caption;
    switch (type) {
      case 'image':
        // A kept GIF/sticker (image/gif) gets its own kind so Our Space labels
        // it "A GIF" (and still animates) instead of flattening to a photo.
        kind = ((mime).contains('gif') ||
                ((msg['media_name'] as String?) ?? '')
                    .toLowerCase()
                    .endsWith('.gif'))
            ? 'gif'
            : 'photo';
        ref = rel;
        break;
      case 'audio':
        kind = 'voice';
        ref = rel;
        break;
      case 'song':
        kind = 'song';
        ref = jsonEncode({'title': _songTitleOf(msg), 'ref': rel});
        break;
      case 'video':
        kind = 'video';
        ref = rel;
        break;
      case 'file':
        if (_isVideoMsg(msg) && rel.isNotEmpty) {
          kind = 'video';
          ref = rel;
        } else {
          final label = _replyQuoteText(msg).trim();
          if (label.isEmpty) {
            showToast(context, 'This can only be kept from Our Space',
                type: ToastType.info);
            return;
          }
          kind = 'note';
          caption = label;
        }
        break;
      case 'text':
        if (text.isEmpty) {
          showToast(context, 'Nothing to keep here', type: ToastType.info);
          return;
        }
        // A kept line IS its own words, so it keeps in one tap; the text lands
        // in `caption`, which is what the moment card renders.
        kind = 'note';
        caption = text;
        break;
      default:
        // call / live / location / contact / file — keep a friendly label.
        final label = _replyQuoteText(msg).trim();
        if (label.isEmpty) {
          showToast(context, 'This can only be kept from Our Space',
              type: ToastType.info);
          return;
        }
        kind = 'note';
        caption = label;
    }
    // For photo / voice / song, let the keeper add an optional one-line note —
    // warmth about the two of them ("so you"), never where it came from, so the
    // moment stays pointed at the couple rather than a third person. The
    // original chat caption is deliberately NOT carried across.
    if (kind == 'photo' ||
        kind == 'voice' ||
        kind == 'song' ||
        kind == 'video' ||
        kind == 'gif') {
      final note = await _keepsakeNoteSheet(msg, type, space);
      if (note == null || !mounted) return; // cancelled
      final t = note.trim();
      caption = t.isEmpty ? null : t;
      // Durable, moment-owned copy (see _durableMediaRef) so the photo / voice
      // / song never breaks after the chat media is purged. (A GIF is an
      // external CDN url, so _durableMediaRef returns it unchanged.)
      final durable = await _durableMediaRef(
          rel, mime.isNotEmpty ? mime : (type == 'image' ? 'image/jpeg' : ''));
      if (!mounted) return;
      ref = (kind == 'song')
          ? jsonEncode({'title': _songTitleOf(msg), 'ref': durable})
          : durable;
    }
    final res = await ApiService()
        .addMoment(sid, kind: kind, ref: ref, caption: caption);
    if (!mounted) return;
    if (res != null) spaceEventBus.value++;
    showToast(
        context,
        res != null ? 'Kept in Our Space 💛' : 'Could not keep that',
        type: res != null ? ToastType.success : ToastType.error);
  }

  /// A small sheet shown when keeping a photo / voice / song: a preview of what
  /// is being kept, an OPTIONAL note (with emoji + quick warmth chips), and a
  /// reminder of which space it lands in. Returns the note text (possibly empty)
  /// on Keep, or null if cancelled. Warmth for the two of them — it never
  /// records where the content came from.
  Future<String?> _keepsakeNoteSheet(
      Map<String, dynamic> msg, String type, Map<String, dynamic> space) {
    final ctrl = TextEditingController();
    final rel = (msg['media_url'] as String?) ?? '';
    final dest = _spaceTitle(space);
    const chips = <String>[
      'so you 🥰',
      'this made me smile',
      'us 🥹',
      'never forget this',
      'my favourite',
    ];
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (bctx) {
        final scheme = Theme.of(bctx).colorScheme;
        bool showEmoji = false;
        Widget preview;
        if (type == 'image' && rel.isNotEmpty) {
          final url = fullMediaUrl(rel);
          preview = ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: authNetworkImage(
                url: url,
                headers: mediaAuthHeaders(url),
                fit: BoxFit.cover,
                width: double.infinity,
                cacheWidth: 900,
              ),
            ),
          );
        } else {
          final isVid = _isVideoMsg(msg);
          final icon = isVid
              ? Icons.movie_rounded
              : (type == 'song'
                  ? Icons.music_note_rounded
                  : (type == 'audio'
                      ? Icons.mic_rounded
                      : Icons.sticky_note_2_rounded));
          final label = isVid
              ? ((msg['media_name'] as String?)?.trim().isNotEmpty == true
                  ? (msg['media_name'] as String).trim()
                  : 'Video')
              : (type == 'song'
                  ? _songTitleOf(msg)
                  : (type == 'audio' ? 'Voice message' : 'Moment'));
          preview = Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                  scheme.primary.withValues(alpha: 0.08), scheme.surface),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                Icon(icon, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          );
        }
        return StatefulBuilder(
          builder: (bctx, setSheet) {
            return Padding(
              padding: EdgeInsets.only(
                  left: 20,
                  right: 20,
                  top: 2,
                  bottom: MediaQuery.of(bctx).viewInsets.bottom + 16),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.auto_awesome_rounded,
                            size: 20, color: scheme.primary),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text('Keep in Our Space',
                              style: TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.lock_rounded,
                            size: 13, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                              'Private to $dest — only you two see it',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    preview,
                    const SizedBox(height: 14),
                    TextField(
                      controller: ctrl,
                      autofocus: true,
                      minLines: 1,
                      maxLines: 3,
                      textCapitalization: TextCapitalization.sentences,
                      onTap: () {
                        if (showEmoji) setSheet(() => showEmoji = false);
                      },
                      decoration: InputDecoration(
                        hintText: 'Add a note for you two… (optional)',
                        filled: true,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14)),
                        suffixIcon: IconButton(
                          tooltip: showEmoji ? 'Keyboard' : 'Emoji',
                          icon: Icon(
                              showEmoji
                                  ? Icons.keyboard_rounded
                                  : Icons.emoji_emotions_outlined,
                              color: scheme.primary),
                          onPressed: () {
                            if (!showEmoji) {
                              FocusManager.instance.primaryFocus?.unfocus();
                            }
                            setSheet(() => showEmoji = !showEmoji);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final c in chips)
                          ActionChip(
                            label: Text(c,
                                style: const TextStyle(fontSize: 12.5)),
                            visualDensity: VisualDensity.compact,
                            onPressed: () => _appendNote(ctrl, c),
                          ),
                      ],
                    ),
                    if (showEmoji) ...[
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 250,
                        child: _emojiPickerFor(scheme, ctrl, height: 250),
                      ),
                    ],
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                            onPressed: () => Navigator.pop(bctx, null),
                            child: const Text('Cancel')),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          onPressed: () => Navigator.pop(bctx, ctrl.text),
                          icon: const Icon(Icons.auto_awesome_rounded,
                              size: 18),
                          label: const Text('Keep'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Append a quick note suggestion / emoji to the keepsake note field.
  void _appendNote(TextEditingController c, String text) {
    final base = c.text.trimRight();
    c.text = base.isEmpty ? text : '$base $text';
    c.selection = TextSelection.collapsed(offset: c.text.length);
  }

  /// Pin a shared song into the couple's Our Playlist (Soundtrack of Us).
  Future<void> _addSongToPlaylist(Map<String, dynamic> msg) async {
    final space = await _pickKeepSpace();
    if (space == null || !mounted) return;
    final sid = (space['id'] as num).toInt();
    final rel = (msg['media_url'] as String?) ?? '';
    final durable =
        await _durableMediaRef(rel, (msg['media_mime'] as String?) ?? '');
    if (!mounted) return;
    final res = await ApiService().addTrack(sid,
        title: _songTitleOf(msg), ref: durable, source: 'share');
    if (!mounted) return;
    if (res != null) spaceEventBus.value++;
    showToast(
        context,
        res != null ? 'Added to Our Playlist 🎵' : 'Could not add that',
        type: res != null ? ToastType.success : ToastType.error);
  }

  /// Dedicate a shared song to the partner — a one-line note turns it into a
  /// feeling. Reuses the dedication flow already in Our Space.
  Future<void> _dedicateSong(Map<String, dynamic> msg) async {
    final space = await _pickKeepSpace();
    if (space == null || !mounted) return;
    final sid = (space['id'] as num).toInt();
    final rel = (msg['media_url'] as String?) ?? '';
    final title = _songTitleOf(msg);
    final note = await _promptDedicationNote(title);
    if (note == null) return; // cancelled
    final trimmed = note.trim();
    final durable =
        await _durableMediaRef(rel, (msg['media_mime'] as String?) ?? '');
    if (!mounted) return;
    final res = await ApiService().createDedication(sid,
        title: title, ref: durable, note: trimmed.isEmpty ? null : trimmed);
    if (!mounted) return;
    if (res != null) spaceEventBus.value++;
    showToast(
        context,
        res != null
            ? 'Dedicated to ${_spacePartnerName(space)} 💫'
            : 'Could not dedicate',
        type: res != null ? ToastType.success : ToastType.error);
  }

  /// A small sheet to add an optional note when dedicating a song from a bubble.
  /// Returns the note text (possibly empty) on confirm, or null if cancelled.
  Future<String?> _promptDedicationNote(String title) {
    final ctrl = TextEditingController();
    return showDialog<String?>(
      context: context,
      builder: (dctx) {
        final scheme = Theme.of(dctx).colorScheme;
        return AlertDialog(
          title: const Text('Dedicate this song'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.music_note_rounded,
                      size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                controller: ctrl,
                autofocus: true,
                minLines: 1,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Say why… (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dctx, null),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(dctx, ctrl.text),
                child: const Text('Dedicate')),
          ],
        );
      },
    );
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
    _loadMySpaces();

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
    if (kIsWeb) webpaste.unregisterClipboardPaste();
    // Release any in-flight caption request so its awaiter unwinds.
    if (_captionCompleter != null && !_captionCompleter!.isCompleted) {
      _captionCompleter!.complete(null);
    }
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
    _viewerPageCtrl?.dispose();
    _starTimer?.cancel();
    _quickStarsOn.dispose();
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
      _initChat(); // _initChat runs _maybeInitialJump after the load
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
    await _loadCachedMessages(); // show cached messages instantly (clears loader)
    if (mounted && _isLoading) setState(() => _isLoading = false);

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

  // ── Chat wallpaper (photo reused from Our Space, or the motif pattern) ────
  String? _chatBgUrl;
  Future<File?>? _chatBgFuture;
  Future<File?> _chatBgFileFuture(String url, Map<String, String> headers) {
    if (_chatBgUrl != url || _chatBgFuture == null) {
      _chatBgUrl = url;
      _chatBgFuture = MediaStore.instance.getFile(url, headers);
    }
    return _chatBgFuture!;
  }

  Widget _chatPhotoWallpaper(ChatBg bg, bool isDark) {
    final veil = isDark ? Colors.black : Colors.white;
    return LayoutBuilder(
      builder: (ctx, c) {
        // Wide screens (tablet/desktop): prefer a landscape variant when the
        // wallpaper has one; otherwise tile the portrait by height so it fills
        // the width without an empty band (same as Our Space).
        final wide = c.maxWidth >= 600;
        final useWide = wide && (bg.wideUrl ?? '').isNotEmpty;
        final url = useWide ? bg.wideUrl! : (bg.url ?? '');
        final headers = mediaAuthHeaders(url);
        return FutureBuilder<File?>(
          future: _chatBgFileFuture(url, headers),
          builder: (ctx, snap) {
            final ImageProvider prov = snap.data != null
                ? FileImage(snap.data!)
                : authNetworkImageProvider(url, headers);
            final DecorationImage deco = (wide && !useWide)
                ? DecorationImage(
                    image: prov,
                    fit: BoxFit.fitHeight,
                    repeat: ImageRepeat.repeatX,
                    onError: (Object e, StackTrace? st) {},
                  )
                : DecorationImage(
                    image: prov,
                    fit: BoxFit.cover,
                    onError: (Object e, StackTrace? st) {},
                  );
            return Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(decoration: BoxDecoration(image: deco)),
                ValueListenableBuilder<double>(
                  valueListenable: wallpaperClarity,
                  builder: (_, _, _) => DecoratedBox(
                    decoration: BoxDecoration(
                      color: veil.withValues(
                          alpha: wallpaperVeilAlpha(isDark ? 0.55 : 0.62)),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _chatMotifWallpaper(ColorScheme scheme, bool isDark) {
    final motifColor = isDark ? Colors.white : scheme.primary;
    // Concentration follows the user's motif-strength setting, live.
    return ValueListenableBuilder<double>(
      valueListenable: motifStrength,
      builder: (_, _, _) => DecoratedBox(
        decoration: BoxDecoration(color: scheme.surface),
        child: CustomPaint(
          painter: RomanticPatternPainter(
            color: motifColor
                .withValues(alpha: motifAccentAlpha(isDark ? 0.06 : 0.055)),
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  // ── Chat wallpaper chooser ───────────────────────────────────────────────
  Future<void> _openChatWallpaperSheet() => showChatWallpaperSheet(
        context,
        convKey: _convKey,
        title: _isGroup ? widget.groupTitle : widget.friendName,
        apiBase: _apiBase,
      );


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
      // Keep the FULL conversation on-device (append-only): merge the current
      // window into whatever is already cached so the local copy never shrinks
      // to a small window. With server-side purge of delivered messages, THIS
      // is the durable copy — it must hold the history, not just the latest
      // few. Bounded to the most recent 3000 per chat to cap storage.
      List<Map<String, dynamic>> stored = const [];
      final raw = prefs.getString(_cacheKey);
      if (raw != null) {
        try {
          stored = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
        } catch (_) {}
      }
      // Pending (optimistic) messages are transient and carry non-JSON local
      // bytes — never persist them.
      final live = _messages.where((m) => m['__pending'] != true).toList();
      final full = _merge(stored, live);
      final toCache = full.length > 3000 ? full.take(3000).toList() : full;
      await prefs.setString(_cacheKey, jsonEncode(toCache));
      // We now durably hold this history locally → let the server purge its
      // copy of what BOTH devices have cached (store-and-forward). Throttled.
      _ackCachedToServer(toCache);
    } catch (_) {}
  }

  int _lastCachedAck = 0;

  int _msgId(Map<String, dynamic> m) {
    final v = m['id'];
    return v is int ? v : int.tryParse('$v') ?? 0;
  }

  /// Tell the server how far we've DURABLY cached — which lets it purge those
  /// messages' media. Crucially, we do NOT ack past a photo whose bytes we
  /// don't yet hold on this device: we first try to persist each image locally
  /// (while the server still has it), and STOP the pointer at any recent image
  /// we couldn't save, so the server keeps holding it until we actually have
  /// it. A single old/unavailable item can't freeze the pointer (7-day grace).
  Future<void> _ackCachedToServer(List<Map<String, dynamic>> cached) async {
    final now = DateTime.now();
    final sorted = [...cached]..sort((a, b) => _msgId(a).compareTo(_msgId(b)));
    int safe = 0;
    for (final m in sorted) {
      final id = _msgId(m);
      if (id <= 0) continue;
      if (!kIsWeb && (m['message_type'] as String?) == 'image') {
        final rel = (m['media_url'] as String?) ?? '';
        if (rel.isNotEmpty) {
          final url = fullMediaUrl(rel);
          File? f;
          try {
            f = await MediaStore.instance.cached(url);
            f ??= await MediaStore.instance.getFile(url, mediaAuthHeaders(url));
          } catch (_) {}
          if (f == null) {
            // No local copy yet. If the photo is recent the server still holds
            // it → stop here so it isn't purged before we've saved it. If it's
            // old it's likely already handled/purged → let the pointer move on.
            final ts = DateTime.tryParse((m['timestamp'] as String?) ?? '');
            final recent = ts != null && now.difference(ts).inDays < 7;
            if (recent) break;
          }
        }
      }
      safe = id;
    }
    if (safe <= _lastCachedAck) return;
    _lastCachedAck = safe;
    if (_isGroup) {
      ApiService().ackChatCached(conversationId: _cid, upTo: safe);
    } else {
      ApiService().ackChatCached(friendId: widget.friendId, upTo: safe);
    }
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
        // Status always follows the server.
        ex['delivered'] = m['delivered'];
        ex['is_read'] = m['is_read'];
        ex['edited'] = m['edited'];
        ex['is_deleted'] = m['is_deleted'];
        ex['reactions'] = m['reactions'];
        ex['pinned_until'] = m['pinned_until'];
        // Store-and-forward: once the server has PURGED its copy after delivery
        // it sends an emptied tombstone (purged:true) — keep OUR local content
        // and media, which are now the durable copy. Otherwise take the
        // server's content/media as before (covers real edits + media).
        if (m['purged'] == true) {
          ex['purged'] = true;
        } else {
          ex['content'] = m['content'];
          ex['message_type'] = m['message_type'];
          ex['media_url'] = m['media_url'];
          ex['media_name'] = m['media_name'];
          ex['media_mime'] = m['media_mime'];
          ex['media_size'] = m['media_size'];
          ex['media_duration'] = m['media_duration'];
        }
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
        peerName: _livePeerLabel,
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
                                'Pick a song to stream to $_livePeerLabel',
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
        peerName: _livePeerLabel,
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
    setState(() => _isAtBottom = atBottom);
    if (atBottom && _hasNewMsg) setState(() => _hasNewMsg = false);
  }

  /// A genuine tap on the thread reveals the quick stars for a few seconds,
  /// then they fade away on their own (idle).
  void _pokeStars() {
    _quickStarsOn.value = true;
    _starTimer?.cancel();
    _starTimer = Timer(const Duration(milliseconds: 2600), () {
      _quickStarsOn.value = false;
    });
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
    if (!_applyingListEdit) _maybeContinueList();
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
    _lastComposerText = _ctrl.text;
  }

  // Word-doc-style lists: pressing Enter after a "- ", "* ", "• " or
  // a numbered line continues the list with the next marker; pressing Enter
  // on an empty item ends the list. Triggered on the newline insertion (mobile
  // Enter, or desktop Shift+Enter — plain desktop Enter sends).
  void _maybeContinueList() {
    final text = _ctrl.text;
    final old = _lastComposerText;
    if (text.length != old.length + 1) return; // only a single-char insert
    final sel = _ctrl.selection;
    if (!sel.isValid || !sel.isCollapsed) return;
    final caret = sel.baseOffset;
    if (caret <= 0 || caret > text.length || text[caret - 1] != '\n') return;
    final before = text.substring(0, caret - 1);
    final lineStart = before.lastIndexOf('\n') + 1;
    final line = before.substring(lineStart);

    final bullet = RegExp(r'^(\s*)([-*•])\s+(.*)$').firstMatch(line);
    final number = RegExp(r'^(\s*)(\d+)([.)])\s+(.*)$').firstMatch(line);

    String nextMarker;
    bool emptyItem;
    if (bullet != null) {
      emptyItem = bullet.group(3)!.trim().isEmpty;
      nextMarker = '${bullet.group(1)}${bullet.group(2)} ';
    } else if (number != null) {
      emptyItem = number.group(4)!.trim().isEmpty;
      final n = int.tryParse(number.group(2)!) ?? 0;
      nextMarker = '${number.group(1)}${n + 1}${number.group(3)} ';
    } else {
      return;
    }

    if (emptyItem) {
      // End the list: drop the empty marker line and the newline.
      final newText = text.substring(0, lineStart) + text.substring(caret);
      _applyComposerEdit(newText, lineStart);
    } else {
      final newText =
          text.substring(0, caret) + nextMarker + text.substring(caret);
      _applyComposerEdit(newText, caret + nextMarker.length);
    }
  }

  void _applyComposerEdit(String newText, int caret) {
    _applyingListEdit = true;
    _ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: caret),
    );
    _applyingListEdit = false;
    _lastComposerText = newText;
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

    final tempId = _newTempId();
    _insertOptimistic(_optimisticMsg(tempId, 'text', content));

    Future<void> attempt() async {
      try {
        final sent = await appBusy.run(() => ApiService().sendMessage(
            widget.friendId, content,
            conversationId: widget.conversationId));
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

  void _showErrorSnack(String msg) =>
      showToast(context, msg, type: ToastType.error);

  // ── Optimistic send ───────────────────────────────────────────────────────
  // A message shows in the thread the instant it's sent, with a spinner in the
  // tick slot, while its upload/send runs in the background. This keeps the
  // composer free (the user can fire off more while one is still in flight) and
  // moves the "working" feedback onto the bubble itself.
  String _newTempId() => 'tmp-${DateTime.now().microsecondsSinceEpoch}';

  Map<String, dynamic> _optimisticMsg(String tempId, String type, String content) {
    return {
      'id': tempId,
      'sender_id': _myId ?? '',
      'content': content,
      'message_type': type,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'status': 'sending',
      'delivered': false,
      'is_read': false,
      '__pending': true,
    };
  }

  void _insertOptimistic(Map<String, dynamic> msg) {
    if (!mounted) return;
    setState(() => _messages.insert(0, msg));
    _scrollToBottom();
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
    if (sent != null) _saveMessagesCache();
  }

  // Re-run a failed send (tapped from the retry marker in the tick slot).
  void _retrySend(Map<String, dynamic> msg) {
    final tempId = msg['id']?.toString();
    if (tempId == null) return;
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

  // Shared presenter for the chat's floating popups (attach sheet, message
  // menu): a frosted-blur backdrop with a spring scale + slide-up, all wrapped
  // in a Material so text/ink render properly (no raw-overlay default style).
  Future<void> _showPopPanel({
    required WidgetBuilder builder,
    String label = 'Menu',
  }) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: label,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (ctx, a1, a2) {
        return Material(
          type: MaterialType.transparency,
          child: AnimatedBuilder(
            animation: a1,
            builder: (context, _) {
              final t = Curves.easeOutCubic.transform(a1.value.clamp(0.0, 1.0));
              final tb =
                  Curves.easeOutBack.transform(a1.value.clamp(0.0, 1.0));
              return Stack(
                children: [
                  Positioned.fill(
                    child: Opacity(
                      opacity: t,
                      child: BackdropFilter(
                        filter:
                            ui.ImageFilter.blur(sigmaX: 8 * t, sigmaY: 8 * t),
                        child: Container(
                          color: Colors.black
                              .withValues(alpha: (isDark ? 0.32 : 0.22) * t),
                        ),
                      ),
                    ),
                  ),
                  Opacity(
                    opacity: t,
                    child: Transform.translate(
                      offset: Offset(0, (1 - t) * 20),
                      child: Transform.scale(
                        scale: 0.92 + 0.08 * tb,
                        child: builder(ctx),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
      transitionBuilder: (ctx, anim, sec, child) => child,
    );
  }

  void _openAttachSheet() {
    // Run an action after closing the sheet (so the picker/preview isn't shown
    // behind it).
    void act(VoidCallback fn) {
      Navigator.of(context).pop();
      fn();
    }

    // Appears from the chat screen itself (a scale + fade pop), rather than
    // sliding up from the footer as a bottom sheet.
    _showPopPanel(
      label: 'Attach',
      builder: (ctx) {
        final media = MediaQuery.of(ctx);
        return Center(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                16, media.padding.top + 24, 16, media.padding.bottom + 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: AttachSheet(
                isMobile: _isMobile,
                onGallery: () => act(() => _pickGalleryImages()),
                onVideo: () => act(_pickVideo),
                onCamera: () => act(() => _pickImage(ImageSource.camera)),
                onLocation: () => act(_shareLocation),
                onContact: () => act(_shareContact),
                onDocument: () => act(_pickDocument),
                onListenTogether: () => act(_startListenTogether),
                onPickPhoto: (bytes, name) =>
                    act(() => _previewAndSendImage(bytes, name, 'image/jpeg')),
              ),
            ),
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
      final pos = await Geolocator.getCurrentPosition()
          .timeout(const Duration(seconds: 15));
      final payload = jsonEncode({
        'lat': pos.latitude,
        'lng': pos.longitude,
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

  /// When a chosen contact has several numbers, ask which one to share.
  Future<String?> _chooseNumber(String name, List<String> phones) {
    return showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text('$name — choose a number',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
            ),
            ...phones.map((p) => ListTile(
                  leading: const Icon(Icons.phone_rounded),
                  title: Text(p),
                  onTap: () => Navigator.pop(ctx, p),
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Send a structured (non-media) message — `location` / `contact` — whose
  /// JSON payload lives in `content`. Mirrors [_sendGif]'s optimistic insert.
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

  Future<void> _pickImage(ImageSource source) async {
    try {
      // Pick at high quality; the compress-on-upload step (or the HD toggle in
      // the preview) decides final size, so HD can send near-original quality.
      // Camera goes through the shared capturePhoto helper so web/desktop get a
      // real camera (not a file picker) and accurate, cause-specific messages
      // (https-needed, allow-permission, in-use, or truly no camera).
      final x = source == ImageSource.camera
          ? await capturePhoto(context, imageQuality: 92, maxWidth: 2560)
          : await ImagePicker()
              .pickImage(source: source, imageQuality: 92, maxWidth: 2560);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      await _previewAndSendImage(bytes, x.name, 'image/jpeg');
    } catch (_) {
      if (mounted) showToast(context, 'Could not pick image', type: ToastType.error);
    }
  }

  /// Pick a video from the gallery and send it. Large clips are compressed
  /// on-device (mobile only) so they fit the upload cap; desktop/web fall back
  /// to the original and a clear message if it's still too big.
  Future<void> _pickVideo() async {
    try {
      final x = await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (x == null) return;
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
        showToast(context, 'Could not pick video', type: ToastType.error);
      }
    } finally {
      try {
        await VideoCompress.deleteAllCache();
      } catch (_) {}
    }
  }

  /// Show a full-screen preview of the picked image with a caption box, so the
  /// user can add a message and send image + text as ONE bubble. Returns
  /// without sending if the user backs out of the preview.
  Future<bool> _previewAndSendImage(
      Uint8List bytes, String filename, String mime,
      {int index = 0, int total = 0}) async {
    if (!mounted) return false;
    final result = await Navigator.of(context).push<Map<String, dynamic>?>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _ImagePreviewScreen(
          imageBytes: bytes,
          friendName: widget.friendName,
          index: index,
          total: total,
        ),
      ),
    );
    // null → the user cancelled/backed out. Otherwise the map carries the
    // (possibly annotated) bytes, its mime, and the caption.
    if (result == null || !mounted) return false;
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
    return true;
  }

  // Gallery supports selecting several photos at once. A single pick keeps the
  // normal preview; multiple are previewed + sent one after another ("Photo i
  // of N"), and backing out of a preview stops the remaining ones.
  Future<void> _pickGalleryImages() async {
    try {
      final files = await ImagePicker()
          .pickMultiImage(imageQuality: 92, maxWidth: 2560);
      if (files.isEmpty) return;
      if (files.length == 1) {
        final x = files.first;
        final bytes = await x.readAsBytes();
        await _previewAndSendImage(bytes, x.name, 'image/jpeg');
        return;
      }
      for (var i = 0; i < files.length; i++) {
        if (!mounted) break;
        final x = files[i];
        final bytes = await x.readAsBytes();
        final sent = await _previewAndSendImage(
            bytes, x.name, 'image/jpeg',
            index: i + 1, total: files.length);
        if (!sent) break; // user backed out → stop sending the rest
      }
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not pick images', type: ToastType.error);
      }
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
      case 'apk':
        return 'application/vnd.android.package-archive';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'pptx':
        return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      case 'zip':
        return 'application/zip';
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
    bool ephemeral = false,
  }) async {
    // Show the bubble immediately with a spinner in the tick slot; the upload +
    // send run in the background so the composer never blocks. The original
    // (uncompressed) bytes/mime/name are captured for the attempt so a retry
    // starts clean.
    final tempId = _newTempId();
    final optimistic = _optimisticMsg(tempId, type, caption);
    optimistic['media_name'] = filename;
    optimistic['media_mime'] = mime;
    optimistic['media_size'] = bytes.length;
    optimistic['media_duration'] = durationMs;
    if (type == 'image') {
      // A local preview so the sent photo shows while it uploads.
      optimistic['__localBytes'] = Uint8List.fromList(bytes);
    }
    _insertOptimistic(optimistic);

    final origBytes = bytes;
    final origMime = mime;
    final origName = filename;

    Future<void> attempt() async {
      var sendBytes = origBytes;
      var sendMime = origMime;
      var sendName = origName;
      try {
        // Compress images before upload to keep server storage + bandwidth
        // down. Skipped when HD is on (send the original) — but still forced if
        // the original exceeds the 15 MB upload cap. GIFs and small images pass
        // through untouched.
        final tooBigForRaw = sendBytes.length > 15 * 1024 * 1024;
        if (type == 'image' &&
            sendMime != 'image/gif' &&
            (!hd || tooBigForRaw) &&
            sendBytes.length > 350 * 1024) {
          try {
            final compressed = await compute(
                _compressChatImage, Uint8List.fromList(sendBytes));
            if (compressed.isNotEmpty && compressed.length < sendBytes.length) {
              sendBytes = compressed;
              sendMime = 'image/jpeg';
              final dot = sendName.lastIndexOf('.');
              sendName =
                  '${dot > 0 ? sendName.substring(0, dot) : sendName}.jpg';
              if (hd && tooBigForRaw && mounted) {
                showToast(context, 'Original too large — sent compressed',
                    type: ToastType.info);
              }
            }
          } catch (_) {/* keep the original bytes on any failure */}
        }
        final up = await appBusy.run(() => ApiService().uploadMedia(
            bytes: sendBytes,
            filename: sendName,
            mime: sendMime,
            ephemeral: ephemeral));
        if (up == null || up['url'] == null) {
          _replaceOptimistic(tempId, null);
          if (mounted) {
            showToast(context, 'Upload failed — tap the ! to retry',
                type: ToastType.error);
          }
          return;
        }
        final sent = await appBusy.run(() => ApiService().sendMessage(
              widget.friendId,
              // Caption travels as the message content, so an image + text
              // render in ONE bubble (image, then this text below).
              caption,
              messageType: type,
              mediaUrl: up['url'] as String,
              mediaName: (up['name'] ?? sendName) as String?,
              mediaMime: (up['mime'] ?? sendMime) as String?,
              mediaSize: (up['size'] as num?)?.toInt(),
              mediaDuration: durationMs,
              conversationId: widget.conversationId,
            ));
        _replaceOptimistic(tempId, sent);
        if (sent == null && mounted) {
          showToast(context, 'Could not send — tap the ! to retry',
              type: ToastType.error);
        }
      } catch (_) {
        _replaceOptimistic(tempId, null);
        if (mounted) {
          showToast(context, 'Upload failed — tap the ! to retry',
              type: ToastType.error);
        }
      }
    }

    _outbox[tempId] = attempt;
    unawaited(attempt());
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
  // Renders an optimistic (still-uploading) media bubble: the local photo for
  // images, otherwise a compact "Uploading…" card with the right icon. The
  // spinner lives in the tick slot, so this just shows what's on its way.
  Widget _pendingMediaContent(
      String type, Map<String, dynamic> msg, Color textColor) {
    final local = msg['__localBytes'];
    if (type == 'image' && local is Uint8List) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
              maxWidth: 240, maxHeight: 300, minWidth: 120, minHeight: 80),
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              Image.memory(local, fit: BoxFit.cover),
              Positioned.fill(
                child: Container(color: Colors.black.withValues(alpha: 0.12)),
              ),
            ],
          ),
        ),
      );
    }
    IconData ic;
    String fallbackLabel;
    switch (type) {
      case 'video':
        ic = Icons.videocam_rounded;
        fallbackLabel = 'Video';
        break;
      case 'audio':
        ic = Icons.mic_rounded;
        fallbackLabel = 'Voice note';
        break;
      case 'song':
        ic = Icons.music_note_rounded;
        fallbackLabel = 'Song';
        break;
      default:
        ic = Icons.insert_drive_file_rounded;
        fallbackLabel = 'File';
    }
    final name = (msg['media_name'] as String?)?.trim();
    final label = (name == null || name.isEmpty) ? fallbackLabel : name;
    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: textColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ic, size: 22, color: textColor.withValues(alpha: 0.85)),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: textColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
                const SizedBox(height: 2),
                Text('Uploading\u2026',
                    style: TextStyle(
                        color: textColor.withValues(alpha: 0.7),
                        fontSize: 11)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _mediaContent(String type, String rel, Map<String, dynamic> msg,
      bool isMe, Color textColor, ColorScheme scheme, {String? caption}) {
    // Still uploading: show a local preview (images) or a compact placeholder.
    if (msg['__pending'] == true) {
      return _pendingMediaContent(type, msg, textColor);
    }
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
      case 'video':
        return _videoBubble(url, msg, scheme, caption: caption);
      default:
        return _fileBubble(url, msg, textColor, scheme);
    }
  }

  // One persisted-file future per image URL (memoised so rebuilds don't
  // re-download or flicker). Persisting the moment a bubble renders is what
  // lets images survive the server's store-and-forward purge.
  final Map<String, Future<File?>> _imgFileCache = {};
  Future<File?> _imgFile(String url) =>
      _imgFileCache.putIfAbsent(
          url, () => MediaStore.instance.getFile(url, mediaAuthHeaders(url)));

  Widget _imgLoader() => Container(
        width: 200,
        height: 150,
        color: Colors.black.withAlpha(20),
        child: const Center(
          child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );

  Widget _imgBroken() => Container(
        width: 180,
        height: 120,
        color: Colors.black.withAlpha(20),
        child: const Icon(Icons.broken_image_rounded),
      );

  // The decoded photo (cache-first: on-device copy, else network), shared by
  // the full image bubble and the side-by-side caption thumbnail. Decodes at
  // ~bubble size, not full resolution, so a thread of photos doesn't exhaust
  // memory (full res still loads in the tap-to-open viewer).
  Widget _imageData(String url) {
    final dpr = MediaQuery.of(context).devicePixelRatio.clamp(1.0, 3.0);
    final thumbW = (240 * dpr).round();
    final headers = mediaAuthHeaders(url);
    Widget net() => authNetworkImage(
          url: url,
          headers: headers,
          fit: BoxFit.cover,
          cacheWidth: thumbW,
          placeholder: (_) => _imgLoader(),
          error: (_) => _imgBroken(),
        );
    if (kIsWeb) return net();
    return FutureBuilder<File?>(
      future: _imgFile(url),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) return net();
        final f = snap.data;
        if (f != null) {
          return Image.file(f,
              fit: BoxFit.cover,
              cacheWidth: thumbW,
              errorBuilder: (_, _, _) => _imgBroken());
        }
        return net();
      },
    );
  }

  Widget _imageBubble(String url) {
    return GestureDetector(
      onTap: () => _openImageViewer(url),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
              maxWidth: 240, maxHeight: 300, minWidth: 120, minHeight: 80),
          child: _imageData(url),
        ),
      ),
    );
  }

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

  // Image + caption laid out as a card: the photo as a portrait thumbnail on
  // the left with the caption filling the space beside it, so a tall photo and
  // its text no longer leave a blank column. A compact look that is ours, not
  // the usual stacked photo-then-caption.
  // A linkified, wrappable text span for a caption (clickable URLs / emails),
  // shared by the image+caption layouts so text can flow around the photo.
  TextSpan _captionSpan(
      String caption, TextStyle style, TextStyle linkStyle) {
    final elements = linkify(
      caption,
      options: const LinkifyOptions(humanize: false),
      linkifiers: const [UrlLinkifier(), EmailLinkifier(), LooseUrlLinkifier()],
    );
    return buildTextSpan(
      elements,
      style: style,
      linkStyle: linkStyle,
      onOpen: (link) => _openLink(link.url),
    );
  }

  TextStyle _capStyle(Color c) =>
      (Theme.of(context).textTheme.bodyMedium ?? const TextStyle())
          .merge(TextStyle(color: c, fontSize: 15, height: 1.38));

  TextStyle _capLinkStyle(Color linkColor) => _capStyle(linkColor).copyWith(
        decoration: TextDecoration.underline,
        decorationColor: linkColor,
      );

  // Plain text bubble (no image), rendered through FloatColumn with the SAME
  // span + style + scaler as image captions — so every bubble, image or not,
  // shares one text engine and one font. Links stay tappable via _captionSpan.
  Widget _bubbleTextOnly(String text, Color textColor, Color linkColor) {
    final span = _captionSpan(
        text, _capStyle(textColor), _capLinkStyle(linkColor));
    return LayoutBuilder(
      builder: (ctx, c) {
        final scaler = MediaQuery.textScalerOf(ctx);
        final maxW = c.maxWidth.isFinite ? c.maxWidth : 280.0;
        // FloatColumn always fills its max width, so measure the text and size
        // the bubble to its content — short messages stay short, long ones wrap
        // at the bubble's max — while still rendering through FloatColumn for a
        // font identical to image captions.
        final tp = TextPainter(
          text: span,
          textDirection: TextDirection.ltr,
          textScaler: scaler,
        )..layout(maxWidth: maxW);
        final w = (tp.width + 0.5).clamp(0.0, maxW);
        return SizedBox(
          width: w,
          child: FloatColumn(
            children: [
              WrappableText(text: span, textScaler: scaler),
            ],
          ),
        );
      },
    );
  }

  // Image + caption. The layout adapts to the caption so the bubble never
  // shows a dead gap: a caption long enough to wrap down the side of the photo
  // FLOATS (photo left, words beside it, then full-width below); a short one
  // STACKS under the photo instead of sitting beside it with blank space. Both
  // render their text through the same FloatColumn/WrappableText path (the
  // stack via _bubbleTextOnly) so the caption font matches every other bubble.
  Widget _imageCaption(
      String url, String caption, Color textColor, Color linkColor) {
    return LayoutBuilder(
      builder: (ctx, c) {
        final scaler = MediaQuery.textScalerOf(ctx);
        final maxW = c.maxWidth.isFinite ? c.maxWidth : 280.0;
        final span = _captionSpan(
            caption, _capStyle(textColor), _capLinkStyle(linkColor));
        // Float geometry: photo on the left, caption in the column beside it.
        final imgW = (maxW * 0.42).clamp(118.0, 160.0).toDouble();
        final imgH = imgW / 0.78; // _imageThumb uses aspectRatio 0.78
        final besideW = maxW - imgW - 10;
        final tp = TextPainter(
          text: span,
          textDirection: TextDirection.ltr,
          textScaler: scaler,
        )..layout(maxWidth: besideW > 40 ? besideW : maxW);
        // If the caption (wrapped at the beside width) runs most of the way
        // down the photo, floating fills the side nicely. If it is shorter it
        // would leave a blank gap beside the photo, so stack it below instead.
        final useFloat = tp.height >= imgH * 0.85;
        if (useFloat) {
          return FloatColumn(
            children: [
              Floatable(
                float: FCFloat.start,
                padding:
                    const EdgeInsetsDirectional.only(end: 10, bottom: 6),
                child: _imageThumb(url, imgW, 0.78),
              ),
              WrappableText(text: span, textScaler: scaler),
            ],
          );
        }
        // Stacked: photo on top, caption below, bubble sized to the photo width.
        final iw = (maxW * 0.52).clamp(150.0, 220.0).toDouble();
        return SizedBox(
          width: iw,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _imageThumb(url, iw, 0.82),
              const SizedBox(height: 6),
              _bubbleTextOnly(caption, textColor, linkColor),
            ],
          ),
        );
      },
    );
  }

  // In-body photo viewer state (fills only the conversation card so the
  // header + composer stay live and the user can keep typing / replying).
  List<String>? _viewerImages;
  List<Map<String, dynamic>?> _viewerMsgs = const <Map<String, dynamic>?>[];
  List<ImageProvider> _viewerProviders = const <ImageProvider>[];
  int _viewerIndex = 0;
  bool _viewerChrome = true;
  PageController? _viewerPageCtrl;

  Future<void> _openImageViewer(String tappedUrl) async {
    // Gather EVERY image shared in this thread (chronological order) so the
    // viewer is a swipeable gallery, not a single photo. Opening any image lets
    // the user page left/right through all of them, pinch-zoom each, and save.
    final images = <String>[];
    final imgMsgs = <Map<String, dynamic>?>[];
    for (final m in _messages) {
      if ((m['message_type'] as String?) == 'image') {
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
    });
  }

  // Back (gesture / app-bar arrow) closes the open photo before leaving chat.
  Widget _wrapViewerBack(Widget child) => PopScope(
        canPop: _viewerImages == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _closeViewer();
        },
        child: child,
      );

  // Desktop/web: Ctrl/Cmd+V pastes a clipboard IMAGE (e.g. a screenshot) into
  // the composer's preview + caption flow. Text paste, undo (Ctrl+Z), redo and
  // the other standard field shortcuts are Flutter defaults and keep working —
  // this only adds image paste on top.
  Widget _pasteWrapper(Widget child) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.keyV &&
            (HardwareKeyboard.instance.isControlPressed ||
                HardwareKeyboard.instance.isMetaPressed)) {
          _tryPasteAttachment();
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }

  Future<void> _tryPasteImage() async {
    try {
      final bytes = await Pasteboard.image;
      if (bytes == null || bytes.isEmpty || !mounted) return;
      final ts = DateTime.now().millisecondsSinceEpoch;
      await _previewAndSendImage(bytes, 'pasted_$ts.png', 'image/png');
    } catch (_) {
      // No image on the clipboard (or unsupported) — the default text paste
      // already handled the keystroke.
    }
  }

  // Ctrl/Cmd+V: first try FILES copied from a file manager (APK, PDF, Excel,
  // ...), then an image, then fall through to the default text paste.
  Future<void> _tryPasteAttachment() async {
    // On web, clipboard files arrive via the DOM paste listener instead
    // (browsers don't expose them to the key handler / pasteboard).
    if (kIsWeb) return;
    try {
      final paths = await Pasteboard.files();
      if (paths.isNotEmpty) {
        await _pasteFilesFlow(paths);
        return;
      }
    } catch (_) {/* no files on the clipboard */}
    await _tryPasteImage();
  }

  Future<void> _pasteFilesFlow(List<String> paths) async {
    const imgExt = ['jpg', 'jpeg', 'png', 'gif', 'webp'];
    const fileCap = 200 * 1024 * 1024; // server cap for arbitrary files
    const ephemeralOver = 15 * 1024 * 1024; // big files: cache-then-purge
    for (var i = 0; i < paths.length; i++) {
      final path = paths[i];
      List<int> bytes;
      try {
        bytes = await readFileBytes(path);
      } catch (_) {
        if (mounted) {
          showToast(context, 'Could not read that file',
              type: ToastType.error);
        }
        continue;
      }
      if (bytes.isEmpty) continue;
      final name = path.split(RegExp(r'[\\/]+')).last;
      final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
      if (imgExt.contains(ext)) {
        await _previewAndSendImage(
            Uint8List.fromList(bytes), name, _mimeForExt(ext));
        continue;
      }
      if (bytes.length > fileCap) {
        if (mounted) {
          showToast(context, '"$name" is too large to send (max 200 MB).',
              type: ToastType.error);
        }
        continue;
      }
      // Only the FIRST file gets the caption sheet; extra files send plain so a
      // multi-file paste isn't a caption gauntlet.
      String? caption = '';
      if (i == 0) {
        caption = await _askFileCaption(name);
        if (caption == null) return; // cancelled the whole paste
      }
      await _uploadAndSend(
        bytes: bytes,
        filename: name,
        mime: _mimeForExt(ext),
        type: 'file',
        caption: caption,
        // Large files ride as ephemeral: the server purges the bytes once the
        // recipient caches them (or after the TTL), so a 200 MB file never
        // lives on the server long-term.
        ephemeral: bytes.length > ephemeralOver,
      );
    }
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

  // Compact caption panel (file chip + caption field + send) that stands in
  // for the composer while a pasted file is awaiting its caption. WhatsApp-
  // style: it lives in the conversation's input slot, not over the whole app.
  Widget _buildFileCaptionBar(ColorScheme scheme) {
    final name = _captionFileName ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.insert_drive_file_rounded,
                      color: scheme.primary, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface)),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  color: scheme.onSurfaceVariant,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Cancel',
                  onPressed: _cancelFileCaption,
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(
                        color: scheme.outlineVariant.withValues(alpha: 0.5)),
                  ),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                    child: Focus(
                      onKeyEvent: (node, event) {
                        if (event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.enter &&
                            !HardwareKeyboard.instance.isShiftPressed &&
                            !HardwareKeyboard.instance.isControlPressed) {
                          _submitFileCaption();
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: TextField(
                        controller: _captionCtrl,
                        autofocus: true,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.newline,
                        keyboardType: TextInputType.multiline,
                        decoration: const InputDecoration(
                          hintText: 'Add a caption…',
                          isDense: true,
                          border: InputBorder.none,
                          contentPadding:
                              EdgeInsets.symmetric(vertical: 10, horizontal: 2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Material(
                color: scheme.primary,
                shape: const CircleBorder(),
                child: IconButton(
                  icon: const Icon(Icons.send_rounded, color: Colors.white),
                  onPressed: _submitFileCaption,
                  tooltip: 'Send',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _viewerSenderName(int i) {
    final m = (i >= 0 && i < _viewerMsgs.length) ? _viewerMsgs[i] : null;
    if (m == null) return '';
    final mine = m['sender_id']?.toString() == _myId;
    if (mine) return 'Me';
    if (_isGroup) {
      final sm = (m['sender'] as Map?) ?? const {};
      return (sm['username'] ?? 'Member').toString();
    }
    return widget.friendName;
  }

  String _viewerSenderAvatar(int i) {
    final m = (i >= 0 && i < _viewerMsgs.length) ? _viewerMsgs[i] : null;
    if (m == null) return '';
    final mine = m['sender_id']?.toString() == _myId;
    if (mine) return _myAvatar ?? '';
    if (_isGroup) {
      final sm = (m['sender'] as Map?) ?? const {};
      return (sm['avatar_url'] ?? '').toString();
    }
    return _friendAvatar;
  }

  String _viewerSentTime(int i) {
    final m = (i >= 0 && i < _viewerMsgs.length) ? _viewerMsgs[i] : null;
    final iso = m?['timestamp']?.toString();
    final t = iso != null ? DateTime.tryParse(iso) : null;
    if (t == null) return '';
    final local = t.toLocal();
    final now = DateTime.now();
    final today = local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    final y = now.subtract(const Duration(days: 1));
    final yday =
        local.year == y.year && local.month == y.month && local.day == y.day;
    final hm = DateFormat('HH:mm').format(local);
    if (today) return 'Today at $hm';
    if (yday) return 'Yesterday at $hm';
    return DateFormat('MMM d, HH:mm').format(local);
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
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Swipe the photo down to close the viewer (when not zoomed).
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 300) _closeViewer();
        },
        child: ColoredBox(
        color: stageColor,
        child: Stack(
          children: [
            PhotoViewGallery.builder(
              pageController: _viewerPageCtrl,
              itemCount: imgs.length,
              onPageChanged: (p) => setState(() => _viewerIndex = p),
              backgroundDecoration: BoxDecoration(color: stageColor),
              loadingBuilder: (_, _) => Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: isDark ? Colors.white : accent),
                ),
              ),
              builder: (ctx2, p) => PhotoViewGalleryPageOptions(
                imageProvider: _viewerProviders[p],
                minScale: PhotoViewComputedScale.contained,
                maxScale: PhotoViewComputedScale.covered * 3,
                initialScale: PhotoViewComputedScale.contained,
                onTapUp: (_, _, _) => toggle(),
              ),
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
                                      style: const TextStyle(
                                          color: Colors.white,
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
                          IconButton(
                            tooltip: 'Reply',
                            onPressed: msg == null
                                ? null
                                : () {
                                    setState(() => _replyTo = msg);
                                    _closeViewer();
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
      )),
    );
  }

  Widget _videoBubble(
      String url, Map<String, dynamic> msg, ColorScheme scheme,
      {String? caption}) {
    final secs = (msg['media_duration'] as num?)?.toInt() ?? 0;
    // Shared poster + silent dwell-glimpse + tap-to-play; fullscreen opens the
    // existing in-app player. Same behaviour as Our Space moments. The caption
    // rides on the video and fades out while it plays.
    return GlimpseVideo(
      url: url,
      headers: mediaAuthHeaders(url),
      accent: scheme.primary,
      maxWidth: 260,
      maxStageHeight: 280,
      aspectRatioFallback: 16 / 10,
      durationSecs: secs > 0 ? secs : null,
      caption: caption,
      posterUrl: '$url/thumb',
      onFullscreen: () => _openVideo(url, msg),
    );
  }

  void _openVideo(String url, Map<String, dynamic> msg) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog<void>(
      context: context,
      barrierColor: isDark ? Colors.black : Colors.white,
      builder: (dctx) => _ChatVideoPlayer(
        url: url,
        onKeep: _canHarmony ? () => _keepsakeMessage(msg) : null,
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
      List<int>? bytes;
      // Prefer the on-device copy (survives the server purge).
      if (!kIsWeb) {
        try {
          final f = await MediaStore.instance.getFile(url, mediaAuthHeaders(url));
          if (f != null) bytes = await f.readAsBytes();
        } catch (_) {}
      }
      if (bytes == null || bytes.isEmpty) {
        final res = await appBusy.run(
            () => http.get(Uri.parse(url), headers: mediaAuthHeaders(url)));
        if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
          bytes = res.bodyBytes;
        }
      }
      if (bytes == null || bytes.isEmpty) {
        if (mounted) {
          showToast(context, 'Photo is no longer available',
              type: ToastType.error);
        }
        return;
      }
      var name = Uri.parse(url).pathSegments.isNotEmpty
          ? Uri.parse(url).pathSegments.last
          : '';
      if (name.isEmpty || !name.contains('.')) {
        name = 'aluta_image_${DateTime.now().millisecondsSinceEpoch}.jpg';
      }
      // Phone → gallery; desktop → a proper Save As… dialog.
      await _saveBytesToDevice(bytes, name, image: true);
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not save image', type: ToastType.error);
      }
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
      // Prefer the locally-persisted copy (images/files survive the server's
      // store-and-forward purge on device), then fall back to the server while
      // it still holds the bytes.
      if (bytes == null || bytes.isEmpty) {
        final url = fullMediaUrl(rel);
        if (!kIsWeb && id == null) {
          try {
            final f =
                await MediaStore.instance.getFile(url, mediaAuthHeaders(url));
            if (f != null) bytes = await f.readAsBytes();
          } catch (_) {}
        }
        if (bytes == null || bytes.isEmpty) {
          final res = await appBusy.run(
              () => http.get(Uri.parse(url), headers: mediaAuthHeaders(url)));
          if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
            bytes = res.bodyBytes;
          }
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
          bytes, (name == null || name.isEmpty) ? fallback : name,
          image: type == 'image');
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
  Future<void> _saveBytesToDevice(List<int> bytes, String fname,
      {bool image = false}) async {
    final data = Uint8List.fromList(bytes);
    // On a phone, drop images straight into the photo gallery (easy to find,
    // like WhatsApp) instead of a file-save dialog.
    if (image && _isMobile) {
      try {
        final perm = await PhotoManager.requestPermissionExtend();
        if (perm.hasAccess) {
          // saveImage returns a non-null AssetEntity on success and throws
          // otherwise, so reaching here means the save landed in the gallery.
          await PhotoManager.editor.saveImage(data, filename: fname);
          if (mounted) {
            showToast(context, 'Saved to gallery', type: ToastType.success);
          }
          return;
        }
      } catch (_) {/* fall through to the generic saver */}
    }
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
        _MenuAction('copy', Icons.copy_rounded, 'Copy', () {
          Navigator.pop(ctx);
          Clipboard.setData(ClipboardData(text: _stripQuote(content)));
          showToast(context, 'Copied');
        }),
        if (!deleted)
          _MenuAction('forward', Icons.forward_rounded, 'Forward', () {
            Navigator.pop(ctx);
            _showForwardPicker(msg);
          }),
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
      );
    }
  }

  /// A desktop/window dropdown anchored at the pointer: a compact reaction row
  /// above the full action list, no full-screen blur. Tap outside or press
  /// Escape to dismiss.
  Future<void> _showAnchoredDropdown({
    required Offset anchor,
    required bool isMe,
    required WidgetBuilder reactionBarBuilder,
    required Widget Function(BuildContext, double) fullMenuBuilder,
  }) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Message actions',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 140),
      pageBuilder: (ctx, a1, a2) {
        final media = MediaQuery.of(ctx);
        final sw = media.size.width;
        final sh = media.size.height;
        final topSafe = media.padding.top + 8;
        final botSafe = media.padding.bottom + 8;
        const menuW = 250.0;
        double left = isMe ? anchor.dx - menuW : anchor.dx;
        left = left.clamp(8.0, (sw - 8 - menuW).clamp(8.0, sw));
        final belowRoom = sh - botSafe - anchor.dy;
        final aboveRoom = anchor.dy - topSafe;
        final below = belowRoom >= aboveRoom;
        final avail = (below ? belowRoom : aboveRoom) - 20;
        final menuMaxH = (avail - 72).clamp(120.0, sh);
        return AnimatedBuilder(
          animation: a1,
          builder: (context, _) {
            final t = Curves.easeOut.transform(a1.value.clamp(0.0, 1.0));
            final col = SizedBox(
              width: menuW,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  reactionBarBuilder(ctx),
                  const SizedBox(height: 8),
                  fullMenuBuilder(ctx, menuMaxH),
                ],
              ),
            );
            return Material(
              type: MaterialType.transparency,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(ctx).pop(),
                    ),
                  ),
                  Positioned(
                    left: left,
                    top: below ? anchor.dy.clamp(topSafe, sh - 40) : null,
                    bottom: below ? null : (sh - anchor.dy).clamp(0.0, sh),
                    child: Opacity(
                      opacity: t,
                      child: Transform.scale(
                        scale: 0.97 + 0.03 * t,
                        alignment:
                            isMe ? Alignment.topRight : Alignment.topLeft,
                        child: col,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Shows the message reaction bar + action menu as a SPOTLIGHT: the whole
  /// screen is dimmed and blurred EXCEPT a hole cut over the pressed bubble, so
  /// that one bubble stays crisp and lifted (WhatsApp / iMessage style). The
  /// reactions sit just above the bubble and the menu just below — flipping to
  /// the side with more room when the bubble is near a screen edge. Falls back
  /// to a centred panel if the bubble's rect couldn't be measured.
  Future<void> _showSpotlightPanel({
    required Rect? bubbleRect,
    required bool isMe,
    required WidgetBuilder reactionBarBuilder,
    required WidgetBuilder actionCardBuilder,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Message actions',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, a1, a2) {
        final media = MediaQuery.of(ctx);
        final sw = media.size.width;
        final sh = media.size.height;
        final topSafe = media.padding.top + 8;
        final botSafe = media.padding.bottom + 8;
        return AnimatedBuilder(
          animation: a1,
          builder: (context, _) {
            final t = Curves.easeOutCubic.transform(a1.value.clamp(0.0, 1.0));
            final tb = Curves.easeOutBack.transform(a1.value.clamp(0.0, 1.0));
            final rect = bubbleRect;

            Widget dim = BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 8 * t, sigmaY: 8 * t),
              child: Container(
                color: Colors.black
                    .withValues(alpha: (isDark ? 0.34 : 0.24) * t),
              ),
            );
            if (rect != null) {
              dim = ClipPath(
                clipper: _HoleClipper(rect.inflate(4), 16),
                child: dim,
              );
            }

            final children = <Widget>[
              Positioned.fill(
                child: Opacity(
                  opacity: t,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(ctx).pop(),
                    child: dim,
                  ),
                ),
              ),
            ];

            if (rect == null) {
              children.add(Opacity(
                opacity: t,
                child: Transform.scale(
                  scale: 0.92 + 0.08 * tb,
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                          18, topSafe + 16, 18, botSafe + 16),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 440),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            reactionBarBuilder(ctx),
                            const SizedBox(height: 10),
                            Flexible(child: actionCardBuilder(ctx)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ));
            } else {
              const barH = 60.0;
              const gap = 10.0;
              final aboveRoom = rect.top - topSafe;
              final belowRoom = sh - botSafe - rect.bottom;
              final barAbove = aboveRoom > barH + gap + 8;
              final barTop =
                  barAbove ? rect.top - gap - barH : rect.bottom + gap;

              final menuW = (sw - 32).clamp(0.0, 270.0);
              double menuLeft = isMe ? rect.right - menuW : rect.left;
              menuLeft = menuLeft.clamp(8.0, (sw - 8 - menuW).clamp(8.0, sw));

              // Reaction bar and action menu share the SAME width and left edge
              // so they stack as one balanced column aligned to the bubble's
              // side (matching the desktop dropdown), instead of the bar being
              // centred on the bubble and drifting out of line with the menu.
              final barW = menuW;
              final barLeft = menuLeft;

              final menuBelow = belowRoom >= aboveRoom;
              final Widget menu = Transform.scale(
                scale: 0.96 + 0.04 * tb,
                alignment:
                    isMe ? Alignment.topRight : Alignment.topLeft,
                child: actionCardBuilder(ctx),
              );
              Widget menuPositioned;
              if (menuBelow) {
                final mTop = barAbove
                    ? rect.bottom + gap
                    : rect.bottom + gap + barH + gap;
                final maxH = (sh - botSafe - mTop).clamp(90.0, sh);
                menuPositioned = Positioned(
                  top: mTop,
                  left: menuLeft,
                  width: menuW,
                  child: Opacity(
                    opacity: t,
                    child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: maxH),
                        child: menu),
                  ),
                );
              } else {
                final mBottomY = barAbove
                    ? rect.top - gap - barH - gap
                    : rect.top - gap;
                final maxH = (mBottomY - topSafe).clamp(90.0, sh);
                menuPositioned = Positioned(
                  bottom: sh - mBottomY,
                  left: menuLeft,
                  width: menuW,
                  child: Opacity(
                    opacity: t,
                    child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: maxH),
                        child: menu),
                  ),
                );
              }

              children.add(Positioned(
                top: barTop,
                left: barLeft,
                width: barW,
                child: Opacity(
                  opacity: t,
                  child: Transform.scale(
                    scale: 0.9 + 0.1 * tb,
                    child: reactionBarBuilder(ctx),
                  ),
                ),
              ));
              children.add(menuPositioned);
            }

            return Material(
              type: MaterialType.transparency,
              child: Stack(children: children),
            );
          },
        );
      },
      transitionBuilder: (ctx, anim, sec, child) => child,
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

  // Renders a shared location (message_type 'location'); content is JSON
  // {lat,lng}. A compact pin card that opens the coordinates in the device's
  // maps app.
  Widget _locationContent(Map<String, dynamic> msg, bool isMe, Color textColor,
      ColorScheme scheme) {
    double? lat, lng;
    try {
      final j = jsonDecode((msg['content'] ?? '{}').toString());
      if (j is Map) {
        lat = (j['lat'] as num?)?.toDouble();
        lng = (j['lng'] as num?)?.toDouble();
      }
    } catch (_) {}
    final coords = (lat != null && lng != null)
        ? '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'
        : 'Shared location';
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: (lat != null && lng != null) ? () => _openMap(lat!, lng!) : null,
      child: Container(
        width: 232,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: textColor.withAlpha(18),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF26A69A).withAlpha(40),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.location_on_rounded,
                  color: Color(0xFF26A69A)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Location',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: textColor)),
                  const SizedBox(height: 2),
                  Text(coords,
                      style: TextStyle(
                          fontSize: 12, color: textColor.withAlpha(170))),
                  const SizedBox(height: 4),
                  const Text('Open in Maps',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF26A69A))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openMap(double lat, double lng) async {
    final geo = Uri.parse('geo:$lat,$lng?q=$lat,$lng');
    final web = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    try {
      if (await canLaunchUrl(geo)) {
        await launchUrl(geo, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(web, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not open maps', type: ToastType.error);
      }
    }
  }

  // Renders a shared contact (message_type 'contact'); content is JSON
  // {name, phone, phones}. A contact card with call + save actions.
  Widget _contactContent(Map<String, dynamic> msg, bool isMe, Color textColor,
      ColorScheme scheme) {
    String name = 'Contact';
    String phone = '';
    try {
      final j = jsonDecode((msg['content'] ?? '{}').toString());
      if (j is Map) {
        final n = (j['name'] ?? '').toString().trim();
        if (n.isNotEmpty) name = n;
        phone = (j['phone'] ?? '').toString().trim();
      }
    } catch (_) {}
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      width: 244,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: textColor.withAlpha(18),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: const Color(0xFF42A5F5).withAlpha(45),
                child: Text(initial,
                    style: const TextStyle(
                        color: Color(0xFF1E88E5),
                        fontWeight: FontWeight.bold,
                        fontSize: 18)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: textColor)),
                    if (phone.isNotEmpty)
                      Text(phone,
                          style: TextStyle(
                              fontSize: 12.5,
                              color: textColor.withAlpha(170))),
                  ],
                ),
              ),
            ],
          ),
          if (phone.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _dialNumber(phone),
                    icon: const Icon(Icons.call_rounded, size: 16),
                    label: const Text('Call'),
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        visualDensity: VisualDensity.compact),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _saveContact(name, phone),
                    icon: const Icon(Icons.person_add_alt_1_rounded, size: 16),
                    label: const Text('Save'),
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        visualDensity: VisualDensity.compact),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _dialNumber(String phone) async {
    try {
      await launchUrl(Uri(scheme: 'tel', path: phone));
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not open dialer', type: ToastType.error);
      }
    }
  }

  Future<void> _saveContact(String name, String phone) async {
    if (!_isMobile) return;
    try {
      final c = Contact()
        ..name.first = name
        ..phones = [Phone(phone)];
      // Opens the OS "new contact" editor prefilled — the user confirms.
      await FlutterContacts.openExternalInsert(c);
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not open contacts', type: ToastType.error);
      }
    }
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

  // Open a tapped link from a message bubble in the external browser.
  Future<void> _openLink(String url) async {
    try {
      // Bare www./domain links (from LooseUrlLinkifier) carry no scheme — assume
      // https so the OS opens them in a browser rather than rejecting them.
      // Emails come through as mailto: from EmailLinkifier and are left as-is.
      var target = url.trim();
      if (!target.contains('://') && !target.startsWith('mailto:')) {
        target = 'https://$target';
      }
      final uri = Uri.parse(target);
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
    // Still uploading / sending: a small spinner sits in the tick slot — no
    // single tick yet. The composer stays free so more messages can queue.
    if (status == 'sending') {
      return SizedBox(
        width: 11,
        height: 11,
        child: CircularProgressIndicator(strokeWidth: 1.6, color: muted),
      );
    }
    // Send failed: a tappable retry marker in the tick slot.
    if (status == 'failed') {
      return GestureDetector(
        onTap: () => _retrySend(msg),
        child: Icon(Icons.error_outline_rounded,
            size: 14, color: Colors.redAccent),
      );
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
    final emojiOnly =
        !tomb && !hasQuote && !isMedia && _isEmojiOnly(mainText);
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
    final quoteBarColor = isMe
        ? (isDark ? const Color(0xFFFF8A93) : scheme.primary)
        : scheme.primary;
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
    final sentMuted = onSent.withAlpha(isDark ? 160 : 150);
    // Read receipt: a blue double-tick, so it stands out against the red/rose
    // sender bubble instead of blending in like the old brand-red tick did.
    final sentRead =
        isDark ? const Color(0xFF6FB1FF) : const Color(0xFF1976D2);
    // Delivery ticks: neutral gray while sent/delivered, blue once read.
    final tickGray =
        isDark ? const Color(0xFFB3ACAE) : const Color(0xFF8C8A8E);
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
                        if (isMedia && !imgCap)
                          _mediaContent(msgType, mediaRel ?? '', msg, isMe,
                              textColor, scheme,
                              caption: msgType == 'video' ? mainText : null),
                        if (imgCap)
                          _imageCaption(fullMediaUrl(mediaRel), mainText,
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
                            msgType != 'video' &&
                            !imgCap &&
                            mainText.trim().isNotEmpty)
                          Padding(
                            padding: EdgeInsets.only(top: isMedia ? 6 : 0),
                            child: _bubbleTextOnly(
                                mainText, textColor, linkColor),
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
        case 'video':
          return '🎥 Video';
        case 'audio':
          return '🎤 Voice message';
        default:
          return '📎 ${(msg['media_name'] as String?) ?? 'File'}';
      }
    }
    // Structured cards store JSON in `content`; show a friendly label instead.
    if (type == 'location') return '📍 Location';
    if (type == 'contact') return '👤 Contact';
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
                              : 'Replying to ${widget.friendName}',
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
    return ContactNames.instance.nameFor(_friendPhone) == null;
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

  // Slim tappable banner inviting the user to save an unknown number.
  Widget _buildSaveContactBanner() {
    if (!_needsContactSave) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primary.withValues(alpha: 0.10),
      child: InkWell(
        onTap: _addFriendToContacts,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.person_add_alt_1_rounded,
                  size: 20, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Add to contacts',
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                            color: scheme.onSurface)),
                    Text(_friendPhone,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded,
                  size: 20, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
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
          if (_editing != null)
            _EditBanner(
              text: _stripQuote((_editing!['content'] as String?) ?? ''),
              onCancel: _cancelEditing,
            ),
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
                            color: scheme.surface,
                            borderRadius: BorderRadius.circular(26),
                            border: Border.all(
                                color: scheme.outlineVariant
                                    .withValues(alpha: 0.5)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black
                                    .withValues(alpha: isDark ? 0.28 : 0.06),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
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
                              AnimatedSize(
                                duration: const Duration(milliseconds: 180),
                                curve: Curves.easeOut,
                                alignment: Alignment.centerLeft,
                                child: hasText
                                    ? const SizedBox.shrink()
                                    : IconButton(
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
                                      hintText: 'Message',
                                      hintMaxLines: 1,
                                      hintStyle: TextStyle(
                                          color: scheme.onSurfaceVariant
                                              .withValues(alpha: 0.7)),
                                      isDense: true,
                                      border: InputBorder.none,
                                      contentPadding: const EdgeInsets.symmetric(
                                          vertical: 10, horizontal: 2),
                                    ),
                                  ),
                                ),
                              ),
                              AnimatedSize(
                                duration: const Duration(milliseconds: 180),
                                curve: Curves.easeOut,
                                alignment: Alignment.centerRight,
                                child: hasText
                                    ? const SizedBox(width: 4)
                                    : Row(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          IconButton(
                                            tooltip: 'Listen together',
                                            icon: Icon(Icons.headphones_rounded,
                                                color: scheme.primary),
                                            onPressed: _startListenTogether,
                                            visualDensity:
                                                VisualDensity.compact,
                                          ),
                                          IconButton(
                                            tooltip: 'Attach',
                                            icon: Icon(Icons.attach_file_rounded,
                                                color: scheme.onSurfaceVariant),
                                            onPressed: _openAttachSheet,
                                            visualDensity:
                                                VisualDensity.compact,
                                          ),
                                          IconButton(
                                            tooltip: 'Camera',
                                            icon: Icon(Icons.camera_alt_rounded,
                                                color: scheme.onSurfaceVariant),
                                            onPressed: () =>
                                                _pickImage(ImageSource.camera),
                                            visualDensity:
                                                VisualDensity.compact,
                                          ),
                                          const SizedBox(width: 4),
                                        ],
                                      ),
                              ),
                            ],
                          ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
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
                                    boxShadow: hasText
                                        ? [
                                            BoxShadow(
                                              color: scheme.primary
                                                  .withValues(alpha: 0.4),
                                              blurRadius: 8,
                                              offset: const Offset(0, 2),
                                            ),
                                          ]
                                        : null,
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

  Widget _buildEmojiPicker(ColorScheme scheme) =>
      _emojiPickerFor(scheme, _ctrl);

  Widget _emojiPickerFor(ColorScheme scheme, TextEditingController controller,
      {double height = 262}) {
    return EmojiPicker(
                // When `textEditingController` is provided, EmojiPicker already
                // inserts the tapped emoji into it (at the cursor). Do NOT also
                // append it here — doing both made every emoji appear twice.
                onEmojiSelected: (_, _) {},
                textEditingController: controller,
                config: Config(
                  height: height,
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
            child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  children: [
                    // ── Chat wallpaper background ─────────────────────────
                    Positioned.fill(
                      child: ValueListenableBuilder<int>(
                        valueListenable: chatBgRevision,
                        builder: (ctx, _, _) {
                          final bg = chatBackgroundFor(_convKey);
                          if (bg.isPhoto) {
                            return _chatPhotoWallpaper(bg, isDark);
                          }
                          if (bg.isMotif) {
                            return _chatMotifWallpaper(scheme, isDark);
                          }
                          return _ChatWallpaper(
                              isDark: isDark, brand: scheme.primary);
                        },
                      ),
                    ),
                    GestureDetector(
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
                    if (_viewerImages != null) _buildInlineViewer(),
                  ],
                ),
          ),
        ),
        // Input
        _buildInput(isDark),
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
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (v) {
              if (v == 'wallpaper') _openChatWallpaperSheet();
            },
            itemBuilder: (_) => const [
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
  });
  final List<_MenuAction> quick;
  final List<_MenuAction> full;
  final ColorScheme scheme;
  final bool isDark;
  final List<BoxShadow> shadow;

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
  });
  final List<_MenuAction> actions;
  final ColorScheme scheme;
  final bool isDark;
  final List<BoxShadow> shadow;
  final double? maxHeight;

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
      decoration: _menuDeco(widget.scheme, widget.isDark, widget.shadow, 18),
      clipBehavior: Clip.antiAlias,
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
              top: -6,
              left: widget.isMe ? null : 30,
              right: widget.isMe ? 2 : null,
              child: GestureDetector(
                onTapDown: (d) => widget.onOpen(d.globalPosition),
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: scheme.outlineVariant.withValues(alpha: 0.6)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
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

class _ChatVideoPlayerState extends State<_ChatVideoPlayer> {
  VideoPlayerController? _c;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _init();
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
            ? VideoPlayerController.file(f)
            : VideoPlayerController.networkUrl(
                Uri.parse(widget.url),
                httpHeaders: mediaAuthHeaders(widget.url),
              );
      } else {
        c = VideoPlayerController.networkUrl(
          Uri.parse(widget.url),
          httpHeaders: mediaAuthHeaders(widget.url),
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
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
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
      onTap: () {
        if (c == null || !c.value.isInitialized) return;
        if (c.value.isPlaying) {
          c.pause();
        } else {
          c.play();
        }
        setState(() {});
      },
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
            child: IconButton(
              icon: Icon(Icons.close_rounded,
                  color: isDark ? Colors.white : Colors.black87),
              onPressed: () => Navigator.pop(context),
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
