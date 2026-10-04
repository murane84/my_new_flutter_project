import 'dart:convert';
import 'dart:async';
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:just_audio/just_audio.dart' as ja;

import 'api_service.dart';
import 'home_page.dart' show playbackBus, playlistNotifier;
import 'live_session_screen.dart';
import 'token_helper.dart' show getToken, mediaAuthHeaders;
import '../services/now_playing_presence.dart';
import '../utils/toast_helper.dart';
import '../utils/avatar_widget.dart';
import '../utils/popup_shell.dart';
import '../utils/chat_background.dart';
import '../utils/net_image.dart';
import '../utils/app_config.dart';
import '../services/media_store.dart';
import '../utils/romantic_pattern.dart';
import '../services/wallpapers_service.dart';
import '../widgets/wallpaper_gallery.dart';
import '../utils/file_bytes.dart';
import '../services/notif_service.dart'
    show syncDiaryReminders, cancelDiaryReminder, PlanReminder;

/// "Our Space" — a bond rendered as a *place*, not a chat thread. Opening a
/// pinned Space shows the story of that connection: who you are together, how
/// long you've been close, your shared song, and the moments you've kept.
///
/// Deliberately calm and read-mostly. It never polls or holds a socket — it
/// fetches the Space once on open (and again only after an edit / pull), so it
/// costs nothing while it sits in the background (efficiency mandate).

// ── theme presets (curated, never a raw colour wheel) ────────────────────────
const Map<String, Color> kSpacePalette = {
  // NOTE: keys are stored on the Space row, so existing keys must never change.
  // New colours are added by appending fresh keys only.
  'red': Color(0xFFD90429),
  'coral': Color(0xFFFF5A5F),
  'sunset': Color(0xFFFB7185),
  'rose': Color(0xFFFF4D8D),
  'magenta': Color(0xFFEC4899),
  'fuchsia': Color(0xFFD946EF),
  'orchid': Color(0xFFA855F7),
  'violet': Color(0xFF8E7CFF),
  'grape': Color(0xFF9333EA),
  'indigo': Color(0xFF6366F1),
  'cobalt': Color(0xFF2563EB),
  'ocean': Color(0xFF37B0E6),
  'sky': Color(0xFF38BDF8),
  'cyan': Color(0xFF06B6D4),
  'teal': Color(0xFF1FB6A6),
  'emerald': Color(0xFF10B981),
  'forest': Color(0xFF39B54A),
  'lime': Color(0xFF84CC16),
  'gold': Color(0xFFEAB308),
  'amber': Color(0xFFF59E0B),
  'ember': Color(0xFFFF8A3D),
  'slate': Color(0xFF64748B),
  'neon_pink': Color(0xFFFF2E88),
  'neon_purple': Color(0xFFB026FF),
  'neon_blue': Color(0xFF2D7DFF),
  'neon_cyan': Color(0xFF17E9E0),
  'neon_green': Color(0xFF2BE86B),
  'neon_lime': Color(0xFFC6FF00),
  'neon_yellow': Color(0xFFFFE500),
  'neon_orange': Color(0xFFFF7A00),
};

Color spaceThemeColor(String? key) => kSpacePalette[key] ?? const Color(0xFFFF5A5F);

// The matched fixed size of the two hero stat chips. Both share this exact size
// so they read as a pair, and it's kept a touch under the avatar cluster's
// height (~58px) so the two photos remain the banner's anchor.
const double _kHeroStatW = 96;
const double _kHeroStatH = 54;

// Diary reactions: the quick presets shown first; "More…" opens the full emoji
// keyboard so any emoji can be used. Both partners can react to any entry.
const List<String> _kQuickReactions = ['❤️', '👍', '😂', '😮', '😢', '🙏'];
// Bodies longer than this are collapsed in the diary list; a "Read more" opens
// the full memory in its own card.
const int _kMemoryPreviewChars = 240;

/// Resolve a (possibly relative) avatar path to a full URL against [apiBase].
String? resolveAvatarUrl(String? raw, String apiBase) {
  final s = raw?.toString() ?? '';
  if (s.isEmpty) return null;
  return s.startsWith('http') ? s : '$apiBase$s';
}

/// An author's profile photo in a small rounded badge (a white rim + soft
/// shadow), like the avatars in the hero — falls back to coloured initials when
/// there's no photo.
/// The diary typefaces, using only built-in font families (no assets). The
/// stored KEY is the author's choice; both partners see each memory in its
/// author's "hand", so each keeps a unique touch in the shared notebook.
/// (Web renders all four; Android/desktop map serif/mono and fall back for
/// handwriting — it degrades to the default rather than breaking.)
const List<(String, String)> kDiaryFonts = [
  ('', 'Classic'),
  ('serif', 'Serif'),
  ('typewriter', 'Typewriter'),
  ('handwriting', 'Handwriting'),
];

/// Map a stored diary font key to a Flutter font-family string (null = default).
String? diaryFontFamily(String? key) {
  switch ((key ?? '').toLowerCase()) {
    case 'serif':
      return 'serif';
    case 'typewriter':
      return 'monospace';
    case 'handwriting':
      return 'cursive';
    default:
      return null;
  }
}

/// The author's profile photo in a rounded badge — NAME-FREE by design (the
/// diary shows only the face, never "You"/a username, on memories, comments and
/// reactions), so the notebook stays personal without labels everywhere.
Widget diaryAuthorBadge({
  required String name,
  String? imageUrl,
  double radius = 14,
}) {
  return Container(
    padding: const EdgeInsets.all(1.5),
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: Colors.white,
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.14),
          blurRadius: 4,
          offset: const Offset(0, 2),
        ),
      ],
    ),
    child: InitialsAvatar(
      name: name.isEmpty ? '?' : name,
      radius: radius,
      imageUrl: (imageUrl != null && imageUrl.isNotEmpty) ? imageUrl : null,
    ),
  );
}

/// A compact "N minutes/hours/days ago" for diary timestamps.
String _diaryAgo(DateTime dt) {
  final d = DateTime.now().difference(dt.toLocal());
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  return DateFormat('MMM d').format(dt.toLocal());
}

/// Pick a reaction emoji: a row of quick presets, or "More…" for the full
/// emoji keyboard. Returns the chosen glyph, or null if dismissed.
Future<String?> pickDiaryReaction(BuildContext context, Color accent) {
  final scheme = Theme.of(context).colorScheme;
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: scheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      var showAll = false;
      return StatefulBuilder(
        builder: (ctx, setS) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('React',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: scheme.onSurface)),
                ),
              ),
              if (!showAll) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final em in _kQuickReactions)
                        InkWell(
                          onTap: () => Navigator.pop(ctx, em),
                          borderRadius: BorderRadius.circular(14),
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            child: Text(em, style: const TextStyle(fontSize: 28)),
                          ),
                        ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: () => setS(() => showAll = true),
                  style: TextButton.styleFrom(foregroundColor: accent),
                  icon: const Icon(Icons.add_reaction_outlined, size: 18),
                  label: const Text('More emoji'),
                ),
                const SizedBox(height: 6),
              ] else
                SizedBox(
                  height: 280,
                  child: EmojiPicker(
                    onEmojiSelected: (cat, emoji) =>
                        Navigator.pop(ctx, emoji.emoji),
                    config: Config(
                      height: 280,
                      emojiViewConfig: EmojiViewConfig(
                        emojiSizeMax: 26,
                        columns: 8,
                        backgroundColor: scheme.surface,
                        buttonMode: ButtonMode.MATERIAL,
                      ),
                      categoryViewConfig: CategoryViewConfig(
                        backgroundColor: scheme.surfaceContainerHighest,
                        indicatorColor: accent,
                        iconColor: scheme.onSurfaceVariant,
                        iconColorSelected: accent,
                        dividerColor: scheme.outlineVariant.withAlpha(80),
                      ),
                      bottomActionBarConfig: BottomActionBarConfig(
                        backgroundColor: scheme.surfaceContainerHighest,
                        buttonColor: scheme.surfaceContainerHighest,
                        buttonIconColor: accent,
                      ),
                      searchViewConfig: SearchViewConfig(
                        backgroundColor: scheme.surfaceContainerHighest,
                        buttonIconColor: accent,
                        hintText: 'Search emoji',
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// The reaction strip for a diary entry: a chip per emoji (with its count,
/// highlighted when I'm one of the reactors) plus a "React" button. [onToggle]
/// adds/removes my reaction of that emoji; [onAdd] opens the picker.
Widget diaryReactionRow({
  required ColorScheme scheme,
  required Color accent,
  required Map<String, dynamic> entry,
  required void Function(String emoji) onToggle,
  required VoidCallback onAdd,
}) {
  final reactions = ((entry['reactions'] as List?) ?? const [])
      .whereType<Map>()
      .toList();
  final mine = ((entry['my_reactions'] as List?) ?? const [])
      .map((e) => e.toString())
      .toSet();
  Widget chip(String emoji, int count, bool isMine) => InkWell(
        onTap: () => onToggle(emoji),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: isMine
                ? accent.withValues(alpha: 0.16)
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: isMine
                    ? accent.withValues(alpha: 0.55)
                    : scheme.outlineVariant.withValues(alpha: 0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 14)),
              if (count > 0) ...[
                const SizedBox(width: 4),
                Text('$count',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: isMine ? accent : scheme.onSurfaceVariant)),
              ],
            ],
          ),
        ),
      );
  return Wrap(
    spacing: 6,
    runSpacing: 6,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      for (final r in reactions)
        chip(r['emoji'].toString(), (r['count'] as num?)?.toInt() ?? 0,
            mine.contains(r['emoji'].toString())),
      InkWell(
        onTap: onAdd,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: accent.withValues(alpha: 0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_reaction_outlined, size: 15, color: accent),
              const SizedBox(width: 4),
              Text('React',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: accent)),
            ],
          ),
        ),
      ),
    ],
  );
}

/// Bumped by the home socket whenever a bond action (moment, reaction, playlist
/// add, accept) arrives, so an OPEN Our Space page reloads itself and both
/// partners see the action live. It carries no payload — a bump just means
/// "something in a bond changed, re-fetch if you're showing one".
final ValueNotifier<int> spaceEventBus = ValueNotifier<int>(0);

/// Derive a friendly title for a Space from its members (excluding me).
String deriveSpaceName(Map<String, dynamic> space, int? myUserId) {
  final explicit = (space['name'] ?? '').toString().trim();
  if (explicit.isNotEmpty) return explicit;
  final members = (space['members'] as List?) ?? const [];
  final others = members
      .whereType<Map>()
      .where((m) => (m['id'] as num?)?.toInt() != myUserId)
      .map((m) => (m['username'] ?? '').toString().trim())
      .where((s) => s.isNotEmpty)
      .toList();
  if (others.isEmpty) return 'Our Space';
  if (others.length == 1) return 'You & ${others.first}';
  if (others.length == 2) return 'You, ${others[0]} & ${others[1]}';
  return 'You & ${others.length} others';
}

class RelationshipSpacePage extends StatefulWidget {
  final Map<String, dynamic> space; // light map from the list (id, members…)
  final String apiBase;
  final int? myUserId;
  final String? myName;      // the signed-in user's display name
  final String? myAvatarUrl; // full URL of the signed-in user's photo
  final VoidCallback? onChanged; // ask HomePage to reload its hero
  // Builds the app-wide overflow (⋮) menu so Our Space can carry the SAME
  // platform menu the home header has — a user deep in Our Space can jump to
  // Together, Groups, Friends, Profile, Sign out… without minimising first.
  // HomePage supplies this (it owns those actions); null → the ⋮ is hidden.
  final WidgetBuilder? mainMenuBuilder;

  const RelationshipSpacePage({
    super.key,
    required this.space,
    required this.apiBase,
    this.myUserId,
    this.myName,
    this.myAvatarUrl,
    this.onChanged,
    this.mainMenuBuilder,
  });

  @override
  State<RelationshipSpacePage> createState() => _RelationshipSpacePageState();
}

class _RelationshipSpacePageState extends State<RelationshipSpacePage> {
  late Map<String, dynamic> _space = Map<String, dynamic>.from(widget.space);

  int get _id => (_space['id'] as num).toInt();
  Color get _accent => spaceThemeColor(_space['theme'] as String?);

  bool _nudging = false;
  // Today's "Us" question: inline text answer + submit guard.
  final TextEditingController _qAnswerCtrl = TextEditingController();
  bool _qSubmitting = false;

  // A stable key per feature tile, so its on-screen centre can anchor the
  // open/close animation of its floating card (the card grows FROM and is
  // absorbed BACK TO its own tile).
  final GlobalKey _kPlaylist = GlobalKey();
  final GlobalKey _kMoments = GlobalKey();
  final GlobalKey _kDiary = GlobalKey();
  final GlobalKey _kDedications = GlobalKey();
  final GlobalKey _kSong = GlobalKey();

  // A feature opens as a FULL PAGE below the Our Space header (the header +
  // minimize stay on top). null = the tile dashboard; otherwise one of
  // 'playlist' | 'moments' | 'diary' | 'song'. On wide screens a left sidebar
  // lets you jump between sections without returning to the dashboard.
  String? _section;
  // On narrow screens the section list lives in a left drawer that slides in
  // over the content; this tracks whether it's showing.
  bool _navDrawerOpen = false;
  // Drives the book's page-turn between memories (adjacent pages peek like a
  // real book at viewportFraction < 1).
  final PageController _diaryPageCtrl = PageController(viewportFraction: 0.92);
  // The page currently centred — powers the prev/next arrows + the dots.
  int _diaryPage = 0;

