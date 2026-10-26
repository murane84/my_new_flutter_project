part of '../music_controls.dart';

// Share songs into chats: send the actual audio FILES (async attachments,
// ≤15 MB each) or "now playing" text RECOMMENDATIONS — several songs to several
// friends in one go. Reuses the chat attachment pipeline (ApiService.uploadMedia
// + sendMessage). Each song is uploaded once PER friend: songs are ephemeral on
// the server (purged once that recipient caches them), so recipients never
// share one upload that the first one's download would purge.

class _ShareSheet extends StatefulWidget {
  /// Songs to start with (usually the one playing / long-pressed).
  final List<String> paths;

  /// The player's songs, offered under "Add songs".
  final List<String> library;
  final String Function(String path) titleOf;
  final String Function(String path) artistOf;

  const _ShareSheet({
    required this.paths,
    required this.library,
    required this.titleOf,
    required this.artistOf,
  });

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  static const int _maxBytes = 15 * 1024 * 1024;

  bool _asFile = true; // true = send files, false = recommend as text
  bool _sending = false;
  String? _progress;
  late List<String> _songs;
  final Set<int> _to = {};
  late final Future<List<Map<String, dynamic>>> _friends;

  @override
  void initState() {
    super.initState();
    _songs = [...widget.paths];
    _friends = ApiService().getFriends();
  }

  String _mimeOf(String path) {
    final p = path.toLowerCase();
    if (p.endsWith('.mp3')) return 'audio/mpeg';
    if (p.endsWith('.m4a') || p.endsWith('.aac')) return 'audio/mp4';
    if (p.endsWith('.wav')) return 'audio/wav';
    if (p.endsWith('.ogg') || p.endsWith('.opus')) return 'audio/ogg';
    if (p.endsWith('.flac')) return 'audio/flac';
    return 'audio/mpeg';
  }

  String _fileName(String path) => path.replaceAll('\\', '/').split('/').last;

  String _label(String path) {
    final t = widget.titleOf(path);
    final a = widget.artistOf(path).trim();
    return a.isEmpty ? t : '$t — $a';
  }

