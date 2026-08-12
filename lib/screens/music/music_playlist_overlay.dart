part of '../music_controls.dart';

// The playlist overlay: search, groups (user-named collections), sorting,
// multi-select bulk actions, favourites filter, and an inline play/seek strip —
// all driven through constructor callbacks (no MusicControls state access).

// ─── Playlist overlay ─────────────────────────────────────────────────────────

// Sort modes for the track list.
enum _PlSort { manual, az, za, artist, recent, fileName, duration, size }

// Smart auto-lists driven by listening stats.
enum _Smart { none, recent, most }

class _PlaylistOverlay extends StatefulWidget {
  final List<String> playlist;
  final int currentIndex;
  final Set<String> favorites;
  final Map<String, List<String>> groups;
  final Map<String, int> playCounts;
  final Map<String, int> lastPlayed;
  final bool loading;

  // Inline transport strip.
  final AudioPlayer player; // observed for live play-state
  final String currentTitle;
  final bool hasTrack;
  final void Function(List<String> paths, int startIndex, bool shuffle)
      onPlayScope;
  final VoidCallback onTogglePlay;
  final VoidCallback onNext;
  final VoidCallback onPrev;
  final void Function(double fraction) onSeekFraction;

  // List ops.
  final void Function(int) onRemove;
  final void Function(String) onFavorite;
  final void Function(String) onShare;
  final VoidCallback onClose;
  final VoidCallback onAdd;

  // Groups.
  final void Function(String name) onCreateGroup;
  final void Function(String name) onDeleteGroup;
  final void Function(String oldName, String newName) onRenameGroup;
  final void Function(String path, Set<String> groups) onSetSongGroups;
  final void Function(List<String> paths, String group) onAddManyToGroup;

  // Bulk selection.
  final void Function(List<String> paths) onRemoveMany;
  final void Function(List<String> paths, bool fav) onFavoriteMany;

  // Presentation: when true this is shown as a right-side full-height DRAWER
  // (no bottom-sheet grab handle/margin/border of its own; a right-pointing
  // back button collapses it) rather than the old bottom sheet.
  final bool drawer;

  // True when hosted on the CHAT surface (phone), where the app's now-playing
  // bar already provides transport — so this body drops its inline strip to
  // avoid two players for one song. False on the music surface (keeps the strip).
  final bool hostIsChat;

  const _PlaylistOverlay({
    required this.playlist,
    required this.currentIndex,
    required this.favorites,
    required this.groups,
    required this.playCounts,
    required this.lastPlayed,
    required this.player,
    required this.currentTitle,
    required this.hasTrack,
    required this.onPlayScope,
    required this.onTogglePlay,
    required this.onNext,
    required this.onPrev,
    required this.onSeekFraction,
    required this.onRemove,
    required this.onFavorite,
    required this.onShare,
    required this.onClose,
    required this.onAdd,
    required this.onCreateGroup,
    required this.onDeleteGroup,
    required this.onRenameGroup,
    required this.onSetSongGroups,
    required this.onAddManyToGroup,
    required this.onRemoveMany,
    required this.onFavoriteMany,
    this.loading = false,
    this.drawer = false,
    this.hostIsChat = false,
  });

  @override
  State<_PlaylistOverlay> createState() => _PlaylistOverlayState();
}