  /// The global-space centre of a tile (via its key), or null if not laid out.
  Offset? _globalCenter(GlobalKey k) {
    final ctx = k.currentContext;
    final box = ctx?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  @override
  void initState() {
    super.initState();
    _load();
    // Repaint when the partner starts/stops/changes what they're playing, so the
    // "tune in together" card appears and clears live.
    NowPlayingPresence.instance.addListener(_onPresence);
    // Reload when a bond action lands over the socket, so an action one partner
    // takes shows up on the other's open page without a manual refresh.
    spaceEventBus.addListener(_onSpaceEvent);
  }

  @override
  void dispose() {
    NowPlayingPresence.instance.removeListener(_onPresence);
    spaceEventBus.removeListener(_onSpaceEvent);
    _diaryPageCtrl.dispose();
    _qAnswerCtrl.dispose();
    super.dispose();
  }

  void _onPresence() {
    if (mounted) setState(() {});
  }

  void _onSpaceEvent() {
    if (mounted) _load();
  }

  int? get _partnerId {
    final o = _others;
    return o.isNotEmpty ? (o.first['id'] as num?)?.toInt() : null;
  }

  String get _fullCacheKey => 'space_full_${_id}_v1';

  Future<void> _load() async {
    // Cache-first: paint the last full copy (diary, moments, playlist…)
    // instantly so the page never opens empty or waits on the server, then
    // refresh in the background. Local-first: the device holds the data.
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_fullCacheKey);
      if (raw != null && mounted) {
        final cached = (jsonDecode(raw) as Map).cast<String, dynamic>();
        setState(() => _space = {..._space, ...cached});
      }
    } catch (_) {}
    final full = await ApiService().getSpace(_id);
    if (!mounted) return;
    if (full != null) {
      setState(() => _space = full);
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_fullCacheKey, jsonEncode(full));
      } catch (_) {}
    }
    // Reconcile the device's pinned-plan reminders with the current diary.
    _syncReminders();
  }

  // ── Our Diary (shared notebook) accessors ─────────────────────────────────
  List<Map<String, dynamic>> get _diary => ((_space['diary'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();
  List<Map<String, dynamic>> get _plans =>
      _diary.where((e) => (e['kind'] ?? '').toString() == 'plan').toList();
  List<Map<String, dynamic>> get _memories =>
      _diary.where((e) => (e['kind'] ?? '').toString() != 'plan').toList();

  /// Schedule/cancel device reminders so they match the pinned future plans in
  /// the shared diary (fires the morning of each plan). Best-effort, guarded on
  /// unsupported platforms inside the service.
  void _syncReminders() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final reminders = <PlanReminder>[];
    for (final e in _plans) {
      if (e['pinned'] != true) continue;
      final d = DateTime.tryParse((e['plan_date'] ?? '').toString());
      if (d == null) continue;
      final day = DateTime(d.year, d.month, d.day);
      if (day.isBefore(today)) continue;
      final id = (e['id'] as num?)?.toInt();
      if (id == null) continue;
      final title = (e['title'] ?? '').toString().trim().isNotEmpty
          ? (e['title']).toString().trim()
          : (e['body'] ?? '').toString().trim();
      reminders.add(PlanReminder(id: id, title: title, date: day));
    }
    // Fire-and-forget; the service reconciles (schedules new, cancels stale).
    syncDiaryReminders(reminders);
  }

  String? _full(dynamic ref) {
    final s = ref?.toString() ?? '';
    if (s.isEmpty) return null;
    return s.startsWith('http') ? s : '${widget.apiBase}$s';
  }

  List<Map<String, dynamic>> get _others {
    final members = (_space['members'] as List?) ?? const [];
    return members
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .where((m) => (m['id'] as num?)?.toInt() != widget.myUserId)
        .toList();
  }

  String _closeSince() {
    final raw = (_space['close_since'] ?? _space['stats']?['close_since'] ?? '')
        .toString();
    final dt = DateTime.tryParse(raw);
    if (dt == null) return '—';
    return DateFormat('MMM d, yyyy').format(dt.toLocal());
  }

  // ── actions ────────────────────────────────────────────────────────────────
  /// Start a private 1:1 Listen Together with this bond's partner: pick the song
  /// (what's playing now, else choose one), then open the live session as host —
  /// the partner gets the "listen together" invite. Plays the bond a song in
  /// sync, exactly as the button promises.
  Future<void> _listenTogether() async {
    if (_others.isEmpty) {
      showToast(context, 'This space has no one to listen with yet.',
          type: ToastType.info);
      return;
    }
    // The opening song: what's already playing (one tap), else pick one.
    final playing = playbackBus.isPlaying?.call() ?? false;
    final curPath = playbackBus.currentPath?.call();
    String? path;
    int startPos = 0;
    if (playing && curPath != null && curPath.isNotEmpty) {
      path = curPath;
      startPos = playbackBus.currentPositionMs?.call() ?? 0;
    } else {
      path = await _pickSong();
    }
    if (path == null || !mounted) return;
    await _hostSession(path, startPos);
  }

  /// Open a live session as host playing `path` for the partner in sync. Shared
  /// by the Listen-together button, the tune-in card, and the playlist rows.
  Future<void> _hostSession(String path, int startPos) async {
    final others = _others;
    if (others.isEmpty) return;
    final partner = others.first;
    final partnerId = (partner['id'] as num?)?.toInt();
    final partnerName = (partner['username'] ?? 'them').toString();
    final myUserId = widget.myUserId;
    if (partnerId == null || myUserId == null) return;

    Uint8List bytes;
    try {
      bytes = Uint8List.fromList(await readFileBytes(path));
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not read that track.', type: ToastType.error);
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
    final token = await getToken();
    if (token == null || !mounted) return;
    // Stop the local player so the song isn't heard twice.
    playbackBus.onPause?.call();

    showDialog<void>(
      context: context,
      useRootNavigator: true, // top-level so the live popup owns its own route
      barrierDismissible: false,
      builder: (_) => LiveSessionScreen.host(
        token: token,
        myUserId: myUserId,
        receiverId: partnerId,
        audioBytes: bytes,
        title: _songTitle(path),
        peerName: partnerName,
        startPositionMs: startPos,
      ),
    );
  }

  String _songTitle(String path) {
    final name = path.split(RegExp(r'[\\/]+')).last;
    return name.replaceAll(RegExp(r'\.[^.]+$'), '');
  }

  Future<String?> _pickSong() async {
    final paths = List<String>.from(playlistNotifier.value);
    if (paths.isEmpty) {
      showToast(context, 'Open the music player and load some songs first.',
          type: ToastType.info);
      return null;
    }
    final scheme = Theme.of(context).colorScheme;
    final maxH = MediaQuery.of(context).size.height * 0.55;
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: _accent.withValues(alpha: 0.22)),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 24,
                offset: const Offset(0, 8)),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: scheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 12),
              Row(children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(Icons.headphones_rounded,
                      color: _accent, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Play together',
                          style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                              color: scheme.onSurface)),
                      Text('Pick a track you\'ll both hear in sync',
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxH),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: paths.length,
                    itemBuilder: (c, i) {
                      final t = _songTitle(paths[i]);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Material(
                          color: scheme.surfaceContainerHighest
                              .withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(14),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () => Navigator.pop(ctx, paths[i]),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              child: Row(children: [
                                Container(
                                  width: 40,
                                  height: 40,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: _accent.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(11),
                                  ),
                                  child: Icon(Icons.music_note_rounded,
                                      color: _accent, size: 19),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(t,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: scheme.onSurface)),
                                ),
                                const SizedBox(width: 8),
                                Icon(Icons.play_circle_fill_rounded,
                                    color: _accent, size: 26),
                              ]),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _sendMoment() async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _MomentComposer(accent: _accent),
    );
    if (result == null) return;
    final saved = await ApiService().addMoment(
      _id,
      kind: (result['kind'] ?? 'note').toString(),
      ref: result['ref'] as String?,
      caption: result['caption'] as String?,
    );
    if (!mounted) return;
    if (saved != null) {
      showToast(context, 'Moment pinned 💛', type: ToastType.success);
      _load();
      widget.onChanged?.call();
    } else {
      showToast(context, 'Could not save that moment', type: ToastType.error);
    }
  }

  /// "Thinking of you 💭" — the lightest touch across the bond. One tap fires a
  /// warm ping (socket + push) to the partner. No thread, no payload; just "I'm
  /// here". Debounced so a double-tap can't double-ping.
  Future<void> _nudge() async {
    if (_nudging) return;
    if (_partnerId == null) {
      showToast(context, 'No one to nudge in this space yet.',
          type: ToastType.info);
      return;
    }
    setState(() => _nudging = true);
    final ok = await ApiService().nudgePartner(_id);
    if (!mounted) return;
    setState(() => _nudging = false);
    showToast(
      context,
      ok ? 'Sent 💭 they will feel it' : 'Could not send — try again',
      type: ok ? ToastType.success : ToastType.error,
    );
  }

  // ── our playlist (shared crate) ─────────────────────────────────────────────
  /// Add a song to the shared crate: pick from your loaded library (title
  /// auto-filled) or type one by hand. Both partners see whatever lands here.
  Future<void> _addToPlaylist() async {
    if (_partnerId == null) {
      showToast(context, 'No one to build a playlist with yet.',
          type: ToastType.info);
      return;
    }
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _PlaylistAddSheet(accent: _accent),
    );
    if (result == null) return;
    final saved = await ApiService().addTrack(
      _id,
      title: (result['title'] ?? '').toString(),
      artist: result['artist'] as String?,
      ref: result['ref'] as String?,
    );
    if (!mounted) return;
    if (saved != null) {
      showToast(context, 'Added to your playlist 🎶', type: ToastType.success);
      _load();
    } else {
      showToast(context, 'Could not add that track', type: ToastType.error);
    }
  }

  Future<void> _removeTrackFromCrate(int trackId) async {
    final done = await ApiService().removeTrack(_id, trackId);
    if (!mounted) return;
    if (done) {
      _load();
    } else {
      showToast(context, 'Could not remove', type: ToastType.error);
    }
  }

  /// Play a crate track together — if I have that song in my own loaded library
  /// (matched by title), host it in sync; otherwise nudge me to load it first.
  Future<void> _playCrateTrack(Map<String, dynamic> track) async {
    final title = (track['title'] ?? '').toString().trim();
    final ref = (track['ref'] ?? '').toString().trim();
    // Prefer the adder's exact path if it happens to exist in my library, else
    // fall back to matching by title.
    final local = _localPathFor(ref, title);
    if (local == null) {
      showToast(
        context,
        'You do not have "$title" loaded — add it to your player to listen '
        'together.',
        type: ToastType.info,
      );
      return;
    }
    await _hostSession(local, 0);
  }

  String? _localPathFor(String ref, String title) {
    final paths = List<String>.from(playlistNotifier.value);
    if (ref.isNotEmpty && paths.contains(ref)) return ref;
    if (title.isEmpty) return null;
    final want = title.toLowerCase();
    for (final p in paths) {
      if (_songTitle(p).toLowerCase() == want) return p;
    }
    return null;
  }

  Future<void> _editSpace() async {
    // The settings sheet returns 'saved' (name/theme/hero changed), 'unpin'
    // (the user chose Unpin from inside settings), or null (dismissed).
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => _EditSpaceSheet(
        initialName: deriveSpaceName(_space, widget.myUserId),
        initialTheme: (_space['theme'] as String?) ?? 'coral',
        initialPrimary: _space['is_primary'] == true,
        spaceId: _id,
        initialBackgroundUrl: _space['background_url'] as String?,
        apiBase: widget.apiBase,
        onSpaceUpdated: (m) {
          if (mounted) setState(() => _space = m);
        },
      ),
      ),
    );
    if (!mounted) return;
    if (result == 'saved') {
      await _load();
      widget.onChanged?.call();
    } else if (result == 'unpin') {
      // Unpin now lives inside settings; run the same confirm-and-remove flow.
      await _unpin();
    }
  }

  Future<void> _unpin() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unpin this Space?'),
        content: const Text(
            'The relationship profile and its pinned moments are removed. Your '
            'friendship and chats stay exactly as they are.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Unpin'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final done = await ApiService().deleteSpace(_id);
    if (!mounted) return;
    if (done) {
      widget.onChanged?.call();
      Navigator.pop(context);
    } else {
      showToast(context, 'Could not unpin — try again', type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = deriveSpaceName(_space, widget.myUserId);
    final moments = ((_space['moments'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();

    // Back (Android system back button OR the edge-swipe-back gesture) should
    // step BACK THROUGH Our Space's own layers first — close an open nav drawer,
    // then a section → the dashboard — and only dismiss the whole page once
    // we're already on the dashboard. Without this, an edge swipe inside a
    // section popped the entire popup straight back to Harmony/Circle.
    final shell = AppPopupShell(
      title: 'Our Space',
      icon: Icons.favorite_rounded,
      // Our Space takes the WHOLE screen — an immersive, focused surface for the
      // couple, not a card floating over the app. The minimize control (below)
      // + the minimize-down animation bring you back out.
      fullScreen: true,
      // The dismiss control reads as "minimize" (paired with the minimize-down
      // exit animation), so ducking out to Circle feels like tucking the page
      // away rather than closing it.
      closeIcon: Icons.close_fullscreen_rounded,
      closeTooltip: 'Minimize',
      // A soft ambient backdrop (theme-tinted wash + corner glows) so the hero
      // and tiles float on atmosphere instead of a flat white sheet.
      backdrop: _pageBackdrop(scheme),
      // Header controls rendered as raised 3D chips to match the page's depth.
      raisedActions: true,
      // Wider than the default popup so the two-column (summary rail + content)
      // layout has real room on desktop/web/tablet. Narrow screens still get a
      // near-full-width card and the single-column stack.
      desktopMaxWidth: 940,
      // The default close chip is suppressed; Minimize lives inside the grouped
      // cluster below so the top-right reads as ONE connected control.
      showClose: false,
      headerAction: _headerCluster(scheme),
      // A section takes over the body as a full page BELOW this header (the
      // "Our Space" title + minimize stay visible); its own back arrow returns.
      // The two views cross-fade while the incoming one gently RISES and the
      // outgoing one SETTLES — so opening/closing a section eases in and out
      // instead of snapping, without the tile-anchored zoom (which read as too
      // busy for an in-body switch).
      builder: (context, isWide) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 340),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, anim) {
          final entering = child.key == const ValueKey('section');
          // The section rises up as it emerges; the dashboard settles back down
          // — so the two feel like one turning to the other, not a hard cut.
          final begin =
              entering ? const Offset(0, 0.05) : const Offset(0, -0.03);
          return FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position:
                  Tween<Offset>(begin: begin, end: Offset.zero).animate(anim),
              child: child,
            ),
          );
        },
        child: _section == null
            ? RefreshIndicator(
                key: const ValueKey('dashboard'),
                onRefresh: _load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                  children: _mainSections(scheme, title, moments),
                ),
              )
            : Padding(
                key: const ValueKey('section'),
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                child: _sectionScaffold(scheme),
              ),
      ),
    );

    return PopScope(
      // Only let the route itself pop when we're already at the top level (the
      // dashboard, no drawer showing). Otherwise we intercept back and unwind
      // one layer at a time below.
      canPop: _section == null && !_navDrawerOpen,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_navDrawerOpen) {
          setState(() => _navDrawerOpen = false);
        } else if (_section != null) {
          // Return to the Our Space dashboard instead of closing the page — the
          // section genies back into the tile it came from.
          setState(() => _section = null);
        }
      },
      child: shell,
    );
  }

  /// The page's ambient backdrop: a barely-there vertical wash of the Space
  /// colour top and bottom, plus two large soft glows drifting in from the
  /// corners — subtle atmosphere so the hero and tiles read as floating.
  Widget _pageBackdrop(ColorScheme scheme) {
    // Custom PHOTO background overrides the default motif theme.
    final bgUrl = (_space['background_url'] ?? '').toString().trim();
    if (bgUrl.isNotEmpty) {
      return _photoBackdrop(scheme, resolveAvatarUrl(bgUrl, widget.apiBase) ?? bgUrl);
    }
    Widget glow(double size, double alpha) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                _accent.withValues(alpha: alpha),
                _accent.withValues(alpha: 0),
              ],
            ),
          ),
        );
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _accent.withValues(alpha: 0.07),
            _accent.withValues(alpha: 0.0),
            _accent.withValues(alpha: 0.05),
          ],
          stops: const [0.0, 0.45, 1.0],
        ),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // DEFAULT theme: a dense, whisper-faint confetti of tiny hearts, music
          // notes, cherry blossoms + sparkle-hearts across the WHOLE page. The
          // motifs are plain shapes with no colour of their own — they INHERIT
          // the Space's chosen colour (_accent) at a hair of opacity, so it just
          // quietly fuels the romantic, music-y mood without fighting content.
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: RomanticPatternPainter(
                  color: _accent.withValues(
                      alpha: Theme.of(context).brightness == Brightness.dark
                          ? 0.06
                          : 0.055),
                ),
              ),
            ),
          ),
          Positioned(top: -110, right: -90, child: glow(300, 0.12)),
          Positioned(bottom: -140, left: -110, child: glow(340, 0.09)),
        ],
      ),
    );
  }

  /// A custom PHOTO background. On a portrait-ish area it fills with cover; on
  /// a WIDER-than-tall area (desktop/tablet) a single portrait can't cover the
  /// width, so it scales to full height and TILES horizontally — no blank space.
  /// A soft scrim keeps the hero, tiles and text readable over any photo.
  // Memoize the on-device lookup per background URL so rebuilds (resize,
  // setState) reuse the same Future instead of re-hitting disk/network.
  String? _bgFutureUrl;
  Future<File?>? _bgFuture;
  Future<File?> _bgFileFuture(String url, Map<String, String> headers) {
    if (_bgFutureUrl != url || _bgFuture == null) {
      _bgFutureUrl = url;
      _bgFuture = MediaStore.instance.getFile(url, headers);
    }
    return _bgFuture!;
  }

  Widget _photoBackdrop(ColorScheme scheme, String url) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final headers = mediaAuthHeaders(url);
    final veil = isDark ? Colors.black : Colors.white;
    return LayoutBuilder(
      builder: (ctx, c) {
        final wide = c.maxWidth > c.maxHeight;
        final fit = wide ? BoxFit.fitHeight : BoxFit.cover;
        final repeat = wide ? ImageRepeat.repeatX : ImageRepeat.noRepeat;
        return FutureBuilder<File?>(
          // Prefer the on-device copy (survives offline / a desktop restart);
          // fall back to the network image on the first, online view while it
          // downloads + persists.
          future: _bgFileFuture(url, headers),
          builder: (ctx, snap) {
            final ImageProvider provider = snap.data != null
                ? FileImage(snap.data!)
                : authNetworkImageProvider(url, headers);
            return Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    image: DecorationImage(
                      image: provider,
                      fit: fit,
                      repeat: repeat,
                      onError: (Object e, StackTrace? st) {},
                    ),
                  ),
                ),
                ValueListenableBuilder<double>(
                  valueListenable: wallpaperClarity,
                  builder: (_, _, _) => DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          veil.withValues(
                              alpha: wallpaperVeilAlpha(isDark ? 0.46 : 0.58)),
                          veil.withValues(
                              alpha: wallpaperVeilAlpha(isDark ? 0.34 : 0.42)),
                        ],
                      ),
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

  /// Everything lives on ONE calm surface: a compact hero, any live/contextual
  /// strips, a quick "thinking of you" pill, and a row of feature tiles. Each
  /// tile opens its details as an in-body section (see [_sectionScaffold]) so
  /// the growing content of the playlist, moments and diary never pushes this
  /// main card taller — it stays compact with every feature visible at a glance.
  List<Widget> _mainSections(
      ColorScheme scheme, String title, List<Map<String, dynamic>> moments) {
    final isPair = _partnerId != null;
    return [
      _header(scheme, title),
      _pendingPartnerBanner(scheme),
      _milestoneBanner(scheme),
      const SizedBox(height: 14),
      _tuneInCard(scheme),
      if (isPair) const SizedBox(height: 12),
      if (isPair) _dailyQuestionCard(scheme),
      _upcomingPlanBanner(scheme),
      if (isPair) _quickPill(scheme),
      if (isPair) const SizedBox(height: 14),
      _tilesSection(scheme, moments),
    ];
  }

  // ── feature tiles (each opens a floating card) ────────────────────────────
  Widget _tilesSection(ColorScheme scheme, List<Map<String, dynamic>> moments) {
    // Prefer the server COUNT fields (present in the light list payload too), so
    // the badges are correct on the very first paint instead of waiting for the
    // full lists to arrive on the follow-up fetch.
    int countOf(String key, int fallback) =>
        (_space[key] as num?)?.toInt() ?? fallback;
    final playlistCount = countOf(
        'playlist_count', ((_space['playlist'] as List?) ?? const []).length);
    final momentsCount = countOf('moment_count', moments.length);
    final diaryCount = countOf('diary_count', _diary.length);
    final tiles = <Widget>[
      if (_partnerId != null)
        _featureTile(scheme,
            tileKey: _kPlaylist,
            icon: Icons.queue_music_rounded,
            label: 'Our Playlist',
            count: playlistCount,
            subtitle: 'Songs + listen together',
            onTap: () => _openPlaylist(_globalCenter(_kPlaylist))),
      _featureTile(scheme,
          tileKey: _kMoments,
          icon: Icons.favorite_rounded,
          label: 'Pinned moments',
          count: momentsCount,
          subtitle: 'Dedications & notes',
          onTap: () => _openMoments(_globalCenter(_kMoments))),
      if (_partnerId != null)
        _featureTile(scheme,
            tileKey: _kDiary,
            icon: Icons.menu_book_rounded,
            label: 'Our Diary',
            count: diaryCount,
            subtitle: 'Memories & plans ahead',
            onTap: () => _openDiary(_globalCenter(_kDiary))),
      if (_partnerId != null)
        _featureTile(scheme,
            tileKey: _kDedications,
            icon: Icons.favorite_border_rounded,
            label: 'Dedications',
            count: countOf(
                'dedication_unopened',
                ((_space['dedications'] as List?) ?? const [])
                    .where((x) =>
                        x is Map && x['mine'] != true && x['opened'] != true)
                    .length),
            subtitle: 'A song as a feeling',
            onTap: () => _openDedications(_globalCenter(_kDedications))),
      _featureTile(scheme,
          tileKey: _kSong,
          icon: Icons.auto_awesome_rounded,
          label: 'Song & milestones',
          count: null,
          subtitle: _songSubtitle(),
          onTap: () => _openSongMilestones(_globalCenter(_kSong))),
    ];
    return LayoutBuilder(
      builder: (ctx, c) {
        // Compact horizontal tiles: full-width rows on a phone (roomy for the
        // title + subtitle), two-up only once there's real width (tablet/
        // desktop). No CrossAxisAlignment.stretch anywhere — the tiles size to
        // content, which also avoids the release-web intrinsic-measure bug.
        final twoCol = c.maxWidth >= 560;
        if (!twoCol) {
          return Column(
            children: [
              for (final t in tiles)
                Padding(padding: const EdgeInsets.only(bottom: 10), child: t),
            ],
          );
        }
        final rows = <Widget>[];
        for (var i = 0; i < tiles.length; i += 2) {
          // NB: no CrossAxisAlignment.stretch here. The tiles have a fixed
          // height (see _featureTile), so the two cells already match — and
          // stretch would force an intrinsic-height measurement of a tile whose
          // header row contains a Spacer/Expanded, which is illegal for a Flex
          // and silently breaks sizing + hit-testing in a release web build.
          rows.add(Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Expanded(child: tiles[i]),
                const SizedBox(width: 10),
                Expanded(
                    child: i + 1 < tiles.length
                        ? tiles[i + 1]
                        : const SizedBox()),
              ],
            ),
          ));
        }
        return Column(children: rows);
      },
    );
  }

  Widget _featureTile(
    ColorScheme scheme, {
    Key? tileKey,
    required IconData icon,
    required String label,
    required int? count,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    // Compact horizontal tile with depth: a raised, gently top-lit card (soft
    // drop shadow + faint top highlight + hairline rim) carrying a 3D icon chip,
    // the title + subtitle beside it, and the count/chevron trailing. Half the
    // height of the old stacked tile.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      key: tileKey,
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [scheme.surface, scheme.surfaceContainerHighest],
          ),
          border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.35)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
            BoxShadow(
              color: Colors.white.withValues(alpha: isDark ? 0.04 : 0.7),
              blurRadius: 1,
              spreadRadius: -1,
              offset: const Offset(0, -1),
            ),
          ],
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          hoverColor: _accent.withValues(alpha: 0.06),
          highlightColor: _accent.withValues(alpha: 0.05),
          splashColor: _accent.withValues(alpha: 0.10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                // 3D icon chip.
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(13),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        _accent.withValues(alpha: 0.24),
                        _accent.withValues(alpha: 0.12),
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: _accent.withValues(alpha: 0.22),
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(icon, color: _accent, size: 22),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                              color: scheme.onSurface)),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                // Fade + scale the count in when the fetch lands, rather than
                // snapping a badge out of nowhere.
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: ScaleTransition(scale: anim, child: child),
                  ),
                  child: (count != null && count > 0)
                      ? Padding(
                          key: ValueKey('badge$count'),
                          padding: const EdgeInsets.only(left: 8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: _accent.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text('$count',
                                style: TextStyle(
                                    color: _accent,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 12.5)),
                          ),
                        )
                      : const SizedBox.shrink(key: ValueKey('noBadge')),
                ),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right_rounded,
                    size: 20, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _songSubtitle() {
    final song = (_space['stats'] as Map?)?['your_song'];
    final title = (song is Map) ? (song['title'] ?? '').toString().trim() : '';
    return title.isNotEmpty ? title : 'Your bond details';
  }

  /// A quiet "thinking of you" pill — the lightest touch across the bond, kept
  /// as its own one-tap action (it has no details to open).
  Widget _quickPill(ColorScheme scheme) {
    // Opaque + bordered so it stands clear over any wallpaper (never dissolves).
    final fill =
        Color.alphaBlend(_accent.withValues(alpha: 0.16), scheme.surface);
    return Center(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Material(
          color: fill,
          borderRadius: BorderRadius.circular(24),
          child: InkWell(
            onTap: _nudging ? null : _nudge,
            borderRadius: BorderRadius.circular(24),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                    color: _accent.withValues(alpha: 0.45), width: 1.2),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _nudging
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: _accent),
                      )
                    : Icon(Icons.chat_bubble_rounded,
                        size: 16, color: _accent),
                const SizedBox(width: 8),
                Text('Thinking of you',
                    style: TextStyle(
                        color: _accent,
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5)),
              ],
            ),
            ),
          ),
        ),
      ),
    );
  }

  // Feature tiles now open IN-BODY as sections (see _sectionScaffold), so a
  // sidebar/drawer can jump between them without returning to the dashboard.
  void _openPlaylist([Offset? origin]) => _goSection('playlist');
  void _openMoments([Offset? origin]) => _goSection('moments');
  void _openSongMilestones([Offset? origin]) => _goSection('song');
  void _openDiary([Offset? origin]) => _goSection('diary');

  void _goSection(String key) =>
      setState(() {
        _section = key;
        _navDrawerOpen = false;
      });

  // ── Section navigation (master–detail) ────────────────────────────────────
  /// The sections available for this Space (playlist + diary only when paired).
  List<(String, IconData, String)> _visibleSections() {
    final pair = _partnerId != null;
    return [
      if (pair) ('playlist', Icons.queue_music_rounded, 'Our Playlist'),
      ('moments', Icons.favorite_rounded, 'Pinned moments'),
      if (pair) ('diary', Icons.menu_book_rounded, 'Our Diary'),
      if (pair)
        ('dedications', Icons.favorite_border_rounded, 'Dedications'),
      ('song', Icons.auto_awesome_rounded, 'Song & milestones'),
    ];
  }

  /// Wide: a persistent left rail beside the content. Narrow: the content full
  /// width with a left DRAWER (the same rail) that slides in over it — opened by
  /// the header's list button, dismissed by tapping out, its minimize button, or
  /// a swipe to the left.
  Widget _sectionScaffold(ColorScheme scheme) {
    return LayoutBuilder(
      builder: (ctx, c) {
        final wide = c.maxWidth >= 720;
        final content = _sectionContent(
          scheme,
          wide,
          _section!,
          onMenu: wide ? null : () => setState(() => _navDrawerOpen = true),
        );
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 214, child: _sectionSidebar(scheme)),
              const SizedBox(width: 12),
              Expanded(child: content),
            ],
          );
        }
        final drawerW = (c.maxWidth * 0.74).clamp(230.0, 330.0);
        return Stack(
          children: [
            Positioned.fill(child: content),
            // Scrim — fades in with the drawer; tap or swipe-left dismisses.
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_navDrawerOpen,
                child: GestureDetector(
                  onTap: () => setState(() => _navDrawerOpen = false),
                  onHorizontalDragEnd: (d) {
                    if ((d.primaryVelocity ?? 0) < 0) {
                      setState(() => _navDrawerOpen = false);
                    }
                  },
                  child: AnimatedOpacity(
                    opacity: _navDrawerOpen ? 1 : 0,
                    duration: const Duration(milliseconds: 260),
                    child:
                        Container(color: Colors.black.withValues(alpha: 0.4)),
                  ),
                ),
              ),
            ),
            // The drawer — slides in from the left; swipe-left to close.
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              top: 0,
              bottom: 0,
              width: drawerW,
              left: _navDrawerOpen ? 0 : -(drawerW + 24),
              child: GestureDetector(
                onHorizontalDragEnd: (d) {
                  if ((d.primaryVelocity ?? 0) < 0) {
                    setState(() => _navDrawerOpen = false);
                  }
                },
                child: _sectionSidebar(
                  scheme,
                  onClose: () => setState(() => _navDrawerOpen = false),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// The section list rail: couple badge on top, then the sections with the
  /// active one highlighted. [onClose] (drawer mode) adds a minimize button.
  Widget _sectionSidebar(ColorScheme scheme, {VoidCallback? onClose}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // In DRAWER mode (onClose != null) the card is flush to the screen edge and
    // runs the full page height, so rounding its OUTER (left/top/bottom) corners
    // just exposes the dimmed page behind as dark notches. Square those; round
    // only the inner RIGHT edge that floats over the content.
    final drawer = onClose != null;
    final radius = drawer
        ? const BorderRadius.horizontal(right: Radius.circular(18))
        : BorderRadius.circular(18);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? [scheme.surfaceContainerHigh, scheme.surfaceContainer]
              : [Colors.white, scheme.surfaceContainerHighest],
        ),
        border: Border.all(color: _accent.withValues(alpha: 0.20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.42 : 0.14),
            blurRadius: 18,
            // Cast the shadow to the RIGHT (over the content) in drawer mode so
            // it never darkens the flush left edge; straight down for the rail.
            offset: drawer ? const Offset(6, 0) : const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (onClose != null)
                Align(
                  alignment: Alignment.topRight,
                  child: HeaderActionButton(
                    icon: Icons.chevron_left_rounded,
                    tooltip: 'Hide',
                    onPressed: onClose,
                  ),
                ),
              _sidebarCoupleHeader(scheme),
              const SizedBox(height: 10),
              Divider(
                  height: 1,
                  color: scheme.outlineVariant.withValues(alpha: 0.5)),
              const SizedBox(height: 8),
              for (final s in _visibleSections()) _sidebarItem(scheme, s),
              // The "Thinking of you 💭" nudge — the lightest touch across the
              // bond — sits below the section list as a special action, so it's
              // always one tap away from any section (wide rail AND mobile
              // drawer), not just the dashboard.
              if (_partnerId != null) ...[
                const SizedBox(height: 6),
                Divider(
                    height: 1,
                    color: scheme.outlineVariant.withValues(alpha: 0.5)),
                const SizedBox(height: 12),
                _quickPill(scheme),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _sidebarCoupleHeader(ColorScheme scheme) {
    final title = deriveSpaceName(_space, widget.myUserId);
    final partner = _others.isNotEmpty ? _others.first : null;
    // A little HERO cap in the Space's own colour — the same warm gradient as
    // the dashboard banner — so the couple badges sit on their bond's colour
    // instead of a flat panel, giving the sidebar/drawer a bright anchor on top.
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _accent,
            _accent.withValues(alpha: 0.74),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: _accent.withValues(alpha: 0.34),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          SizedBox(
            width: 70,
            height: 44,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                    left: 0,
                    top: 1,
                    child: diaryAuthorBadge(
                        name: widget.myName ?? 'You',
                        imageUrl: widget.myAvatarUrl,
                        radius: 19)),
                Positioned(
                    right: 0,
                    top: 1,
                    child: diaryAuthorBadge(
                        name: (partner?['username'] ?? '?').toString(),
                        imageUrl: _full(partner?['avatar_url']),
                        radius: 19)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(title,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  color: Colors.white)),
        ],
      ),
    );
  }

  /// How many items a section holds, for the sidebar badges (null = no count,
  /// e.g. Song & milestones). Uses the server COUNT fields with a live fallback.
  int? _sectionCount(String key) {
    switch (key) {
      case 'playlist':
        return (_space['playlist_count'] as num?)?.toInt() ??
            ((_space['playlist'] as List?) ?? const []).length;
      case 'moments':
        return (_space['moment_count'] as num?)?.toInt() ??
            ((_space['moments'] as List?) ?? const []).length;
      case 'diary':
        return (_space['diary_count'] as num?)?.toInt() ?? _diary.length;
      case 'dedications':
        return ((_space['dedications'] as List?) ?? const []).length;
      default:
        return null;
    }
  }

  Widget _sidebarItem(ColorScheme scheme, (String, IconData, String) s) {
    final active = _section == s.$1;
    final count = _sectionCount(s.$1);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: active ? null : () => _goSection(s.$1),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: const EdgeInsets.fromLTRB(8, 11, 10, 11),
            decoration: BoxDecoration(
              color:
                  active ? _accent.withValues(alpha: 0.14) : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: active
                      ? _accent.withValues(alpha: 0.5)
                      : Colors.transparent),
            ),
            child: Row(
              children: [
                // Active "rail" indicator — a short accent bar on the left. A
                // fixed-width slot (transparent when idle) keeps every icon
                // aligned whether or not the bar is showing.
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 3,
                  height: active ? 18 : 0,
                  decoration: BoxDecoration(
                    color: active ? _accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(s.$2,
                    size: 18,
                    color: active ? _accent : scheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(s.$3,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight:
                              active ? FontWeight.w800 : FontWeight.w600,
                          color: active ? _accent : scheme.onSurface)),
                ),
                if (count != null && count > 0) ...[
                  const SizedBox(width: 8),
                  _sidebarCountBadge(count, active),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A small count pill on a sidebar row — filled accent on the active row,
  /// a faint accent tint on the others.
  Widget _sidebarCountBadge(int count, bool active) {
    return Container(
      constraints: const BoxConstraints(minWidth: 22),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: active ? _accent : _accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('$count',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: active ? Colors.white : _accent)),
    );
  }

  /// The content for a section. Diary keeps its own book header; the others use
  /// a shared panel (back to dashboard + optional list button + body + footer).
  Widget _sectionContent(ColorScheme scheme, bool isWide, String section,
      {VoidCallback? onMenu}) {
    switch (section) {
      case 'diary':
        return _diaryBookView(scheme, isWide, onMenu: onMenu);
      case 'playlist':
        final tracks = ((_space['playlist'] as List?) ?? const [])
            .whereType<Map>()
            .map((t) => Map<String, dynamic>.from(t))
            .toList();
        return _sectionPanel(
          scheme,
          Icons.queue_music_rounded,
          'Our Playlist',
          onMenu: onMenu,
          body: tracks.isEmpty
              ? _playlistEmpty(scheme)
              : Column(
                  children: [for (final t in tracks) _trackRow(scheme, t)]),
          footer: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _listenTogether,
                  style: FilledButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white),
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  label: const Text('Listen together'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _addToPlaylist,
                  style: OutlinedButton.styleFrom(
                      foregroundColor: _accent,
                      side:
                          BorderSide(color: _accent.withValues(alpha: 0.6))),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add song'),
                ),
              ),
            ],
          ),
        );
      case 'moments':
        final moments = ((_space['moments'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
        return _sectionPanel(
          scheme,
          Icons.favorite_rounded,
          'Pinned moments',
          onMenu: onMenu,
          body: moments.isEmpty
              ? _momentsEmpty(scheme)
              : Column(
                  children: [for (final m in moments) _momentCard(scheme, m)]),
          footer: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _sendMoment,
              style: FilledButton.styleFrom(
                  backgroundColor: _accent, foregroundColor: Colors.white),
              icon: const Icon(Icons.favorite_border_rounded, size: 18),
              label: const Text('Send a moment'),
            ),
          ),
        );
      case 'dedications':
        return _sectionPanel(
          scheme,
          Icons.favorite_border_rounded,
          'Dedications',
          onMenu: onMenu,
          body: _dedicationsBody(scheme),
          footer: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _composeDedication,
              style: FilledButton.styleFrom(
                  backgroundColor: _accent, foregroundColor: Colors.white),
              icon: const Icon(Icons.favorite_rounded, size: 18),
              label: const Text('Dedicate a song'),
            ),
          ),
        );
      case 'song':
        final stats = (_space['stats'] as Map?) ?? const {};
        final song = stats['your_song'];
        final next = stats['next_milestone'];
        final hasHint =
            next is Map && ((next['remaining'] as num?)?.toInt() ?? 0) > 0;
        final days = (stats['days_in_song'] as num?)?.toInt() ?? 0;
        final streak = (stats['listen_streak'] as num?)?.toInt() ?? 0;
        return _sectionPanel(
          scheme,
          Icons.auto_awesome_rounded,
          'Song & milestones',
          onMenu: onMenu,
          body: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  _accent.withValues(alpha: 0.10),
                  scheme.surfaceContainerHighest.withValues(alpha: 0.35),
                ],
              ),
              border: Border.all(color: _accent.withValues(alpha: 0.18)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _yourSongInner(scheme, song),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                        child: _detailStat(scheme, '🎧', '$days',
                            days == 1 ? 'day in a song' : 'days in a song')),
                    const SizedBox(width: 10),
                    Expanded(
                        child: _detailStat(scheme, '🔥', '$streak',
                            streak == 1 ? 'day streak' : 'day streak')),
                  ],
                ),
                if (hasHint) ...[
                  const SizedBox(height: 14),
                  _nextMilestoneHint(scheme),
                ],
              ],
            ),
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  /// A section's chrome: header (optional list button + back to dashboard +
  /// icon + title), a scrolling body, and an optional footer bar.
  Widget _sectionPanel(
    ColorScheme scheme,
    IconData icon,
    String title, {
    required Widget body,
    Widget? footer,
    VoidCallback? onMenu,
  }) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 2, 2, 8),
          child: Row(
            children: [
              // The same connected nav pill the Diary page uses (Sections | Back)
              // so every section header reads as one unit, not two loose chips.
              _diaryNavCluster(scheme, onMenu),
              const SizedBox(width: 10),
              Icon(icon, color: _accent, size: 20),
              const SizedBox(width: 6),
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: scheme.onSurface)),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(2, 2, 2, 8),
            child: body,
          ),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 2),
            child: footer,
          ),
      ],
    );
  }

  // ── Our Diary — the full-page book ────────────────────────────────────────
  /// The diary as a book: a slim back bar, then the memories as ruled-paper
  /// pages you turn one at a time, and a "write" button. Plans sit behind a
  /// small chip so the book stays about memories.
  Widget _diaryBookView(ColorScheme scheme, bool isWide,
      {VoidCallback? onMenu}) {
    // Read like a journal: oldest memory first, newest last.
    final mems = List<Map<String, dynamic>>.from(_memories)
      ..sort((a, b) => (a['created_at'] ?? '')
          .toString()
          .compareTo((b['created_at'] ?? '').toString()));
    return Column(
      children: [
        // (List button on narrow) + back to the dashboard + title + page count.
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 2, 2, 8),
          child: Row(
            children: [
              // ONE segmented nav control (sections | back on narrow, just back
              // on wide) instead of two separate chips crowding the corner.
              _diaryNavCluster(scheme, onMenu),
              const SizedBox(width: 10),
              Icon(Icons.menu_book_rounded, color: _accent, size: 20),
              const SizedBox(width: 6),
              // Just "Diary" here — "Our Diary" reads awkwardly right beneath the
              // "Our Space" app header.
              Text('Diary',
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: scheme.onSurface)),
              const Spacer(),
              // Page count is already shown by the dots below — no separate label.
            ],
          ),
        ),
        Expanded(
          child: mems.isEmpty
              ? SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: _diaryEmpty(scheme))
              : Stack(
                  children: [
                    Positioned.fill(
                      // Let a mouse/trackpad DRAG turn pages on desktop, just
                      // like a finger swipe on mobile (PageView ignores mouse
                      // drag by default).
                      child: ScrollConfiguration(
                        behavior: ScrollConfiguration.of(context).copyWith(
                          dragDevices: const {
                            PointerDeviceKind.touch,
                            PointerDeviceKind.mouse,
                            PointerDeviceKind.trackpad,
                            PointerDeviceKind.stylus,
                          },
                        ),
                        child: PageView.builder(
                        controller: _diaryPageCtrl,
                        itemCount: mems.length,
                        onPageChanged: (i) =>
                            setState(() => _diaryPage = i),
                        itemBuilder: (ctx, i) => AnimatedBuilder(
                          animation: _diaryPageCtrl,
                          builder: (ctx, child) {
                            // Turning-page depth: the centred page is full size,
                            // neighbours shrink slightly like leaves of a book.
                            double t = 0;
                            if (_diaryPageCtrl.hasClients &&
                                _diaryPageCtrl.position.hasContentDimensions) {
                              t = (_diaryPageCtrl.page ?? i.toDouble()) - i;
                            }
                            final scale =
                                (1 - (t.abs() * 0.10)).clamp(0.88, 1.0);
                            return Center(
                              child:
                                  Transform.scale(scale: scale, child: child),
                            );
                          },
                          child: _memoryBookPage(
                              scheme, mems[i], i, mems.length),
                        ),
                        ),
                      ),
                    ),
                    // Page turning now lives on the page itself as a DOG-EAR
                    // corner you tap or drag (see _memoryBookPage) — more
                    // book-like, and it never covers the writing.
                  ],
                ),
        ),
        // Page dots — which page you're on, and how many there are.
        if (mems.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (int i = 0; i < mems.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _diaryPage ? 18 : 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: i == _diaryPage
                          ? _accent
                          : _accent.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
              ],
            ),
          ),
        _diaryPlansStrip(scheme),
        // Raised 3D write button — full width on a phone, a centred pill capped
        // at a comfortable width on tablet/desktop so it never stretches edge to
        // edge on a big screen.
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 2),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: SizedBox(
                width: double.infinity,
                child: _diaryWriteButton(scheme),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// The header's control cluster, folded into ONE connected pill
  /// (Space settings · menu · minimize) — the same segmented treatment as the
  /// section nav pill — so the top-right reads as a single unit, not three
  /// scattered chips.
  Widget _headerCluster(ColorScheme scheme) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Widget seg(IconData icon, String tip, VoidCallback onTap) => Tooltip(
          message: tip,
          child: InkResponse(
            onTap: onTap,
            radius: 24,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              child: Icon(icon, size: 20, color: _accent),
            ),
          ),
        );
    Widget divider() => Container(
        width: 1, height: 22, color: _accent.withValues(alpha: 0.22));
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [scheme.surfaceContainerHigh, scheme.surfaceContainer]
              : [Colors.white, scheme.surfaceContainerHighest],
        ),
        border: Border.all(color: _accent.withValues(alpha: 0.45)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.36 : 0.12),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            seg(Icons.tune_rounded, 'Space settings', _editSpace),
            if (widget.mainMenuBuilder != null) ...[
              divider(),
              // The platform ⋮ menu, tinted to the accent so it belongs to the
              // cluster rather than floating as a separate control.
              IconTheme.merge(
                data: IconThemeData(color: _accent, size: 20),
                child: widget.mainMenuBuilder!(context),
              ),
            ],
            divider(),
            seg(Icons.close_fullscreen_rounded, 'Minimize', () {
              FocusScope.of(context).unfocus();
              Navigator.of(context).pop();
            }),
          ],
        ),
      ),
    );
  }

  /// The section header's single segmented nav control, shared by every Our
  /// Space section (Diary, Pinned moments, Playlist, …): on narrow screens it
  /// holds [sections | back] as one connected pill; on wide screens (no drawer)
  /// it's just [back]. One unit reads calmer than two separate floating chips.
  Widget _diaryNavCluster(ColorScheme scheme, VoidCallback? onMenu) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Widget seg(IconData icon, String tip, VoidCallback onTap) => Tooltip(
          message: tip,
          child: InkResponse(
            onTap: onTap,
            radius: 26,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Icon(icon, size: 20, color: _accent),
            ),
          ),
        );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [scheme.surfaceContainerHigh, scheme.surfaceContainer]
              : [Colors.white, scheme.surfaceContainerHighest],
        ),
        border: Border.all(color: _accent.withValues(alpha: 0.45)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.36 : 0.12),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onMenu != null) ...[
              seg(Icons.view_sidebar_rounded, 'Sections', onMenu),
              Container(
                  width: 1,
                  height: 22,
                  color: _accent.withValues(alpha: 0.22)),
            ],
            seg(Icons.arrow_back_rounded, 'Back',
                () => setState(() => _section = null)),
          ],
        ),
      ),
    );
  }

  /// One memory rendered as a page of ruled paper, in its AUTHOR's font. Shows
  /// only the author's photo (no name); readers can react + comment; only the
  /// author gets the edit/delete menu.
  Widget _memoryBookPage(
      ColorScheme scheme, Map<String, dynamic> e, int index, int total) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final title = (e['title'] ?? '').toString().trim();
    final body = (e['body'] ?? '').toString().trim();
    final mine = e['mine'] == true;
    final author = (e['author'] as Map?)?.cast<String, dynamic>();
    final created = DateTime.tryParse((e['created_at'] ?? '').toString());
    final font = diaryFontFamily((e['font'] ?? '').toString());
    final paper = isDark ? const Color(0xFF211B17) : const Color(0xFFFFFDF5);
    final ink = isDark ? const Color(0xFFEDE6DD) : const Color(0xFF352A20);
    final rule = (isDark ? Colors.white : _accent)
        .withValues(alpha: isDark ? 0.06 : 0.10);
    final commentCount = (e['comment_count'] as num?)?.toInt() ?? 0;
    // Who signs the entry — real username, or the reader's own name for a memory
    // they wrote before the author record hydrates.
    final signName = ((author?['username'] ?? '').toString().trim().isNotEmpty)
        ? (author!['username']).toString().trim()
        : (mine ? (widget.myName ?? '').trim() : '');
    void turn(int dir) {
      final target = index + dir;
      if (target < 0 || target >= total) return;
      _diaryPageCtrl.animateToPage(target,
          duration: const Duration(milliseconds: 340),
          curve: Curves.easeOutCubic);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              color: paper,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _accent.withValues(alpha: 0.20)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.42 : 0.16),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: CustomPaint(
          painter: _RuledPaperPainter(
            line: rule,
            margin: _accent.withValues(alpha: 0.28),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Author photo only (no name), the time, and the author's menu.
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 8, 6),
                child: Row(
                  children: [
                    diaryAuthorBadge(
                      name: (author?['username'] ?? '?').toString(),
                      imageUrl: _full(author?['avatar_url']),
                      radius: 15,
                    ),
                    const Spacer(),
                    if (created != null)
                      Text(_diaryAgo(created),
                          style: TextStyle(
                              fontSize: 11.5,
                              color: ink.withValues(alpha: 0.6))),
                    if (mine) _memoryMenuButton(e, ink),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(52, 2, 20, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (title.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(title,
                              style: TextStyle(
                                  fontFamily: font,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 19,
                                  height: 1.6,
                                  color: ink)),
                        ),
                      Text(body,
                          style: TextStyle(
                              fontFamily: font,
                              fontSize: 15.5,
                              height: 1.9,
                              color: ink.withValues(alpha: 0.92))),
                    ],
                  ),
                ),
              ),
              // Sign off like a love letter — the author's name in a hand plus
              // the full date, sitting low on the page, so a short memory's
              // blank ruled space reads as a CLOSED entry, not an unfinished one.
              if (signName.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 22, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('❦',
                          style: TextStyle(
                              fontSize: 14,
                              color: _accent.withValues(alpha: 0.55))),
                      Text('— $signName',
                          style: TextStyle(
                              // Signed in the author's chosen hand; Classic
                              // still flourishes in handwriting.
                              fontFamily: font ?? diaryFontFamily('handwriting'),
                              fontSize: 20,
                              height: 1.15,
                              color: ink.withValues(alpha: 0.9))),
                      if (created != null)
                        Text(
                            DateFormat('d MMMM yyyy')
                                .format(created.toLocal()),
                            style: TextStyle(
                                fontSize: 10.5,
                                color: ink.withValues(alpha: 0.5))),
                    ],
                  ),
                ),
              // Footer: reactions + comment on one clean strip.
              Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      (isDark ? Colors.white : _accent)
                          .withValues(alpha: isDark ? 0.05 : 0.03),
                      (isDark ? Colors.black : _accent)
                          .withValues(alpha: isDark ? 0.20 : 0.07),
                    ],
                  ),
                  border: Border(
                      top: BorderSide(color: _accent.withValues(alpha: 0.14))),
                ),
                child: LayoutBuilder(
                  builder: (ctx, c) {
                    final reactions = diaryReactionRow(
                      scheme: scheme,
                      accent: _accent,
                      entry: e,
                      onToggle: (em) => _reactDiary(e, em),
                      onAdd: () async {
                        final em = await pickDiaryReaction(context, _accent);
                        if (em != null) _reactDiary(e, em);
                      },
                    );
                    // One strip always: reactions take the room they need, the
                    // comment button trails — compact (icon + count) on a phone
                    // so the two never have to stack onto two rows.
                    final compact = c.maxWidth < 440;
                    final commentPill = _diaryCommentPill(scheme, commentCount,
                        () => _openMemoryDetail(e),
                        compact: compact);
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(child: reactions),
                        const SizedBox(width: 8),
                        commentPill,
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
          ),
          // Dog-ear page-turn corners ON the page: bottom-right turns to the
          // next memory, bottom-left to the previous — tap the fold, or keep
          // swiping/dragging the page. Shown only when a page exists that way,
          // tucked exactly into the paper's corner.
          if (index < total - 1)
            Positioned(
              right: 6,
              bottom: 4,
              child: _DiaryDogEar(
                isNext: true,
                paper: paper,
                accent: _accent,
                isDark: isDark,
                onTap: () => turn(1),
              ),
            ),
          if (index > 0)
            Positioned(
              left: 6,
              bottom: 4,
              child: _DiaryDogEar(
                isNext: false,
                paper: paper,
                accent: _accent,
                isDark: isDark,
                onTap: () => turn(-1),
              ),
            ),
        ],
      ),
    );
  }

  /// Edit/Delete menu — only ever shown on the author's own memory.
  /// The raised 3D "Write in our diary" button (gradient body, down-shadow +
  /// top highlight, press-sink) — the app's depth language on the primary CTA.
  Widget _diaryWriteButton(ColorScheme scheme) {
    return _PressableRaised(
      onTap: _addDiaryEntry,
      radius: 16,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.lerp(_accent, Colors.white, 0.14)!,
          _accent,
          Color.lerp(_accent, Colors.black, 0.20)!,
        ],
      ),
      border: Border.all(color: Colors.white.withValues(alpha: 0.20)),
      shadows: [
        BoxShadow(
          color: _accent.withValues(alpha: 0.45),
          blurRadius: 16,
          offset: const Offset(0, 8),
        ),
        BoxShadow(
          color: Colors.white.withValues(alpha: 0.22),
          blurRadius: 1,
          spreadRadius: -1,
          offset: const Offset(0, -1),
        ),
      ],
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.edit_rounded, size: 18, color: Colors.white),
            SizedBox(width: 8),
            Text('Write in our diary',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 15)),
          ],
        ),
      ),
    );
  }

  /// The raised 3D comment pill in a memory's footer.
  Widget _diaryCommentPill(
      ColorScheme scheme, int count, VoidCallback onTap,
      {bool compact = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return _PressableRaised(
      onTap: onTap,
      radius: 22,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          isDark ? scheme.surfaceContainerHigh : Colors.white,
          isDark ? scheme.surfaceContainer : scheme.surfaceContainerHighest,
        ],
      ),
      border: Border.all(color: _accent.withValues(alpha: 0.45)),
      shadows: [
        BoxShadow(
          color: Colors.black.withValues(alpha: isDark ? 0.40 : 0.12),
          blurRadius: 8,
          offset: const Offset(0, 3),
        ),
        BoxShadow(
          color: Colors.white.withValues(alpha: isDark ? 0.05 : 0.9),
          blurRadius: 1,
          spreadRadius: -1,
          offset: const Offset(0, -1),
        ),
      ],
      child: Padding(
        padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 14, vertical: 9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mode_comment_outlined, size: 16, color: _accent),
            const SizedBox(width: 6),
            // Compact (phone footer): just the count, so it never forces a
            // second row. Full: the worded label + a chevron affordance.
            Text(
                compact
                    ? (count == 0 ? '0' : '$count')
                    : (count == 0
                        ? 'Comment'
                        : '$count ${count == 1 ? 'comment' : 'comments'}'),
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: _accent)),
            if (!compact)
              Icon(Icons.chevron_right_rounded, size: 16, color: _accent),
          ],
        ),
      ),
    );
  }

  Widget _memoryMenuButton(Map<String, dynamic> e, Color ink) {
    final scheme = Theme.of(context).colorScheme;
    Widget row(IconData icon, String label, Color color) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 12),
            Text(label,
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600, color: color)),
          ],
        );
    return PopupMenuButton<String>(
      tooltip: 'Options',
      // Drop UNDER the trigger, styled like the app's other menus: rounded with
      // a soft accent hairline, iconized rows, and a clearly destructive Delete.
      icon: Icon(Icons.more_horiz_rounded,
          size: 18, color: ink.withValues(alpha: 0.6)),
      color: scheme.surface,
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: 0.28),
      position: PopupMenuPosition.under,
      menuPadding: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: _accent.withValues(alpha: 0.35), width: 1),
      ),
      onSelected: (v) {
        if (v == 'edit') {
          _editDiaryEntry(e);
        } else if (v == 'delete') {
          _deleteDiaryEntry(e);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'edit',
          height: 42,
          child: row(Icons.edit_outlined, 'Edit', scheme.onSurface),
        ),
        PopupMenuItem(
          enabled: false,
          height: 8,
          padding: EdgeInsets.zero,
          child: Divider(
              height: 1,
              thickness: 1,
              indent: 12,
              endIndent: 12,
              color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        PopupMenuItem(
          value: 'delete',
          height: 42,
          child: row(Icons.delete_outline_rounded, 'Delete', scheme.error),
        ),
      ],
    );
  }

  /// A small chip that opens the couple's upcoming plans (kept out of the book
  /// so the pages stay about memories). Hidden when there are no plans.
  Widget _diaryPlansStrip(ColorScheme scheme) {
    final plans = _plans;
    if (plans.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => _showPlansSheet(scheme),
        icon: const Text('🗓️', style: TextStyle(fontSize: 14)),
        label: Text('Plans ahead (${plans.length})',
            style: TextStyle(
                color: _accent, fontWeight: FontWeight.w600, fontSize: 13)),
      ),
    );
  }

  void _showPlansSheet(ColorScheme scheme) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _diarySectionLabel(scheme, 'Plans ahead', '🗓️'),
              const SizedBox(height: 10),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: [for (final e in _plans) _planRow(scheme, e)],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── header ───────────────────────────────────────────────────────────────
  Widget _header(ColorScheme scheme, String title) {
    final others = _others;
    final stats = (_space['stats'] as Map?) ?? const {};
    final days = (stats['days_in_song'] as num?)?.toInt() ?? 0;
    final streak = (stats['listen_streak'] as num?)?.toInt() ?? 0;
    final hasStats = others.isNotEmpty && (days > 0 || streak > 0);

    // The identity block: avatars, name, close-since — always centred.
    final identity = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _overlappedAvatars(others),
        const SizedBox(height: 12),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
            shadows: [
              Shadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: 6,
                offset: const Offset(0, 1.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 5),
        Text(
          'Close since ${_closeSince()}',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.92),
            fontSize: 12.5,
            shadows: [
              Shadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
            ],
          ),
        ),
      ],
    );

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _accent.withValues(alpha: 0.95),
            _accent.withValues(alpha: 0.55),
          ],
        ),
        // A soft coloured lift so the whole banner floats off the surface.
        boxShadow: [
          BoxShadow(
            color: _accent.withValues(alpha: 0.32),
            blurRadius: 22,
            spreadRadius: -6,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Stack(
        children: [
          // Top-lit sheen: a faint white glow from above, so the banner reads
          // as a gently curved, lit surface rather than a flat colour fill.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: RadialGradient(
                    center: const Alignment(0, -1.05),
                    radius: 1.1,
                    colors: [
                      Colors.white.withValues(alpha: 0.22),
                      Colors.white.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            child: LayoutBuilder(
              builder: (ctx, c) {
          // Layout is decided by the PARTNER + width, not by whether stats have
          // loaded yet — so the slots are reserved up-front and the numbers just
          // FADE IN when the fetch lands, instead of snapping in and shoving the
          // avatars around. `hasStats` only controls opacity.
          const statFade = Duration(milliseconds: 340);
          final hasPartner = others.isNotEmpty;
          final wide = c.maxWidth >= 440;
          if (hasPartner && wide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: AnimatedOpacity(
                      opacity: hasStats ? 1 : 0,
                      duration: statFade,
                      curve: Curves.easeOut,
                      child: _heroSideStat('🔥', '$streak', 'day streak'),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: identity,
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: AnimatedOpacity(
                      opacity: hasStats ? 1 : 0,
                      duration: statFade,
                      curve: Curves.easeOut,
                      child: _heroSideStat('🎧', '$days',
                          days == 1 ? 'day in a song' : 'days in a song'),
                    ),
                  ),
                ),
              ],
            );
          }
          return Column(
            children: [
              identity,
              if (hasPartner)
                AnimatedOpacity(
                  opacity: hasStats ? 1 : 0,
                  duration: statFade,
                  curve: Curves.easeOut,
                  child: _heroStats(),
                ),
            ],
          );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// A frosted "glass" stat chip beside the identity in the wide hero. Both
  /// chips share ONE fixed size ([_kHeroStatW] × [_kHeroStatH]) so they read as
  /// a matched pair, and that size is kept a touch smaller than the avatar
  /// cluster so the two photos stay the anchor of the banner.
  Widget _heroSideStat(String emoji, String value, String label) {
    const glyphShadow = Shadow(
      color: Color(0x33000000),
      blurRadius: 3,
      offset: Offset(0, 1),
    );
    return SizedBox(
      width: _kHeroStatW,
      height: _kHeroStatH,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          // Frosted glass: brighter at the top, dimmer at the base — a lit facet.
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: 0.30),
              Colors.white.withValues(alpha: 0.12),
            ],
          ),
          border: Border.all(color: Colors.white.withValues(alpha: 0.45)),
          boxShadow: [
            // Cast shadow (depth) + a soft top highlight (bevel).
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.14),
              blurRadius: 10,
              offset: const Offset(0, 5),
            ),
            BoxShadow(
              color: Colors.white.withValues(alpha: 0.25),
              blurRadius: 1,
              spreadRadius: -1,
              offset: const Offset(0, -1),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(emoji,
                    style: const TextStyle(fontSize: 15, shadows: [glyphShadow])),
                const SizedBox(width: 5),
                Text(value,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                        shadows: [glyphShadow])),
              ],
            ),
            const SizedBox(height: 1),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    shadows: [glyphShadow])),
          ],
        ),
      ),
    );
  }

  /// A slim, at-a-glance pair of listening stats woven into the hero itself, so
  /// the main surface shows the pulse of the bond without a separate grey bar.
  /// The moments count now lives on its tile, so it isn't repeated here.
  Widget _heroStats() {
    final stats = (_space['stats'] as Map?) ?? const {};
    final days = (stats['days_in_song'] as num?)?.toInt() ?? 0;
    final streak = (stats['listen_streak'] as num?)?.toInt() ?? 0;
    // NB: always renders (no early shrink) so the caller can reserve its space
    // and fade it in when the stats load — the visibility is controlled by the
    // AnimatedOpacity in _header, not by returning an empty box here.
    const glyphShadow = Shadow(
      color: Color(0x33000000),
      blurRadius: 3,
      offset: Offset(0, 1),
    );
    // Each stat is a small frosted pill so it lifts off the banner colour.
    Widget chip(String emoji, String value, String label) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white.withValues(alpha: 0.28),
                Colors.white.withValues(alpha: 0.12),
              ],
            ),
            border: Border.all(color: Colors.white.withValues(alpha: 0.42)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(emoji,
                  style: const TextStyle(fontSize: 12, shadows: [glyphShadow])),
              const SizedBox(width: 5),
              Text(value,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 12.5,
                      shadows: [glyphShadow])),
              const SizedBox(width: 4),
              Text(label,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.92),
                      fontSize: 11.5,
                      shadows: const [glyphShadow])),
            ],
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          chip('🔥', '$streak', streak == 1 ? 'day streak' : 'day streak'),
          const SizedBox(width: 10),
          chip('🎧', '$days', days == 1 ? 'day in a song' : 'days in a song'),
        ],
      ),
    );
  }

  /// A boxed stat used inside the Song & milestones card.
  Widget _detailStat(
      ColorScheme scheme, String emoji, String value, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
        border:
            Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _accent.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: Text(emoji, style: const TextStyle(fontSize: 16)),
          ),
          const SizedBox(height: 8),
          Text(value,
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 20,
                  height: 1.0,
                  color: scheme.onSurface)),
          const SizedBox(height: 3),
          Text(label,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _overlappedAvatars(List<Map<String, dynamic>> others) {
    // Me on the left, the primary other on the right, slightly overlapped.
    final rightUrl = others.isNotEmpty ? _full(others.first['avatar_url']) : null;
    final rightName =
        others.isNotEmpty ? (others.first['username'] ?? '').toString() : '';
    return SizedBox(
      height: 62,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 44),
            child: _ringed(
              child: InitialsAvatar(
                name: (widget.myName ?? 'You').isEmpty ? 'You' : widget.myName!,
                radius: 26,
                imageUrl: widget.myAvatarUrl,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 44),
            child: _ringed(
              child: InitialsAvatar(
                  name: rightName.isEmpty ? '?' : rightName,
                  radius: 26,
                  imageUrl: rightUrl),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ringed({required Widget child}) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          // A subtly bevelled white ring (bright top-left → cooler bottom-right)
          // reads as a rounded, lit rim rather than a flat white circle.
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.white, Color(0xFFEDEDF2)],
          ),
          boxShadow: [
            // Cast shadow lifts the avatar off the banner…
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 12,
              spreadRadius: -1,
              offset: const Offset(0, 6),
            ),
            // …and a faint white halo softens the rim into the light.
            BoxShadow(
              color: Colors.white.withValues(alpha: 0.35),
              blurRadius: 3,
              spreadRadius: -2,
              offset: const Offset(0, -1),
            ),
          ],
        ),
        child: child,
      );

  // ── pending partner (bond not yet mutual) ────────────────────────────────
  Widget _pendingPartnerBanner(ColorScheme scheme) {
    if ((_space['status'] ?? 'active').toString() != 'pending_partner') {
      return const SizedBox.shrink();
    }
    final name =
        _others.isNotEmpty ? (_others.first['username'] ?? 'them').toString() : 'them';
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: scheme.surfaceContainerHighest,
          border: Border.all(color: _accent.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(Icons.hourglass_top_rounded, size: 18, color: _accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Waiting for $name to accept — this becomes a two-way Space once '
                'they join.',
                style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── milestones ───────────────────────────────────────────────────────────
  Widget _milestoneBanner(ColorScheme scheme) {
    final reached = (_space['stats'] as Map?)?['milestone_reached'];
    if (reached is! Map) return const SizedBox.shrink();
    final kind = (reached['kind'] ?? '').toString();
    final label = (reached['label'] ?? '').toString();
    final emoji = kind == 'streak' ? '🔥' : '💫';
    final line = kind == 'streak'
        ? "You're on a roll together"
        : 'A milestone worth marking';
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [_accent.withValues(alpha: 0.85), _accent],
          ),
        ),
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 26)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: Colors.white)),
                  const SizedBox(height: 2),
                  Text(line,
                      style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.9))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _nextMilestoneHint(ColorScheme scheme) {
    final next = (_space['stats'] as Map?)?['next_milestone'];
    if (next is! Map) return const SizedBox.shrink();
    final remaining = (next['remaining'] as num?)?.toInt() ?? 0;
    final label = (next['label'] ?? '').toString();
    final kind = (next['kind'] ?? '').toString();
    if (remaining <= 0 || label.isEmpty) return const SizedBox.shrink();
    final emoji = kind == 'streak' ? '🔥' : '💫';
    // Optional progress bar: parse the target (first number in the label) and
    // show how far along the bond already is toward it.
    final match = RegExp(r'\d+').firstMatch(label);
    final target = match != null ? int.tryParse(match.group(0)!) : null;
    double? progress;
    if (target != null && target > 0 && remaining < target) {
      progress = ((target - remaining) / target).clamp(0.0, 1.0);
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: _accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _accent.withValues(alpha: 0.28)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.auto_awesome_rounded, size: 14, color: _accent),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  '$remaining more day${remaining == 1 ? '' : 's'} to $label $emoji',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface),
                ),
              ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: _accent.withValues(alpha: 0.15),
                valueColor: AlwaysStoppedAnimation<Color>(_accent),
              ),
            ),
          ],
        ],
      ),
    );
  }


  Widget _yourSongInner(ColorScheme scheme, dynamic song) {
    final has = song is Map && (song['title'] ?? '').toString().trim().isNotEmpty;
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: _accent.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(Icons.music_note_rounded, color: _accent, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('YOUR SONG',
                  style: TextStyle(
                      fontSize: 9.5,
                      letterSpacing: 0.8,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant)),
              const SizedBox(height: 2),
              Text(
                has
                    ? '${song['title']}'
                    : 'The track you two play most shows here as you listen together.',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontWeight: has ? FontWeight.w700 : FontWeight.w400,
                    fontSize: has ? 14 : 12,
                    color: has ? scheme.onSurface : scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── tune in together ──────────────────────────────────────────────────────
  /// When the partner is playing something right now (live "now playing"
  /// presence), invite the user to sync up in one tap. Disappears the moment
  /// they stop. This is the "③ tune-in" beat — catch the bond in a listening
  /// mood and turn it into a shared session.
  Widget _tuneInCard(ColorScheme scheme) {
    final pid = _partnerId;
    if (pid == null) return const SizedBox.shrink();
    final track = NowPlayingPresence.instance.trackFor(pid);
    if (track == null) return const SizedBox.shrink();
    final t = (track['title'] ?? '').toString().trim();
    final a = (track['artist'] ?? '').toString().trim();
    if (t.isEmpty) return const SizedBox.shrink();
    final line = a.isNotEmpty ? '$t — $a' : t;
    final name = _others.isNotEmpty
        ? (_others.first['username'] ?? 'They').toString()
        : 'They';
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        // Opaque tinted fill so the now-playing tile never washes out over a
        // wallpaper (same treatment as the 'Thinking of you' pill).
        decoration: BoxDecoration(
          color: Color.alphaBlend(
              _accent.withValues(alpha: 0.16), scheme.surface),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _accent.withValues(alpha: 0.35)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _accent.withValues(alpha: 0.9),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.graphic_eq_rounded,
                  color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$name is listening now',
                      style: TextStyle(
                          fontSize: 11.5, color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 2),
                  Text(line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(
              onPressed: _listenTogether,
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
              child: const Text('Tune in'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Dedications (an in-body section, like the other tiles) ────────────────
  void _openDedications([Offset? origin]) => _goSection('dedications');

  Future<void> _composeDedication() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _DedicateComposeSheet(spaceId: _id, accent: _accent),
    );
    if (created == true && mounted) _load();
  }

  Widget _dedicationsBody(ColorScheme scheme) {
    final items = ((_space['dedications'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    if (items.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
          border:
              Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
        ),
        child: Column(
          children: [
            Icon(Icons.favorite_border_rounded, color: _accent, size: 28),
            const SizedBox(height: 10),
            Text('No dedications yet',
                style: TextStyle(
                    fontWeight: FontWeight.w700, color: scheme.onSurface)),
            const SizedBox(height: 4),
            Text('Send a song as a feeling — tap Dedicate.',
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ],
        ),
      );
    }
    return Column(
      children: [for (final d in items) _dedicationCard(scheme, d)],
    );
  }

  Widget _dedicationCard(ColorScheme scheme, Map<String, dynamic> d) {
    final mine = d['mine'] == true;
    final unopened = !mine && d['opened'] != true;
    final title = (d['track_title'] ?? '').toString();
    final artist = (d['track_artist'] ?? '').toString();
    final mood = (d['mood'] ?? '').toString();
    final partnerName =
        ((_space['question'] as Map?)?['partner_name'] ?? 'Partner').toString();
    final who = mine ? 'To $partnerName' : 'From ${d['from_username'] ?? partnerName}';
    return GestureDetector(
      onTap: () => _openDedicationDetail(d),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: unopened
              ? Color.alphaBlend(_accent.withValues(alpha: 0.14), scheme.surface)
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
          border: unopened
              ? Border.all(color: _accent.withValues(alpha: 0.5))
              : null,
        ),
        child: Row(
          children: [
            Icon(mine ? Icons.send_rounded : Icons.favorite_rounded,
                size: 20, color: _accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text(who,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: _accent)),
                    if (unopened) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: _accent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text('New',
                            style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: Colors.white)),
                      ),
                    ],
                  ]),
                  const SizedBox(height: 2),
                  Text(artist.isNotEmpty ? '$title — $artist' : title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: scheme.onSurface)),
                  if (mood.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(mood,
                          style: TextStyle(
                              fontSize: 11.5,
                              color: scheme.onSurfaceVariant)),
                    ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: scheme.onSurfaceVariant, size: 20),
          ],
        ),
      ),
    );
  }

  Future<void> _openDedicationDetail(Map<String, dynamic> d) async {
    final id = (d['id'] as num?)?.toInt();
    final mine = d['mine'] == true;
    if (id != null && !mine && d['opened'] != true) {
      await ApiService().openDedication(_id, id);
    }
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    final title = (d['track_title'] ?? '').toString();
    final artist = (d['track_artist'] ?? '').toString();
    final mood = (d['mood'] ?? '').toString();
    final note = (d['note'] ?? '').toString();
    final voiceUrl = (d['voice_note_url'] ?? '').toString();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(mine ? 'Your dedication' : 'A dedication for you 💝'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: TextStyle(
                    fontWeight: FontWeight.w800, color: scheme.onSurface)),
            if (artist.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(artist,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
            if (mood.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(mood, style: TextStyle(color: _accent)),
            ],
            if (note.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('“$note”',
                  style: TextStyle(
                      fontStyle: FontStyle.italic, color: scheme.onSurface)),
            ],
            if (voiceUrl.isNotEmpty) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: _DedVoicePlayer(url: voiceUrl, accent: _accent),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _accent),
            onPressed: () {
              Navigator.pop(ctx);
              _playCrateTrack({
                'title': title,
                'ref': (d['track_ref'] ?? '').toString(),
              });
            },
            icon: const Icon(Icons.headphones_rounded, size: 18),
            label: const Text('Listen together'),
          ),
        ],
      ),
    );
    if (mounted) _load();
  }

  // ── Today's "Us" question (hub card) ──────────────────────────────────────
  Widget _dailyQuestionCard(ColorScheme scheme) {
    final q = (_space['question'] as Map?)?.cast<String, dynamic>();
    if (q == null) return const SizedBox.shrink();
    final prompt = (q['prompt'] as Map?)?.cast<String, dynamic>() ?? const {};
    final body = (prompt['body'] ?? '').toString();
    if (body.isEmpty) return const SizedBox.shrink();
    final kind = (prompt['kind'] ?? 'text').toString();
    final answered = q['answered'] == true;
    final revealed = q['revealed'] == true;
    final partnerName = (q['partner_name'] ?? 'your partner').toString();
    final myAns = (q['my_answer'] as Map?)?.cast<String, dynamic>();
    final partnerAns = (q['partner_answer'] as Map?)?.cast<String, dynamic>();

    Widget content;
    if (revealed) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _answerBubble(scheme, 'You', myAns, kind),
          const SizedBox(height: 8),
          _answerBubble(scheme, partnerName, partnerAns, kind),
        ],
      );
    } else if (answered) {
      content = Row(
        children: [
          Icon(Icons.hourglass_top_rounded,
              size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Answered — waiting for $partnerName…',
                style: TextStyle(
                    fontSize: 12.5, color: scheme.onSurfaceVariant)),
          ),
        ],
      );
    } else if (kind == 'music') {
      content = Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
              backgroundColor: _accent,
              visualDensity: VisualDensity.compact),
          onPressed: _qSubmitting ? null : _answerWithSong,
          icon: const Icon(Icons.library_music_rounded, size: 18),
          label: const Text('Pick your song'),
        ),
      );
    } else {
      content = Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _qAnswerCtrl,
              minLines: 1,
              maxLines: 3,
              maxLength: 240,
              buildCounter: (context,
                      {required int currentLength,
                      required bool isFocused,
                      int? maxLength}) =>
                  null,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'Your answer…',
                isDense: true,
                filled: true,
                fillColor: scheme.surface,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            icon: Icon(Icons.send_rounded, color: _accent),
            onPressed: _qSubmitting ? null : _submitTextAnswer,
          ),
        ],
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:
            Color.alphaBlend(_accent.withValues(alpha: 0.10), scheme.surface),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _accent.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                  kind == 'music'
                      ? Icons.music_note_rounded
                      : Icons.favorite_rounded,
                  size: 16,
                  color: _accent),
              const SizedBox(width: 6),
              Text("Today's question",
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                      color: _accent)),
              const Spacer(),
              if (revealed)
                GestureDetector(
                  onTap: _openQuestionArchive,
                  child: Text('Past',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurfaceVariant)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(body,
              style: TextStyle(
                  fontSize: 14.5,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface)),
          const SizedBox(height: 12),
          content,
        ],
      ),
    );
  }

  Widget _answerBubble(ColorScheme scheme, String who,
      Map<String, dynamic>? ans, String kind) {
    final text = (ans?['answer_text'] ?? '').toString().trim();
    final tt = (ans?['track_title'] ?? '').toString().trim();
    final ta = (ans?['track_artist'] ?? '').toString().trim();
    final display = kind == 'music'
        ? (tt.isEmpty ? '—' : (ta.isEmpty ? tt : '$tt — $ta'))
        : (text.isEmpty ? '—' : text);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(who,
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700, color: _accent)),
          const SizedBox(height: 3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (kind == 'music') ...[
                Icon(Icons.music_note_rounded,
                    size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(display,
                    style: TextStyle(
                        fontSize: 13, height: 1.3, color: scheme.onSurface)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _submitTextAnswer() async {
    final text = _qAnswerCtrl.text.trim();
    if (text.isEmpty) {
      showToast(context, 'Write a short answer first.', type: ToastType.info);
      return;
    }
    await _sendAnswer(answerText: text);
  }

  Future<void> _answerWithSong() async {
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _PlaylistAddSheet(accent: _accent),
    );
    if (picked == null || !mounted) return;
    await _sendAnswer(
      trackTitle: (picked['title'] ?? '').toString(),
      trackArtist: picked['artist'] as String?,
      trackRef: picked['ref'] as String?,
    );
  }

  Future<void> _sendAnswer({
    String? answerText,
    String? trackTitle,
    String? trackArtist,
    String? trackRef,
  }) async {
    setState(() => _qSubmitting = true);
    final res = await ApiService().answerQuestion(
      _id,
      answerText: answerText,
      trackTitle: trackTitle,
      trackArtist: trackArtist,
      trackRef: trackRef,
    );
    if (!mounted) return;
    setState(() => _qSubmitting = false);
    if (res != null) {
      setState(() {
        _space['question'] = res;
        _qAnswerCtrl.clear();
      });
      showToast(
        context,
        res['revealed'] == true
            ? 'You both answered — revealed 💞'
            : 'Answer saved — waiting for your partner 💬',
        type: ToastType.success,
      );
    } else {
      showToast(context, 'Could not send your answer', type: ToastType.error);
    }
  }

  Future<void> _openQuestionArchive() async {
    final data = await ApiService().getQuestionArchive(_id);
    if (!mounted) return;
    final items = ((data?['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    final scheme = Theme.of(context).colorScheme;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (ctx, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
          children: [
            Text('Past questions',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface)),
            const SizedBox(height: 12),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text('No answered questions yet.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              )
            else
              for (final it in items) _archiveItem(scheme, it),
          ],
        ),
      ),
    );
  }

  Widget _archiveItem(ColorScheme scheme, Map<String, dynamic> it) {
    final prompt = (it['prompt'] as Map?)?.cast<String, dynamic>() ?? const {};
    final body = (prompt['body'] ?? '').toString();
    final kind = (prompt['kind'] ?? 'text').toString();
    final day = (it['day'] ?? '').toString();
    final mine = (it['my_answer'] as Map?)?.cast<String, dynamic>();
    final theirs = (it['partner_answer'] as Map?)?.cast<String, dynamic>();
    final partnerName =
        ((_space['question'] as Map?)?['partner_name'] ?? 'Partner').toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(day,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text(body,
              style: TextStyle(
                  fontWeight: FontWeight.w700, color: scheme.onSurface)),
          const SizedBox(height: 8),
          _answerBubble(scheme, 'You', mine, kind),
          const SizedBox(height: 6),
          _answerBubble(scheme, partnerName, theirs, kind),
        ],
      ),
    );
  }


  Widget _playlistEmpty(ColorScheme scheme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          Icon(Icons.queue_music_rounded, color: _accent, size: 26),
          const SizedBox(height: 8),
          Text('Start your crate',
              style: TextStyle(
                  fontWeight: FontWeight.w700, color: scheme.onSurface)),
          const SizedBox(height: 4),
          Text(
            'Add the songs that are you two. Whoever adds, you both see it here.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _trackRow(ColorScheme scheme, Map<String, dynamic> t) {
    final id = (t['id'] as num?)?.toInt();
    final title = (t['title'] ?? '').toString();
    final artist = (t['artist'] ?? '').toString();
    final memo = (t['memo'] ?? '').toString().trim();
    final source = (t['source'] ?? 'manual').toString();
    final mine = t['mine'] == true;
    final adder = mine ? 'You' : (t['added_by_username'] ?? '').toString();
    final (srcIcon, srcText) = _sourceBadge(source);
    final subParts = <String>[];
    if (artist.isNotEmpty) subParts.add(artist);
    subParts.add('added by $adder');
    if (srcText.isNotEmpty) subParts.add('from $srcText');
    final subtitle = subParts.join(' · ');
    return GestureDetector(
      onLongPress: id == null ? null : () => _editTrackMemo(t),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: _accent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child:
                      Icon(Icons.music_note_rounded, color: _accent, size: 18),
                ),
                if (srcIcon != null)
                  Positioned(
                    right: -4,
                    bottom: -4,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(srcIcon, size: 12, color: _accent),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: scheme.onSurface)),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                  if (memo.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      '\u201c$memo\u201d',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.25,
                        fontStyle: FontStyle.italic,
                        color: scheme.onSurface.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: memo.isEmpty ? 'Add a memory' : 'Edit memory',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                memo.isEmpty
                    ? Icons.note_add_outlined
                    : Icons.sticky_note_2_rounded,
                size: 18,
                color: memo.isEmpty ? scheme.onSurfaceVariant : _accent,
              ),
              onPressed: id == null ? null : () => _editTrackMemo(t),
            ),
            IconButton(
              tooltip: 'Listen together',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.play_circle_fill_rounded, color: _accent),
              onPressed: () => _playCrateTrack(t),
            ),
            if (id != null)
              IconButton(
                tooltip: 'Remove',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.close_rounded,
                    size: 18, color: scheme.onSurfaceVariant),
                onPressed: () => _removeTrackFromCrate(id),
              ),
          ],
        ),
      ),
    );
  }

  // Small badge describing how a track entered the soundtrack. Manual adds get
  // no badge (the default needs no explanation).
  (IconData?, String) _sourceBadge(String source) {
    switch (source) {
      case 'dedication':
        return (Icons.favorite_rounded, 'a dedication');
      case 'question':
        return (Icons.lightbulb_rounded, 'a daily question');
      case 'listen_together':
        return (Icons.headphones_rounded, 'a listen together');
      case 'share':
        return (Icons.auto_awesome_rounded, '\u201creminds me of you\u201d');
      default:
        return (null, '');
    }
  }

  /// Add or edit the one-line memory on a soundtrack track (long-press, or the
  /// note button). Saving an empty note clears it.
  Future<void> _editTrackMemo(Map<String, dynamic> t) async {
    final id = (t['id'] as num?)?.toInt();
    if (id == null) return;
    final ctrl = TextEditingController(text: (t['memo'] ?? '').toString());
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add a memory'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 1,
          maxLines: 3,
          maxLength: 140,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'playing the night we\u2026'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (result == null || !mounted) return;
    final updated = await ApiService().annotateTrack(_id, id, result);
    if (!mounted) return;
    if (updated != null) {
      _load();
    } else {
      showToast(context, 'Could not save the memory', type: ToastType.error);
    }
  }

  // ── moments ───────────────────────────────────────────────────────────────
  Widget _momentsEmpty(ColorScheme scheme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          Icon(Icons.auto_awesome_rounded, color: _accent, size: 28),
          const SizedBox(height: 10),
          Text('No moments yet',
              style: TextStyle(
                  fontWeight: FontWeight.w700, color: scheme.onSurface)),
          const SizedBox(height: 4),
          Text(
            'Pin a dedication, a first song, or a note you never want to lose.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  // A tender moment card — who sent it, the song (if any), the note, and a
  // heart the other can tap.
  Widget _momentCard(ColorScheme scheme, Map<String, dynamic> m) {
    final id = (m['id'] as num).toInt();
    final kind = (m['kind'] ?? 'note').toString();
    final caption = (m['caption'] ?? '').toString();
    final mine = m['mine'] == true;
    final author = (m['author'] as Map?)?.cast<String, dynamic>();
    final authorName = mine ? 'You' : (author?['username'] ?? '').toString();
    final created = DateTime.tryParse((m['created_at'] ?? '').toString());
    final song = _songFromRef(m['ref']);
    final reactions = (m['reactions'] as List?) ?? const [];
    final reactedByMe = (m['my_reaction'] ?? '').toString().isNotEmpty;
    final displayName = authorName.isEmpty ? _momentLabel(kind) : authorName;

    return GestureDetector(
      onLongPress: mine ? () => _confirmDeleteMoment(id) : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _accent.withValues(alpha: 0.16)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 14,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: avatar · name over a kind·time subtitle · pin marker.
            Row(
              children: [
                diaryAuthorBadge(
                  name: displayName,
                  imageUrl: _full(author?['avatar_url']),
                  radius: 16,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5,
                              color: scheme.onSurface)),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(_momentIcon(kind), size: 12, color: _accent),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              created != null
                                  ? '${_momentLabel(kind)} · ${_timeAgo(created)}'
                                  : _momentLabel(kind),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.push_pin_rounded,
                    size: 15, color: _accent.withValues(alpha: 0.55)),
              ],
            ),
            if (song != null) ...[
              const SizedBox(height: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.music_note_rounded, size: 16, color: _accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (song['title'] ?? 'A song').toString(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 12.5,
                                color: scheme.onSurface),
                          ),
                          if ((song['artist'] ?? '').toString().isNotEmpty)
                            Text(
                              (song['artist']).toString(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (kind == 'photo' && _full(m['ref']) != null) ...[
              const SizedBox(height: 12),
              _momentPhoto(scheme, _full(m['ref'])!),
            ],
            if (kind == 'voice' && _full(m['ref']) != null) ...[
              const SizedBox(height: 12),
              _DedVoicePlayer(url: _full(m['ref'])!, accent: _accent),
            ],
            if (caption.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(caption,
                  style: TextStyle(
                      fontSize: 14.5, height: 1.4, color: scheme.onSurface)),
            ],
            const SizedBox(height: 12),
            // Reaction chip — a clear affordance whether or not it has loves yet.
            Row(
              children: [
                InkWell(
                  onTap: () => _reactMoment(id, '❤️'),
                  borderRadius: BorderRadius.circular(20),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: reactedByMe
                          ? _accent.withValues(alpha: 0.14)
                          : scheme.surface.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: reactedByMe
                            ? _accent.withValues(alpha: 0.5)
                            : scheme.outlineVariant.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          reactedByMe
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          size: 16,
                          color:
                              reactedByMe ? _accent : scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          reactions.isNotEmpty
                              ? '${reactions.length}'
                              : 'Love this',
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: reactedByMe
                                  ? _accent
                                  : scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Parse a song moment's `ref` (JSON {title, artist}); null if it isn't a song.
  Map<String, dynamic>? _songFromRef(dynamic ref) {
    if (ref is! String || ref.trim().isEmpty) return null;
    try {
      final j = jsonDecode(ref);
      if (j is Map && (j['title'] ?? '').toString().trim().isNotEmpty) {
        return j.cast<String, dynamic>();
      }
    } catch (_) {}
    return null;
  }

  /// A kept photo thumbnail inside a moment card; tap opens a zoomable viewer.
  Widget _momentPhoto(ColorScheme scheme, String url) {
    return GestureDetector(
      onTap: () => _openMomentPhoto(url),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: authNetworkImage(
            url: url,
            headers: mediaAuthHeaders(url),
            fit: BoxFit.cover,
            width: double.infinity,
            cacheWidth: 1000,
          ),
        ),
      ),
    );
  }

  void _openMomentPhoto(String url) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      builder: (dctx) => GestureDetector(
        onTap: () => Navigator.pop(dctx),
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 4,
                child: authNetworkImage(
                  url: url,
                  headers: mediaAuthHeaders(url),
                  fit: BoxFit.contain,
                ),
              ),
            ),
            Positioned(
              top: 40,
              right: 16,
              child: IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                onPressed: () => Navigator.pop(dctx),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final d = DateTime.now().difference(dt.toLocal());
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    if (d.inDays < 7) return '${d.inDays}d';
    return DateFormat('MMM d').format(dt.toLocal());
  }

  Future<void> _reactMoment(int momentId, String emoji) async {
    final res = await ApiService().reactMoment(_id, momentId, emoji);
    if (!mounted) return;
    if (res != null) {
      _load(); // refresh the shared timeline with the new reaction state
    }
  }

  Future<void> _confirmDeleteMoment(int momentId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this moment?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final done = await ApiService().deleteMoment(_id, momentId);
    if (!mounted) return;
    if (done) {
      _load();
    } else {
      showToast(context, 'Could not remove', type: ToastType.error);
    }
  }

  IconData _momentIcon(String kind) {
    switch (kind) {
      case 'dedication':
        return Icons.favorite_rounded;
      case 'song':
        return Icons.music_note_rounded;
      case 'voice':
        return Icons.mic_rounded;
      case 'photo':
        return Icons.photo_rounded;
      default:
        return Icons.sticky_note_2_rounded;
    }
  }

  String _momentLabel(String kind) {
    switch (kind) {
      case 'dedication':
        return 'A dedication';
      case 'song':
        return 'A song';
      case 'voice':
        return 'A voice note';
      case 'photo':
        return 'A photo';
      default:
        return 'A note';
    }
  }

  // ── Our Diary (shared notebook: memories + plans) ─────────────────────────
  /// A compact strip at the top of the main surface for the soonest pinned plan
  /// — a gentle in-app reminder that also complements the device notification.
  /// Tapping opens the diary. Hidden when nothing is pinned ahead.
  Widget _upcomingPlanBanner(ColorScheme scheme) {
    if (_partnerId == null) return const SizedBox.shrink();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    Map<String, dynamic>? soonest;
    DateTime? soonestDay;
    for (final e in _plans) {
      if (e['pinned'] != true) continue;
      final d = DateTime.tryParse((e['plan_date'] ?? '').toString());
      if (d == null) continue;
      final day = DateTime(d.year, d.month, d.day);
      if (day.isBefore(today)) continue;
      if (soonestDay == null || day.isBefore(soonestDay)) {
        soonest = e;
        soonestDay = day;
      }
    }
    if (soonest == null || soonestDay == null) return const SizedBox.shrink();
    final title = (soonest['title'] ?? '').toString().trim().isNotEmpty
        ? (soonest['title']).toString().trim()
        : (soonest['body'] ?? '').toString().trim();
    final rel = _relDay(soonestDay);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        // Opaque (tint blended onto the surface) so the wallpaper never bleeds
        // through this card, matching the other Our Space cards.
        color: Color.alphaBlend(
            _accent.withValues(alpha: 0.10), scheme.surface),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: _openDiary,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _accent.withValues(alpha: 0.30)),
            ),
            child: Row(
              children: [
                const Text('🗓️', style: TextStyle(fontSize: 18)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Plan ahead · $rel',
                          style: TextStyle(
                              fontSize: 11.5, color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 2),
                      Text(title.isEmpty ? 'A plan you pinned' : title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded,
                    color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _diaryEmpty(ColorScheme scheme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          Icon(Icons.menu_book_rounded, color: _accent, size: 28),
          const SizedBox(height: 10),
          Text('Your story, in your words',
              style: TextStyle(
                  fontWeight: FontWeight.w700, color: scheme.onSurface)),
          const SizedBox(height: 4),
          Text(
            'Write the moments you shared, and the plans you’re dreaming up '
            'together. Pin a plan and you’ll both get a reminder.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _diarySectionLabel(ColorScheme scheme, String label, String emoji) {
    return Row(
      children: [
        Text(emoji, style: const TextStyle(fontSize: 14)),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 13,
                color: scheme.onSurface)),
      ],
    );
  }

  Widget _planRow(ColorScheme scheme, Map<String, dynamic> e) {
    final id = (e['id'] as num?)?.toInt();
    final title = (e['title'] ?? '').toString().trim();
    final body = (e['body'] ?? '').toString().trim();
    final mine = e['mine'] == true;
    final pinned = e['pinned'] == true;
    final author = (e['author'] as Map?)?.cast<String, dynamic>();
    final authorName = mine ? 'You' : (author?['username'] ?? '').toString();
    final d = DateTime.tryParse((e['plan_date'] ?? '').toString());
    final when = d != null
        ? '${DateFormat('EEE, MMM d').format(d)} · ${_relDay(DateTime(d.year, d.month, d.day))}'
        : 'No date yet';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: pinned
            ? Border.all(color: _accent.withValues(alpha: 0.5))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.event_rounded, size: 15, color: _accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(when,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface)),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: pinned ? 'Unpin reminder' : 'Pin for a reminder',
                icon: Icon(
                  pinned
                      ? Icons.notifications_active_rounded
                      : Icons.notifications_none_rounded,
                  size: 20,
                  color: pinned ? _accent : scheme.onSurfaceVariant,
                ),
                onPressed: id == null ? null : () => _togglePin(e),
              ),
              _diaryMenu(scheme, e),
            ],
          ),
          if (title.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(title,
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: scheme.onSurface)),
          ],
          if (body.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(body,
                maxLines: body.length > _kMemoryPreviewChars ? 5 : null,
                overflow: body.length > _kMemoryPreviewChars
                    ? TextOverflow.ellipsis
                    : TextOverflow.clip,
                style: TextStyle(
                    fontSize: 13, height: 1.3, color: scheme.onSurface)),
            if (body.length > _kMemoryPreviewChars)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => _openMemoryDetail(e),
                  style: TextButton.styleFrom(
                    foregroundColor: _accent,
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    minimumSize: const Size(0, 0),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Read more'),
                ),
              ),
          ],
          const SizedBox(height: 6),
          Text(mine ? 'You' : (authorName.isEmpty ? 'Partner' : authorName),
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          _diaryEngagement(scheme, e),
        ],
      ),
    );
  }

  Widget _diaryEngagement(ColorScheme scheme, Map<String, dynamic> e) {
    final count = (e['comment_count'] as num?)?.toInt() ??
        ((e['comments'] as List?)?.length ?? 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        diaryReactionRow(
          scheme: scheme,
          accent: _accent,
          entry: e,
          onToggle: (em) => _reactDiary(e, em),
          onAdd: () async {
            final em = await pickDiaryReaction(context, _accent);
            if (em != null && mounted) _reactDiary(e, em);
          },
        ),
        const SizedBox(height: 6),
        InkWell(
          onTap: () => _openMemoryDetail(e),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.mode_comment_outlined,
                    size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                  count == 0
                      ? 'Comment'
                      : (count == 1 ? '1 comment' : '$count comments'),
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant),
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right_rounded,
                    size: 16, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _diaryMenu(ColorScheme scheme, Map<String, dynamic> e) {
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: Icon(Icons.more_horiz_rounded,
          size: 20, color: scheme.onSurfaceVariant),
      onSelected: (v) {
        if (v == 'edit') _editDiaryEntry(e);
        if (v == 'delete') _deleteDiaryEntry(e);
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'edit', child: Text('Edit')),
        PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
  }

  /// 'today' / 'tomorrow' / 'in N days' / 'N days ago' for a plan's day.
  String _relDay(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = day.difference(today).inDays;
    if (diff == 0) return 'today';
    if (diff == 1) return 'tomorrow';
    if (diff > 1) return 'in $diff days';
    if (diff == -1) return 'yesterday';
    return '${-diff} days ago';
  }

  /// The current version of a diary entry by id (so an open detail card and the
  /// list stay in sync after a reload).
  Map<String, dynamic>? _diaryById(int id) {
    for (final e in _diary) {
      if ((e['id'] as num?)?.toInt() == id) return e;
    }
    return null;
  }

  /// Toggle my [emoji] reaction on a diary entry from the list, then reload so
  /// the counts update in place.
  Future<void> _reactDiary(Map<String, dynamic> e, String emoji) async {
    final id = (e['id'] as num?)?.toInt();
    if (id == null) return;
    final updated = await ApiService().reactDiaryEntry(_id, id, emoji);
    if (!mounted) return;
    if (updated == null) {
      showToast(context, 'Could not react — try again', type: ToastType.error);
      return;
    }
    await _load();
  }

  /// Open the full-read card for one memory/plan: complete text, reactions and
  /// the comment thread. Grows from / is absorbed back into its row.
  void _openMemoryDetail(Map<String, dynamic> e, [Offset? origin]) {
    final id = (e['id'] as num?)?.toInt();
    if (id == null) return;
    _absorbDialog<void>(
      origin: origin,
      builder: (dctx) => _MemoryDetailSheet(
        spaceId: _id,
        entry: _diaryById(id) ?? e,
        accent: _accent,
        apiBase: widget.apiBase,
        onChanged: () {
          if (mounted) _load();
        },
      ),
    );
  }

  /// A centered dialog whose open/close scales + fades toward [origin] (a tile
  /// or row), so a card looks absorbed back into where it came from. Shared by
  /// the feature cards and the memory-detail card.
  Future<T?> _absorbDialog<T>({
    required Offset? origin,
    required WidgetBuilder builder,
  }) {
    final media = MediaQuery.of(context).size;
    final align = origin == null
        ? Alignment.center
        : Alignment(
            ((origin.dx / media.width) * 2 - 1).clamp(-1.0, 1.0),
            ((origin.dy / media.height) * 2 - 1).clamp(-1.0, 1.0),
          );
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Minimize',
      barrierColor: Colors.black.withValues(alpha: 0.45),
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (dctx, _, _) => builder(dctx),
      transitionBuilder: (dctx, anim, _, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.55, end: 1.0).animate(curved),
            alignment: align,
            child: child,
          ),
        );
      },
    );
  }

  Future<void> _addDiaryEntry() async {
    final res = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _DiaryComposer(accent: _accent, myName: widget.myName),
    );
    if (res == null) return;
    final saved = await ApiService().addDiaryEntry(
      _id,
      kind: (res['kind'] ?? 'memory').toString(),
      body: (res['body'] ?? '').toString(),
      title: res['title'] as String?,
      planDate: res['plan_date'] as String?,
      pinned: res['pinned'] == true,
      font: res['font'] as String?,
    );
    if (!mounted) return;
    if (saved != null) {
      showToast(context, 'Saved to your diary 📖', type: ToastType.success);
      await _load();
    } else {
      showToast(context, 'Could not save that entry', type: ToastType.error);
    }
  }

  Future<void> _editDiaryEntry(Map<String, dynamic> e) async {
    final id = (e['id'] as num?)?.toInt();
    if (id == null) return;
    final res = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _DiaryComposer(accent: _accent, existing: e, myName: widget.myName),
    );
    if (res == null) return;
    final saved = await ApiService().editDiaryEntry(
      _id,
      id,
      kind: res['kind'] as String?,
      body: res['body'] as String?,
      title: (res['title'] ?? '') as String?,
      planDate: (res['plan_date'] ?? '') as String?,
      pinned: res['pinned'] as bool?,
      font: res['font'] as String?,
    );
    if (!mounted) return;
    if (saved != null) {
      // A plan turned into a memory (or its pin/date changed) may no longer
      // warrant a reminder — clear this one; _load() reschedules what remains.
      if ((saved['kind'] ?? '').toString() != 'plan' ||
          saved['pinned'] != true) {
        await cancelDiaryReminder(id);
      }
      await _load();
    } else {
      showToast(context, 'Could not update that entry', type: ToastType.error);
    }
  }

  Future<void> _togglePin(Map<String, dynamic> e) async {
    final id = (e['id'] as num?)?.toInt();
    if (id == null) return;
    final newPinned = !(e['pinned'] == true);
    final saved =
        await ApiService().editDiaryEntry(_id, id, pinned: newPinned);
    if (!mounted) return;
    if (saved == null) {
      showToast(context, 'Could not update the reminder', type: ToastType.error);
      return;
    }
    if (!newPinned) await cancelDiaryReminder(id);
    await _load();
  }

  Future<void> _deleteDiaryEntry(Map<String, dynamic> e) async {
    final id = (e['id'] as num?)?.toInt();
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this entry?'),
        content: const Text('It’s removed from your shared diary for both of you.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final done = await ApiService().deleteDiaryEntry(_id, id);
    if (!mounted) return;
    if (done) {
      await cancelDiaryReminder(id);
      await _load();
    } else {
      showToast(context, 'Could not remove', type: ToastType.error);
    }
  }
}

