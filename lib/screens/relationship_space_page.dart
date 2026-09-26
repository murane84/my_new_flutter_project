import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';

import 'api_service.dart';
import 'home_page.dart' show playbackBus, playlistNotifier;
import 'live_session_screen.dart';
import 'token_helper.dart' show getToken;
import '../services/now_playing_presence.dart';
import '../utils/toast_helper.dart';
import '../utils/avatar_widget.dart';
import '../utils/popup_shell.dart';
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
  'coral': Color(0xFFFF5A5F),
  'violet': Color(0xFF8E7CFF),
  'ocean': Color(0xFF37B0E6),
  'ember': Color(0xFFFF8A3D),
  'forest': Color(0xFF39B54A),
  'rose': Color(0xFFFF4D8D),
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

  const RelationshipSpacePage({
    super.key,
    required this.space,
    required this.apiBase,
    this.myUserId,
    this.myName,
    this.myAvatarUrl,
    this.onChanged,
  });

  @override
  State<RelationshipSpacePage> createState() => _RelationshipSpacePageState();
}

class _RelationshipSpacePageState extends State<RelationshipSpacePage> {
  late Map<String, dynamic> _space = Map<String, dynamic>.from(widget.space);

  int get _id => (_space['id'] as num).toInt();
  Color get _accent => spaceThemeColor(_space['theme'] as String?);

  bool _nudging = false;
  // Set while a feature's floating card is open, so a data reload (from an
  // in-card action or a live bond event) repaints the OPEN card too — not just
  // the main surface underneath it. Cleared when the card closes.
  VoidCallback? _sheetRefresh;

  // A stable key per feature tile, so its on-screen centre can anchor the
  // open/close animation of its floating card (the card grows FROM and is
  // absorbed BACK TO its own tile).
  final GlobalKey _kPlaylist = GlobalKey();
  final GlobalKey _kMoments = GlobalKey();
  final GlobalKey _kDiary = GlobalKey();
  final GlobalKey _kSong = GlobalKey();

  // Our Diary opens as a FULL PAGE below the Our Space header (the header +
  // minimize stay on top); the book's own back arrow returns to the tiles.
  bool _diaryOpen = false;
  // Drives the book's page-turn between memories (adjacent pages peek like a
  // real book at viewportFraction < 1).
  final PageController _diaryPageCtrl = PageController(viewportFraction: 0.92);

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

