part of '../relationship_space_page.dart';

// Split out of relationship_space_page.dart (pure code movement, no behaviour
// change): moment composer + add-to-playlist sheet. A library `part`, so it shares the page's imports and
// private members.

// ── moment composer sheet ─────────────────────────────────────────────────
class _MomentComposer extends StatefulWidget {
  final Color accent;
  const _MomentComposer({required this.accent});

  @override
  State<_MomentComposer> createState() => _MomentComposerState();
}

class _MomentComposerState extends State<_MomentComposer> {
  final TextEditingController _c = TextEditingController();
  // What we're pinning: 'photo' | 'video' | 'voice' | 'file' | 'song' | 'note'.
  String _mode = 'photo';

  // Picked media (photo / video / gif / file / voice): raw bytes + meta. The
  // parent uploads these durably and creates the moment.
  Uint8List? _bytes;
  String? _filename;
  String? _mime;
  String _mediaKind = ''; // resolved moment kind for the picked bytes

  // Photo mode can hold MULTIPLE images; each entry is {bytes, filename, mime}.
  // (Other modes still use the single _bytes above.) They are pinned as one
  // moment per photo, sharing the caption.
  final List<Map<String, dynamic>> _photos = [];

  // Song moment.
  String? _songTitle;
  String? _songArtist;

  // Voice recording.
  final AudioRecorder _rec = AudioRecorder();
  bool _recording = false;
  String? _voicePath;
  int _voiceMs = 0;
  Timer? _voiceTimer;

  @override
  void dispose() {
    _c.dispose();
    _voiceTimer?.cancel();
    _rec.dispose();
    super.dispose();
  }

  String _titleFromPath(String path) {
    final name = path.split(RegExp(r'[\\/]+')).last;
    return name.replaceAll(RegExp(r'\.[^.]+$'), '');
  }

  void _clearPicked() {
    _bytes = null;
    _filename = null;
    _mime = null;
    _mediaKind = '';
    _photos.clear();
    _songTitle = null;
    _songArtist = null;
    final p = _voicePath;
    _voicePath = null;
    _voiceMs = 0;
    if (p != null) {
      try {
        File(p).delete();
      } catch (_) {}
    }
    if (_recording) {
      try {
        _rec.stop();
      } catch (_) {}
      _recording = false;
    }
    _voiceTimer?.cancel();
  }