// ── moment composer sheet ─────────────────────────────────────────────────
class _MomentComposer extends StatefulWidget {
  final Color accent;
  const _MomentComposer({required this.accent});

  @override
  State<_MomentComposer> createState() => _MomentComposerState();
}

class _MomentComposerState extends State<_MomentComposer> {
  final TextEditingController _c = TextEditingController();
  bool _songMode = true; // the star action: dedicate a song
  String? _songTitle;
  String? _songArtist;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  String _titleFromPath(String path) {
    final name = path.split(RegExp(r'[\\/]+')).last;
    return name.replaceAll(RegExp(r'\.[^.]+$'), '');
  }

  Future<void> _chooseSong() async {
    final scheme = Theme.of(context).colorScheme;
    final paths = List<String>.from(playlistNotifier.value);
    if (paths.isEmpty) {
      showToast(context, 'Open the music player and load some songs first.',
          type: ToastType.info);
      return;
    }
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Row(children: [
                Text('Choose a song',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: scheme.onSurface)),
              ]),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: paths.length,
                itemBuilder: (c, i) => ListTile(
                  leading:
                      Icon(Icons.music_note_rounded, color: widget.accent),
                  title: Text(_titleFromPath(paths[i]),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(ctx, paths[i]),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen != null && mounted) {
      setState(() {
        _songTitle = _titleFromPath(chosen);
        _songArtist = '';
      });
    }
  }