  Future<void> _load() async {
    final full = await ApiService().getSpace(_id);
    if (!mounted) return;
    setState(() {
      if (full != null) _space = full;
    });
    // Keep an open feature card in sync with the freshly-loaded data.
    _sheetRefresh?.call();
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
    return showModalBottomSheet<String>(
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
                Text('Pick a song to play together',
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
                  leading: Icon(Icons.music_note_rounded, color: _accent),
                  title: Text(_songTitle(paths[i]),
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
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _EditSpaceSheet(
        initialName: deriveSpaceName(_space, widget.myUserId),
        initialTheme: (_space['theme'] as String?) ?? 'coral',
        initialPrimary: _space['is_primary'] == true,
        spaceId: _id,
      ),
    );
    if (changed == true) {
      await _load();
      widget.onChanged?.call();
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

    return AppPopupShell(
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
      headerAction: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          HeaderActionButton(
            tooltip: 'Edit',
            icon: Icons.edit_outlined,
            onPressed: _editSpace,
          ),
          HeaderActionButton(
            tooltip: 'Unpin',
            icon: Icons.push_pin_outlined,
            onPressed: _unpin,
          ),
        ],
      ),
      // Our Diary takes over the body as a full page BELOW this header (the
      // "Our Space" title + minimize stay visible); its own back arrow returns.
      builder: (context, isWide) => _diaryOpen
          ? Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
              child: _diaryBookView(scheme, isWide),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                children: _mainSections(scheme, title, moments),
              ),
            ),
    );
  }

  /// The page's ambient backdrop: a barely-there vertical wash of the Space
  /// colour top and bottom, plus two large soft glows drifting in from the
  /// corners — subtle atmosphere so the hero and tiles read as floating.
  Widget _pageBackdrop(ColorScheme scheme) {
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
          Positioned(top: -110, right: -90, child: glow(300, 0.12)),
          Positioned(bottom: -140, left: -110, child: glow(340, 0.09)),
        ],
      ),
    );
  }

  /// Everything lives on ONE calm surface: a compact hero, any live/contextual
  /// strips, a quick "thinking of you" pill, and a row of feature tiles. Each
  /// tile opens its details in a floating card (see [_openFeatureSheet]) so the
  /// growing content of the playlist, moments and diary never pushes this main
  /// card taller — it stays compact with every feature visible at a glance.
  List<Widget> _mainSections(
      ColorScheme scheme, String title, List<Map<String, dynamic>> moments) {
    final isPair = _partnerId != null;
    return [
      _header(scheme, title),
      _pendingPartnerBanner(scheme),
      _milestoneBanner(scheme),
      const SizedBox(height: 14),
      _tuneInCard(scheme),
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
    return Center(
      child: Material(
        color: _accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          onTap: _nudging ? null : _nudge,
          borderRadius: BorderRadius.circular(24),
          child: Padding(
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
                    : const Text('💭', style: TextStyle(fontSize: 15)),
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
    );
  }

  // ── floating feature card (a tap-opened overlay) ──────────────────────────
  /// Open [body] in a centered floating card so a feature's details — however
  /// long they grow — scroll inside the overlay instead of stretching the main
  /// Our Space surface. [footer] holds the feature's primary actions. While the
  /// card is open, [_sheetRefresh] repaints it whenever the space reloads.
  Future<void> _openFeatureSheet({
    required String title,
    required IconData icon,
    required Widget Function(void Function() refresh) body,
    Widget Function(void Function() refresh)? footer,
    Offset? origin,
  }) async {
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context).size;
    // Anchor the grow/shrink at the tile's on-screen direction (falls back to
    // centre), so the card appears to emerge FROM its tile and, on minimize, be
    // absorbed BACK INTO it.
    final align = origin == null
        ? Alignment.center
        : Alignment(
            ((origin.dx / media.width) * 2 - 1).clamp(-1.0, 1.0),
            ((origin.dy / media.height) * 2 - 1).clamp(-1.0, 1.0),
          );
    var open = true;
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Minimize',
      barrierColor: Colors.black.withValues(alpha: 0.45),
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (dctx, _, _) {
        return StatefulBuilder(
          builder: (dctx, setSheet) {
            void refresh() {
              if (open) setSheet(() {});
            }

            _sheetRefresh = refresh;
            return Dialog(
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 36),
              backgroundColor: scheme.surface,
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 560,
                  maxHeight: MediaQuery.of(dctx).size.height * 0.82,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 14, 8, 10),
                      child: Row(
                        children: [
                          Icon(icon, color: _accent),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(title,
                                style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16,
                                    color: scheme.onSurface)),
                          ),
                          // Raised 3D minimize chip (red hairline), matching the
                          // Our Space header + the rest of the app's popups.
                          HeaderActionButton(
                            tooltip: 'Minimize',
                            icon: Icons.close_fullscreen_rounded,
                            onPressed: () => Navigator.pop(dctx),
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: scheme.outlineVariant),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
                        child: body(refresh),
                      ),
                    ),
                    if (footer != null) ...[
                      Divider(height: 1, color: scheme.outlineVariant),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                        child: footer(refresh),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
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
    open = false;
    _sheetRefresh = null;
  }

  void _openPlaylist([Offset? origin]) {
    final scheme = Theme.of(context).colorScheme;
    _openFeatureSheet(
      origin: origin,
      title: 'Our Playlist',
      icon: Icons.queue_music_rounded,
      body: (refresh) {
        final tracks = ((_space['playlist'] as List?) ?? const [])
            .whereType<Map>()
            .map((t) => Map<String, dynamic>.from(t))
            .toList();
        if (tracks.isEmpty) return _playlistEmpty(scheme);
        return Column(children: [for (final t in tracks) _trackRow(scheme, t)]);
      },
      footer: (refresh) => Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _listenTogether,
              style: FilledButton.styleFrom(
                  backgroundColor: _accent, foregroundColor: Colors.white),
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
                  side: BorderSide(color: _accent.withValues(alpha: 0.6))),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add song'),
            ),
          ),
        ],
      ),
    );
  }

  void _openMoments([Offset? origin]) {
    final scheme = Theme.of(context).colorScheme;
    _openFeatureSheet(
      origin: origin,
      title: 'Pinned moments',
      icon: Icons.favorite_rounded,
      body: (refresh) {
        final moments = ((_space['moments'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
        if (moments.isEmpty) return _momentsEmpty(scheme);
        return Column(children: [for (final m in moments) _momentCard(scheme, m)]);
      },
      footer: (refresh) => SizedBox(
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
  }

  void _openSongMilestones([Offset? origin]) {
    final scheme = Theme.of(context).colorScheme;
    _openFeatureSheet(
      origin: origin,
      title: 'Song & milestones',
      icon: Icons.auto_awesome_rounded,
      body: (refresh) {
        final stats = (_space['stats'] as Map?) ?? const {};
        final song = stats['your_song'];
        final next = stats['next_milestone'];
        final hasHint =
            next is Map && ((next['remaining'] as num?)?.toInt() ?? 0) > 0;
        final days = (stats['days_in_song'] as num?)?.toInt() ?? 0;
        final streak = (stats['listen_streak'] as num?)?.toInt() ?? 0;
        return Column(
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
        );
      },
    );
  }

  void _openDiary([Offset? origin]) {
    // Full page below the Our Space header — the book view (see _diaryBookView).
    setState(() => _diaryOpen = true);
  }

  // ── Our Diary — the full-page book ────────────────────────────────────────
  /// The diary as a book: a slim back bar, then the memories as ruled-paper
  /// pages you turn one at a time, and a "write" button. Plans sit behind a
  /// small chip so the book stays about memories.
  Widget _diaryBookView(ColorScheme scheme, bool isWide) {
    // Read like a journal: oldest memory first, newest last.
    final mems = List<Map<String, dynamic>>.from(_memories)
      ..sort((a, b) => (a['created_at'] ?? '')
          .toString()
          .compareTo((b['created_at'] ?? '').toString()));
    return Column(
      children: [
        // Back to the tiles + title + page count.
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 2, 2, 8),
          child: Row(
            children: [
              HeaderActionButton(
                icon: Icons.arrow_back_rounded,
                tooltip: 'Back',
                onPressed: () => setState(() => _diaryOpen = false),
              ),
              const SizedBox(width: 10),
              Icon(Icons.menu_book_rounded, color: _accent, size: 20),
              const SizedBox(width: 6),
              Text('Our Diary',
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: scheme.onSurface)),
              const Spacer(),
              if (mems.isNotEmpty)
                Text('${mems.length} ${mems.length == 1 ? 'page' : 'pages'}',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
        Expanded(
          child: mems.isEmpty
              ? SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: _diaryEmpty(scheme))
              : PageView.builder(
                  controller: _diaryPageCtrl,
                  itemCount: mems.length,
                  itemBuilder: (ctx, i) => AnimatedBuilder(
                    animation: _diaryPageCtrl,
                    builder: (ctx, child) {
                      // Turning-page depth: the centred page is full size, the
                      // peeking neighbours shrink slightly like leaves of a book.
                      double t = 0;
                      if (_diaryPageCtrl.hasClients &&
                          _diaryPageCtrl.position.hasContentDimensions) {
                        t = (_diaryPageCtrl.page ?? i.toDouble()) - i;
                      }
                      final scale = (1 - (t.abs() * 0.10)).clamp(0.88, 1.0);
                      return Center(
                        child: Transform.scale(scale: scale, child: child),
                      );
                    },
                    child: _memoryBookPage(scheme, mems[i]),
                  ),
                ),
        ),
        _diaryPlansStrip(scheme),
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 2),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _addDiaryEntry,
              style: FilledButton.styleFrom(
                  backgroundColor: _accent, foregroundColor: Colors.white),
              icon: const Icon(Icons.edit_rounded, size: 18),
              label: const Text('Write in our diary'),
            ),
          ),
        ),
      ],
    );
  }

  /// One memory rendered as a page of ruled paper, in its AUTHOR's font. Shows
  /// only the author's photo (no name); readers can react + comment; only the
  /// author gets the edit/delete menu.
  Widget _memoryBookPage(ColorScheme scheme, Map<String, dynamic> e) {
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Container(
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
              // Footer: reactions + comment (readers can always do both).
              Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                decoration: BoxDecoration(
                  color: (isDark ? Colors.black : _accent)
                      .withValues(alpha: isDark ? 0.16 : 0.04),
                  border: Border(
                      top: BorderSide(
                          color: _accent.withValues(alpha: 0.12))),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    diaryReactionRow(
                      scheme: scheme,
                      accent: _accent,
                      entry: e,
                      onToggle: (em) => _reactDiary(e, em),
                      onAdd: () async {
                        final em = await pickDiaryReaction(context, _accent);
                        if (em != null) _reactDiary(e, em);
                      },
                    ),
                    const SizedBox(height: 8),
                    InkWell(
                      onTap: () => _openMemoryDetail(e),
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            vertical: 4, horizontal: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.mode_comment_outlined,
                                size: 16, color: _accent),
                            const SizedBox(width: 6),
                            Text(
                                commentCount == 0
                                    ? 'Comment'
                                    : '$commentCount ${commentCount == 1 ? 'comment' : 'comments'}',
                                style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: _accent)),
                            Icon(Icons.chevron_right_rounded,
                                size: 16, color: _accent),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Edit/Delete menu — only ever shown on the author's own memory.
  Widget _memoryMenuButton(Map<String, dynamic> e, Color ink) {
    return PopupMenuButton<String>(
      tooltip: 'Options',
      icon: Icon(Icons.more_horiz_rounded,
          size: 18, color: ink.withValues(alpha: 0.6)),
      onSelected: (v) {
        if (v == 'edit') {
          _editDiaryEntry(e);
        } else if (v == 'delete') {
          _deleteDiaryEntry(e);
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'edit', child: Text('Edit')),
        PopupMenuItem(value: 'delete', child: Text('Delete')),
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
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 14)),
              const SizedBox(width: 6),
              Text(value,
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      color: scheme.onSurface)),
            ],
          ),
          const SizedBox(height: 2),
          Text(label,
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
    final unit = kind == 'streak' ? 'day' : 'day';
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.auto_awesome_rounded, size: 13, color: _accent),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '$remaining more $unit${remaining == 1 ? '' : 's'} to $label $emoji',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
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
              Text('Your song',
                  style:
                      TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
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
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [
              _accent.withValues(alpha: 0.20),
              _accent.withValues(alpha: 0.08),
            ],
          ),
          border: Border.all(color: _accent.withValues(alpha: 0.35)),
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
    final mine = t['mine'] == true;
    final adder = mine ? 'You' : (t['added_by_username'] ?? '').toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: _accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.music_note_rounded, color: _accent, size: 18),
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
                  artist.isNotEmpty
                      ? '$artist · added by $adder'
                      : 'Added by $adder',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
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
    );
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

    return GestureDetector(
      onLongPress: mine ? () => _confirmDeleteMoment(id) : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                diaryAuthorBadge(
                  name: authorName,
                  imageUrl: _full(author?['avatar_url']),
                  radius: 13,
                ),
                const SizedBox(width: 8),
                Icon(_momentIcon(kind), size: 14, color: _accent),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    authorName.isEmpty ? _momentLabel(kind) : authorName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                        color: scheme.onSurface),
                  ),
                ),
                const Spacer(),
                if (created != null)
                  Text(_timeAgo(created),
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant)),
              ],
            ),
            if (song != null) ...[
              const SizedBox(height: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
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
            if (caption.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(caption,
                  style: TextStyle(
                      fontSize: 13.5, height: 1.3, color: scheme.onSurface)),
            ],
            const SizedBox(height: 6),
            Row(
              children: [
                InkWell(
                  onTap: () => _reactMoment(id, '❤️'),
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          reactedByMe
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          size: 18,
                          color:
                              reactedByMe ? _accent : scheme.onSurfaceVariant,
                        ),
                        if (reactions.isNotEmpty) ...[
                          const SizedBox(width: 5),
                          Text('${reactions.length}',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant)),
                        ],
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
        color: _accent.withValues(alpha: 0.10),
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
      builder: (_) => _DiaryComposer(accent: _accent),
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
      builder: (_) => _DiaryComposer(accent: _accent, existing: e),
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
  const _EditSpaceSheet({
    required this.initialName,
    required this.initialTheme,
    required this.initialPrimary,
    required this.spaceId,
  });

  @override
  State<_EditSpaceSheet> createState() => _EditSpaceSheetState();
}

class _EditSpaceSheetState extends State<_EditSpaceSheet> {
  late final TextEditingController _c =
      TextEditingController(text: widget.initialName);
  late String _theme = widget.initialTheme;
  late bool _primary = widget.initialPrimary;
  bool _busy = false;

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
    Navigator.pop(context, ok != null);
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
          Text('Edit Space',
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  color: scheme.onSurface)),
          const SizedBox(height: 14),
          TextField(
            controller: _c,
            decoration: InputDecoration(
              labelText: 'Name',
              filled: true,
              fillColor: scheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Theme',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final entry in kSpacePalette.entries)
                GestureDetector(
                  onTap: () => setState(() => _theme = entry.key),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: entry.value,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _theme == entry.key
                            ? scheme.onSurface
                            : Colors.transparent,
                        width: 3,
                      ),
                    ),
                    child: _theme == entry.key
                        ? const Icon(Icons.check,
                            color: Colors.white, size: 20)
                        : null,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Hero Space'),
            subtitle: Text(
              widget.initialPrimary
                  ? 'This bond leads your list'
                  : 'Show this bond at the top of your list',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            value: _primary,
            // Already the hero → can't unset directly (promote another instead).
            onChanged: widget.initialPrimary
                ? null
                : (v) => setState(() => _primary = v),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save'),
            ),
          ),
        ],
      ),
    );
  }
}

