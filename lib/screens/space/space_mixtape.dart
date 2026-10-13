part of '../relationship_space_page.dart';

// Split out of relationship_space_page.dart (pure code movement, no behaviour
// change): mixtape screen. A library `part`, so it shares the page's imports and
// private members.

// ── Monthly Mixtape screen (§5.8) ─────────────────────────────────────────────
/// A playable retrospective of a month: a photo-backed hero with a vinyl and a
/// Play button, the month's warm numbers, the playable song list, and a
/// filmstrip of the month's moments. Playing a song reuses Our Space's existing
/// "play this crate track together" path (passed in as [onPlaySong]).
class _MixtapeScreen extends StatefulWidget {
  const _MixtapeScreen({
    required this.recap,
    required this.apiBase,
    required this.accent,
    required this.onPlaySong,
  });

  final Map<String, dynamic> recap;
  final String apiBase;
  final Color accent;
  final Future<void> Function(Map<String, dynamic> track) onPlaySong;

  @override
  State<_MixtapeScreen> createState() => _MixtapeScreenState();
}

class _MixtapeScreenState extends State<_MixtapeScreen> {
  int _bgIndex = 0;
  Timer? _bgTimer;

  List<Map<String, dynamic>> get _songs =>
      ((widget.recap['songs'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  List<Map<String, dynamic>> get _highlights =>
      ((widget.recap['highlights'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  List<Map<String, dynamic>> get _photoHighlights =>
      _highlights.where((h) => (h['kind'] ?? '') != 'video').toList();

  @override
  void initState() {
    super.initState();
    // A slow cross-fade through the month's photos behind the hero.
    if (_photoHighlights.length > 1) {
      _bgTimer = Timer.periodic(const Duration(seconds: 4), (_) {
        if (!mounted) return;
        setState(() => _bgIndex = (_bgIndex + 1) % _photoHighlights.length);
      });
    }
  }

  @override
  void dispose() {
    _bgTimer?.cancel();
    super.dispose();
  }

  String? _url(Object? ref) {
    final r = (ref ?? '').toString().trim();
    if (r.isEmpty) return null;
    return resolveAvatarUrl(r, widget.apiBase) ?? r;
  }

  Future<void> _playFirst() async {
    final playable = _songs.firstWhere(
      (t) => ((t['audio_url'] ?? '').toString().trim().isNotEmpty) ||
          ((t['ref'] ?? '').toString().trim().isNotEmpty),
      orElse: () => const {},
    );
    if (playable.isEmpty) {
      showToast(context, 'No playable songs saved for this month',
          type: ToastType.info);
      return;
    }
    await widget.onPlaySong(playable);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = widget.accent;
    final label = (widget.recap['label'] ?? 'Our month').toString();
    final nums =
        (widget.recap['numbers'] as Map?)?.cast<String, dynamic>() ?? const {};
    int n(String k) => (nums[k] as num?)?.toInt() ?? 0;
    final songs = _songs;
    final photos = _photoHighlights;
    final bgRef = photos.isNotEmpty
        ? photos[_bgIndex % photos.length]['ref']
        : widget.recap['cover_ref'];
    final bgUrl = _url(bgRef);

    final stats = <(String, int)>[
      ('songs', n('songs')),
      ('photos', n('photos')),
      ('moments', n('moments')),
      ('diary', n('diary')),
      ('listen days', n('listen_days')),
      ('dedications', n('dedications')),
    ].where((e) => e.$2 > 0).toList();

    return Scaffold(
      backgroundColor: scheme.surface,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 320,
            backgroundColor: scheme.surface,
            foregroundColor: Colors.white,
            flexibleSpace: FlexibleSpaceBar(
              background: _hero(scheme, accent, label, bgUrl),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Warm numbers.
                  if (stats.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final st in stats) _statChip(scheme, accent, st.$1, st.$2),
                      ],
                    ),
                  if (stats.isNotEmpty) const SizedBox(height: 22),
                  // The playable songs.
                  if (songs.isNotEmpty) ...[
                    _sectionLabel(scheme, accent, Icons.queue_music_rounded,
                        'The songs'),
                    const SizedBox(height: 8),
                    for (final t in songs) _songRow(scheme, accent, t),
                    const SizedBox(height: 22),
                  ],
                  // The month's moments, as a filmstrip.
                  if (photos.isNotEmpty) ...[
                    _sectionLabel(scheme, accent, Icons.photo_library_rounded,
                        'The moments'),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 120,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: photos.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 10),
                        itemBuilder: (_, i) => _filmFrame(scheme, photos[i]),
                      ),
                    ),
                  ],
                  if (songs.isEmpty && photos.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 30),
                      child: Center(
                        child: Text(
                          'A quiet month — but it was yours.',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hero(ColorScheme scheme, Color accent, String label, String? bgUrl) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Cross-fading photo backdrop (or a themed gradient).
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 900),
          child: bgUrl != null
              ? Image.network(
                  bgUrl,
                  key: ValueKey(bgUrl),
                  fit: BoxFit.cover,
                  headers: mediaAuthHeaders(bgUrl),
                  errorBuilder: (_, _, _) => _gradientBg(scheme, accent),
                )
              : _gradientBg(scheme, accent),
        ),
        // Legibility scrim.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.25),
                Colors.black.withValues(alpha: 0.65),
              ],
            ),
          ),
        ),
        // Vinyl + title + play.
        Align(
          alignment: Alignment.bottomLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('A mixtape of the two of you',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('Our $label',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        height: 1.05)),
                const SizedBox(height: 14),
                GestureDetector(
                  onTap: _playFirst,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 11),
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(30),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 12,
                            offset: const Offset(0, 4)),
                      ],
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.play_arrow_rounded,
                            color: Colors.white, size: 22),
                        SizedBox(width: 6),
                        Text('Play the mixtape',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                fontSize: 14)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _gradientBg(ColorScheme scheme, Color accent) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent,
            Color.alphaBlend(accent.withValues(alpha: 0.6), Colors.black),
          ],
        ),
      ),
      child: Center(
        child: Icon(Icons.album_rounded,
            size: 92, color: Colors.white.withValues(alpha: 0.35)),
      ),
    );
  }

  Widget _statChip(ColorScheme scheme, Color accent, String label, int value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Color.alphaBlend(accent.withValues(alpha: 0.10), scheme.surface),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$value',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  color: accent)),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 12.5, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _sectionLabel(
      ColorScheme scheme, Color accent, IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 17, color: accent),
        const SizedBox(width: 7),
        Text(text,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: scheme.onSurface)),
      ],
    );
  }

  Widget _songRow(ColorScheme scheme, Color accent, Map<String, dynamic> t) {
    final title = (t['title'] ?? 'A song').toString();
    final artist = (t['artist'] ?? '').toString().trim();
    final memo = (t['memo'] ?? '').toString().trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => widget.onPlaySong(t),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(Icons.play_arrow_rounded, color: accent, size: 22),
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
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface)),
                      if (memo.isNotEmpty || artist.isNotEmpty)
                        Text(memo.isNotEmpty ? memo : artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11.5,
                                fontStyle: memo.isNotEmpty
                                    ? FontStyle.italic
                                    : FontStyle.normal,
                                color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _filmFrame(ColorScheme scheme, Map<String, dynamic> h) {
    final url = _url(h['ref']);
    final caption = (h['caption'] ?? '').toString().trim();
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 120,
        height: 120,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (url != null)
              Image.network(url,
                  fit: BoxFit.cover,
                  headers: mediaAuthHeaders(url),
                  errorBuilder: (_, _, _) =>
                      Container(color: scheme.surfaceContainerHighest))
            else
              Container(color: scheme.surfaceContainerHighest),
            if (caption.isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.6),
                      ],
                    ),
                  ),
                  child: Text(caption,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