  void _pin() {
    final text = _c.text.trim();
    if (_songMode) {
      if (_songTitle == null) {
        showToast(context, 'Choose a song to dedicate.', type: ToastType.info);
        return;
      }
      Navigator.pop(context, {
        'kind': 'song',
        'ref': jsonEncode({'title': _songTitle, 'artist': _songArtist ?? ''}),
        'caption': text.isEmpty ? null : text,
      });
    } else {
      if (text.isEmpty) {
        Navigator.pop(context);
        return;
      }
      Navigator.pop(context, {'kind': 'note', 'caption': text});
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 18, 20, 18 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Pin a moment',
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  color: scheme.onSurface)),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Dedicate a song'),
                selected: _songMode,
                selectedColor: widget.accent.withValues(alpha: 0.22),
                onSelected: (_) => setState(() => _songMode = true),
              ),
              ChoiceChip(
                label: const Text('Note'),
                selected: !_songMode,
                selectedColor: widget.accent.withValues(alpha: 0.22),
                onSelected: (_) => setState(() => _songMode = false),
              ),
            ],
          ),
          if (_songMode) ...[
            const SizedBox(height: 14),
            InkWell(
              onTap: _chooseSong,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.music_note_rounded,
                        color: widget.accent, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _songTitle ?? 'Choose a song…',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _songTitle == null
                              ? scheme.onSurfaceVariant
                              : scheme.onSurface,
                          fontWeight: _songTitle == null
                              ? FontWeight.w400
                              : FontWeight.w700,
                        ),
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded,
                        color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          TextField(
            controller: _c,
            maxLines: 3,
            maxLength: 240,
            decoration: InputDecoration(
              hintText: _songMode
                  ? 'Say why this song is you two… (optional)'
                  : 'Write a note you want to keep…',
              filled: true,
              fillColor: scheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: widget.accent,
                  foregroundColor: Colors.white),
              onPressed: _pin,
              child: const Text('Pin it'),
            ),
          ),
        ],
      ),
    );
  }
}