// ── diary composer sheet ──────────────────────────────────────────────────
/// Write (or edit) a shared diary entry: a memory (something you shared) or a
/// plan ahead (with an optional date + a pin for a reminder). Returns a map
/// {kind, title, body, plan_date, pinned} on save, or null on cancel.
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
  const _DiaryComposer({required this.accent, this.existing});

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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final editing = widget.existing != null;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 18, 20, 18 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(editing ? 'Edit diary entry' : 'Write in our diary',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: scheme.onSurface)),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Memory'),
                  selected: !_planMode,
                  selectedColor: widget.accent.withValues(alpha: 0.22),
                  onSelected: (_) => setState(() => _planMode = false),
                ),
                ChoiceChip(
                  label: const Text('Plan ahead'),
                  selected: _planMode,
                  selectedColor: widget.accent.withValues(alpha: 0.22),
                  onSelected: (_) => setState(() => _planMode = true),
                ),
              ],
            ),
            // A memory carries the author's own "hand" — pick a typeface both of
            // you will see it in. (Plans are joint, so they use the default.)
            if (!_planMode) ...[
              const SizedBox(height: 14),
              Text('Your handwriting',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final f in kDiaryFonts)
                    ChoiceChip(
                      label: Text(f.$2,
                          style: TextStyle(fontFamily: diaryFontFamily(f.$1))),
                      selected: _font == f.$1,
                      selectedColor: widget.accent.withValues(alpha: 0.22),
                      onSelected: (_) => setState(() => _font = f.$1),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            TextField(
              controller: _title,
              maxLength: 80,
              decoration: InputDecoration(
                hintText: _planMode
                    ? 'What are you planning? (a title)'
                    : 'Give this memory a title (optional)',
                filled: true,
                fillColor: scheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _body,
              maxLines: 4,
              maxLength: 1000,
              decoration: InputDecoration(
                hintText: _planMode
                    ? 'The details — where, when, why it’ll be special…'
                    : 'Tell the story of this moment…',
                filled: true,
                fillColor: scheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            if (_planMode) ...[
              const SizedBox(height: 6),
              InkWell(
                onTap: _pickDate,
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
                      Icon(Icons.event_rounded,
                          color: widget.accent, size: 18),
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
                title: const Text('Remind us'),
                subtitle: Text(
                  _date == null
                      ? 'Pick a date to enable a reminder'
                      : 'We’ll both get a nudge the morning of',
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
                value: _pinned && _date != null,
                onChanged: _date == null
                    ? null
                    : (v) => setState(() => _pinned = v),
              ),
            ],
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: widget.accent,
                    foregroundColor: Colors.white),
                onPressed: _save,
                child: Text(editing ? 'Save changes' : 'Save to diary'),
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
  bool _sending = false;

  Color get _accent => widget.accent;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
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
    final c = await ApiService().addDiaryComment(widget.spaceId, id, text);
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (c != null) {
        final list = List<Map<String, dynamic>>.from(
            (_e['comments'] as List?) ?? const []);
        list.add(Map<String, dynamic>.from(c));
        _e['comments'] = list;
        _e['comment_count'] = list.length;
        _c.clear();
      }
    });
    if (c != null) {
      widget.onChanged?.call();
    } else if (mounted) {
      showToast(context, 'Could not add comment', type: ToastType.error);
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
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 168),
                      child: SingleChildScrollView(
                        child: Text(body,
                            style: TextStyle(
                                fontFamily: diaryFontFamily(
                                    (_e['font'] ?? '').toString()),
                                fontSize: 14.5,
                                height: 1.5,
                                color: scheme.onSurface)),
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
                      padding: const EdgeInsets.fromLTRB(18, 6, 18, 14),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                            'No comments yet — start the conversation.',
                            style: TextStyle(
                                fontSize: 12.5,
                                color: scheme.onSurfaceVariant)),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                      itemCount: comments.length,
                      itemBuilder: (ctx, i) =>
                          _commentBubble(scheme, comments[i]),
                    ),
            ),
            Divider(height: 1, color: scheme.outlineVariant),
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
                        hintText: 'Add a comment…',
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
                          onPressed: _addComment,
                          style: IconButton.styleFrom(
                              backgroundColor: _accent,
                              foregroundColor: Colors.white),
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
  Widget _commentBubble(ColorScheme scheme, Map<String, dynamic> cm) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mine = cm['mine'] == true;
    final author = (cm['author'] as Map?)?.cast<String, dynamic>();
    final body = (cm['body'] ?? '').toString();
    final created = DateTime.tryParse((cm['created_at'] ?? '').toString());
    final cid = (cm['id'] as num?)?.toInt();
    final avatar = diaryAuthorBadge(
      name: (author?['username'] ?? '?').toString(),
      imageUrl:
          resolveAvatarUrl(author?['avatar_url']?.toString(), widget.apiBase),
      radius: 12,
    );
    final bubbleColor = mine
        ? _accent.withValues(alpha: isDark ? 0.30 : 0.16)
        : scheme.surfaceContainerHighest;
    final bubble = Flexible(
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
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
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: () => _deleteComment(cid),
                    borderRadius: BorderRadius.circular(20),
                    child: Icon(Icons.close_rounded,
                        size: 13, color: scheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ],
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