class _PlaylistOverlayState extends State<_PlaylistOverlay>
    with SingleTickerProviderStateMixin {
  String _search = '';
  bool _favOnly = false;
  String? _activeGroup; // null = no group filter
  _Smart _smart = _Smart.none; // Recent / Most-played auto-list
  _PlSort _sort = _PlSort.manual;

  // Per-track duration (ms) + file size (bytes), used by the Duration / File
  // size sorts. Filled lazily from the device MediaStore (+ filesystem fallback
  // for app-cached files); missing entries sort as 0.
  Map<String, int> _durMs = {};
  Map<String, int> _sizeB = {};
  // Per-track MediaStore id, used to pull embedded album art for the row leading.
  Map<String, int> _songId = {};

  // Multi-select mode.
  bool _selecting = false;
  final Set<String> _selected = {};

  late final ScrollController _listCtrl;
  late final AnimationController _pulseCtrl;
  final GlobalKey _nowKey = GlobalKey();

  @override
  void initState() {
    super.initState();
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
    _loadTrackMeta();
  }

  /// Populate the duration/size maps used by the Duration & File-size sorts.
  /// MediaStore (on_audio_query) gives both for device songs; for any path it
  /// doesn't know (app-cached / shared files) we read the size off disk.
  Future<void> _loadTrackMeta() async {
    final dur = <String, int>{};
    final size = <String, int>{};
    final ids = <String, int>{};
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final songs = await OnAudioQuery().querySongs();
        for (final s in songs) {
          final p = s.data;
          if (p.isEmpty) continue;
          // Read via dynamic so this compiles whether the plugin types these as
          // int or int? — and to sidestep the matching analyzer warnings.
          final dynamic dRaw = s.duration;
          final dynamic szRaw = s.size;
          final dynamic idRaw = s.id;
          final int d = dRaw is int ? dRaw : 0;
          final int sz = szRaw is int ? szRaw : 0;
          final int id = idRaw is int ? idRaw : 0;
          if (d > 0) dur[p] = d;
          if (sz > 0) size[p] = sz;
          if (id > 0) ids[p] = id;
        }
      }
    } catch (_) {/* desktop / no permission — fall back to file stats */}
    for (final p in widget.playlist) {
      if (!size.containsKey(p)) {
        try {
          final f = File(p);
          if (f.existsSync()) size[p] = f.lengthSync();
        } catch (_) {/* unreadable path */}
      }
    }
    if (!mounted) return;
    setState(() {
      _durMs = dur;
      _sizeB = size;
      _songId = ids;
    });
  }

  /// Row leading: the now-playing indicator, the song's embedded cover art when
  /// we can pull it, or a music-note icon — never the raw track number.
  Widget _leadingArt(String path, bool isNow, ColorScheme scheme) {
    if (isNow) {
      return CircleAvatar(
        radius: 15,
        backgroundColor: scheme.primary,
        child:
            Icon(Icons.equalizer_rounded, size: 15, color: scheme.onPrimary),
      );
    }
    final fallback = CircleAvatar(
      radius: 15,
      backgroundColor: scheme.surfaceContainerHighest,
      child: Icon(Icons.music_note_rounded,
          size: 16, color: scheme.onSurfaceVariant),
    );
    final id = _songId[path];
    // Embedded art is only queryable from the device MediaStore (Android/iOS).
    if (id == null || !(Platform.isAndroid || Platform.isIOS)) return fallback;
    return SizedBox(
      width: 30,
      height: 30,
      child: ClipOval(
        child: QueryArtworkWidget(
          id: id,
          type: ArtworkType.AUDIO,
          artworkWidth: 30,
          artworkHeight: 30,
          artworkFit: BoxFit.cover,
          keepOldArtwork: true,
          nullArtworkWidget: fallback,
        ),
      ),
    );
  }

  // Raw file name (with extension) for the "File name" sort — distinct from the
  // cleaned display title used by the A→Z sorts.
  String _rawFileName(String path) {
    final sep = Platform.pathSeparator;
    if (path.contains(sep)) return path.substring(path.lastIndexOf(sep) + 1);
    if (path.contains('/')) return path.substring(path.lastIndexOf('/') + 1);
    return path;
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

  String _effTitle(String path) {
    final ta = _titleArtist(_name(path));
    return metadataStore.title(path, ta.$1);
  }

  String _effArtist(String path) {
    final ta = _titleArtist(_name(path));
    return metadataStore.artist(path, ta.$2 ?? '');
  }

  String _fmtTime(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  // The filtered + sorted view. entry.key = real library index, entry.value = path.
  List<MapEntry<int, String>> _displayed() {
    final q = _search.toLowerCase();
    final groupMembers =
        _activeGroup == null ? null : (widget.groups[_activeGroup] ?? const []);

    var entries = widget.playlist.asMap().entries.where((e) {
      if (q.isNotEmpty &&
          !_effTitle(e.value).toLowerCase().contains(q) &&
          !_effArtist(e.value).toLowerCase().contains(q)) {
        return false;
      }
      // Smart lists override the favourite/group filter with a stats filter.
      if (_smart == _Smart.recent) {
        return (widget.lastPlayed[e.value] ?? 0) > 0;
      }
      if (_smart == _Smart.most) {
        return (widget.playCounts[e.value] ?? 0) > 0;
      }
      if (_favOnly && !widget.favorites.contains(e.value)) return false;
      if (groupMembers != null && !groupMembers.contains(e.value)) return false;
      return true;
    }).toList();

    // Smart lists carry their own ordering (most-recent / most-played first).
    if (_smart == _Smart.recent) {
      entries.sort((a, b) => (widget.lastPlayed[b.value] ?? 0)
          .compareTo(widget.lastPlayed[a.value] ?? 0));
      return entries;
    }
    if (_smart == _Smart.most) {
      entries.sort((a, b) => (widget.playCounts[b.value] ?? 0)
          .compareTo(widget.playCounts[a.value] ?? 0));
      return entries;
    }

    switch (_sort) {
      case _PlSort.az:
        entries.sort((a, b) =>
            _effTitle(a.value).toLowerCase().compareTo(_effTitle(b.value).toLowerCase()));
        break;
      case _PlSort.za:
        entries.sort((a, b) =>
            _effTitle(b.value).toLowerCase().compareTo(_effTitle(a.value).toLowerCase()));
        break;
      case _PlSort.artist:
        entries.sort((a, b) {
          final c = _effArtist(a.value)
              .toLowerCase()
              .compareTo(_effArtist(b.value).toLowerCase());
          return c != 0
              ? c
              : _effTitle(a.value)
                  .toLowerCase()
                  .compareTo(_effTitle(b.value).toLowerCase());
        });
        break;
      case _PlSort.recent:
        // Newly-added songs are appended to the library, so newest = highest index.
        entries = entries.reversed.toList();
        break;
      case _PlSort.fileName:
        entries.sort((a, b) => _rawFileName(a.value)
            .toLowerCase()
            .compareTo(_rawFileName(b.value).toLowerCase()));
        break;
      case _PlSort.duration:
        // Shortest first; unknown durations (0) sink to the top harmlessly.
        entries.sort(
            (a, b) => (_durMs[a.value] ?? 0).compareTo(_durMs[b.value] ?? 0));
        break;
      case _PlSort.size:
        // Largest first — the more useful default when hunting big files.
        entries.sort(
            (a, b) => (_sizeB[b.value] ?? 0).compareTo(_sizeB[a.value] ?? 0));
        break;
      case _PlSort.manual:
        break;
    }
    return entries;
  }

  void _toggleSelect(String path) {
    setState(() {
      if (_selected.contains(path)) {
        _selected.remove(path);
        if (_selected.isEmpty) _selecting = false;
      } else {
        _selected.add(path);
      }
    });
  }

  void _enterSelect(String path) {
    setState(() {
      _selecting = true;
      _selected
        ..clear()
        ..add(path);
    });
  }

  void _exitSelect() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  // ── Groups: create / manage ─────────────────────────────────────────────────

  Future<void> _promptCreateGroup(BuildContext context,
      {List<String>? addPaths}) async {
    final scheme = Theme.of(context).colorScheme;
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: scheme.surface,
        title: const Text('New group'),
        content: TextField(
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            hintText: 'e.g. Gospels',
            prefixIcon: Icon(Icons.folder_rounded),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('Create')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    widget.onCreateGroup(name);
    if (addPaths != null && addPaths.isNotEmpty) {
      widget.onAddManyToGroup(addPaths, name);
    }
    if (mounted) setState(() => _activeGroup = name);
  }

  void _manageGroup(BuildContext context, String name) {
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(10),
        decoration: BoxDecoration(
            color: scheme.surface, borderRadius: BorderRadius.circular(22)),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Text(name,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
              Text('${widget.groups[name]?.length ?? 0} songs',
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 6),
              Divider(height: 1, color: scheme.outlineVariant.withAlpha(70)),
              _optionTile(scheme, Icons.play_arrow_rounded, 'Play group', () {
                Navigator.pop(ctx);
                final paths = List<String>.from(widget.groups[name] ?? const []);
                if (paths.isNotEmpty) widget.onPlayScope(paths, 0, false);
              }),
              _optionTile(scheme, Icons.shuffle_rounded, 'Shuffle group', () {
                Navigator.pop(ctx);
                final paths = List<String>.from(widget.groups[name] ?? const []);
                if (paths.isNotEmpty) widget.onPlayScope(paths, 0, true);
              }),
              _optionTile(scheme, Icons.drive_file_rename_outline_rounded,
                  'Rename group', () {
                Navigator.pop(ctx);
                _promptRenameGroup(context, name);
              }),
              _optionTile(scheme, Icons.delete_outline_rounded, 'Delete group',
                  () {
                Navigator.pop(ctx);
                widget.onDeleteGroup(name);
                if (mounted && _activeGroup == name) {
                  setState(() => _activeGroup = null);
                }
              }, danger: true),
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _promptRenameGroup(BuildContext context, String oldName) async {
    final scheme = Theme.of(context).colorScheme;
    final c = TextEditingController(text: oldName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: scheme.surface,
        title: const Text('Rename group'),
        content: TextField(
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == oldName) return;
    widget.onRenameGroup(oldName, name);
    if (mounted && _activeGroup == oldName) {
      setState(() => _activeGroup = name);
    }
  }

  // Checkbox sheet: which groups a song belongs to.
  void _showAddToGroups(BuildContext context, String path) {
    final scheme = Theme.of(context).colorScheme;
    final selected = <String>{
      for (final e in widget.groups.entries)
        if (e.value.contains(path)) e.key
    };
    showModalBottomSheet(
      context: context,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              const Text('Add to groups',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 6),
              if (widget.groups.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('No groups yet — create one below.',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final g in widget.groups.keys)
                      CheckboxListTile(
                        dense: true,
                        value: selected.contains(g),
                        title: Text(g),
                        onChanged: (v) => setSheet(() {
                          v == true ? selected.add(g) : selected.remove(g);
                        }),
                      ),
                  ],
                ),
              ),
              Divider(height: 1, color: scheme.outlineVariant.withAlpha(70)),
              ListTile(
                leading: Icon(Icons.add_rounded, color: scheme.primary),
                title: Text('New group…',
                    style: TextStyle(color: scheme.primary)),
                onTap: () {
                  Navigator.pop(ctx);
                  _promptCreateGroup(context, addPaths: [path]);
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      widget.onSetSongGroups(path, selected);
                      Navigator.pop(ctx);
                    },
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('Save'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Bulk: pick a group to add the current selection to.
  void _bulkAddToGroup(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final paths = _selected.toList();
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
            const SizedBox(height: 10),
            Text('Add ${paths.length} to group',
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 6),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final g in widget.groups.keys)
                    ListTile(
                      dense: true,
                      leading: Icon(Icons.folder_rounded, color: scheme.primary),
                      title: Text(g),
                      onTap: () {
                        widget.onAddManyToGroup(paths, g);
                        Navigator.pop(ctx);
                        _exitSelect();
                      },
                    ),
                ],
              ),
            ),
            Divider(height: 1, color: scheme.outlineVariant.withAlpha(70)),
            ListTile(
              leading: Icon(Icons.add_rounded, color: scheme.primary),
              title:
                  Text('New group…', style: TextStyle(color: scheme.primary)),
              onTap: () {
                Navigator.pop(ctx);
                _promptCreateGroup(context, addPaths: paths);
                _exitSelect();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // Sort picker.
  void _showSort(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget tile(_PlSort mode, IconData icon, String label) {
      final on = _sort == mode;
      return ListTile(
        dense: true,
        leading: Icon(icon,
            color: on ? scheme.primary : scheme.onSurfaceVariant),
        title: Text(label,
            style: TextStyle(color: on ? scheme.primary : null)),
        trailing: on
            ? Icon(Icons.check_rounded, color: scheme.primary)
            : null,
        onTap: () {
          setState(() => _sort = mode);
          Navigator.pop(context);
        },
      );
    }
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
            const SizedBox(height: 10),
            const Text('Sort by',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 4),
            tile(_PlSort.manual, Icons.reorder_rounded, 'Custom (added order)'),
            tile(_PlSort.az, Icons.sort_by_alpha_rounded, 'Title A → Z'),
            tile(_PlSort.za, Icons.sort_by_alpha_rounded, 'Title Z → A'),
            tile(_PlSort.fileName, Icons.text_snippet_rounded, 'File name'),
            tile(_PlSort.artist, Icons.person_rounded, 'Artist'),
            tile(_PlSort.recent, Icons.schedule_rounded, 'Recently added'),
            tile(_PlSort.duration, Icons.timer_outlined, 'Duration (shortest first)'),
            tile(_PlSort.size, Icons.sd_storage_rounded, 'File size (largest first)'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // Per-track options sheet (⋮).
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
                                fontSize: 12, color: scheme.onSurfaceVariant)),
                      ),
                  ],
                ),
              ),
              Divider(height: 1, color: scheme.outlineVariant.withAlpha(70)),
              _optionTile(scheme, Icons.play_arrow_rounded, 'Play now', () {
                Navigator.pop(ctx);
                _playPath(path);
              }),
              _optionTile(scheme, Icons.playlist_add_rounded, 'Add to groups',
                  () {
                Navigator.pop(ctx);
                _showAddToGroups(context, path);
              }),
              _optionTile(scheme, Icons.share_rounded, 'Share to chat', () {
                Navigator.pop(ctx);
                widget.onShare(path);
              }),
              _optionTile(scheme, Icons.edit_rounded, 'Edit details', () async {
                Navigator.pop(ctx);
                // Let the options sheet finish closing BEFORE opening the edit
                // sheet — otherwise the two modal transitions (and then the
                // keyboard) animate on top of each other, dropping frames and
                // making the edit UI feel stuck on open.
                await Future.delayed(const Duration(milliseconds: 210));
                if (!mounted) return;
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
                  _confirmRemove(realIdx, title);
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

  /// Confirm before removing a track from the playlist (no accidental deletes).
  Future<void> _confirmRemove(int realIdx, String title) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dctx) {
        final scheme = Theme.of(dctx).colorScheme;
        return AlertDialog(
          title: const Text('Remove track?'),
          content: Text(
            'Remove "$title" from your playlist?\n'
            'This only removes it from the list — the file stays on your device.',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dctx, false),
                child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: scheme.error),
              onPressed: () => Navigator.pop(dctx, true),
              child: const Text('Remove'),
            ),
          ],
        );
      },
    );
    if (yes == true) widget.onRemove(realIdx);
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

  String _activeFilterLabel() {
    if (_smart == _Smart.recent) return 'Recent';
    if (_smart == _Smart.most) return 'Most played';
    if (_activeGroup != null) return _activeGroup!;
    if (_favOnly) return 'Favourites';
    return 'All';
  }

  bool get _isFiltered =>
      _smart != _Smart.none || _activeGroup != null || _favOnly;

  void _playPath(String path) {
    final disp = _displayed();
    final paths = disp.map((e) => e.value).toList();
    final pos = paths.indexOf(path);
    widget.onPlayScope(paths, pos < 0 ? 0 : pos, false);
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
        {TextInputType? kb, IconData? icon, bool autofocus = false}) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          keyboardType: kb,
          // Focus the first field on open so the keyboard rises together with
          // the sheet (one smooth motion) instead of on a second tap.
          autofocus: autofocus,
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
              field('Title', titleC,
                  icon: Icons.music_note_rounded, autofocus: true),
              field('Artist', artistC, icon: Icons.person_rounded),
              field('Album', albumC, icon: Icons.album_rounded),
              Row(
                children: [
                  Expanded(child: field('Genre', genreC)),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 110,
                    child: field('Year', yearC, kb: TextInputType.number),
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
                  if (mounted) setState(() {});
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
    final displayed = _displayed();
    final displayedPaths = displayed.map((e) => e.value).toList();
    // On the CHAT surface the app's own now-playing bar (richer, at the bottom)
    // already controls playback, so the card drawer omits its inline strip —
    // otherwise one playing song would show two transport controls. On the music
    // surface there's no bottom bar, so the strip stays as the drawer's control.
    final bool appBarHandlesPlayback = widget.hostIsChat;

    return Container(
      // In drawer mode the surrounding Material provides the surface, left-
      // rounded corners and elevation, so this inner container stays flush with
      // no margin/border of its own. The bottom-sheet look keeps its card.
      margin: widget.drawer
          ? EdgeInsets.zero
          : const EdgeInsets.only(left: 8, right: 8, bottom: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius:
            widget.drawer ? BorderRadius.zero : BorderRadius.circular(20),
        border: widget.drawer
            ? null
            : Border.all(color: scheme.primary.withAlpha(130)),
        boxShadow: widget.drawer
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withAlpha(50),
                  blurRadius: 26,
                  offset: const Offset(0, 8),
                ),
              ],
      ),
      child: Column(
        // Stretch every row to the full panel width so the header spans edge to
        // edge and its trailing collapse chevron stays pinned to the far right,
        // however wide the panel is stretched.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Grab handle — bottom-sheet only (tap OR slide down to dismiss). The
          // drawer collapses via its header back button or a right swipe.
          if (!widget.drawer)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onClose,
              onVerticalDragEnd: (d) {
                if ((d.primaryVelocity ?? 0) > 0) widget.onClose();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
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

          // Header — either the normal header or the multi-select action bar.
          _selecting ? _selectionBar(scheme) : _header(scheme),

          // Search + filter + sort — the ONLY chrome above the list now. The
          // old always-on chip row and the Play/Shuffle row were folded into
          // the filter menu (the funnel button) to give the list more room.
          if (!_selecting)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      onChanged: (v) => setState(() => _search = v),
                      decoration: InputDecoration(
                        hintText: 'Search tracks…',
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
                  const SizedBox(width: 6),
                  // Filter & play menu (All / Recent / Most played / groups /
                  // New group + Play/Shuffle the current view).
                  _filterButton(scheme),
                  const SizedBox(width: 2),
                  // Sort button.
                  _iconBtn(scheme, Icons.sort_rounded, 'Sort',
                      () => _showSort(context),
                      active: _sort != _PlSort.manual),
                ],
              ),
            ),

          // Track list.
          Expanded(
            child: widget.loading && widget.playlist.isEmpty
                ? _loadingView(scheme)
                : displayed.isEmpty
                    ? _emptyView(scheme)
                    : ListView.builder(
                        controller: _listCtrl,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 4),
                        itemCount: displayed.length,
                        itemBuilder: (ctx, i) =>
                            _row(scheme, displayed, displayedPaths, i),
                      ),
          ),

          // Inline transport strip — control playback without leaving the list.
          // Skipped on phone (the app's now-playing bar handles it), so a single
          // song never shows two players stacked.
          if (widget.hasTrack && !_selecting && !appBarHandlesPlayback)
            _transportStrip(scheme),
        ],
      ),
    );
  }

  // ── Header ──────────────────────────────────────────────────────────────────

  Widget _header(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withAlpha(120),
        border: Border(
            bottom: BorderSide(color: scheme.outlineVariant.withAlpha(80))),
      ),
      child: Row(
        children: [
          Icon(Icons.queue_music_rounded, color: scheme.primary, size: 18),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'Playlist (${widget.playlist.length})',
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _iconBtn(scheme, Icons.add_rounded, 'Add music', widget.onAdd),
          _iconBtn(
            scheme,
            _favOnly ? Icons.favorite : Icons.favorite_border,
            'Favourites',
            () => setState(() {
              _favOnly = !_favOnly;
              if (_favOnly) {
                _activeGroup = null;
                _smart = _Smart.none;
              }
            }),
            color: _favOnly ? Colors.pinkAccent : null,
          ),
          _iconBtn(scheme, Icons.checklist_rounded, 'Select', () {
            if (widget.playlist.isNotEmpty) {
              setState(() {
                _selecting = true;
                _selected.clear();
              });
            }
          }),
          const Spacer(),
          GestureDetector(
            onTap: widget.onClose,
            child: Tooltip(
              // In drawer mode this collapses the panel back to the right edge
              // (a right chevron reads as "push it away"); the sheet just closes.
              message: widget.drawer ? 'Collapse' : 'Close',
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: scheme.primary.withAlpha(28),
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.primary.withAlpha(70)),
                ),
                child: Icon(
                    widget.drawer
                        ? Icons.chevron_right_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 22,
                    color: scheme.primary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _selectionBar(ColorScheme scheme) {
    final paths = _selected.toList();
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      decoration: BoxDecoration(
        color: scheme.primary.withAlpha(22),
        border: Border(
            bottom: BorderSide(color: scheme.outlineVariant.withAlpha(80))),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close_rounded),
            visualDensity: VisualDensity.compact,
            tooltip: 'Cancel',
            onPressed: _exitSelect,
          ),
          Text('${_selected.length} selected',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const Spacer(),
          _iconBtn(scheme, Icons.playlist_add_rounded, 'Add to group', () {
            if (paths.isNotEmpty) _bulkAddToGroup(context);
          }),
          _iconBtn(scheme, Icons.favorite, 'Favourite',
              () => widget.onFavoriteMany(paths, true),
              color: Colors.pinkAccent),
          _iconBtn(scheme, Icons.delete_outline_rounded, 'Remove', () {
            widget.onRemoveMany(paths);
            _exitSelect();
          }, color: scheme.error),
        ],
      ),
    );
  }

  Widget _iconBtn(ColorScheme scheme, IconData icon, String tip, VoidCallback? onTap,
      {Color? color, bool active = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Tooltip(
        message: tip,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Icon(icon,
              size: 20,
              color: color ?? (active ? scheme.primary : scheme.onSurfaceVariant)),
        ),
      ),
    );
  }

  /// Compact filter control that sits in the search row: a funnel icon that
  /// grows a tinted label when a filter is active, so the current view is
  /// visible at a glance without a dedicated chip row. Tapping opens the menu.
  Widget _filterButton(ColorScheme scheme) {
    final on = _isFiltered;
    final fg = on ? scheme.primary : scheme.onSurfaceVariant;
    return Tooltip(
      message: 'Filter & play',
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _showFilterMenu(context),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: on ? 10 : 8, vertical: 7),
          decoration: BoxDecoration(
            color: on ? scheme.primary.withAlpha(28) : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: on
                    ? scheme.primary.withAlpha(120)
                    : scheme.outlineVariant.withAlpha(120)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.filter_list_rounded, size: 18, color: fg),
              if (on) ...[
                const SizedBox(width: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 92),
                  child: Text(
                    _activeFilterLabel(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600, color: fg),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The filter + play sheet: pick All / Recent / Most played / a group / make
  /// a new group, and Play or Shuffle the current view — everything the old
  /// chip row and Play/Shuffle row used to hold, now off the panel's main area.
  void _showFilterMenu(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final displayedPaths = _displayed().map((e) => e.value).toList();
    final label = _activeFilterLabel();
    final scopeWord = label == 'All' ? 'all' : label;

    void pick(VoidCallback apply) {
      setState(apply);
      Navigator.pop(context);
    }

    Widget filterTile(IconData icon, String text, bool active, VoidCallback onTap,
        {Widget? trailing}) {
      return ListTile(
        dense: true,
        leading:
            Icon(icon, color: active ? scheme.primary : scheme.onSurfaceVariant),
        title: Text(text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: active ? scheme.primary : null)),
        trailing: trailing ??
            (active ? Icon(Icons.check_rounded, color: scheme.primary) : null),
        onTap: onTap,
      );
    }

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
            const SizedBox(height: 10),
            const Text('Show',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 4),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  filterTile(
                    Icons.library_music_rounded,
                    'All songs',
                    _activeGroup == null && !_favOnly && _smart == _Smart.none,
                    () => pick(() {
                      _activeGroup = null;
                      _favOnly = false;
                      _smart = _Smart.none;
                    }),
                  ),
                  filterTile(
                    Icons.history_rounded,
                    'Recently played',
                    _smart == _Smart.recent,
                    () => pick(() {
                      _smart = _Smart.recent;
                      _activeGroup = null;
                      _favOnly = false;
                    }),
                  ),
                  filterTile(
                    Icons.trending_up_rounded,
                    'Most played',
                    _smart == _Smart.most,
                    () => pick(() {
                      _smart = _Smart.most;
                      _activeGroup = null;
                      _favOnly = false;
                    }),
                  ),
                  if (widget.groups.isNotEmpty)
                    Divider(
                        height: 1, color: scheme.outlineVariant.withAlpha(70)),
                  for (final g in widget.groups.keys)
                    filterTile(
                      Icons.folder_rounded,
                      '$g (${widget.groups[g]?.length ?? 0})',
                      _activeGroup == g,
                      () => pick(() {
                        _activeGroup = g;
                        _favOnly = false;
                        _smart = _Smart.none;
                      }),
                      trailing: IconButton(
                        icon: Icon(Icons.more_horiz_rounded,
                            color: scheme.onSurfaceVariant),
                        tooltip: 'Manage group',
                        onPressed: () {
                          Navigator.pop(ctx);
                          _manageGroup(context, g);
                        },
                      ),
                    ),
                  ListTile(
                    dense: true,
                    leading: Icon(Icons.create_new_folder_rounded,
                        color: scheme.primary),
                    title: Text('New group…',
                        style: TextStyle(color: scheme.primary)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _promptCreateGroup(context);
                    },
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: scheme.outlineVariant.withAlpha(70)),
            _optionTile(scheme, Icons.play_arrow_rounded, 'Play $scopeWord', () {
              Navigator.pop(ctx);
              if (displayedPaths.isNotEmpty) {
                widget.onPlayScope(displayedPaths, 0, false);
              }
            }),
            _optionTile(scheme, Icons.shuffle_rounded, 'Shuffle $scopeWord', () {
              Navigator.pop(ctx);
              if (displayedPaths.isNotEmpty) {
                widget.onPlayScope(displayedPaths, 0, true);
              }
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _loadingView(ColorScheme scheme) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 30,
              height: 30,
              child: CircularProgressIndicator(
                  strokeWidth: 2.6, color: scheme.primary),
            ),
            const SizedBox(height: 14),
            Text('Scanning your music…',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
          ],
        ),
      );

  Widget _emptyView(ColorScheme scheme) {
    String msg;
    if (_smart == _Smart.recent) {
      msg = 'Nothing played yet';
    } else if (_smart == _Smart.most) {
      msg = 'No play history yet';
    } else if (_activeGroup != null) {
      msg = 'No songs in "$_activeGroup" yet';
    } else if (_favOnly) {
      msg = 'No favourites yet';
    } else {
      msg = 'No tracks match';
    }
    return Center(
      child: Text(msg, style: TextStyle(color: scheme.onSurfaceVariant)),
    );
  }

  // ── Track row ─────────────────────────────────────────────────────────────

  Widget _row(ColorScheme scheme, List<MapEntry<int, String>> displayed,
      List<String> displayedPaths, int i) {
    final entry = displayed[i];
    final realIdx = entry.key;
    final path = entry.value;
    final isNow = realIdx == widget.currentIndex;
    final isFav = widget.favorites.contains(path);
    final isSel = _selected.contains(path);

    Widget buildRow() {
      final tile = ListTile(
        key: ValueKey('tile_$i'),
        dense: true,
        visualDensity: const VisualDensity(vertical: -3),
        minVerticalPadding: 0,
        horizontalTitleGap: 10,
        selected: isNow || isSel,
        selectedTileColor: isSel
            ? scheme.primary.withAlpha(40)
            : scheme.primary.withAlpha(
                isNow ? 22 + (70 * _pulseCtrl.value).round() : 22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
        leading: _selecting
            ? Icon(
                isSel
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: isSel ? scheme.primary : scheme.onSurfaceVariant,
              )
            : _leadingArt(path, isNow, scheme),
        title: Text(
          _effTitle(path),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: isNow ? FontWeight.bold : FontWeight.w500,
            color: isNow ? scheme.primary : null,
          ),
        ),
        subtitle: _effArtist(path).isEmpty
            ? null
            : Text(_effArtist(path),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
        trailing: _selecting
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isFav)
                    const Padding(
                      padding: EdgeInsets.only(right: 2),
                      child: Icon(Icons.favorite,
                          size: 14, color: Colors.pinkAccent),
                    ),
                  IconButton(
                    icon: Icon(Icons.more_vert,
                        size: 20, color: scheme.onSurfaceVariant),
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Options',
                    onPressed: () =>
                        _showTrackOptions(context, path, realIdx, isFav),
                  ),
                ],
              ),
        onTap: () {
          if (_selecting) {
            _toggleSelect(path);
          } else {
            // Play within the CURRENT view so auto-advance respects the filter.
            widget.onPlayScope(displayedPaths, i, false);
          }
        },
        onLongPress: () {
          if (!_selecting) _enterSelect(path);
        },
      );

      // Removal is an explicit action (row ⋮ → Remove, with a confirm dialog),
      // never a swipe — swiping accidentally deleted tracks and clashed with the
      // drawer's swipe-to-close.
      return tile;
    }

    if (!isNow) return buildRow();
    return KeyedSubtree(
      key: _nowKey,
      child: AnimatedBuilder(
        animation: _pulseCtrl,
        builder: (_, _) => buildRow(),
      ),
    );
  }

  // ── Inline transport strip ────────────────────────────────────────────────

  /// Path of the track currently playing, or null if the index is out of range.
  String? _curPath() {
    final i = widget.currentIndex;
    if (i >= 0 && i < widget.playlist.length) return widget.playlist[i];
    return null;
  }

  Widget _transportStrip(ColorScheme scheme) {
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(
            top: BorderSide(color: scheme.outlineVariant.withAlpha(80))),
      ),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Seek bar + time labels (driven by the shared play clock).
          ValueListenableBuilder<PlayClock>(
            valueListenable: playClockNotifier,
            builder: (_, clock, _) {
              final total = clock.duration.inMilliseconds;
              final pos = clock.position.inMilliseconds;
              final frac =
                  total > 0 ? (pos / total).clamp(0.0, 1.0) : 0.0;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 12),
                    ),
                    child: Slider(
                      value: frac,
                      onChanged: total > 0
                          ? (v) => widget.onSeekFraction(v)
                          : null,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_fmtTime(clock.position),
                            style: TextStyle(
                                fontSize: 10.5,
                                color: scheme.onSurfaceVariant)),
                        Text(_fmtTime(clock.duration),
                            style: TextStyle(
                                fontSize: 10.5,
                                color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.currentTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
              ),
              // Share the CURRENT song straight to a chat — a one-tap, always-
              // visible affordance (the per-track ⋮ menu also has "Share to
              // chat" for any other song in the list).
              if (_curPath() != null)
                IconButton(
                  icon: Icon(Icons.share_rounded, color: scheme.primary),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Share this song',
                  onPressed: () => widget.onShare(_curPath()!),
                ),
              IconButton(
                icon: const Icon(Icons.skip_previous_rounded),
                visualDensity: VisualDensity.compact,
                onPressed: widget.onPrev,
              ),
              // Play/pause reflects the live player state.
              StreamBuilder<PlayerState>(
                stream: widget.player.playerStateStream,
                builder: (_, snap) {
                  final playing = snap.data?.playing ?? false;
                  return Container(
                    decoration: BoxDecoration(
                        color: scheme.primary, shape: BoxShape.circle),
                    child: IconButton(
                      icon: Icon(
                          playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: scheme.onPrimary),
                      visualDensity: VisualDensity.compact,
                      onPressed: widget.onTogglePlay,
                    ),
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.skip_next_rounded),
                visualDensity: VisualDensity.compact,
                onPressed: widget.onNext,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