// ── playlist add sheet ────────────────────────────────────────────────────
class _PlaylistAddSheet extends StatefulWidget {
  final Color accent;
  const _PlaylistAddSheet({required this.accent});

  @override
  State<_PlaylistAddSheet> createState() => _PlaylistAddSheetState();
}

class _PlaylistAddSheetState extends State<_PlaylistAddSheet> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _artist = TextEditingController();
  String? _ref; // the adder's local path when picked from the library

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    super.dispose();
  }

  String _titleFromPath(String path) {
    final name = path.split(RegExp(r'[\\/]+')).last;
    return name.replaceAll(RegExp(r'\.[^.]+$'), '');
  }

  Future<void> _pickFromLibrary() async {
    final scheme = Theme.of(context).colorScheme;
    final paths = List<String>.from(playlistNotifier.value);
    if (paths.isEmpty) {
      showToast(context, 'Open the music player and load some songs first.',
          type: ToastType.info);
      return;
    }
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Row(children: [
                Text('Pick from your songs',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: scheme.onSurface)),
              ]),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: paths.length,
                itemBuilder: (c, i) => ListTile(
                  leading:
                      Icon(Icons.music_note_rounded, color: widget.accent),
                  title: Text(_titleFromPath(paths[i]),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(ctx, paths[i]),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen != null && mounted) {
      setState(() {
        _title.text = _titleFromPath(chosen);
        _ref = chosen;
      });
    }
  }

  void _add() {
    final title = _title.text.trim();
    if (title.isEmpty) {
      showToast(context, 'Give the track a title.', type: ToastType.info);
      return;
    }
    final artist = _artist.text.trim();
    Navigator.pop(context, {
      'title': title,
      'artist': artist.isEmpty ? null : artist,
      'ref': _ref,
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 18, 20, 18 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Add to Our Playlist',
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  color: scheme.onSurface)),
          const SizedBox(height: 14),
          InkWell(
            onTap: _pickFromLibrary,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.library_music_rounded,
                      color: widget.accent, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('Pick from your songs',
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface)),
                  ),
                  Icon(Icons.chevron_right_rounded,
                      color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _title,
            decoration: InputDecoration(
              labelText: 'Title',
              filled: true,
              fillColor: scheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _artist,
            decoration: InputDecoration(
              labelText: 'Artist (optional)',
              filled: true,
              fillColor: scheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: widget.accent,
                  foregroundColor: Colors.white),
              onPressed: _add,
              child: const Text('Add'),
            ),
          ),
        ],
      ),
    );
  }
}

