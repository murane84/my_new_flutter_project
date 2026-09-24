import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import 'api_service.dart';
import 'home_page.dart' show playbackBus, playlistNotifier;
import 'live_session_screen.dart';
import 'token_helper.dart' show getToken;
import '../utils/toast_helper.dart';
import '../utils/avatar_widget.dart';
import '../utils/popup_shell.dart';
import '../utils/file_bytes.dart';

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
  bool _loading = true;

  int get _id => (_space['id'] as num).toInt();
  Color get _accent => spaceThemeColor(_space['theme'] as String?);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final full = await ApiService().getSpace(_id);
    if (!mounted) return;
    setState(() {
      if (full != null) _space = full;
      _loading = false;
    });
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
    final others = _others;
    if (others.isEmpty) {
      showToast(context, 'This space has no one to listen with yet.',
          type: ToastType.info);
      return;
    }
    final partner = others.first;
    final partnerId = (partner['id'] as num?)?.toInt();
    final partnerName = (partner['username'] ?? 'them').toString();
    final myUserId = widget.myUserId;
    if (partnerId == null || myUserId == null) return;

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
        title: _songTitle(path!),
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
          children: [
            _header(scheme, title),
            const SizedBox(height: 18),
            _statsRow(scheme),
            const SizedBox(height: 18),
            _yourSong(scheme),
            const SizedBox(height: 22),
            _actions(scheme),
            const SizedBox(height: 26),
            Row(
              children: [
                Text('Pinned moments',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: scheme.onSurface)),
                const Spacer(),
                if (_loading)
                  const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            const SizedBox(height: 12),
            if (moments.isEmpty)
              _momentsEmpty(scheme)
            else
              _momentsTimeline(scheme, moments),
          ],
        ),
      ),
    );
  }

  // ── header ───────────────────────────────────────────────────────────────
  Widget _header(ColorScheme scheme, String title) {
    final others = _others;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
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
      child: Column(
        children: [
          _overlappedAvatars(others),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Close since ${_closeSince()}',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9), fontSize: 12.5),
          ),
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
      height: 72,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 48),
            child: _ringed(
              child: InitialsAvatar(
                name: (widget.myName ?? 'You').isEmpty ? 'You' : widget.myName!,
                radius: 30,
                imageUrl: widget.myAvatarUrl,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 48),
            child: _ringed(
              child: InitialsAvatar(
                  name: rightName.isEmpty ? '?' : rightName,
                  radius: 30,
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

  // ── stats ─────────────────────────────────────────────────────────────────
  Widget _statsRow(ColorScheme scheme) {
    final stats = (_space['stats'] as Map?) ?? const {};
    final days = (stats['days_in_song'] as num?)?.toInt() ?? 0;
    final streak = (stats['listen_streak'] as num?)?.toInt() ?? 0;
    return Row(
      children: [
        _statTile(scheme, '🎧', '$days', 'days in a song'),
        const SizedBox(width: 10),
        _statTile(scheme, '🔥', '$streak', 'listen streak'),
        const SizedBox(width: 10),
        _statTile(scheme, '💫', _closeSince() == '—' ? '—' : 'Since',
            _closeSince()),
      ],
    );
  }

  Widget _statTile(
      ColorScheme scheme, String emoji, String big, String label) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 6),
            Text(big,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: scheme.onSurface)),
            const SizedBox(height: 2),
            Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 10.5, color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  // ── your song ───────────────────────────────────────────────────────────
  Widget _yourSong(ColorScheme scheme) {
    final song = (_space['stats'] as Map?)?['your_song'];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: _accent.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.music_note_rounded, color: _accent),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: song is Map
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Your song',
                          style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 2),
                      Text('${song['title'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface)),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Your song',
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface)),
                      const SizedBox(height: 3),
                      Text(
                        'The track you two play most will show here as you listen together.',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  // ── actions ───────────────────────────────────────────────────────────────
  Widget _actions(ColorScheme scheme) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: _listenTogether,
            style: FilledButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Listen together'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _sendMoment,
            style: OutlinedButton.styleFrom(
              foregroundColor: _accent,
              side: BorderSide(color: _accent.withValues(alpha: 0.6)),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: const Icon(Icons.favorite_border_rounded),
            label: const Text('Send a moment'),
          ),
        ),
      ],
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

  // A tender, scroll-back timeline of the bond — each moment shows who sent it,
  // the song (if any), the note, and a heart the other can tap.
  Widget _momentsTimeline(
      ColorScheme scheme, List<Map<String, dynamic>> moments) {
    return Column(
      children: [for (final m in moments) _momentCard(scheme, m)],
    );
  }

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
