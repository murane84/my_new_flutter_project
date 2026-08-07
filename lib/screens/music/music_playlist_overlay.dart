part of '../music_controls.dart';

// The full-screen playlist overlay (search, favourites filter, reorder,
// now-playing pulse) pulled out of music_controls.dart unchanged. Driven
// entirely through its constructor callbacks — no MusicControls state access.

// ─── Playlist overlay ─────────────────────────────────────────────────────────

class _PlaylistOverlay extends StatefulWidget {
  final List<String> playlist;
  final int currentIndex;
  final Set<String> favorites;
  final void Function(int) onPlay;
  final void Function(int) onRemove;
  final void Function(String) onFavorite;
  final void Function(int, int) onReorder;
  final VoidCallback onClose;
  final VoidCallback onAdd;
  final bool loading;

  const _PlaylistOverlay({
    required this.playlist,
    required this.currentIndex,
    required this.favorites,
    required this.onPlay,
    required this.onRemove,
    required this.onFavorite,
    required this.onReorder,
    required this.onClose,
    required this.onAdd,
    this.loading = false,
  });

  @override
  State<_PlaylistOverlay> createState() => _PlaylistOverlayState();
}

class _PlaylistOverlayState extends State<_PlaylistOverlay>
    with SingleTickerProviderStateMixin {
  String _search = '';
  bool _favOnly = false;
  late final ScrollController _listCtrl;
  late final AnimationController _pulseCtrl;
  final GlobalKey _nowKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // Start near the playing row (estimate) so it's already built, then snap
    // pixel-perfect onto it and give it a gentle highlight-pulse.
    final offset = widget.currentIndex > 0
        ? (widget.currentIndex * 56.0 - 100).clamp(0.0, double.infinity)
        : 0.0;
    _listCtrl = ScrollController(initialScrollOffset: offset);
    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 500));

    if (widget.currentIndex >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final ctx = _nowKey.currentContext;
        if (ctx != null) {
          await Scrollable.ensureVisible(
            ctx,
            alignment: 0.35,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeInOut,
          );
        }
        for (int i = 0; i < 2 && mounted; i++) {
          await _pulseCtrl.forward(from: 0);
          if (!mounted) break;
          await _pulseCtrl.reverse();
        }
      });
    }
  }

  @override
  void dispose() {
    _listCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  String _name(String path) {
    final sep = Platform.pathSeparator;
    final n = path.contains(sep)
        ? path.substring(path.lastIndexOf(sep) + 1)
        : path.contains('/')
            ? path.substring(path.lastIndexOf('/') + 1)
            : path;
    final d = n.lastIndexOf('.');
    return _cleanTrackName(d > 0 ? n.substring(0, d) : n);
  }

  // Display title/artist with the user's in-app override applied on top of the
  // heuristic derived from the filename.
  String _effTitle(String path) {
    final ta = _titleArtist(_name(path));
    return metadataStore.title(path, ta.$1);
  }

  String _effArtist(String path) {
    final ta = _titleArtist(_name(path));
    return metadataStore.artist(path, ta.$2 ?? '');
  }

  // Per-track options sheet (opened from the ⋮ button).
  void _showTrackOptions(
      BuildContext context, String path, int realIdx, bool isFav) {
    final scheme = Theme.of(context).colorScheme;
    final title = _effTitle(path);
    final artist = _effArtist(path);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(22),
        ),
        child: SafeArea(
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
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                    if (artist.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant)),
                      ),
                  ],
                ),
              ),
              Divider(height: 1, color: scheme.outlineVariant.withAlpha(70)),
              _optionTile(scheme, Icons.play_arrow_rounded, 'Play now', () {
                Navigator.pop(ctx);
                widget.onPlay(realIdx);
              }),
              _optionTile(scheme, Icons.edit_rounded, 'Edit details', () {
                Navigator.pop(ctx);
                _showEditDetails(context, path);
              }),
              _optionTile(
                scheme,
                isFav ? Icons.favorite : Icons.favorite_border,
                isFav ? 'Remove from favourites' : 'Add to favourites',
                () {
                  Navigator.pop(ctx);
                  widget.onFavorite(path);
                },
                iconColor: isFav ? Colors.pinkAccent : null,
              ),
              _optionTile(
                scheme,
                Icons.playlist_remove_rounded,
                'Remove from list',
                () {
                  Navigator.pop(ctx);
                  widget.onRemove(realIdx);
                },
                danger: true,
              ),
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    );
  }

  Widget _optionTile(ColorScheme scheme, IconData icon, String label,
      VoidCallback onTap,
      {Color? iconColor, bool danger = false}) {
    final c = danger ? scheme.error : scheme.onSurface;
    return ListTile(
      dense: true,
      leading: Icon(icon, color: iconColor ?? c, size: 22),
      title: Text(label, style: TextStyle(color: c, fontSize: 14)),
      onTap: onTap,
    );
  }

  // ── Edit track details (in-app, Play-safe — no file rewrite) ────────────────
  Future<void> _showEditDetails(BuildContext context, String path) async {
    final scheme = Theme.of(context).colorScheme;
    final o = metadataStore.of(path);
    final ta = _titleArtist(_name(path));
    final titleC = TextEditingController(text: o?.title ?? ta.$1);
    final artistC = TextEditingController(text: o?.artist ?? (ta.$2 ?? ''));
    final albumC = TextEditingController(text: o?.album ?? '');
    final genreC = TextEditingController(text: o?.genre ?? '');
    final yearC = TextEditingController(text: o?.year ?? '');

    Widget field(String label, TextEditingController c,
        {TextInputType? kb, IconData? icon}) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          keyboardType: kb,
          decoration: InputDecoration(
            labelText: label,
            prefixIcon: icon != null ? Icon(icon, size: 20) : null,
            isDense: true,
            filled: true,
            fillColor: scheme.surfaceContainerHighest,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      );
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        // Lift above the keyboard.
        padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 8,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 4, bottom: 12),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.onSurfaceVariant.withAlpha(80),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Icon(Icons.edit_note_rounded, color: scheme.primary),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Edit details',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                  // One-tap cleanup of junk titles.
                  TextButton.icon(
                    onPressed: () {
                      titleC.text = _cleanTrackName(titleC.text);
                    },
                    icon: const Icon(Icons.auto_fix_high_rounded, size: 16),
                    label: const Text('Clean'),
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              field('Title', titleC, icon: Icons.music_note_rounded),
              field('Artist', artistC, icon: Icons.person_rounded),
              field('Album', albumC, icon: Icons.album_rounded),
              Row(
                children: [
                  Expanded(child: field('Genre', genreC)),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 110,
                    child: field('Year', yearC,
                        kb: TextInputType.number),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              FilledButton.icon(
                onPressed: () async {
                  await metadataStore.set(
                    path,
                    TrackMeta(
                      title: titleC.text.trim(),
                      artist: artistC.text.trim(),
                      album: albumC.text.trim(),
                      genre: genreC.text.trim(),
                      year: yearC.text.trim(),
                    ),
                  );
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (mounted) setState(() {}); // refresh the list
                },
                icon: const Icon(Icons.check_rounded),
                label: const Text('Save details'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final q = _search.toLowerCase();

    final displayed = widget.playlist
        .asMap()
        .entries
        .where((e) =>
            _name(e.value).toLowerCase().contains(q) &&
            (!_favOnly || widget.favorites.contains(e.value)))
        .toList();

    return Container(
      margin: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.primary.withAlpha(130)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(50),
            blurRadius: 26,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          // Grab handle — tap OR slide down to dismiss the sheet.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            onVerticalDragEnd: (details) {
              // A downward flick (or drag) collapses the panel.
              if ((details.primaryVelocity ?? 0) > 0) widget.onClose();
            },
            child: Container(
              // Generous padding gives the thin bar a comfortable hit area.
              padding: const EdgeInsets.symmetric(vertical: 10),
              width: double.infinity,
              alignment: Alignment.center,
              child: Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: scheme.onSurfaceVariant.withAlpha(90),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withAlpha(120),
              border: Border(
                  bottom: BorderSide(
                      color: scheme.outlineVariant.withAlpha(80))),
            ),
            child: Row(
              children: [
                Icon(Icons.queue_music_rounded,
                    color: scheme.primary, size: 18),
                const SizedBox(width: 6),
                // Flexible prevents overflow when panel is narrow
                Flexible(
                  child: Text(
                    'Playlist (${widget.playlist.length})',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Action icons — compact sizing to fit small panels
                GestureDetector(
                  onTap: widget.onAdd,
                  child: Tooltip(
                    message: 'Add music',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 4),
                      child: Icon(Icons.add_rounded,
                          color: scheme.primary, size: 20),
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () =>
                      setState(() => _favOnly = !_favOnly),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 4),
                    child: Icon(
                      _favOnly
                          ? Icons.favorite
                          : Icons.favorite_border,
                      color: _favOnly
                          ? Colors.pinkAccent
                          : scheme.onSurfaceVariant,
                      size: 18,
                    ),
                  ),
                ),
                // Push the close control to the far edge, away from the
                // add/favourite actions.
                const Spacer(),
                // Close / collapse — down chevron matches the slide-down gesture
                GestureDetector(
                  onTap: widget.onClose,
                  child: Tooltip(
                    message: 'Close',
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        // Red accent touch to match the brand.
                        color: scheme.primary.withAlpha(28),
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.primary.withAlpha(70)),
                      ),
                      child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 22,
                          color: scheme.primary),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Search bar
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: TextField(
              onChanged: (v) => setState(() => _search = v),
              decoration: InputDecoration(
                hintText: 'Search tracks...',
                prefixIcon: const Icon(Icons.search, size: 18),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                filled: true,
                fillColor: scheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),

          // Track list
          Expanded(
            child: widget.loading && widget.playlist.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 30,
                          height: 30,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.6,
                            color: scheme.primary,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'Scanning your music…',
                          style: TextStyle(
                              color: scheme.onSurfaceVariant, fontSize: 13),
                        ),
                      ],
                    ),
                  )
                : displayed.isEmpty
                    ? Center(
                        child: Text(
                          _favOnly ? 'No favorites yet' : 'No tracks match',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      )
                    : ListView.builder(
                    controller: _listCtrl,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 4),
                    itemCount: displayed.length,
                    itemBuilder: (ctx, i) {
                      final entry = displayed[i];
                      // entry.key IS the real index in the full playlist.
                      final realIdx = entry.key;
                      final isNow = realIdx == widget.currentIndex;
                      final isFav =
                          widget.favorites.contains(entry.value);

                      Widget buildRow() => Dismissible(
                        key: ValueKey(entry.value),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 16),
                          color: scheme.error.withAlpha(180),
                          child: const Icon(Icons.delete_outline,
                              color: Colors.white),
                        ),
                        onDismissed: (_) =>
                            widget.onRemove(realIdx),
                        child: ListTile(
                          key: ValueKey('tile_$i'),
                          dense: true,
                          visualDensity:
                              const VisualDensity(vertical: -3),
                          minVerticalPadding: 0,
                          horizontalTitleGap: 10,
                          selected: isNow,
                          selectedTileColor: scheme.primary.withAlpha(
                              isNow
                                  ? 22 + (70 * _pulseCtrl.value).round()
                                  : 22),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 0),
                          leading: CircleAvatar(
                            radius: 15,
                            backgroundColor: isNow
                                ? scheme.primary
                                : scheme.surfaceContainerHighest,
                            child: isNow
                                ? Icon(Icons.equalizer_rounded,
                                    size: 15, color: scheme.onPrimary)
                                : Text('${realIdx + 1}',
                                    style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: scheme.onSurfaceVariant)),
                          ),
                          title: Text(
                            _effTitle(entry.value),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: isNow
                                  ? FontWeight.bold
                                  : FontWeight.w500,
                              color: isNow ? scheme.primary : null,
                            ),
                          ),
                          subtitle: _effArtist(entry.value).isEmpty
                              ? null
                              : Text(
                                  _effArtist(entry.value),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isFav)
                                const Padding(
                                  padding: EdgeInsets.only(right: 2),
                                  child: Icon(Icons.favorite,
                                      size: 14,
                                      color: Colors.pinkAccent),
                                ),
                              IconButton(
                                icon: Icon(Icons.more_vert,
                                    size: 20,
                                    color: scheme.onSurfaceVariant),
                                visualDensity: VisualDensity.compact,
                                tooltip: 'Options',
                                onPressed: () => _showTrackOptions(
                                    context, entry.value, realIdx, isFav),
                              ),
                            ],
                          ),
                          onTap: () => widget.onPlay(realIdx),
                        ),
                      );

                      if (!isNow) return buildRow();
                      // The playing row: keyed for precise scroll + rebuilt on
                      // each pulse frame so its highlight breathes on open.
                      return KeyedSubtree(
                        key: _nowKey,
                        child: AnimatedBuilder(
                          animation: _pulseCtrl,
                          builder: (_, _) => buildRow(),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