// ── edit sheet (name + theme) ─────────────────────────────────────────────
class _EditSpaceSheet extends StatefulWidget {
  final String initialName;
  final String initialTheme;
  final bool initialPrimary;
  final int spaceId;
  final String? initialBackgroundUrl;
  final String apiBase;
  final void Function(Map<String, dynamic>)? onSpaceUpdated;
  const _EditSpaceSheet({
    required this.initialName,
    required this.initialTheme,
    required this.initialPrimary,
    required this.spaceId,
    this.initialBackgroundUrl,
    required this.apiBase,
    this.onSpaceUpdated,
  });

  @override
  State<_EditSpaceSheet> createState() => _EditSpaceSheetState();
}

class _EditSpaceSheetState extends State<_EditSpaceSheet> {
  late final TextEditingController _c =
      TextEditingController(text: widget.initialName);
  late String _theme = widget.initialTheme;
  late bool _primary = widget.initialPrimary;
  late String? _bgUrl = widget.initialBackgroundUrl;
  // Remember the last wallpaper and the last device photo separately, so each
  // background tile keeps its own preview and the user can flip between them
  // without the other tile going blank.
  late String? _lastGalleryUrl =
      (widget.initialBackgroundUrl ?? '').startsWith('/wallpapers/')
          ? widget.initialBackgroundUrl
          : null;
  late String? _lastPhotoUrl =
      (widget.initialBackgroundUrl ?? '').startsWith('/attachments/')
          ? widget.initialBackgroundUrl
          : null;
  bool _busy = false;
  bool _bgBusy = false;

  Future<void> _pickBackground() async {
    FilePickerResult? res;
    try {
      res = await FilePicker.pickFiles(type: FileType.image);
    } catch (_) {
      return;
    }
    if (res == null || res.files.isEmpty) return;
    final f = res.files.single;
    final bytes = await f.readAsBytes();
    if (bytes.isEmpty) return;
    final name = f.name;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : 'jpg';
    final mime = ext == 'png'
        ? 'image/png'
        : ext == 'webp'
            ? 'image/webp'
            : ext == 'gif'
                ? 'image/gif'
                : 'image/jpeg';
    setState(() => _bgBusy = true);
    final updated = await ApiService()
        .uploadSpaceBackground(widget.spaceId, bytes, filename: name, mime: mime);
    if (!mounted) return;
    setState(() {
      _bgBusy = false;
      if (updated != null) {
        _bgUrl = updated['background_url'] as String?;
        if ((_bgUrl ?? '').startsWith('/attachments/')) _lastPhotoUrl = _bgUrl;
      }
    });
    if (updated != null) {
      widget.onSpaceUpdated?.call(updated);
    } else {
      showToast(context, 'Could not set that background', type: ToastType.error);
    }
  }

  Future<void> _removeBackground() async {
    if ((_bgUrl ?? '').isEmpty) return;
    setState(() => _bgBusy = true);
    final updated = await ApiService().clearSpaceBackground(widget.spaceId);
    if (!mounted) return;
    setState(() {
      _bgBusy = false;
      if (updated != null) _bgUrl = updated['background_url'] as String?;
    });
    if (updated != null) widget.onSpaceUpdated?.call(updated);
  }

