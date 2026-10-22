import 'dart:convert';
import 'dart:async';
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:just_audio/just_audio.dart' as ja;

import 'api_service.dart';
import 'music/player_disc_style.dart' show PlayerStyleController;
import 'home_page.dart' show playbackBus, playlistNotifier;
import 'live_session_screen.dart';
import 'token_helper.dart' show getToken, mediaAuthHeaders;
import '../services/now_playing_presence.dart';
import '../utils/toast_helper.dart';
import '../utils/time_utils.dart' show parseServerTime;
import '../services/heart_lock.dart';
import 'chat/heart_message.dart' show HeartMood, showHeartGenie, heartOpensLabel;
import '../utils/avatar_widget.dart';
import '../utils/popup_shell.dart';
import '../utils/chat_background.dart';
import '../utils/net_image.dart';
import '../widgets/glimpse_video.dart';
import '../utils/app_config.dart';
import '../services/media_store.dart';
import '../utils/romantic_pattern.dart';
import '../services/wallpapers_service.dart';
import '../widgets/wallpaper_gallery.dart';
import '../utils/file_bytes.dart';
import '../services/notif_service.dart'
    show syncDiaryReminders, cancelDiaryReminder, PlanReminder;
import 'package:video_player/video_player.dart';
import '../widgets/genie_menu.dart';
import '../theme/aluta_palette.dart';

part 'space/space_moment_composer.dart'; // moment composer + add-to-playlist sheet
part 'space/space_edit_sheet.dart'; // edit-space sheet + wallpaper picker
part 'space/space_diary.dart'; // diary composer, paper/dog-ear painters, pressable button
part 'space/space_moment_detail.dart'; // moment comments, memory detail sheet, moment video player
part 'space/space_capsules.dart'; // time capsules, dedications, press-play countdown, voice player
part 'space/space_mixtape.dart'; // mixtape screen
part 'space/space_love_letters.dart'; // love letters: secret hearts shelf
part 'space/space_page_helpers_1.dart'; // _RelationshipSpacePageState helpers (30 methods)
part 'space/space_page_helpers_2.dart'; // _RelationshipSpacePageState helpers (15 methods)
part 'space/space_page_helpers_3.dart'; // _RelationshipSpacePageState helpers (23 methods)
part 'space/space_page_helpers_4.dart'; // _RelationshipSpacePageState helpers (36 methods)
part 'space/space_dashboard_layout.dart'; // compact sticky hero + responsive dashboard

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
  // — appended batch: softer pastels + richer mids for more variety —
  'crimson': Color(0xFFE11D48),
  'punch': Color(0xFFF43F5E),
  'blush': Color(0xFFFDA4AF),
  'peach': Color(0xFFFFB4A2),
  'apricot': Color(0xFFFFB877),
  'marigold': Color(0xFFF6A609),
  'honey': Color(0xFFFFD166),
  'mint': Color(0xFF6EE7B7),
  'sea': Color(0xFF2DD4BF),
  'aqua': Color(0xFF22D3EE),
  'azure': Color(0xFF3B82F6),
  'denim': Color(0xFF4F6FE5),
  'periwinkle': Color(0xFF9DA8FF),
  'lavender': Color(0xFFC4B5FD),
  'plum': Color(0xFF8B5CF6),
  'mauve': Color(0xFFC084FC),
  'bubblegum': Color(0xFFFF7AC6),
  'flamingo': Color(0xFFFF6FA3),
  'moss': Color(0xFF5FA14A),
  'olive': Color(0xFF9EB23B),
  'graphite': Color(0xFF475569),
  'steel': Color(0xFF7C8AA0),
  // — appended: rounds every family of the shared Aluta palette to six —
  'petal': Color(0xFFF9A8D4),
  'pistachio': Color(0xFFA3E635),
  'mustard': Color(0xFFCA8A04),
  'sun': Color(0xFFFACC15),
  'butter': Color(0xFFFDE68A),
  'terracotta': Color(0xFFC2410C),
  'rust': Color(0xFFEA580C),
  'charcoal': Color(0xFF334155),
  'mocha': Color(0xFF8D6E63),
  'sand': Color(0xFFC2A27A),
  'neon_red': Color(0xFFFF073A),
  'neon_magenta': Color(0xFFFF00E5),
  'neon_violet': Color(0xFF7A00FF),
  'neon_mint': Color(0xFF00FFC6),
};

// The earned "In tune" accent — a warm anniversary gold, surfaced as a theme
// swatch once the bond crosses the 7-day streak (§5.7).
const Color kInTuneAccent = Color(0xFFE6B84C);

Color spaceThemeColor(String? key) {
  if (key == 'in_tune') return kInTuneAccent;
  return kSpacePalette[key] ?? const Color(0xFFFF5A5F);
}