  void _setMode(String m) => setState(() {
        _clearPicked();
        _mode = m;
      });

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
      case 'heic':
        return 'image/heic';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'webm':
        return 'video/webm';
      case 'm4a':
      case 'aac':
        return 'audio/mp4';
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'ogg':
        return 'audio/ogg';
      default:
        return 'application/octet-stream';
    }
  }

  // Resolve a moment kind from a file's mime/extension. '' = can't be pinned.
  String _kindFromMedia(String mime, String ext) {
    final m = mime.toLowerCase();
    if (m == 'image/gif' || ext == 'gif') return 'gif';
    if (m.startsWith('image/')) return 'photo';
    if (m.startsWith('video/')) return 'video';
    if (m.startsWith('audio/')) return 'voice';
    return '';
  }

  // Photo mode: pick one OR many images at once. They stack up as a set and
  // are pinned as individual moments sharing the caption.
  Future<void> _pickPhotos() async {
    try {
      final res = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'heic', 'gif'],
        allowMultiple: true, // ignore: deprecated_member_use
      );
      if (res == null || res.files.isEmpty) return;
      final added = <Map<String, dynamic>>[];
      var skipped = 0;
      for (final f in res.files) {
        final bytes = await f.readAsBytes();
        if (bytes.isEmpty) {
          skipped++;
          continue;
        }
        final e = (f.extension ?? '').toLowerCase();
        final mime = _mimeForExt(e);
        final kind = _kindFromMedia(mime, e);
        if (kind != 'photo' && kind != 'gif') {
          skipped++;
          continue;
        }
        if (bytes.length > 15 * 1024 * 1024) {
          skipped++;
          continue;
        }
        added.add({
          'bytes': bytes,
          'filename': f.name.isNotEmpty
              ? f.name
              : 'photo_${DateTime.now().millisecondsSinceEpoch}_${added.length}.jpg',
          'mime': mime,
        });
      }
      if (!mounted) return;
      if (added.isEmpty) {
        showToast(context, 'Could not add those photos',
            type: ToastType.error);
        return;
      }
      setState(() => _photos.addAll(added));
      if (skipped > 0) {
        showToast(context, '$skipped skipped (too large or unsupported).',
            type: ToastType.info);
      }
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not pick photos', type: ToastType.error);
      }
    }
  }

  Future<void> _pickMedia() async {
    try {
      FileType type;
      List<String>? ext;
      switch (_mode) {
        case 'photo':
          type = FileType.custom;
          ext = ['jpg', 'jpeg', 'png', 'webp', 'heic', 'gif'];
          break;
        case 'video':
          type = FileType.video;
          break;
        default: // 'file' — anything, auto-routed by mime
          type = FileType.any;
      }
      final res = await FilePicker.pickFiles(
        type: type,
        allowedExtensions: ext,
      );
      if (res == null || res.files.isEmpty) return;
      final f = res.files.first;
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) {
        if (mounted) {
          showToast(context, 'Could not read that file',
              type: ToastType.error);
        }
        return;
      }
      final e = (f.extension ?? '').toLowerCase();
      final mime = _mimeForExt(e);
      final kind =
          _mode == 'video' ? 'video' : _kindFromMedia(mime, e);
      if (kind.isEmpty) {
        if (mounted) {
          showToast(context, "That file type can't be pinned here.",
              type: ToastType.info);
        }
        return;
      }
      final cap = kind == 'video' ? 200 * 1024 * 1024 : 15 * 1024 * 1024;
      if (bytes.length > cap) {
        if (mounted) {
          showToast(
              context,
              kind == 'video'
                  ? 'Video is too large (max 200 MB).'
                  : 'File is too large (max 15 MB).',
              type: ToastType.error);
        }
        return;
      }
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _filename = f.name.isNotEmpty
            ? f.name
            : 'moment_${DateTime.now().millisecondsSinceEpoch}';
        _mime = mime;
        _mediaKind = kind;
      });
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not pick that', type: ToastType.error);
      }
    }
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
          '${dir.path}/moment_${DateTime.now().millisecondsSinceEpoch}.m4a';
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

  String _fmtMs(int ms) {
    final sec = (ms / 1000).floor();
    return '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _pin() async {
    final text = _c.text.trim();
    if (_mode == 'note') {
      if (text.isEmpty) {
        Navigator.pop(context);
        return;
      }
      Navigator.pop(context, {'kind': 'note', 'caption': text});
      return;
    }
    if (_mode == 'song') {
      if (_songTitle == null) {
        showToast(context, 'Choose a song to pin.', type: ToastType.info);
        return;
      }
      Navigator.pop(context, {
        'kind': 'song',
        'ref': jsonEncode({'title': _songTitle, 'artist': _songArtist ?? ''}),
        'caption': text.isEmpty ? null : text,
      });
      return;
    }
    if (_mode == 'voice') {
      if (_recording) {
        showToast(context, 'Stop the recording first.', type: ToastType.info);
        return;
      }
      if (_voicePath == null) {
        showToast(context, 'Record a voice note first.', type: ToastType.info);
        return;
      }
      try {
        final b = await File(_voicePath!).readAsBytes();
        if (b.isEmpty) throw Exception('empty');
        if (!mounted) return;
        Navigator.pop(context, {
          'kind': 'voice',
          '_bytes': b,
          '_filename': _voicePath!.replaceAll('\\', '/').split('/').last,
          '_mime': 'audio/mp4',
          'caption': text.isEmpty ? null : text,
        });
      } catch (_) {
        if (mounted) {
          showToast(context, 'Could not read the recording',
              type: ToastType.error);
        }
      }
      return;
    }
    // photo (one OR many)
    if (_mode == 'photo') {
      if (_photos.isEmpty) {
        showToast(context, 'Pick at least one photo.', type: ToastType.info);
        return;
      }
      Navigator.pop(context, {
        'kind': 'photo',
        '_items': _photos,
        'caption': text.isEmpty ? null : text,
      });
      return;
    }
    // video / file
    if (_bytes == null || _mediaKind.isEmpty) {
      showToast(context, 'Pick something to pin first.', type: ToastType.info);
      return;
    }
    Navigator.pop(context, {
      'kind': _mediaKind,
      '_bytes': _bytes,
      '_filename': _filename,
      '_mime': _mime,
      'caption': text.isEmpty ? null : text,
    });
  }

  Widget _sourceChip(ColorScheme scheme, String m, IconData icon, String label) {
    final sel = _mode == m;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _setMode(m),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: sel
              ? widget.accent.withValues(alpha: 0.16)
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: sel
                  ? widget.accent.withValues(alpha: 0.6)
                  : scheme.outlineVariant.withValues(alpha: 0.5),
              width: sel ? 1.4 : 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 16,
                color: sel ? widget.accent : scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: sel ? FontWeight.w700 : FontWeight.w600,
                    color: sel ? widget.accent : scheme.onSurface)),
          ],
        ),
      ),
    );
  }

  // A horizontal strip of picked photos with remove (×) and an add-more tile.
  Widget _photoStrip(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8, left: 2),
          child: Text(
            '${_photos.length} photo${_photos.length == 1 ? '' : 's'} selected',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant),
          ),
        ),
        SizedBox(
          height: 84,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _photos.length + 1,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (ctx, i) {
              if (i == _photos.length) {
                return InkWell(
                  onTap: _pickPhotos,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: widget.accent.withValues(alpha: 0.4),
                          width: 1.4),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add_rounded, color: widget.accent),
                        const SizedBox(height: 2),
                        Text('Add',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: widget.accent)),
                      ],
                    ),
                  ),
                );
              }
              final bytes = _photos[i]['bytes'] as Uint8List;
              return Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(bytes,
                        width: 84, height: 84, fit: BoxFit.cover),
                  ),
                  Positioned(
                    top: 3,
                    right: 3,
                    child: GestureDetector(
                      onTap: () => setState(() => _photos.removeAt(i)),
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: const BoxDecoration(
                            color: Colors.black54, shape: BoxShape.circle),
                        child: const Icon(Icons.close_rounded,
                            size: 14, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  // The selected single media (video / file): thumbnail, name, kind·size, and a
  // clear "Change" action on the right.
  Widget _selectedMediaTile(ColorScheme scheme) {
    final kb = _bytes!.length / 1024;
    final sizeLabel = kb >= 1024
        ? '${(kb / 1024).toStringAsFixed(1)} MB'
        : '${kb.toStringAsFixed(0)} KB';
    final kindLabel = _mediaKind == 'video' ? 'Video' : 'File';
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: widget.accent.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 52,
              height: 52,
              child: ColoredBox(
                color: widget.accent.withValues(alpha: 0.12),
                child: Icon(
                    _mediaKind == 'video'
                        ? Icons.movie_rounded
                        : Icons.insert_drive_file_rounded,
                    color: widget.accent),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_filename ?? 'Selected',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface)),
                const SizedBox(height: 2),
                Text('$kindLabel · $sizeLabel',
                    style: TextStyle(
                        fontSize: 11.5, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: widget.accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: _pickMedia,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.swap_horiz_rounded,
                        size: 16, color: widget.accent),
                    const SizedBox(width: 5),
                    Text('Change',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: widget.accent)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pickTile(ColorScheme scheme, IconData icon, String label,
      VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: widget.accent.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Icon(icon, color: widget.accent, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600)),
            ),
            Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _mediaInput(ColorScheme scheme) {
    final picked = _bytes != null;
    if (_mode == 'song') {
      return _pickTile(
          scheme,
          Icons.music_note_rounded,
          _songTitle ?? 'Choose a song…',
          _chooseSong);
    }
    if (_mode == 'voice') {
      if (_recording) {
        return Row(
          children: [
            IconButton(
                onPressed: _toggleRecord,
                icon: const Icon(Icons.stop_circle_rounded,
                    color: Colors.red, size: 30)),
            Text('Recording… ${_fmtMs(_voiceMs)}',
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ],
        );
      }
      if (_voicePath != null) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.graphic_eq_rounded, color: widget.accent, size: 18),
              const SizedBox(width: 8),
              Text('Voice note (${_fmtMs(_voiceMs)})',
                  style: TextStyle(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              IconButton(
                  onPressed: () => setState(() => _voicePath = null),
                  icon: Icon(Icons.close_rounded,
                      size: 18, color: scheme.onSurfaceVariant)),
            ],
          ),
        );
      }
      return _pickTile(scheme, Icons.mic_rounded, 'Tap to record a voice note',
          _toggleRecord);
    }
    // Photo mode: multi-image set (strip) or the initial pick tile.
    if (_mode == 'photo') {
      if (_photos.isEmpty) {
        return _pickTile(
            scheme, Icons.add_photo_alternate_rounded, 'Pick photos…',
            _pickPhotos);
      }
      return _photoStrip(scheme);
    }
    // video / file — single item.
    if (picked) {
      return _selectedMediaTile(scheme);
    }
    final label = _mode == 'video' ? 'Pick a video…' : 'Pick a file…';
    final icon =
        _mode == 'video' ? Icons.movie_rounded : Icons.attach_file_rounded;
    return _pickTile(scheme, icon, label, _pickMedia);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Text('Pin a moment',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 17,
                    color: scheme.onSurface)),
            const SizedBox(height: 4),
            Text('Keep a photo, a clip, a voice note, a song or a line — just '
                'the two of you.',
                style:
                    TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _sourceChip(scheme, 'photo', Icons.image_rounded, 'Photo'),
                _sourceChip(scheme, 'video', Icons.movie_rounded, 'Video'),
                _sourceChip(scheme, 'voice', Icons.mic_rounded, 'Voice'),
                _sourceChip(
                    scheme, 'file', Icons.attach_file_rounded, 'File'),
                _sourceChip(scheme, 'song', Icons.music_note_rounded, 'Song'),
                _sourceChip(scheme, 'note', Icons.edit_note_rounded, 'Note'),
              ],
            ),
            const SizedBox(height: 14),
            if (_mode != 'note') ...[
              _mediaInput(scheme),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _c,
              maxLines: 3,
              maxLength: 240,
              decoration: InputDecoration(
                hintText: _mode == 'note'
                    ? 'Write a note you want to keep…'
                    : (_mode == 'song'
                        ? 'Say why this song is you two… (optional)'
                        : 'Add a line for you two… (optional)'),
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
            const SizedBox(height: 8),
            // Dedicate: the fuller event (song + mood + optional voice note),
            // delivered to your partner. Lives right here in one composer.
            Center(
              child: TextButton.icon(
                onPressed: () => Navigator.pop(context, {'_dedicate': true}),
                icon: Icon(Icons.favorite_rounded,
                    size: 18, color: widget.accent),
                label: Text('Dedicate a song instead',
                    style: TextStyle(
                        color: widget.accent, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
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