  Future<void> _addSongs() async {
    final have = _songs.toSet();
    final options = widget.library.where((p) => !have.contains(p)).toList();
    if (options.isEmpty) {
      showToast(context, 'All your songs are already in the list');
      return;
    }
    final picked = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SongPickSheet(
        options: options,
        labelOf: _label,
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    setState(() => _songs = [..._songs, ...picked]);
  }

  Future<void> _sendAll(List<Map<String, dynamic>> friends) async {
    if (_sending || _songs.isEmpty || _to.isEmpty) return;
    final targets =
        friends.where((f) => _to.contains((f['id'] as num?)?.toInt())).toList();
    setState(() => _sending = true);
    final api = ApiService();
    var ok = 0, failed = 0, tooBig = 0;
    final total = _songs.length * targets.length;
    var step = 0;
    try {
      for (final path in _songs) {
        List<int>? bytes;
        if (_asFile) {
          final file = File(path);
          final len = await file.length();
          if (len > _maxBytes) {
            tooBig++;
            step += targets.length;
            continue;
          }
          bytes = await file.readAsBytes();
        }
        for (final f in targets) {
          if (!mounted) return;
          step++;
          setState(() => _progress = 'Sending $step of $total…');
          final id = (f['id'] as num?)?.toInt();
          if (id == null) continue;
          try {
            if (_asFile) {
              final data = bytes!;
              final up = await api.uploadMedia(
                  bytes: data,
                  filename: _fileName(path),
                  mime: _mimeOf(path),
                  ephemeral: true);
              if (up == null || up['url'] == null) throw Exception('upload');
              // Seed OUR OWN cache so the sender can still play it from the
              // bubble after the server purges it.
              final aid = SongCache.assetId(up['url'].toString());
              if (aid != null) {
                await SongCache.putBytes(aid, data,
                    filename: _fileName(path), mime: _mimeOf(path));
              }
              final sent = await api.sendMessage(
                id,
                _label(path),
                messageType: 'song',
                mediaUrl: up['url'].toString(),
                mediaName: (up['name'] ?? _fileName(path)).toString(),
                mediaMime: (up['mime'] ?? _mimeOf(path)).toString(),
                mediaSize: (up['size'] as num?)?.toInt() ?? data.length,
              );
              if (sent == null) throw Exception('send');
            } else {
              final sent = await api.sendMessage(
                  id, '🎵 Now playing: ${_label(path)}',
                  messageType: 'text');
              if (sent == null) throw Exception('send');
            }
            ok++;
          } catch (_) {
            failed++;
          }
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _progress = null;
        });
      }
    }
    if (!mounted) return;
    final people = targets.length == 1
        ? ContactNames.instance.displayName(
            of: targets.first,
            registered: (targets.first['username'] ?? 'friend').toString())
        : '${targets.length} friends';
    final what = _songs.length == 1
        ? (_asFile ? 'Song' : 'Recommendation')
        : '${_songs.length} ${_asFile ? 'songs' : 'recommendations'}';
    if (failed == 0 && tooBig == 0) {
      Navigator.pop(context);
      showToast(context, '$what sent to $people', type: ToastType.success);
    } else {
      final parts = <String>[
        if (ok > 0) '$ok sent',
        if (failed > 0) '$failed failed — check your connection',
        if (tooBig > 0) '$tooBig song${tooBig == 1 ? '' : 's'} over 15 MB skipped',
      ];
      showToast(context, parts.join(' · '),
          type: ok > 0 ? ToastType.info : ToastType.error);
      if (ok > 0 && failed == 0) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      initialChildSize: 0.78,
      minChildSize: 0.45,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, sc) => Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _friends,
          builder: (ctx, snap) {
            final friends = snap.data ?? const <Map<String, dynamic>>[];
            return Column(
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 6),
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: scheme.onSurfaceVariant.withAlpha(90),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                // Header.
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Row(
                    children: [
                      Icon(Icons.share_rounded, color: scheme.primary, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _songs.length == 1
                              ? 'Share 1 song'
                              : 'Share ${_songs.length} songs',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                      ),
                      ChoiceChip(
                        label: const Text('File'),
                        selected: _asFile,
                        showCheckmark: false,
                        selectedColor: scheme.primary,
                        labelStyle: TextStyle(
                            color:
                                _asFile ? scheme.onPrimary : scheme.onSurface),
                        onSelected: _sending
                            ? null
                            : (_) => setState(() => _asFile = true),
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: const Text('Recommend'),
                        selected: !_asFile,
                        showCheckmark: false,
                        selectedColor: scheme.primary,
                        labelStyle: TextStyle(
                            color:
                                !_asFile ? scheme.onPrimary : scheme.onSurface),
                        onSelected: _sending
                            ? null
                            : (_) => setState(() => _asFile = false),
                      ),
                    ],
                  ),
                ),
                // Songs being shared.
                SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (final p in _songs)
                        Padding(
                          padding: const EdgeInsets.only(right: 6, top: 4),
                          child: InputChip(
                            avatar: Icon(Icons.music_note_rounded,
                                size: 16, color: scheme.primary),
                            label: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 170),
                              child: Text(_label(p),
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                            ),
                            onDeleted: _sending || _songs.length == 1
                                ? null
                                : () => setState(() => _songs.remove(p)),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: ActionChip(
                          avatar: Icon(Icons.add_rounded,
                              size: 18, color: scheme.primary),
                          label: const Text('Add songs'),
                          onPressed: _sending ? null : _addSongs,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _asFile
                              ? 'Send the audio — they can play or save it.'
                              : 'Send a text recommendation (no file).',
                          style: TextStyle(
                              fontSize: 11.5, color: scheme.onSurfaceVariant),
                        ),
                      ),
                      if (friends.isNotEmpty)
                        TextButton(
                          onPressed: _sending
                              ? null
                              : () => setState(() {
                                    final all = friends
                                        .map((f) => (f['id'] as num?)?.toInt())
                                        .whereType<int>()
                                        .toSet();
                                    if (_to.length == all.length) {
                                      _to.clear();
                                    } else {
                                      _to
                                        ..clear()
                                        ..addAll(all);
                                    }
                                  }),
                          child: Text(_to.isNotEmpty &&
                                  _to.length == friends.length
                              ? 'Clear'
                              : 'Select all'),
                        ),
                    ],
                  ),
                ),
                Divider(height: 1, color: scheme.outlineVariant.withAlpha(70)),
                // Friend picker (tick one or more).
                Expanded(
                  child: snap.connectionState == ConnectionState.waiting
                      ? Center(
                          child: CircularProgressIndicator(
                              strokeWidth: 2.4, color: scheme.primary),
                        )
                      : friends.isEmpty
                          ? Center(
                              child: Text('No contacts yet',
                                  style: TextStyle(
                                      color: scheme.onSurfaceVariant)),
                            )
                          : ListView.builder(
                              controller: sc,
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              itemCount: friends.length,
                              itemBuilder: (_, i) {
                                final f = friends[i];
                                final uname = ContactNames.instance.displayName(
                                    of: f,
                                    registered:
                                        (f['username'] ?? 'Friend').toString());
                                final fid = (f['id'] as num?)?.toInt();
                                final on = fid != null && _to.contains(fid);
                                return ListTile(
                                  leading: CircleAvatar(
                                    radius: 18,
                                    backgroundColor: scheme.primaryContainer,
                                    child: Text(
                                      uname.isNotEmpty
                                          ? uname[0].toUpperCase()
                                          : '?',
                                      style: TextStyle(
                                          color: scheme.onPrimaryContainer,
                                          fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                  title: Text(uname,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                  trailing: Icon(
                                    on
                                        ? Icons.check_circle_rounded
                                        : Icons.radio_button_unchecked_rounded,
                                    color: on ? scheme.primary : scheme.outline,
                                  ),
                                  enabled: !_sending && fid != null,
                                  onTap: () => setState(() {
                                    if (fid == null) return;
                                    if (!_to.remove(fid)) _to.add(fid);
                                  }),
                                );
                              },
                            ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _sending || _to.isEmpty
                            ? null
                            : () => _sendAll(friends),
                        icon: _sending
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: scheme.onPrimary),
                              )
                            : Icon(_asFile
                                ? Icons.send_rounded
                                : Icons.recommend_rounded),
                        label: Text(_progress ??
                            (_to.isEmpty
                                ? 'Choose who gets it'
                                : 'Send to ${_to.length == 1 ? '1 friend' : '${_to.length} friends'}')),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// "Add songs": tick songs from the player's list.
class _SongPickSheet extends StatefulWidget {
  final List<String> options;
  final String Function(String path) labelOf;
  const _SongPickSheet({required this.options, required this.labelOf});

  @override
  State<_SongPickSheet> createState() => _SongPickSheetState();
}

class _SongPickSheetState extends State<_SongPickSheet> {
  final Set<String> _picked = {};
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final q = _q.toLowerCase();
    final list = q.isEmpty
        ? widget.options
        : widget.options
            .where((p) => widget.labelOf(p).toLowerCase().contains(q))
            .toList();
    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, sc) => Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: TextField(
                onChanged: (v) => setState(() => _q = v.trim()),
                decoration: InputDecoration(
                  hintText: 'Search your songs',
                  prefixIcon: const Icon(Icons.search_rounded),
                  isDense: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: sc,
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final p = list[i];
                  final on = _picked.contains(p);
                  return ListTile(
                    dense: true,
                    leading: Icon(Icons.music_note_rounded,
                        color: on ? scheme.primary : scheme.onSurfaceVariant),
                    title: Text(widget.labelOf(p),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Icon(
                      on
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      color: on ? scheme.primary : scheme.outline,
                    ),
                    onTap: () => setState(() {
                      if (!_picked.remove(p)) _picked.add(p);
                    }),
                  );
                },
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _picked.isEmpty
                        ? null
                        : () => Navigator.pop(
                            context,
                            widget.options
                                .where((p) => _picked.contains(p))
                                .toList()),
                    child: Text(_picked.isEmpty
                        ? 'Tick songs to add'
                        : 'Add ${_picked.length} song${_picked.length == 1 ? '' : 's'}'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