// The matched fixed size of the two hero stat chips. Both share this exact size
// so they read as a pair, and it's kept a touch under the avatar cluster's
// height (~58px) so the two photos remain the banner's anchor.

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
  // The bond's "In tune" streak (§5.7), fetched alongside the space.
  Map<String, dynamic>? _streak;
  // The most recent FINISHED month that has shared content (from GET /recaps):
  // what the Monthly Mixtape dashboard card offers to open. Null = nothing yet.
  Map<String, dynamic>? _recapReady;
  // Preset ids that ship a landscape (wide) companion — used to swap in the
  // wide wallpaper on desktop/wide screens instead of tiling the portrait.
  final Set<String> _wideWallpaperIds = {};

  int get _id => (_space['id'] as num).toInt();
  // Settings preview a theme live on the whole page until Save / Back.
  String? _previewTheme;
  Color get _accent =>
      spaceThemeColor(_previewTheme ?? _space['theme'] as String?);

  bool _nudging = false;
  // Settings open in place, right under the pinned hero.
  bool _settingsOpen = false;
  // Today's question folds to a chip once you've both answered.
  bool _qExpanded = false;
  // Drawer: sections with nothing in them yet sit behind "More…".
  bool _drawerMore = false;

  // ── "New" dots: what each section held when you last looked (per Space,
  // on this device). A section whose count grew since then shows a dot.
  Map<String, int> _seenCounts = {};
  bool _seenLoaded = false;
  String get _seenKey => 'space_seen_v1_$_id';

  // ── Card order on the phone dashboard (long-press to drag), per Space.
  static const List<String> kDefaultCardOrder = [
    'listen', 'question', 'streak', 'recap', 'plan'
  ];
  List<String> _cardOrder = List.of(kDefaultCardOrder);
  String get _orderKey => 'space_order_v1_$_id';

  Future<void> _loadLocalPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_seenKey);
      final order = prefs.getStringList(_orderKey);
      if (!mounted) return;
      setState(() {
        if (raw != null) {
          _seenCounts = (jsonDecode(raw) as Map)
              .map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
        }
        _seenLoaded = true;
        if (order != null) {
          // Keep known cards only, and add any new ones at the end.
          _cardOrder = [
            ...order.where(kDefaultCardOrder.contains),
            ...kDefaultCardOrder.where((k) => !order.contains(k)),
          ];
        }
      });
    } catch (_) {
      if (mounted) setState(() => _seenLoaded = true);
    }
  }

  /// Everything a section holds (not just what's waiting), for "new" dots.
  int? _totalCount(String key) {
    switch (key) {
      case 'capsule':
        return ((_space['capsules'] as List?) ?? const []).length;
      case 'moments':
        return ((_space['moment_count'] as num?)?.toInt() ??
                ((_space['moments'] as List?) ?? const []).length) +
            ((_space['dedications'] as List?) ?? const []).length;
      default:
        return _sectionCount(key);
    }
  }

  bool _hasNew(String key) {
    if (!_seenLoaded) return false;
    final now = _totalCount(key);
    if (now == null) return false;
    final seen = _seenCounts[key];
    if (seen == null) {
      // First look on this device: this is the baseline, not "new".
      _seenCounts[key] = now;
      _saveSeenSoon();
      return false;
    }
    return now > seen;
  }

  void _markSeen(String? key) {
    if (key == null) return;
    final now = _totalCount(key);
    if (now == null || _seenCounts[key] == now) return;
    _seenCounts[key] = now;
    _saveSeenSoon();
  }

  Timer? _seenSave;
  void _saveSeenSoon() {
    _seenSave?.cancel();
    _seenSave = Timer(const Duration(milliseconds: 400), () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_seenKey, jsonEncode(_seenCounts));
      } catch (_) {}
    });
  }

  bool get _anyNew => _visibleSections().any((s) => _hasNew(s.$1));

  Future<void> _saveCardOrder(List<String> order) async {
    setState(() => _cardOrder = order);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_orderKey, order);
    } catch (_) {}
  }
  // Today's "Us" question: inline text answer + submit guard.
  final TextEditingController _qAnswerCtrl = TextEditingController();
  bool _qSubmitting = false;

  // A stable key per feature tile, so its on-screen centre can anchor the
  // open/close animation of its floating card (the card grows FROM and is
  // absorbed BACK TO its own tile).
  final GlobalKey _kPlaylist = GlobalKey();
  final GlobalKey _kMoments = GlobalKey();
  final GlobalKey _kDiary = GlobalKey();
  final GlobalKey _kCapsule = GlobalKey();

  // A feature opens as a FULL PAGE below the Our Space header (the header +
  // minimize stay on top). null = the tile dashboard; otherwise one of
  // 'playlist' | 'moments' | 'diary' | 'song'. On wide screens a left sidebar
  // lets you jump between sections without returning to the dashboard.
  String? _section;
  // Per-moment keys so a diary entry can glide back to the exact Pinned moment
  // it grew from; _highlightMomentId briefly glows that card on arrival.
  final Map<int, GlobalKey> _momentKeys = {};
  int? _highlightMomentId;
  // On narrow screens the section list lives in a left drawer that slides in
  // over the content; this tracks whether it's showing.
  bool _navDrawerOpen = false;
  // The in-page "how this works" guide for the OPEN section (one at a time).
  bool _guideOpen = false;
  // Drives the book's page-turn between memories (adjacent pages peek like a
  // real book at viewportFraction < 1).
  final PageController _diaryPageCtrl = PageController(viewportFraction: 0.92);
  // The page currently centred — powers the prev/next arrows + the dots.
  int _diaryPage = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _loadLocalPrefs();
    // Repaint when the partner starts/stops/changes what they're playing, so the
    // "tune in together" card appears and clears live.
    NowPlayingPresence.instance.addListener(_onPresence);
    // Reload when a bond action lands over the socket, so an action one partner
    // takes shows up on the other's open page without a manual refresh.
    spaceEventBus.addListener(_onSpaceEvent);
    _loadWideWallpaperIds();
  }

  // Which gallery presets have a landscape companion, so a wide screen shows a
  // real landscape wallpaper rather than a tiled portrait. Cheap + cached.
  Future<void> _loadWideWallpaperIds() async {
    try {
      final presets = await WallpapersService.instance.load();
      if (!mounted) return;
      final ids = <String>{
        for (final p in presets)
          if ((p.wideUrl ?? '').isNotEmpty) p.id,
      };
      if (ids.isNotEmpty) setState(() => _wideWallpaperIds.addAll(ids));
    } catch (_) {}
  }

  @override
  void dispose() {
    NowPlayingPresence.instance.removeListener(_onPresence);
    spaceEventBus.removeListener(_onSpaceEvent);
    _diaryPageCtrl.dispose();
    _qAnswerCtrl.dispose();
    // Flush the "seen" counts now rather than losing a pending save.
    if (_seenSave?.isActive ?? false) {
      _seenSave!.cancel();
      final snapshot = jsonEncode(_seenCounts);
      final key = _seenKey;
      SharedPreferences.getInstance()
          .then((p) => p.setString(key, snapshot))
          .catchError((_) => false);
    }
    super.dispose();
  }

  void _onPresence() {
    if (mounted) setState(() {});
  }

  void _onSpaceEvent() {
    if (mounted) _load();
  }

  // Love letters shelf (space/space_love_letters.dart) — loaded once per visit.
  Future<List<Map<String, dynamic>>>? _lettersFuture;

  int? get _partnerId {
    final o = _others;
    return o.isNotEmpty ? (o.first['id'] as num?)?.toInt() : null;
  }

  String get _fullCacheKey => 'space_full_${_id}_v1';

  Future<void> _load({bool keepCurrent = false}) async {
    // Cache-first: paint the last full copy (diary, moments, playlist…)
    // instantly so the page never opens empty or waits on the server, then
    // refresh in the background. Local-first: the device holds the data.
    //
    // keepCurrent: set right after saving settings. The page already shows the
    // freshly-saved theme/wallpaper from the optimistic update, so we skip the
    // cache-paint — repainting from the stale cached copy would flip the page
    // back to the OLD theme/wallpaper for a moment until the network refresh
    // lands (the "few seconds then it changes" delay). Go straight to refresh.
    if (!keepCurrent) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_fullCacheKey);
        if (raw != null && mounted) {
          final cached = (jsonDecode(raw) as Map).cast<String, dynamic>();
          setState(() => _space = {..._space, ...cached});
        }
      } catch (_) {}
    }
    final full = await ApiService().getSpace(_id);
    if (!mounted) return;
    if (full != null) {
      setState(() => _space = full);
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_fullCacheKey, jsonEncode(full));
      } catch (_) {}
      // Cache any shared crate audio so Listen Together quick-starts.
      _prefetchPlaylistAudio();
      // The "In tune" streak (separate endpoint) — refreshes the hub card and
      // reveals any freshly-earned unlock.
      if (_partnerId != null) _fetchStreak();
      if (_partnerId != null) _fetchRecap();
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

  List<Map<String, dynamic>> get _others {
    final members = (_space['members'] as List?) ?? const [];
    return members
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .where((m) => (m['id'] as num?)?.toInt() != widget.myUserId)
        .toList();
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
    if (!mounted) return;
    // "Dedicate" routes to the full dedication composer (song + mood + voice),
    // reachable from this one composer now.
    if (result['_dedicate'] == true) {
      await _composeDedication();
      return;
    }
    // Multi-photo: upload each image and pin one moment per photo, all sharing
    // the same caption.
    final items = result['_items'];
    if (items is List && items.isNotEmpty) {
      showToast(context, 'Uploading ${items.length} photo'
          '${items.length == 1 ? '' : 's'}…', type: ToastType.info);
      final caption = result['caption'] as String?;
      var ok = 0;
      for (final it in items) {
        final m = it as Map;
        final b = m['bytes'];
        if (b is! List<int>) continue;
        final up = await ApiService().uploadMedia(
          bytes: b,
          filename: (m['filename'] ?? 'photo').toString(),
          mime: (m['mime'] ?? 'image/jpeg').toString(),
        );
        if (!mounted) return;
        if (up == null || up['url'] == null) continue;
        final saved = await ApiService().addMoment(
          _id,
          kind: 'photo',
          ref: up['url'] as String,
          caption: caption,
        );
        if (saved != null) ok++;
      }
      if (!mounted) return;
      if (ok > 0) {
        showToast(context,
            ok == 1 ? 'Moment pinned 💛' : '$ok moments pinned 💛',
            type: ToastType.success);
        _load();
        widget.onChanged?.call();
      } else {
        showToast(context, 'Could not save those photos',
            type: ToastType.error);
      }
      return;
    }
    String? ref = result['ref'] as String?;
    final bytes = result['_bytes'];
    if (bytes is List<int>) {
      showToast(context, 'Uploading…', type: ToastType.info);
      final up = await ApiService().uploadMedia(
        bytes: bytes,
        filename: (result['_filename'] ?? 'moment').toString(),
        mime: (result['_mime'] ?? '').toString(),
      );
      if (!mounted) return;
      if (up == null || up['url'] == null) {
        showToast(context, 'Upload failed — try again', type: ToastType.error);
        return;
      }
      ref = up['url'] as String;
    }
    final saved = await ApiService().addMoment(
      _id,
      kind: (result['kind'] ?? 'note').toString(),
      ref: ref,
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
    final ref = (result['ref'] ?? '').toString();
    String? audioUrl;
    // If the adder has the actual file, upload its bytes (ephemeral) so the
    // partner's device can cache it and EITHER of us can start a Listen
    // Together from a local copy — no fresh byte-streaming per session.
    if (!kIsWeb && ref.isNotEmpty) {
      try {
        final bytes = await readFileBytes(ref);
        if (bytes.isNotEmpty) {
          if (mounted) {
            showToast(context, 'Sharing the song with your partner…',
                type: ToastType.info);
          }
          final up = await ApiService().uploadMedia(
            bytes: bytes,
            filename: ref.split(RegExp(r'[\\/]+')).last,
            mime: _audioMimeFor(ref),
            ephemeral: true,
          );
          if (up != null && up['url'] != null) {
            audioUrl = up['url'] as String;
          }
        }
      } catch (_) {}
    }
    final saved = await ApiService().addTrack(
      _id,
      title: (result['title'] ?? '').toString(),
      artist: result['artist'] as String?,
      ref: result['ref'] as String?,
      audioUrl: audioUrl,
    );
    if (!mounted) return;
    if (saved != null) {
      showToast(context, 'Added to your playlist 🎶', type: ToastType.success);
      _load();
      _prefetchPlaylistAudio();
    } else {
      showToast(context, 'Could not add that track', type: ToastType.error);
    }
  }

  /// The header's settings button: settings open in place under the pinned
  /// hero (the dashboard's cards make way); tapping it again closes them.
  Future<void> _editSpace() async {
    setState(() {
      _settingsOpen = !_settingsOpen;
      _section = null;
      _navDrawerOpen = false;
    });
  }

  /// From the drawer / rail: open settings (never toggles closed).
  void _openSettings() => setState(() {
        _settingsOpen = true;
        _section = null;
        _navDrawerOpen = false;
        _guideOpen = false;
      });

  /// Back to the dashboard cards.
  void _goOverview() => setState(() {
        _markSeen(_section);
        _settingsOpen = false;
        _section = null;
        _navDrawerOpen = false;
        _guideOpen = false;
      });

  void _openNavDrawer() => setState(() => _navDrawerOpen = true);

  void _toggleDrawerMore() => setState(() => _drawerMore = !_drawerMore);

  /// The phone drawer over [content] (the same rail as wide screens): slides
  /// in from the left over a scrim; tap out, its hide button or a swipe left
  /// closes it. Shared by the dashboard and the sections.
  Widget _withNavDrawer(ColorScheme scheme, Widget content, double maxWidth) {
    final drawerW = (maxWidth * 0.74).clamp(230.0, 330.0);
    return Stack(
      children: [
        Positioned.fill(child: content),
        // Swipe in from the left edge to open (as swiping left closes it).
        if (!_navDrawerOpen)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 18,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragUpdate: (d) {
                if (d.delta.dx > 4) _openNavDrawer();
              },
            ),
          ),
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
                child: Container(color: Colors.black.withValues(alpha: 0.4)),
              ),
            ),
          ),
        ),
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
  }

  Widget _settingsPanel() => _EditSpaceSheet(
        key: const ValueKey('space-settings'),
        initialName: deriveSpaceName(_space, widget.myUserId),
        initialTheme: (_space['theme'] as String?) ?? 'coral',
        initialPrimary: _space['is_primary'] == true,
        spaceId: _id,
        initialBackgroundUrl: _space['background_url'] as String?,
        apiBase: widget.apiBase,
        inTuneUnlocked: _hasStreakUnlock('theme_in_tune'),
        onSpaceUpdated: (m) {
          if (mounted) setState(() => _space = {..._space, ...m});
        },
        onDone: _onSettingsDone,
        onPreviewTheme: (k) => setState(() => _previewTheme = k),
      );

  // The settings return 'saved' (name/theme/hero changed), 'unpin' (the user
  // chose Unpin from inside settings), or null (back).
  Future<void> _onSettingsDone(String? result) async {
    if (!mounted) return;
    setState(() {
      _settingsOpen = false;
      // Saved: the server copy now carries it. Back: the old colour returns.
      if (result == 'saved' && _previewTheme != null) {
        _space = {..._space, 'theme': _previewTheme};
      }
      _previewTheme = null;
    });
    if (result == 'saved') {
      await _load(keepCurrent: true);
      widget.onChanged?.call();
    } else if (result == 'unpin') {
      // Unpin now lives inside settings; run the same confirm-and-remove flow.
      await _unpin();
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
      desktopMaxWidth: 1140,
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
                child: _spaceDashboard(scheme, title, moments),
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
      canPop: _section == null && !_navDrawerOpen && !_settingsOpen,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_settingsOpen) {
          setState(() => _settingsOpen = false);
        } else if (_navDrawerOpen) {
          setState(() => _navDrawerOpen = false);
        } else if (_section != null) {
          // Return to the Our Space dashboard instead of closing the page — the
          // section genies back into the tile it came from.
          setState(() {
            _markSeen(_section);
            _section = null;
          });
        }
      },
      child: shell,
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
  /// From a diary entry grown out of a kept moment: hop to the Pinned moments
  /// wall and glide to that very moment, with a brief glow so it's easy to spot.
  void _jumpToMoment(int momentId) {
    setState(() {
      _section = 'moments';
      _navDrawerOpen = false;
      _highlightMomentId = momentId;
    });
    // Wait out the section transition, then ensure the card is on screen.
    Future.delayed(const Duration(milliseconds: 320), () {
      if (!mounted) return;
      final ctx = _momentKeys[momentId]?.currentContext;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOutCubic,
          alignment: 0.12,
        );
      }
    });
    Future.delayed(const Duration(milliseconds: 2800), () {
      if (mounted && _highlightMomentId == momentId) {
        setState(() => _highlightMomentId = null);
      }
    });
  }
  void _openDiary([Offset? origin]) => _goSection('diary');

  void _goSection(String key) =>
      setState(() {
        _markSeen(_section);
        _markSeen(key);
        _section = key;
        _navDrawerOpen = false;
        _guideOpen = false;
        _settingsOpen = false;
      });

  // ── Section navigation (master–detail) ────────────────────────────────────
  /// The sections available for this Space (playlist + diary only when paired).
  List<(String, IconData, String)> _visibleSections() {
    final pair = _partnerId != null;
    return [
      if (pair) ('playlist', Icons.queue_music_rounded, 'Our Playlist'),
      ('moments', Icons.favorite_rounded, 'Pinned moments'),
      if (pair) ('diary', Icons.menu_book_rounded, 'Our Diary'),
      if (pair) ('capsule', Icons.card_giftcard_rounded, 'Love capsule'),
      if (pair) ('letters', Icons.mark_email_unread_rounded, 'Love letters'),
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
        final rawContent = _sectionContent(
          scheme,
          wide,
          _section!,
          onMenu: wide ? null : () => setState(() => _navDrawerOpen = true),
        );
        // Keep rawContent as a STABLE first child of the Stack whether the
        // guide is open or not — toggling only adds/removes the overlay layer.
        // (Conditionally wrapping remounted the subtree, which broke the diary
        // PageView and left a blank page after closing the guide.)
        final content = Stack(children: [
          rawContent,
          if (_guideOpen && _section != null)
            Positioned.fill(
                child: _sectionGuideOverlay(scheme, _section!)),
        ]);
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
        return _withNavDrawer(scheme, content, c.maxWidth);
      },
    );
  }

  /// A section's chrome: header (optional list button + back to dashboard +
  /// icon + title), a scrolling body, and an optional footer bar.
  /// The little "?" in a section header that opens that section's in-page guide.
  Widget _guideButton(ColorScheme scheme) {
    return IconButton(
      tooltip: 'How this works',
      visualDensity: VisualDensity.compact,
      icon: Icon(Icons.help_outline_rounded, size: 20, color: _accent),
      onPressed: () => setState(() => _guideOpen = true),
    );
  }

  /// Per-section guide copy: (title, tagline, steps[icon, head, body]). Add a
  /// case here whenever a new feature section is introduced — the "?" button and
  /// the overlay come for free from _sectionPanel / _sectionScaffold.
  (String, String, List<(IconData, String, String)>) _sectionGuideData(
      String section) {
    switch (section) {
      case 'playlist':
        return (
          'Our Playlist',
          'Your shared soundtrack — and a way to listen as one.',
          [
            (Icons.auto_awesome_rounded, 'Your song, up top',
                'The card at the top shows your current song, days-in-a-song and your streak — the heartbeat of the bond.'),
            (Icons.add_rounded, 'Add songs together',
                'Tap “Add song” to drop a track into your shared crate. Both of you see everything that lands here.'),
            (Icons.play_arrow_rounded, 'Listen together',
                'Tap “Listen together” to play a song in sync — the other person hears it too, and either of you can pause or skip.'),
            (Icons.favorite_rounded, 'It grows on its own',
                'Songs you dedicate or keep from a chat quietly flow in here, memo’d with the moment.'),
          ],
        );
      case 'moments':
        return (
          'Pinned moments',
          'A private wall for the little things worth keeping.',
          [
            (Icons.add_a_photo_rounded, 'Pin anything',
                'Tap “Send a moment” to pin a photo, video, voice note, file, song or a note — just the two of you.'),
            (Icons.emoji_emotions_rounded, 'React & comment',
                'React with any emoji and leave comments on a moment, exactly like the diary.'),
            (Icons.title_rounded, 'Captions sit on the media',
                'Add a line and it floats, bold, over the bottom of the photo or video.'),
            (Icons.menu_book_rounded, 'Carry it to the diary',
                'Tap “Write about this in Our Diary” to grow a moment into a full memory — its photo links back here.'),
            (Icons.card_giftcard_rounded, 'Dedications live here',
                'A dedication (a song + a mood + a voice note) shows up right in this same feed.'),
          ],
        );
      case 'diary':
        return (
          'Our Diary',
          'A shared notebook — memories behind you, plans ahead.',
          [
            (Icons.edit_rounded, 'Write a memory or a plan',
                'Tap “Write in our diary”. A plan can carry a date and a gentle reminder.'),
            (Icons.brush_rounded, 'Your own handwriting',
                'Pick a font for your memories — each person’s entries keep their own hand on the shared page.'),
            (Icons.swipe_rounded, 'Turn the pages',
                'Swipe, or tap the folded dog-ear corner, to move between memories.'),
            (Icons.forum_rounded, 'React & discuss',
                'Both of you can react and comment on any entry.'),
            (Icons.push_pin_rounded, 'Kept from a moment',
                'A memory grown from a pinned moment shows its photo at the top — tap it to jump back to the moment.'),
          ],
        );
      case 'capsule':
        return (
          'Love capsule',
          'A song + a message, sealed until a moment you choose.',
          [
            (Icons.schedule_send_rounded, 'Seal a surprise',
                'Tap “Seal a capsule”: pick a song, write a message, and choose the date and time it unlocks.'),
            (Icons.headphones_rounded, 'Two modes',
                '“Just a message”, or “Listen together” — which opens into a 3-2-1 press-play when it unlocks.'),
            (Icons.lock_clock_rounded, 'Sealed until then',
                'The song and message stay hidden — both of you only see a countdown.'),
            (Icons.notifications_active_rounded, 'Opens right on time',
                'You both get a ping the moment it unlocks. Then tap “Open the capsule”.'),
            (Icons.close_rounded, 'Change your mind',
                'The sender can cancel a capsule any time before it unlocks.'),
          ],
        );
      case 'letters':
        return (
          'Love letters',
          'Every secret heart you\'ve traded, kept to reread.',
          [
            (Icons.favorite_rounded, 'Send one from chat',
                'Tap the ♡ in the composer, pick a mood, write your note. They hold the heart to open it.'),
            (Icons.hourglass_top_rounded, 'Seal it for later',
                'Choose “Open anytime” → a moment (tonight, a birthday…). It stays sealed — even to you — until then.'),
            (Icons.lock_rounded, 'Private by default',
                'With “Lock secret hearts” on, opening asks for your fingerprint, face or PIN, and open letters reseal on their own.'),
            (Icons.mark_email_read_rounded, 'Know it landed',
                'Under a heart you sent you\'ll see “Opened 💗” the moment they open it.'),
          ],
        );
      default:
        return (
          'This section',
          'A quick guide to getting the most from it.',
          const [],
        );
    }
  }

  /// The in-page guide overlay for [section]: a card over the section body with
  /// a title + close (X); dismiss by the X, tapping the dimmed backdrop, or a
  /// swipe DOWN (mobile). Reused by every section via _sectionScaffold.
  Widget _sectionGuideOverlay(ColorScheme scheme, String section) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final (title, tagline, steps) = _sectionGuideData(section);
    void close() => setState(() => _guideOpen = false);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: close, // tap the dimmed backdrop to dismiss
      child: Container(
        color: Colors.black.withValues(alpha: 0.45),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(14),
        child: GestureDetector(
          onTap: () {}, // swallow taps inside the card
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) > 180) close(); // swipe down to close
          },
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 520,
              maxHeight: MediaQuery.of(context).size.height * 0.74,
            ),
            child: Container(
              decoration: BoxDecoration(
                color: isDark
                    ? scheme.surfaceContainerHigh
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _accent.withValues(alpha: 0.30)),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.28),
                      blurRadius: 24,
                      offset: const Offset(0, 10)),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Drag handle (also a swipe-down affordance on mobile).
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                          color: scheme.outlineVariant,
                          borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
                    child: Row(
                      children: [
                        Icon(Icons.lightbulb_rounded,
                            size: 20, color: _accent),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title,
                                  style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 16.5,
                                      color: scheme.onSurface)),
                              const SizedBox(height: 1),
                              Text(tagline,
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: scheme.onSurfaceVariant)),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          icon: Icon(Icons.close_rounded,
                              color: scheme.onSurfaceVariant),
                          onPressed: close,
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: scheme.outlineVariant),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      itemCount: steps.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (ctx, i) {
                        final (icon, head, body) = steps[i];
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: _accent.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(icon, size: 18, color: _accent),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(head,
                                      style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13.5,
                                          color: scheme.onSurface)),
                                  const SizedBox(height: 2),
                                  Text(body,
                                      style: TextStyle(
                                          fontSize: 12.5,
                                          height: 1.35,
                                          color: scheme.onSurfaceVariant)),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                            backgroundColor: _accent,
                            foregroundColor: Colors.white),
                        onPressed: close,
                        child: const Text('Got it'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
              if (_plans.isNotEmpty) ...[
                _diaryPlansStrip(scheme, compact: !isWide),
                const SizedBox(width: 8),
              ],
              _guideButton(scheme),
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
        // Consistent with every other section's footer action.
        _footerBar(_footerPrimary(
            'Write in our diary', Icons.edit_rounded, _addDiaryEntry)),
      ],
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

  // ── Dedications (an in-body section, like the other tiles) ────────────────

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

  Future<void> _composeCapsule() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _CapsuleComposeSheet(spaceId: _id, accent: _accent),
    );
    if (created == true && mounted) _load();
  }

  /// A sync-listen capsule's "press play together" — a shared 3-2-1 countdown,
  /// then the synchronized listen-together session.
  Future<void> _pressPlayTogether() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.72),
      builder: (_) => _PressPlayCountdown(accent: _accent),
    );
    if (!mounted) return;
    await _listenTogether();
  }

  // ── "In tune" streak (§5.7) ───────────────────────────────────────────────
  Future<void> _fetchStreak() async {
    final s = await ApiService().getStreak(_id);
    if (!mounted || s == null) return;
    setState(() => _streak = s);
    // Apply earned cosmetics: the Anniversary Vinyl disc becomes selectable in
    // the player once the bond has reached the 30-day milestone.
    if (_hasStreakUnlock('disc_anniversary')) {
      PlayerStyleController.instance.unlockAnniversary();
    }
    final nu = (s['new_unlocks'] as List?) ?? const [];
    if (nu.isNotEmpty) _showUnlockToast(nu);
  }

  // Ask which months have a recap; keep the most recent finished one for the
  // dashboard card ("Our <Month> is ready").
  Future<void> _fetchRecap() async {
    final r = await ApiService().listRecaps(_id);
    if (!mounted) return;
    final ready = (r?['latest_ready'] as Map?)?.cast<String, dynamic>();
    setState(() => _recapReady = ready);
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
    // Both answered (and no mood to mend): fold to a small chip so the
    // dashboard gets its room back; tap to read the answers.
    final foldMismatch = kind == 'mood' &&
        (myAns?['mood'] ?? '').toString().trim().isNotEmpty &&
        (partnerAns?['mood'] ?? '').toString().trim().isNotEmpty &&
        (myAns?['mood'] ?? '').toString().trim() !=
            (partnerAns?['mood'] ?? '').toString().trim();
    if (revealed && !_qExpanded && !foldMismatch) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Material(
          color: Color.alphaBlend(
              _accent.withValues(alpha: 0.08), scheme.surface),
          shape: StadiumBorder(
              side: BorderSide(color: _accent.withValues(alpha: 0.25))),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () => setState(() => _qExpanded = true),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.check_circle_rounded, size: 18, color: _accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        'You both answered today\'s question',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface)),
                  ),
                  Text('See answers',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: _accent)),
                  Icon(Icons.expand_more_rounded, size: 18, color: _accent),
                ],
              ),
            ),
          ),
        ),
      );
    }

    Widget content;
    if (revealed) {
      final myMood = (myAns?['mood'] ?? '').toString().trim();
      final partnerMood = (partnerAns?['mood'] ?? '').toString().trim();
      final moodMismatch = kind == 'mood' &&
          myMood.isNotEmpty &&
          partnerMood.isNotEmpty &&
          myMood != partnerMood;
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _answerBubble(scheme, 'You', myAns, kind),
          const SizedBox(height: 8),
          _answerBubble(scheme, partnerName, partnerAns, kind),
          if (moodMismatch) ...[
            const SizedBox(height: 10),
            _moodRemedyRow(scheme),
          ],
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
    } else if (kind == 'mood') {
      content = Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final m in _kMoods) _moodChip(scheme, m[0], m[1]),
        ],
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
                      : kind == 'mood'
                          ? Icons.mood_rounded
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

  // Mood-variant options for the daily question (emoji + label). Stored as
  // "<emoji> <label>" so both the picker and the reveal read the same string.
  static const List<List<String>> _kMoods = [
    ['🥰', 'loved'],
    ['😊', 'happy'],
    ['😌', 'calm'],
    ['🤗', 'grateful'],
    ['🥳', 'excited'],
    ['🥺', 'missing you'],
    ['😟', 'anxious'],
    ['😔', 'low'],
    ['😤', 'frustrated'],
    ['😴', 'tired'],
  ];

  Future<void> _sendAnswer({
    String? answerText,
    String? trackTitle,
    String? trackArtist,
    String? trackRef,
    String? mood,
  }) async {
    setState(() => _qSubmitting = true);
    final res = await ApiService().answerQuestion(
      _id,
      answerText: answerText,
      trackTitle: trackTitle,
      trackArtist: trackArtist,
      trackRef: trackRef,
      mood: mood,
    );
    if (!mounted) return;
    setState(() => _qSubmitting = false);
    if (res != null) {
      setState(() {
        _space['question'] = res;
        _qAnswerCtrl.clear();
      });
      // Answering is a meaningful act — refresh the streak so it reflects today.
      if (_partnerId != null) _fetchStreak();
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

  Future<void> _addDiaryEntry({Map<String, dynamic>? fromMoment}) async {
    String? seedTitle;
    String? fromThumb;
    String? fromLabel;
    int? srcId;
    String? srcRef; // the moment's raw media ref, stored for the diary thumb
    if (fromMoment != null) {
      final cap = (fromMoment['caption'] ?? '').toString().trim();
      final k = (fromMoment['kind'] ?? 'note').toString();
      seedTitle = cap.isEmpty ? null : cap;
      fromLabel = 'From ${_momentLabel(k).toLowerCase()} you kept';
      srcId = (fromMoment['id'] as num?)?.toInt();
      if (k == 'photo' || k == 'gif' || k == 'video') {
        srcRef = (fromMoment['ref'] ?? '').toString();
        if (srcRef.isEmpty) srcRef = null;
        fromThumb = srcRef == null ? null : _full(srcRef);
      }
    }
    final res = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _DiaryComposer(
        accent: _accent,
        myName: widget.myName,
        seedTitle: seedTitle,
        fromMomentThumb: fromThumb,
        fromMomentLabel: fromLabel,
      ),
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
      sourceMomentId: srcId,
      sourceThumb: srcRef,
    );
    if (!mounted) return;
    if (saved != null) {
      showToast(
          context,
          fromMoment != null
              ? 'Added to Our Diary 📖 — tap its photo to revisit the moment'
              : 'Saved to your diary 📖',
          type: ToastType.success);
      await _load();
    } else {
      showToast(context, 'Could not save that entry', type: ToastType.error);
    }
  }
}