  Future<void> _openSpaceGallery() async {
    final presets = await WallpapersService.instance.load();
    if (!mounted) return;
    final accent = spaceThemeColor(_theme);
    final selFull = (_bgUrl ?? '').startsWith('/wallpapers/')
        ? resolveAvatarUrl(_bgUrl, widget.apiBase)
        : null;
    // Full-screen sub-page: the header stays put while the grid scrolls, and
    // tapping a wallpaper pops straight back to Settings with the pick.
    final pickedId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => _WallpaperPickerPage(
          presets: presets,
          apiBase: widget.apiBase,
          accent: accent,
          selectedFullUrl: selFull,
        ),
      ),
    );
    if (!mounted || pickedId == null) return;
    if (pickedId == '__upload__') {
      await _pickBackground();
      return;
    }
    await _applyPreset(pickedId);
  }

  Future<void> _applyPreset(String id) async {
    setState(() => _bgBusy = true);
    final updated = await ApiService()
        .updateSpace(widget.spaceId, backgroundUrl: '/wallpapers/$id');
    if (!mounted) return;
    setState(() {
      _bgBusy = false;
      if (updated != null) {
        _bgUrl = updated['background_url'] as String?;
        if ((_bgUrl ?? '').startsWith('/wallpapers/')) _lastGalleryUrl = _bgUrl;
      }
    });
    if (updated != null) {
      widget.onSpaceUpdated?.call(updated);
    } else {
      showToast(context, 'Could not set that wallpaper',
          type: ToastType.error);
    }
  }

  /// Instantly re-apply the last-used gallery wallpaper (a preset — allowed by
  /// the server without a re-upload). Falls back to opening the picker.
  Future<void> _reapplyGallery() async {
    final url = _lastGalleryUrl;
    if (url == null || !url.startsWith('/wallpapers/')) {
      await _openSpaceGallery();
      return;
    }
    await _applyPreset(url.split('/').last);
  }

  Widget _bgOption(ColorScheme scheme,
      {required bool selected,
      required VoidCallback? onTap,
      required IconData icon,
      Widget? thumbnail,
      bool dim = false,
      required String label}) {
    final accent = spaceThemeColor(_theme);
    return Expanded(
      child: Column(
        children: [
          SizedBox(
            height: 92,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: onTap,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: selected
                          ? accent
                          : scheme.outlineVariant.withValues(alpha: 0.7),
                      width: selected ? 2.5 : 1.2,
                    ),
                    boxShadow: selected
                        ? [
                            BoxShadow(
                              color: accent.withValues(alpha: 0.22),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ]
                        : null,
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (thumbnail != null)
                        thumbnail
                      else
                        Center(
                          child: Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.14),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(icon, size: 21, color: accent),
                          ),
                        ),
                      // Inactive preview: soften it and show the type icon, so
                      // it clearly invites a tap to switch back / change.
                      if (thumbnail != null && dim) ...[
                        Container(color: Colors.black.withValues(alpha: 0.28)),
                        Center(
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.35),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(icon, size: 18, color: Colors.white),
                          ),
                        ),
                      ],
                      if (selected)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                                color: accent, shape: BoxShape.circle),
                            child: const Icon(Icons.check_rounded,
                                size: 13, color: Colors.white),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: selected ? accent : scheme.onSurface)),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final ok = await ApiService().updateSpace(
      widget.spaceId,
      name: _c.text.trim(),
      theme: _theme,
      // Only ever promote to hero here (never demote to headless).
      isPrimary: (_primary && !widget.initialPrimary) ? true : null,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    Navigator.pop(context, ok != null ? 'saved' : null);
  }

  Widget _label(ColorScheme scheme, String t) => Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Text(t,
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
                color: scheme.onSurfaceVariant)),
      );

  /// A theme swatch with a clean COLOURED halo (outer ring in the swatch's own
  /// colour + a white gap) when picked — softer and more premium than the old
  /// hard black ring, and it grows a touch so the choice is unmistakable.
  Widget _swatch(MapEntry<String, Color> entry) {
    final sel = _theme == entry.key;
    return GestureDetector(
      onTap: () => setState(() => _theme = entry.key),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        padding: EdgeInsets.all(sel ? 3 : 0),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
              color: sel ? entry.value : Colors.transparent, width: 2),
        ),
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: entry.value,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: sel ? 2 : 0),
            boxShadow: [
              BoxShadow(
                color: entry.value.withValues(alpha: sel ? 0.45 : 0.25),
                blurRadius: sel ? 10 : 5,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: sel
              ? const Icon(Icons.check_rounded, color: Colors.white, size: 20)
              : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    // The settings preview the CHOSEN theme live: the picked swatch, the Save
    // button and the Hero switch all adopt this colour as you tap around.
    final accent = spaceThemeColor(_theme);
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleSpacing: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.tune_rounded, size: 18, color: accent),
            ),
            const SizedBox(width: 10),
            Text('Settings',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                    color: scheme.onSurface)),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + bottom),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          _label(scheme, 'NAME'),
          TextField(
            controller: _c,
            decoration: InputDecoration(
              hintText: 'What do you call this bond?',
              filled: true,
              fillColor: scheme.surfaceContainerHighest,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: accent, width: 1.6),
              ),
            ),
          ),
          const SizedBox(height: 20),
          _label(scheme, 'THEME'),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              for (final entry in kSpacePalette.entries) _swatch(entry),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              _label(scheme, 'BACKGROUND'),
              if (_bgBusy) ...[
                const SizedBox(width: 8),
                const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ],
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _bgOption(
                scheme,
                selected: (_bgUrl ?? '').isEmpty,
                onTap: _bgBusy ? null : _removeBackground,
                label: 'Default',
                icon: Icons.auto_awesome_rounded,
              ),
              const SizedBox(width: 12),
              _bgOption(
                scheme,
                selected: (_bgUrl ?? '').startsWith('/wallpapers/'),
                // Tap re-applies the last wallpaper instantly; tap again while
                // active (or when none is remembered yet) opens the picker.
                onTap: _bgBusy
                    ? null
                    : () {
                        if ((_bgUrl ?? '').startsWith('/wallpapers/') ||
                            _lastGalleryUrl == null) {
                          _openSpaceGallery();
                        } else {
                          _reapplyGallery();
                        }
                      },
                label: 'Gallery',
                icon: Icons.collections_rounded,
                thumbnail: (_lastGalleryUrl ?? '').isNotEmpty
                    ? WallpaperThumb(
                        resolveAvatarUrl(_lastGalleryUrl, widget.apiBase) ?? '')
                    : null,
                dim: !(_bgUrl ?? '').startsWith('/wallpapers/'),
              ),
              const SizedBox(width: 12),
              _bgOption(
                scheme,
                selected: (_bgUrl ?? '').startsWith('/attachments/'),
                onTap: _bgBusy ? null : _pickBackground,
                label: 'Your photo',
                icon: Icons.add_photo_alternate_outlined,
                thumbnail: (_lastPhotoUrl ?? '').isNotEmpty
                    ? authNetworkImage(
                        url: resolveAvatarUrl(_lastPhotoUrl, widget.apiBase) ??
                            '',
                        headers: mediaAuthHeaders(
                            resolveAvatarUrl(_lastPhotoUrl, widget.apiBase) ??
                                ''),
                        fit: BoxFit.cover,
                      )
                    : null,
                dim: !(_bgUrl ?? '').startsWith('/attachments/'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          // Hero row, grouped on a soft surface. Already-hero shows a clear
          // "Leading" badge instead of a dead, greyed-out toggle.
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(Icons.workspace_premium_rounded, size: 20, color: accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Hero Space',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface)),
                      const SizedBox(height: 2),
                      Text(
                        widget.initialPrimary
                            ? 'This bond leads your list'
                            : 'Show this bond at the top of your list',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (widget.initialPrimary)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_rounded, size: 14, color: accent),
                        const SizedBox(width: 4),
                        Text('Leading',
                            style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                                color: accent)),
                      ],
                    ),
                  )
                else
                  Switch(
                    value: _primary,
                    activeThumbColor: Colors.white,
                    activeTrackColor: accent,
                    onChanged: (v) => setState(() => _primary = v),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _busy ? null : _save,
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Save',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 16),
          // Danger zone — Unpin set apart in a faint red panel so it reads as
          // the destructive action, not just another link.
          Material(
            color: scheme.error.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: _busy ? null : () => Navigator.pop(context, 'unpin'),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: scheme.error.withValues(alpha: 0.20)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.link_off_rounded,
                        size: 20, color: scheme.error),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Unpin this Space',
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: scheme.error)),
                          const SizedBox(height: 2),
                          Text(
                            'Removes the profile & pinned moments. Your chats stay.',
                            style: TextStyle(
                                fontSize: 11.5,
                                color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
        ),
          ),
        ),
      ),
    );
  }
}


/// Full-screen wallpaper picker (a sub-page of Space Settings). The header
/// stays pinned while the grid scrolls, a back arrow returns to Settings, and
/// tapping a wallpaper pops back with the chosen id so Settings can apply it.
class _WallpaperPickerPage extends StatelessWidget {
  final List<WallpaperPreset> presets;
  final String apiBase;
  final Color accent;
  final String? selectedFullUrl;
  const _WallpaperPickerPage({
    required this.presets,
    required this.apiBase,
    required this.accent,
    this.selectedFullUrl,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleSpacing: 0,
        title: Text('Choose a wallpaper',
            style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 18,
                color: scheme.onSurface)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
        child: WallpaperGalleryGrid(
          presets: presets,
          apiBase: apiBase,
          accent: accent,
          selectedFullUrl: selectedFullUrl,
          onPick: (pp) => Navigator.pop(context, pp.id),
        ),
      ),
      // Pinned footer: pick a photo from the device instead of a preset.
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(18, 6, 18, 12),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => Navigator.pop(context, '__upload__'),
            icon: const Icon(Icons.add_photo_alternate_rounded, size: 20),
            label: const Text('Upload a photo'),
            style: OutlinedButton.styleFrom(
              foregroundColor: accent,
              side: BorderSide(color: accent.withValues(alpha: 0.6)),
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
      ),
    );
  }
}

// ── diary composer sheet ──────────────────────────────────────────────────
/// Write (or edit) a shared diary entry: a memory (something you shared) or a
/// plan ahead (with an optional date + a pin for a reminder). Returns a map
/// {kind, title, body, plan_date, pinned} on save, or null on cancel.
/// A reusable raised, 3D tappable surface: gradient body, hairline border and
/// layered shadows (down-shadow + top highlight), sinking flatter while held.
/// Used for the diary's primary CTA and its comment pill.
class _PressableRaised extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double radius;
  final Gradient gradient;
  final BoxBorder? border;
  final List<BoxShadow> shadows;
  const _PressableRaised({
    required this.child,
    required this.onTap,
    required this.gradient,
    this.shadows = const [],
    this.border,
    this.radius = 14,
  });

  @override
  State<_PressableRaised> createState() => _PressableRaisedState();
}

class _PressableRaisedState extends State<_PressableRaised> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(widget.radius);
    return AnimatedScale(
      scale: _down ? 0.97 : 1.0,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOut,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: r,
          gradient: widget.gradient,
          border: widget.border,
          // Sink: drop the lift while pressed so it reads as pushed in.
          boxShadow: _down ? const [] : widget.shadows,
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: r,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            borderRadius: r,
            onTap: widget.onTap,
            onHighlightChanged: (v) {
              if (mounted) setState(() => _down = v);
            },
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// A folded page-corner ("dog-ear") you tap to turn the diary. Bottom-right
/// turns forward, bottom-left turns back — the little curl reads as a real
/// book and, unlike the old floating arrow, never sits over the writing.
class _DiaryDogEar extends StatelessWidget {
  final bool isNext;
  final Color paper;
  final Color accent;
  final bool isDark;
  final VoidCallback onTap;
  const _DiaryDogEar({
    required this.isNext,
    required this.paper,
    required this.accent,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const s = 46.0;
    return Semantics(
      button: true,
      label: isNext ? 'Next page' : 'Previous page',
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: CustomPaint(
          size: const Size(s, s),
          painter: _DogEarPainter(
              isNext: isNext, paper: paper, accent: accent, isDark: isDark),
        ),
      ),
    );
  }
}

class _DogEarPainter extends CustomPainter {
  final bool isNext;
  final Color paper;
  final Color accent;
  final bool isDark;
  _DogEarPainter({
    required this.isNext,
    required this.paper,
    required this.accent,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.save();
    // Paint a bottom-RIGHT fold, then mirror horizontally for the prev corner.
    if (!isNext) {
      canvas.translate(w, 0);
      canvas.scale(-1, 1);
    }
    final creaseA = Offset(0, h); // bottom-left of the little square
    final creaseB = Offset(w, 0); // top-right
    final corner = Offset(w, h); // the folded page corner

    // Soft shadow along the crease, cast up-left onto the page, so the corner
    // reads as physically lifted.
    canvas.drawLine(
      creaseA,
      creaseB,
      Paint()
        ..color = Colors.black.withValues(alpha: isDark ? 0.30 : 0.15)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );

    // The flap (page underside): a triangle from the crease to the corner, with
    // a gentle gradient + a whisper of the Space colour so it feels warm.
    final flap = Path()
      ..moveTo(creaseA.dx, creaseA.dy)
      ..lineTo(corner.dx, corner.dy)
      ..lineTo(creaseB.dx, creaseB.dy)
      ..close();
    final under =
        Color.lerp(paper, isDark ? Colors.black : accent, isDark ? 0.35 : 0.20)!;
    canvas.drawPath(
      flap,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomRight,
          end: Alignment.topLeft,
          colors: [under, paper],
        ).createShader(Rect.fromLTWH(0, 0, w, h)),
    );

    // Crease highlight — the sharp top edge of the fold catching light.
    canvas.drawLine(
      creaseA,
      creaseB,
      Paint()
        ..color = Colors.white.withValues(alpha: isDark ? 0.06 : 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    // A faint chevron on the flap so the fold clearly reads as "turn the page".
    final cx = w * 0.70, cy = h * 0.70, cs = 5.0;
    canvas.drawPath(
      Path()
        ..moveTo(cx - cs, cy - cs)
        ..lineTo(cx + cs * 0.4, cy)
        ..lineTo(cx - cs, cy + cs),
      Paint()
        ..color = accent.withValues(alpha: 0.80)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _DogEarPainter old) =>
      old.isNext != isNext ||
      old.paper != paper ||
      old.accent != accent ||
      old.isDark != isDark;
}



/// Faint horizontal rules + a soft left margin line, so a memory reads like a
/// page from a lined notebook. Kept very low-contrast on purpose.
class _RuledPaperPainter extends CustomPainter {
  final Color line;
  final Color margin;
  _RuledPaperPainter({required this.line, required this.margin});

  @override
  void paint(Canvas canvas, Size size) {
    final rule = Paint()
      ..color = line
      ..strokeWidth = 1;
    const gap = 30.0;
    for (double y = 62; y < size.height - 8; y += gap) {
      canvas.drawLine(Offset(16, y), Offset(size.width - 16, y), rule);
    }
    final m = Paint()
      ..color = margin
      ..strokeWidth = 1.2;
    canvas.drawLine(const Offset(40, 14), Offset(40, size.height - 12), m);
  }

  @override
  bool shouldRepaint(covariant _RuledPaperPainter old) =>
      old.line != line || old.margin != margin;
}

class _DiaryComposer extends StatefulWidget {
  final Color accent;
  final Map<String, dynamic>? existing; // non-null when editing
  final String? myName; // for the live signature preview
  const _DiaryComposer({required this.accent, this.existing, this.myName});

  @override
  State<_DiaryComposer> createState() => _DiaryComposerState();
}

class _DiaryComposerState extends State<_DiaryComposer> {
  late final TextEditingController _title;
  late final TextEditingController _body;
  bool _planMode = false;
  DateTime? _date;
  bool _pinned = false;
  String _font = ''; // the author's chosen typeface for this memory

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _title = TextEditingController(text: (e?['title'] ?? '').toString());
    _body = TextEditingController(text: (e?['body'] ?? '').toString());
    _planMode = (e?['kind'] ?? 'memory').toString() == 'plan';
    _date = DateTime.tryParse((e?['plan_date'] ?? '').toString());
    _pinned = e?['pinned'] == true;
    _font = (e?['font'] ?? '').toString();
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? now.add(const Duration(days: 1)),
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (picked != null && mounted) setState(() => _date = picked);
  }

  void _save() {
    final body = _body.text.trim();
    if (body.isEmpty) {
      showToast(context, 'Write a little something first.',
          type: ToastType.info);
      return;
    }
    final title = _title.text.trim();
    // plan_date is only meaningful for a plan; send '' (cleared) otherwise so an
    // edit that turns a plan into a memory drops the old date server-side.
    final planDate = _planMode && _date != null
        ? DateFormat('yyyy-MM-dd').format(_date!)
        : '';
    Navigator.pop(context, {
      'kind': _planMode ? 'plan' : 'memory',
      'title': title.isEmpty ? '' : title,
      'body': body,
      'plan_date': planDate,
      'pinned': _planMode && _pinned,
      // Font is the author's per-memory touch; plans (joint) don't carry one.
      'font': _planMode ? '' : _font,
    });
  }

  Widget _sectionLabel(ColorScheme scheme, String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t.toUpperCase(),
            style: TextStyle(
                fontSize: 10.5,
                letterSpacing: 0.8,
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant)),
      );

  Widget _modeSeg(ColorScheme scheme, String label, IconData icon,
      bool selected, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            color: selected ? widget.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            boxShadow: selected
                ? [
                    BoxShadow(
                        color: widget.accent.withValues(alpha: 0.35),
                        blurRadius: 10,
                        offset: const Offset(0, 3))
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 17,
                  color: selected ? Colors.white : scheme.onSurfaceVariant),
              const SizedBox(width: 7),
              Text(label,
                  style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color:
                          selected ? Colors.white : scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fontPill(ColorScheme scheme, (String, String) f) {
    final selected = _font == f.$1;
    return GestureDetector(
      onTap: () => setState(() => _font = f.$1),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? widget.accent.withValues(alpha: 0.14)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: selected
                ? widget.accent
                : scheme.outlineVariant.withValues(alpha: 0.5),
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              Icon(Icons.check_rounded, size: 15, color: widget.accent),
              const SizedBox(width: 6),
            ],
            Text(f.$2,
                style: TextStyle(
                    fontFamily: diaryFontFamily(f.$1),
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? widget.accent : scheme.onSurface)),
          ],
        ),
      ),
    );
  }

  InputDecoration _fieldDecoration(ColorScheme scheme, String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle:
          TextStyle(color: scheme.onSurfaceVariant.withValues(alpha: 0.7)),
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      counterStyle: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide:
            BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: widget.accent, width: 1.6),
      ),
    );
  }

  Widget _signaturePreview(ColorScheme scheme) {
    final name =
        (widget.myName ?? '').trim().isEmpty ? 'You' : widget.myName!.trim();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 18, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            widget.accent.withValues(alpha: 0.08),
            scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          ],
        ),
        border: Border.all(color: widget.accent.withValues(alpha: 0.20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.draw_rounded, size: 13, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text('YOUR SIGNATURE',
                  style: TextStyle(
                      fontSize: 9.5,
                      letterSpacing: 0.8,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Flexible(
                child: Text('— $name',
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: diaryFontFamily(_font) ??
                            diaryFontFamily('handwriting'),
                        fontSize: 22,
                        height: 1.15,
                        color: scheme.onSurface.withValues(alpha: 0.92))),
              ),
              const SizedBox(width: 8),
              Text('❦',
                  style: TextStyle(
                      fontSize: 15,
                      color: widget.accent.withValues(alpha: 0.75))),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final editing = widget.existing != null;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 10, 20, 18 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: widget.accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(Icons.menu_book_rounded,
                      size: 20, color: widget.accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(editing ? 'Edit diary entry' : 'Write in our diary',
                          style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 17,
                              color: scheme.onSurface)),
                      Text(
                          _planMode
                              ? 'A plan to look forward to'
                              : 'A moment worth keeping',
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  _modeSeg(scheme, 'Memory', Icons.auto_stories_rounded,
                      !_planMode, () => setState(() => _planMode = false)),
                  const SizedBox(width: 4),
                  _modeSeg(scheme, 'Plan ahead', Icons.event_rounded, _planMode,
                      () => setState(() => _planMode = true)),
                ],
              ),
            ),
            if (!_planMode) ...[
              const SizedBox(height: 18),
              _sectionLabel(scheme, 'Your handwriting & signature'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [for (final f in kDiaryFonts) _fontPill(scheme, f)],
              ),
              const SizedBox(height: 12),
              _signaturePreview(scheme),
            ],
            const SizedBox(height: 18),
            _sectionLabel(scheme, _planMode ? 'Title' : 'Title (optional)'),
            TextField(
              controller: _title,
              maxLength: 80,
              style: TextStyle(
                  fontFamily: _planMode ? null : diaryFontFamily(_font),
                  fontWeight: FontWeight.w700),
              decoration: _fieldDecoration(
                  scheme,
                  _planMode
                      ? 'What are you planning?'
                      : 'Give this memory a title'),
            ),
            const SizedBox(height: 6),
            _sectionLabel(scheme, _planMode ? 'Details' : 'The story'),
            TextField(
              controller: _body,
              maxLines: 5,
              maxLength: 1000,
              style: TextStyle(
                  fontFamily: _planMode ? null : diaryFontFamily(_font),
                  height: 1.5),
              decoration: _fieldDecoration(
                  scheme,
                  _planMode
                      ? 'Where, when, why it will be special…'
                      : 'Tell the story of this moment…'),
            ),
            if (_planMode) ...[
              const SizedBox(height: 10),
              InkWell(
                onTap: _pickDate,
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                  decoration: BoxDecoration(
                    color:
                        scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: scheme.outlineVariant.withValues(alpha: 0.35)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.event_rounded, color: widget.accent, size: 19),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _date == null
                              ? 'Pick a date (optional)'
                              : DateFormat('EEE, MMM d, yyyy').format(_date!),
                          style: TextStyle(
                            color: _date == null
                                ? scheme.onSurfaceVariant
                                : scheme.onSurface,
                            fontWeight: _date == null
                                ? FontWeight.w400
                                : FontWeight.w700,
                          ),
                        ),
                      ),
                      if (_date != null)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: Icon(Icons.close_rounded,
                              size: 18, color: scheme.onSurfaceVariant),
                          onPressed: () => setState(() => _date = null),
                        ),
                    ],
                  ),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Remind us',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(
                  _date == null
                      ? 'Pick a date to enable a reminder'
                      : 'We will both get a nudge the morning of',
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
                value: _pinned && _date != null,
                onChanged:
                    _date == null ? null : (v) => setState(() => _pinned = v),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: widget.accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: _save,
                icon: Icon(
                    editing ? Icons.check_rounded : Icons.auto_stories_rounded,
                    size: 20),
                label: Text(editing ? 'Save changes' : 'Save to diary',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── memory / plan detail card (full read + reactions + comments) ───────────
class _MemoryDetailSheet extends StatefulWidget {
  final int spaceId;
  final Map<String, dynamic> entry;
  final Color accent;
  final String apiBase;
  final VoidCallback? onChanged;
  const _MemoryDetailSheet({
    required this.spaceId,
    required this.entry,
    required this.accent,
    required this.apiBase,
    this.onChanged,
  });

  @override
  State<_MemoryDetailSheet> createState() => _MemoryDetailSheetState();
}

class _MemoryDetailSheetState extends State<_MemoryDetailSheet> {
  late Map<String, dynamic> _e = Map<String, dynamic>.from(widget.entry);
  final TextEditingController _c = TextEditingController();
  final ScrollController _listC = ScrollController();
  bool _sending = false;
  // The memory body starts collapsed on this comment-focused page so the thread
  // gets the room; the reader expands it if they want the full text.
  bool _memoExpanded = false;
  // Rebuilds the send button's enabled state as the field fills/empties.
  bool _hasText = false;
  // The id of the comment being edited (its text is loaded into the composer),
  // or null when composing a new comment.
  int? _editingId;

  Color get _accent => widget.accent;

  /// Long-press actions on your own comment — a clean sheet instead of an
  /// inline "X". Edit loads it into the composer; Delete removes it.
  void _commentActions(Map<String, dynamic> cm) {
    final cid = (cm['id'] as num?)?.toInt();
    if (cid == null) return;
    final scheme = Theme.of(context).colorScheme;
    final preview = (cm['body'] ?? '').toString().trim();
    // One action row: a rounded, full-width tappable with an icon + label,
    // tinted for a destructive action.
    Widget action(IconData icon, String label, Color color, VoidCallback tap) =>
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Material(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: tap,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                child: Row(
                  children: [
                    Icon(icon, size: 20, color: color),
                    const SizedBox(width: 14),
                    Text(label,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: color)),
                  ],
                ),
              ),
            ),
          ),
        );
    showModalBottomSheet(
      context: context,
      backgroundColor: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        side: BorderSide(color: _accent.withValues(alpha: 0.28)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 10),
            // Grab handle.
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Which comment — a quiet one-line quote so it's clear what you're
            // about to edit or delete.
            if (preview.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Text('“$preview”',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontStyle: FontStyle.italic,
                        color: scheme.onSurfaceVariant)),
              ),
            action(Icons.edit_outlined, 'Edit', _accent, () {
              Navigator.pop(ctx);
              _startEditComment(cm);
            }),
            action(Icons.delete_outline_rounded, 'Delete', scheme.error, () {
              Navigator.pop(ctx);
              _deleteComment(cid);
            }),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  void _startEditComment(Map<String, dynamic> cm) {
    final cid = (cm['id'] as num?)?.toInt();
    if (cid == null) return;
    setState(() {
      _editingId = cid;
      _c.text = (cm['body'] ?? '').toString();
      _c.selection = TextSelection.collapsed(offset: _c.text.length);
    });
  }

  void _cancelEdit() {
    setState(() {
      _editingId = null;
      _c.clear();
    });
  }

  @override
  void initState() {
    super.initState();
    // Live updates: when a bond event lands over the socket (partner reacted or
    // commented), re-fetch THIS memory so its reactions + comment feed update in
    // place without a manual refresh.
    spaceEventBus.addListener(_onBus);
    _c.addListener(_onText);
    // Open on the NEWEST comment, like any chat thread.
    _scrollToBottom(animated: false);
  }

  void _onText() {
    final has = _c.text.trim().isNotEmpty;
    if (has != _hasText) setState(() => _hasText = has);
  }

  /// Drop the comment list to the bottom so the latest message is in view —
  /// on open and after sending. Post-frame so the new row is laid out first.
  void _scrollToBottom({bool animated = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_listC.hasClients) return;
      final max = _listC.position.maxScrollExtent;
      if (animated) {
        _listC.animateTo(max,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOut);
      } else {
        _listC.jumpTo(max);
      }
    });
  }

  @override
  void dispose() {
    spaceEventBus.removeListener(_onBus);
    _c.removeListener(_onText);
    _listC.dispose();
    _c.dispose();
    super.dispose();
  }

  Future<void> _onBus() async {
    final id = (_e['id'] as num?)?.toInt();
    if (id == null) return;
    final full = await ApiService().getSpace(widget.spaceId);
    if (!mounted || full == null) return;
    final match = ((full['diary'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where((e) => (e['id'] as num?)?.toInt() == id)
        .toList();
    if (match.isNotEmpty) {
      final before = _comments.length;
      setState(() => _e = match.first);
      // A comment arrived live (e.g. the partner replied) → bring it into view.
      if (_comments.length > before) _scrollToBottom();
    }
  }

  List<Map<String, dynamic>> get _comments =>
      ((_e['comments'] as List?) ?? const [])
          .whereType<Map>()
          .map((c) => Map<String, dynamic>.from(c))
          .toList();

  Future<void> _toggle(String emoji) async {
    final id = (_e['id'] as num).toInt();
    final updated =
        await ApiService().reactDiaryEntry(widget.spaceId, id, emoji);
    if (!mounted) return;
    if (updated != null) {
      setState(() => _e = updated);
      widget.onChanged?.call();
    } else {
      showToast(context, 'Could not react — try again', type: ToastType.error);
    }
  }

  Future<void> _addComment() async {
    final text = _c.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final id = (_e['id'] as num).toInt();
    final editing = _editingId;
    final c = editing != null
        ? await ApiService().editDiaryComment(widget.spaceId, id, editing, text)
        : await ApiService().addDiaryComment(widget.spaceId, id, text);
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (c != null) {
        final list = List<Map<String, dynamic>>.from(
            (_e['comments'] as List?) ?? const []);
        if (editing != null) {
          final idx =
              list.indexWhere((x) => (x['id'] as num?)?.toInt() == editing);
          if (idx >= 0) {
            list[idx] = Map<String, dynamic>.from(c);
          } else {
            list.add(Map<String, dynamic>.from(c));
          }
        } else {
          list.add(Map<String, dynamic>.from(c));
        }
        _e['comments'] = list;
        _e['comment_count'] = list.length;
        _c.clear();
        _editingId = null;
      }
    });
    if (c != null) {
      widget.onChanged?.call();
      // Follow a freshly sent comment down to it (an edit stays in place).
      if (editing == null) _scrollToBottom();
    } else if (mounted) {
      showToast(
          context,
          editing != null
              ? 'Could not edit comment'
              : 'Could not add comment',
          type: ToastType.error);
    }
  }

  Future<void> _deleteComment(int cid) async {
    final id = (_e['id'] as num).toInt();
    final ok = await ApiService().deleteDiaryComment(widget.spaceId, id, cid);
    if (!mounted) return;
    if (ok) {
      setState(() {
        final list = List<Map<String, dynamic>>.from(
            (_e['comments'] as List?) ?? const []);
        list.removeWhere((x) => (x['id'] as num?)?.toInt() == cid);
        _e['comments'] = list;
        _e['comment_count'] = list.length;
      });
      widget.onChanged?.call();
    }
  }

  /// The memory body text in the author's font; [maxLines] null = full text.
  Widget _memoBody(ColorScheme scheme, String body, int? maxLines) {
    return Text(
      body,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      style: TextStyle(
          fontFamily: diaryFontFamily((_e['font'] ?? '').toString()),
          fontSize: 14.5,
          height: 1.5,
          color: scheme.onSurface),
    );
  }

  /// Two comments count as the same run when they're from the same side of the
  /// bond (so a run of yours, or a run of theirs, groups under one avatar).
  bool _sameRun(Map<String, dynamic> a, Map<String, dynamic> b) {
    if ((a['mine'] == true) != (b['mine'] == true)) return false;
    final ai = ((a['author'] as Map?)?['id'] as num?)?.toInt();
    final bi = ((b['author'] as Map?)?['id'] as num?)?.toInt();
    return ai == bi;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = (_e['title'] ?? '').toString().trim();
    final body = (_e['body'] ?? '').toString().trim();
    final author = (_e['author'] as Map?)?.cast<String, dynamic>();
    final created = DateTime.tryParse((_e['created_at'] ?? '').toString());
    final isPlan = (_e['kind'] ?? '') == 'plan';
    final comments = _comments;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 36),
      backgroundColor: scheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 8, 10),
              child: Row(
                children: [
                  Icon(isPlan ? Icons.event_rounded : Icons.menu_book_rounded,
                      color: _accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                        title.isNotEmpty
                            ? title
                            : (isPlan ? 'Plan' : 'Memory'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: scheme.onSurface)),
                  ),
                  HeaderActionButton(
                    tooltip: 'Minimize',
                    icon: Icons.close_fullscreen_rounded,
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: scheme.outlineVariant),
            // PINNED memory — stays put while the comments scroll below it.
            // Its body is capped + scrolls on its own so a long memory can't
            // swallow the comment area.
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      diaryAuthorBadge(
                        name: (author?['username'] ?? '?').toString(),
                        imageUrl: resolveAvatarUrl(
                            author?['avatar_url']?.toString(), widget.apiBase),
                        radius: 15,
                      ),
                      const Spacer(),
                      if (created != null)
                        Text(_diaryAgo(created),
                            style: TextStyle(
                                fontSize: 11.5,
                                color: scheme.onSurfaceVariant)),
                    ],
                  ),
                  if (body.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    // Collapsed to a few lines by default so the CONVERSATION is
                    // the focus; expands (and scrolls, if very long) on request.
                    AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      alignment: Alignment.topCenter,
                      child: _memoExpanded
                          ? ConstrainedBox(
                              constraints:
                                  const BoxConstraints(maxHeight: 300),
                              child: SingleChildScrollView(
                                child: _memoBody(scheme, body, null),
                              ),
                            )
                          : _memoBody(scheme, body, 3),
                    ),
                    if (body.length > 140)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: GestureDetector(
                          onTap: () => setState(
                              () => _memoExpanded = !_memoExpanded),
                          child: Text(
                              _memoExpanded ? 'Show less' : 'Show more',
                              style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: _accent)),
                        ),
                      ),
                  ],
                  const SizedBox(height: 12),
                  diaryReactionRow(
                    scheme: scheme,
                    accent: _accent,
                    entry: _e,
                    onToggle: _toggle,
                    onAdd: () async {
                      final em = await pickDiaryReaction(context, _accent);
                      if (em != null && mounted) _toggle(em);
                    },
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: scheme.outlineVariant),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    comments.isEmpty
                        ? 'Comments'
                        : 'Comments (${comments.length})',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        color: scheme.onSurface)),
              ),
            ),
            // Comments scroll INDEPENDENTLY, so the memory above stays visible
            // however long the conversation grows.
            Flexible(
              child: comments.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(18, 18, 18, 22),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.forum_outlined,
                              size: 30,
                              color: _accent.withValues(alpha: 0.55)),
                          const SizedBox(height: 8),
                          Text('No comments yet',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: scheme.onSurface)),
                          const SizedBox(height: 2),
                          Text('Be the first to say something 💬',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    )
                  : ListView.builder(
                      controller: _listC,
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                      itemCount: comments.length,
                      itemBuilder: (ctx, i) {
                        // Show the avatar only on the LAST bubble of a run and
                        // tighten spacing within a run, so a burst of messages
                        // from one person reads as a group, like a chat.
                        final grouped = i < comments.length - 1 &&
                            _sameRun(comments[i], comments[i + 1]);
                        return _commentBubble(scheme, comments[i],
                            showAvatar: !grouped, grouped: grouped);
                      },
                    ),
            ),
            Divider(height: 1, color: scheme.outlineVariant),
            // While editing a comment, a slim banner makes it obvious and offers
            // a quick way out.
            if (_editingId != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    Icon(Icons.edit_rounded, size: 15, color: _accent),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('Editing your comment',
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: _accent)),
                    ),
                    TextButton(
                      onPressed: _cancelEdit,
                      style: TextButton.styleFrom(
                          foregroundColor: scheme.onSurfaceVariant,
                          visualDensity: VisualDensity.compact),
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                  14, 10, 14, 12 + MediaQuery.of(context).viewInsets.bottom),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _c,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _addComment(),
                      decoration: InputDecoration(
                        hintText: _editingId != null
                            ? 'Edit your comment…'
                            : 'Add a comment…',
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
                    ),
                  ),
                  const SizedBox(width: 8),
                  _sending
                      ? SizedBox(
                          width: 40,
                          height: 40,
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: _accent),
                          ),
                        )
                      : IconButton.filled(
                          // Disabled (dimmed) until there's something to send.
                          onPressed: _hasText ? _addComment : null,
                          style: IconButton.styleFrom(
                              backgroundColor: _accent,
                              foregroundColor: Colors.white,
                              disabledBackgroundColor:
                                  _accent.withValues(alpha: 0.35)),
                          icon: const Icon(Icons.send_rounded, size: 18),
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A comment as a circle-chat bubble: the sender's photo only (no name), mine
  /// on the right (accent-tinted), the partner's on the left (surface), each
  /// with the near-square tail corner — the same language as the Circle chats.
  Widget _commentBubble(ColorScheme scheme, Map<String, dynamic> cm,
      {bool showAvatar = true, bool grouped = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mine = cm['mine'] == true;
    final author = (cm['author'] as Map?)?.cast<String, dynamic>();
    final body = (cm['body'] ?? '').toString();
    final created = DateTime.tryParse((cm['created_at'] ?? '').toString());
    final cid = (cm['id'] as num?)?.toInt();
    // Avatar only on the last bubble of a run; a same-size spacer otherwise so
    // grouped bubbles stay in the same column.
    final Widget avatar = showAvatar
        ? diaryAuthorBadge(
            name: (author?['username'] ?? '?').toString(),
            imageUrl: resolveAvatarUrl(
                author?['avatar_url']?.toString(), widget.apiBase),
            radius: 12,
          )
        : const SizedBox(width: 24);
    final bubbleColor = mine
        ? _accent.withValues(alpha: isDark ? 0.30 : 0.16)
        : scheme.surfaceContainerHighest;
    final bubble = Flexible(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Modern chat-style: long-press (or right-click) your OWN comment to
        // edit or delete — no cramped inline "X".
        onLongPress: mine && cid != null ? () => _commentActions(cm) : null,
        onSecondaryTap: mine && cid != null ? () => _commentActions(cm) : null,
        child: Container(
          margin: EdgeInsets.only(bottom: grouped ? 3 : 8),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 7),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(mine ? 16 : 4),
            bottomRight: Radius.circular(mine ? 4 : 16),
          ),
          border: Border.all(
              color: (mine ? _accent : scheme.outlineVariant)
                  .withValues(alpha: mine ? 0.35 : 0.4)),
        ),
        child: Column(
          crossAxisAlignment:
              mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(body,
                style: TextStyle(
                    fontSize: 13.5, height: 1.3, color: scheme.onSurface)),
            const SizedBox(height: 3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (created != null)
                  Text(_diaryAgo(created),
                      style: TextStyle(
                          fontSize: 10, color: scheme.onSurfaceVariant)),
                if (mine && cid != null) ...[
                  const SizedBox(width: 5),
                  GestureDetector(
                    onTap: () => _commentActions(cm),
                    child: Icon(Icons.more_horiz_rounded,
                        size: 15,
                        color:
                            scheme.onSurfaceVariant.withValues(alpha: 0.75)),
                  ),
                ],
              ],
            ),
          ],
        ),
        ),
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment:
          mine ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: mine
          ? [bubble, const SizedBox(width: 6), avatar]
          : [avatar, const SizedBox(width: 6), bubble],
    );
  }
}

