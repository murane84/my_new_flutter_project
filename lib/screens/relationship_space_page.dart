import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

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
      // Wider than the default popup so the two-column (summary rail + content)
      // layout has real room on desktop/web/tablet. Narrow screens still get a
      // near-full-width card and the single-column stack.
      desktopMaxWidth: 940,
      headerAction: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _editSpace,
          ),
          IconButton(
            tooltip: 'Unpin',
            icon: const Icon(Icons.push_pin_outlined),
            onPressed: _unpin,
          ),
        ],
      ),
      builder: (context, isWide) => RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          children: _mainSections(scheme, title, moments),
        ),
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
    final playlistCount = ((_space['playlist'] as List?) ?? const []).length;
    final tiles = <Widget>[
      if (_partnerId != null)
        _featureTile(scheme,
            icon: Icons.queue_music_rounded,
            label: 'Our Playlist',
            count: playlistCount,
            subtitle: 'Songs + listen together',
            onTap: _openPlaylist),
      _featureTile(scheme,
          icon: Icons.favorite_rounded,
          label: 'Pinned moments',
          count: moments.length,
          subtitle: 'Dedications & notes',
          onTap: _openMoments),
      if (_partnerId != null)
        _featureTile(scheme,
            icon: Icons.menu_book_rounded,
            label: 'Our Diary',
            count: _diary.length,
            subtitle: 'Memories & plans ahead',
            onTap: _openDiary),
      _featureTile(scheme,
          icon: Icons.auto_awesome_rounded,
          label: 'Song & milestones',
          count: null,
          subtitle: _songSubtitle(),
          onTap: _openSongMilestones),
    ];
    return LayoutBuilder(
      builder: (ctx, c) {
        // Two compact tiles per row once there's a little width (almost always,
        // even on a phone); a single column only on the very narrowest cards.
        final twoCol = c.maxWidth >= 360;
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
    required IconData icon,
    required String label,
    required int? count,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    // No fixed height and no Spacer/stretch: every tile has the same single-line
    // structure, so tiles size to content and naturally match in a row. This
    // avoids the release-web bug where stretch (or a fixed height that's too
    // short) plus a Spacer-containing row breaks sizing and kills taps.
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: _accent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(icon, color: _accent, size: 20),
                  ),
                  if (count != null && count > 0)
                    Container(
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
                    )
                  else
                    const SizedBox(height: 22),
                ],
              ),
              const SizedBox(height: 12),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: scheme.onSurface)),
              const SizedBox(height: 2),
              Row(
                children: [
                  Expanded(
                    child: Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11.5, color: scheme.onSurfaceVariant)),
                  ),
                  Icon(Icons.chevron_right_rounded,
                      size: 18, color: scheme.onSurfaceVariant),
                ],
              ),
            ],
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
  }) async {
    final scheme = Theme.of(context).colorScheme;
    var open = true;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (dctx) {
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
                          IconButton(
                            icon: const Icon(Icons.close_rounded),
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
    );
    open = false;
    _sheetRefresh = null;
  }

  void _openPlaylist() {
    final scheme = Theme.of(context).colorScheme;
    _openFeatureSheet(
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

  void _openMoments() {
    final scheme = Theme.of(context).colorScheme;
    _openFeatureSheet(
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

  void _openSongMilestones() {
    final scheme = Theme.of(context).colorScheme;
    _openFeatureSheet(
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

  void _openDiary() {
    final scheme = Theme.of(context).colorScheme;
    _openFeatureSheet(
      title: 'Our Diary',
      icon: Icons.menu_book_rounded,
      body: (refresh) => _diaryContent(scheme),
      footer: (refresh) => SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _addDiaryEntry,
          style: FilledButton.styleFrom(
              backgroundColor: _accent, foregroundColor: Colors.white),
          icon: const Icon(Icons.edit_rounded, size: 18),
          label: const Text('Write in our diary'),
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
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          'Close since ${_closeSince()}',
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9), fontSize: 12.5),
        ),
      ],
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
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
      ),
      child: LayoutBuilder(
        builder: (ctx, c) {
          // Wide enough to seat the two stats LEFT and RIGHT of the identity
          // block, so the hero stays short instead of growing taller. Below the
          // threshold we stack the stats under the name (the old compact row).
          final sideBySide = hasStats && c.maxWidth >= 440;
          if (sideBySide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _heroSideStat('🔥', '$streak', 'day streak'),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: identity,
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _heroSideStat(
                        '🎧', '$days', days == 1 ? 'day in a song' : 'days in a song'),
                  ),
                ),
              ],
            );
          }
          return Column(
            children: [
              identity,
              if (hasStats) _heroStats(),
            ],
          );
        },
      ),
    );
  }

  /// A vertical stat block that sits beside the identity in the wide hero.
  Widget _heroSideStat(String emoji, String value, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(emoji, style: const TextStyle(fontSize: 20)),
        const SizedBox(height: 3),
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 19)),
        const SizedBox(height: 1),
        Text(label,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85), fontSize: 11)),
      ],
    );
  }

  /// A slim, at-a-glance pair of listening stats woven into the hero itself, so
  /// the main surface shows the pulse of the bond without a separate grey bar.
  /// The moments count now lives on its tile, so it isn't repeated here.
  Widget _heroStats() {
    final stats = (_space['stats'] as Map?) ?? const {};
    final days = (stats['days_in_song'] as num?)?.toInt() ?? 0;
    final streak = (stats['listen_streak'] as num?)?.toInt() ?? 0;
    if (days == 0 && streak == 0) return const SizedBox.shrink();
    Widget chip(String emoji, String value, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 12)),
            const SizedBox(width: 4),
            Text(value,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 12.5)),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 11.5)),
          ],
        );
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          chip('🔥', '$streak', streak == 1 ? 'day streak' : 'day streak'),
          Container(
            width: 1,
            height: 12,
            margin: const EdgeInsets.symmetric(horizontal: 12),
            color: Colors.white.withValues(alpha: 0.35),
          ),
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
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
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
                CircleAvatar(
                  radius: 12,
                  backgroundColor: _accent.withValues(alpha: 0.25),
                  child: Text(
                    (authorName.isNotEmpty ? authorName[0] : '·').toUpperCase(),
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: _accent),
                  ),
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

  Widget _diaryContent(ColorScheme scheme) {
    final plans = _plans;
    final mems = _memories;
    if (plans.isEmpty && mems.isEmpty) return _diaryEmpty(scheme);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (plans.isNotEmpty) ...[
          _diarySectionLabel(scheme, 'Plans ahead', '🗓️'),
          const SizedBox(height: 8),
          for (final e in plans) _planRow(scheme, e),
          if (mems.isNotEmpty) const SizedBox(height: 14),
        ],
        if (mems.isNotEmpty) ...[
          _diarySectionLabel(scheme, 'Memories', '📖'),
          const SizedBox(height: 8),
          for (final e in mems) _memoryRow(scheme, e),
        ],
      ],
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
                style: TextStyle(
                    fontSize: 13, height: 1.3, color: scheme.onSurface)),
          ],
          const SizedBox(height: 6),
          Text(mine ? 'You' : (authorName.isEmpty ? 'Partner' : authorName),
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _memoryRow(ColorScheme scheme, Map<String, dynamic> e) {
    final title = (e['title'] ?? '').toString().trim();
    final body = (e['body'] ?? '').toString().trim();
    final mine = e['mine'] == true;
    final author = (e['author'] as Map?)?.cast<String, dynamic>();
    final authorName = mine ? 'You' : (author?['username'] ?? '').toString();
    final created = DateTime.tryParse((e['created_at'] ?? '').toString());
    return Container(
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
              CircleAvatar(
                radius: 12,
                backgroundColor: _accent.withValues(alpha: 0.25),
                child: Text(
                  (authorName.isNotEmpty ? authorName[0] : '·').toUpperCase(),
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _accent),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(authorName.isEmpty ? 'A memory' : authorName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                        color: scheme.onSurface)),
              ),
              if (created != null)
                Text(_timeAgo(created),
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant)),
              _diaryMenu(scheme, e),
            ],
          ),
          if (title.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(title,
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: scheme.onSurface)),
          ],
          if (body.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(body,
                style: TextStyle(
                    fontSize: 13.5, height: 1.35, color: scheme.onSurface)),
          ],
        ],
      ),
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

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _title = TextEditingController(text: (e?['title'] ?? '').toString());
    _body = TextEditingController(text: (e?['body'] ?? '').toString());
    _planMode = (e?['kind'] ?? 'memory').toString() == 'plan';
    _date = DateTime.tryParse((e?['plan_date'] ?? '').toString());
    _pinned = e?['pinned'] == true;
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