/// Compose a dedication: pick a song, choose a mood, add a line. Returns true on
/// a successful send so the inbox refreshes.
class _DedicateComposeSheet extends StatefulWidget {
  const _DedicateComposeSheet({required this.spaceId, required this.accent});
  final int spaceId;
  final Color accent;

  @override
  State<_DedicateComposeSheet> createState() => _DedicateComposeSheetState();
}

class _DedicateComposeSheetState extends State<_DedicateComposeSheet> {
  Map<String, dynamic>? _song;
  String? _mood;
  final TextEditingController _noteCtrl = TextEditingController();
  bool _sending = false;
  final AudioRecorder _rec = AudioRecorder();
  bool _recording = false;
  String? _voicePath;
  int _voiceMs = 0;
  Timer? _voiceTimer;

  static const List<String> _moods = [
    '❤️ Loved',
    '🥰 Missing you',
    '🌙 Thinking of you',
    '🙏 Grateful',
    '🔥 Hyped',
    '😌 Calm',
    '🎉 Celebrating',
    '😢 Blue',
  ];

  @override
  void dispose() {
    _noteCtrl.dispose();
    _voiceTimer?.cancel();
    _rec.dispose();
    super.dispose();
  }

  Future<void> _toggleRecord() async {
    if (_recording) {
      _voiceTimer?.cancel();
      try {
        final p = await _rec.stop();
        if (!mounted) return;
        setState(() {
          _recording = false;
          _voicePath = p;
        });
      } catch (_) {
        if (mounted) setState(() => _recording = false);
      }
      return;
    }
    try {
      if (!await _rec.hasPermission()) {
        if (mounted) {
          showToast(context, 'Microphone permission needed',
              type: ToastType.error);
        }
        return;
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/ded_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _rec.start(
        const RecordConfig(
            encoder: AudioEncoder.aacLc, bitRate: 128000, sampleRate: 44100),
        path: path,
      );
      if (!mounted) return;
      setState(() {
        _recording = true;
        _voiceMs = 0;
        _voicePath = null;
      });
      _voiceTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (mounted) setState(() => _voiceMs += 200);
      });
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not start recording',
            type: ToastType.error);
      }
    }
  }

  void _clearVoice() {
    final p = _voicePath;
    setState(() => _voicePath = null);
    if (p != null) {
      try {
        File(p).delete();
      } catch (_) {}
    }
  }

  String _fmtMs(int ms) {
    final s = (ms / 1000).floor();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Widget _voiceRow(ColorScheme scheme) {
    if (_recording) {
      return Row(
        children: [
          IconButton(
            onPressed: _toggleRecord,
            icon: const Icon(Icons.stop_circle_rounded, color: Colors.red),
          ),
          Text('Recording… ${_fmtMs(_voiceMs)}',
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ],
      );
    }
    if (_voicePath != null) {
      return Row(
        children: [
          Icon(Icons.mic_rounded, size: 18, color: widget.accent),
          const SizedBox(width: 6),
          Text('Voice note (${_fmtMs(_voiceMs)})',
              style: TextStyle(
                  color: scheme.onSurface, fontWeight: FontWeight.w600)),
          const Spacer(),
          IconButton(
            onPressed: _clearVoice,
            icon: Icon(Icons.close_rounded,
                size: 18, color: scheme.onSurfaceVariant),
          ),
        ],
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: _toggleRecord,
        icon: Icon(Icons.mic_none_rounded, color: widget.accent),
        label:
            Text('Add a voice note', style: TextStyle(color: widget.accent)),
      ),
    );
  }

  Future<void> _pickSong() async {
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _PlaylistAddSheet(accent: widget.accent),
    );
    if (picked != null && mounted) setState(() => _song = picked);
  }

  Future<void> _send() async {
    if (_song == null) {
      showToast(context, 'Pick a song to dedicate.', type: ToastType.info);
      return;
    }
    setState(() => _sending = true);
    String? voiceUrl;
    if (_voicePath != null) {
      try {
        final bytes = await File(_voicePath!).readAsBytes();
        if (bytes.isNotEmpty) {
          final up = await ApiService().uploadMedia(
            bytes: bytes,
            filename: _voicePath!.replaceAll('\\', '/').split('/').last,
            mime: 'audio/mp4',
          );
          voiceUrl = up?['url'] as String?;
        }
      } catch (_) {}
    }
    final res = await ApiService().createDedication(
      widget.spaceId,
      title: (_song!['title'] ?? '').toString(),
      artist: _song!['artist'] as String?,
      ref: _song!['ref'] as String?,
      mood: _mood,
      note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
      voiceNoteUrl: voiceUrl,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (res != null) {
      showToast(context, 'Dedication sent 💝', type: ToastType.success);
      Navigator.pop(context, true);
    } else {
      showToast(context, 'Could not send the dedication',
          type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final songLabel = _song == null
        ? 'Pick a song'
        : ((_song!['artist'] ?? '').toString().isNotEmpty
            ? '${_song!['title']} — ${_song!['artist']}'
            : (_song!['title'] ?? '').toString());
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 14, 18, 18 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Dedicate a song 💝',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurface)),
          const SizedBox(height: 14),
          InkWell(
            onTap: _pickSong,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: _song == null
                        ? scheme.outlineVariant
                        : widget.accent.withValues(alpha: 0.5)),
              ),
              child: Row(
                children: [
                  Icon(Icons.library_music_rounded,
                      size: 20, color: widget.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(songLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: _song == null
                                ? scheme.onSurfaceVariant
                                : scheme.onSurface,
                            fontWeight: FontWeight.w600)),
                  ),
                  Icon(Icons.chevron_right_rounded,
                      color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text('Mood',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in _moods)
                GestureDetector(
                  onTap: () =>
                      setState(() => _mood = (_mood == m) ? null : m),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: _mood == m
                          ? widget.accent.withValues(alpha: 0.18)
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: _mood == m
                              ? widget.accent
                              : Colors.transparent),
                    ),
                    child: Text(m,
                        style: TextStyle(
                            fontSize: 12.5,
                            color: scheme.onSurface,
                            fontWeight: _mood == m
                                ? FontWeight.w700
                                : FontWeight.w500)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _noteCtrl,
            minLines: 1,
            maxLines: 3,
            maxLength: 300,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: 'A line, if you like…',
              filled: true,
              fillColor: scheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 10),
          _voiceRow(scheme),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: widget.accent),
              onPressed: _sending ? null : _send,
              icon: const Icon(Icons.send_rounded, size: 18),
              label: Text(_sending ? 'Sending…' : 'Send dedication'),
            ),
          ),
        ],
      ),
    );
  }
}

/// A tiny tap-to-play pill for a dedication's voice note (just_audio).
class _DedVoicePlayer extends StatefulWidget {
  const _DedVoicePlayer({required this.url, required this.accent});
  final String url;
  final Color accent;

  @override
  State<_DedVoicePlayer> createState() => _DedVoicePlayerState();
}

class _DedVoicePlayerState extends State<_DedVoicePlayer> {
  final ja.AudioPlayer _p = ja.AudioPlayer();
  bool _playing = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _load();
    _p.playerStateStream.listen((st) {
      if (!mounted) return;
      final done = st.processingState == ja.ProcessingState.completed;
      setState(() => _playing = st.playing && !done);
      if (done) {
        _p.seek(Duration.zero);
        _p.pause();
      }
    });
  }

  Future<void> _load() async {
    try {
      final full = widget.url.startsWith('http')
          ? widget.url
          : '${await AppConfig.baseUrl}${widget.url}';
      await _p.setUrl(full, headers: mediaAuthHeaders(full));
      if (mounted) setState(() => _ready = true);
    } catch (_) {}
  }

  @override
  void dispose() {
    _p.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: !_ready ? null : () => _playing ? _p.pause() : _p.play(),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: widget.accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: widget.accent),
            const SizedBox(width: 6),
            Text(_ready ? 'Voice note' : 'Loading…',
                style: TextStyle(
                    color: scheme.onSurface, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
