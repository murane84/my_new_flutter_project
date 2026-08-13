import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api_service.dart';

/// Entry point: a bottom sheet offering the four ways to post a story
/// (photo from gallery, camera photo, a short video clip, or a "now playing"
/// music moment). Each path ends in a compose page that uploads + posts, then
/// calls [onPosted] so the tray refreshes.
Future<void> showCreateStorySheet(
  BuildContext context, {
  required String apiBase,
  required VoidCallback onPosted,
}) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      Widget tile(IconData icon, String label, String value, String sub) =>
          ListTile(
            leading: CircleAvatar(
              backgroundColor:
                  Theme.of(ctx).colorScheme.primaryContainer,
              child: Icon(icon,
                  color: Theme.of(ctx).colorScheme.onPrimaryContainer),
            ),
            title: Text(label),
            subtitle: Text(sub),
            onTap: () => Navigator.pop(ctx, value),
          );
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Add to your story',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
            tile(Icons.photo_library_rounded, 'Photo', 'gallery',
                'Pick a picture from your gallery'),
            tile(Icons.photo_camera_rounded, 'Camera', 'camera',
                'Take a photo now'),
            tile(Icons.videocam_rounded, 'Video clip', 'video',
                'A short clip (up to 30s)'),
            tile(Icons.music_note_rounded, 'Now playing', 'music',
                'Share what you\'re listening to'),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );

  if (choice == null || !context.mounted) return;

  if (choice == 'music') {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _MusicStoryPage(apiBase: apiBase, onPosted: onPosted),
      ),
    );
    return;
  }

  final picker = ImagePicker();
  XFile? file;
  try {
    if (choice == 'video') {
      file = await picker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(seconds: 30),
      );
    } else {
      file = await picker.pickImage(
        source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
        imageQuality: 90,
        maxWidth: 1600,
      );
    }
  } catch (_) {
    file = null;
  }
  if (file == null || !context.mounted) return;

  final kind = choice == 'video' ? 'video' : 'photo';
  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => _MediaComposePage(
        kind: kind,
        file: file!,
        onPosted: onPosted,
      ),
    ),
  );
}

String _mimeFor(XFile file, String kind) {
  final m = file.mimeType;
  if (m != null && m.isNotEmpty) return m;
  final name = file.name.toLowerCase();
  if (kind == 'video') {
    if (name.endsWith('.mov')) return 'video/quicktime';
    if (name.endsWith('.webm')) return 'video/webm';
    return 'video/mp4';
  }
  if (name.endsWith('.png')) return 'image/png';
  if (name.endsWith('.webp')) return 'image/webp';
  if (name.endsWith('.gif')) return 'image/gif';
  return 'image/jpeg';
}

// ── Photo / video compose ────────────────────────────────────────────────────
class _MediaComposePage extends StatefulWidget {
  final String kind; // "photo" | "video"
  final XFile file;
  final VoidCallback onPosted;

  const _MediaComposePage({
    required this.kind,
    required this.file,
    required this.onPosted,
  });

  @override
  State<_MediaComposePage> createState() => _MediaComposePageState();
}

class _MediaComposePageState extends State<_MediaComposePage> {
  final TextEditingController _caption = TextEditingController();
  Uint8List? _bytes;
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final b = await widget.file.readAsBytes();
    if (!mounted) return;
    setState(() => _bytes = b);
  }

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  Future<void> _post() async {
    final bytes = _bytes;
    if (bytes == null || _posting) return;
    setState(() => _posting = true);
    final mime = _mimeFor(widget.file, widget.kind);
    final assetId = await ApiService().uploadStoryMedia(
      bytes: bytes,
      filename: widget.file.name,
      mime: mime,
    );
    if (!mounted) return;
    if (assetId == null) {
      setState(() => _posting = false);
      _toast('Upload failed — please try again');
      return;
    }
    final created = await ApiService().createStory(
      kind: widget.kind,
      mediaAssetId: assetId,
      mediaMime: mime,
      caption: _caption.text.trim(),
    );
    if (!mounted) return;
    setState(() => _posting = false);
    if (created == null) {
      _toast('Could not post story');
      return;
    }
    widget.onPosted();
    Navigator.pop(context);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('New story'),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: widget.kind == 'video'
                  ? _videoCard()
                  : (_bytes != null
                      ? Image.memory(_bytes!, fit: BoxFit.contain)
                      : const CircularProgressIndicator(color: Colors.white)),
            ),
          ),
          Container(
            color: Colors.black,
            padding: EdgeInsets.fromLTRB(
                12, 8, 12, MediaQuery.of(context).viewInsets.bottom + 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _caption,
                    style: const TextStyle(color: Colors.white),
                    minLines: 1,
                    maxLines: 3,
                    decoration: InputDecoration(
                      hintText: 'Add a caption…',
                      hintStyle:
                          TextStyle(color: Colors.white.withValues(alpha: 0.6)),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.1),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _posting
                    ? const SizedBox(
                        width: 48,
                        height: 48,
                        child: Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          ),
                        ),
                      )
                    : FloatingActionButton(
                        onPressed: _bytes == null ? null : _post,
                        child: const Icon(Icons.send_rounded),
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _videoCard() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.movie_creation_rounded,
            color: Colors.white70, size: 96),
        const SizedBox(height: 12),
        Text(
          widget.file.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 4),
        const Text('Clip ready to share',
            style: TextStyle(color: Colors.white38, fontSize: 12)),
      ],
    );
  }
}

// ── "Now playing" compose ────────────────────────────────────────────────────
class _MusicStoryPage extends StatefulWidget {
  final String apiBase;
  final VoidCallback onPosted;

  const _MusicStoryPage({required this.apiBase, required this.onPosted});

  @override
  State<_MusicStoryPage> createState() => _MusicStoryPageState();
}

class _MusicStoryPageState extends State<_MusicStoryPage> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _artist = TextEditingController();
  final TextEditingController _caption = TextEditingController();
  bool _posting = false;

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _caption.dispose();
    super.dispose();
  }

  Future<void> _post() async {
    if (_posting) return;
    final title = _title.text.trim();
    if (title.isEmpty) {
      _toast('Add the song title');
      return;
    }
    setState(() => _posting = true);
    final created = await ApiService().createStory(
      kind: 'music',
      musicTitle: title,
      musicArtist: _artist.text.trim().isEmpty ? null : _artist.text.trim(),
      caption: _caption.text.trim(),
    );
    if (!mounted) return;
    setState(() => _posting = false);
    if (created == null) {
      _toast('Could not post story');
      return;
    }
    widget.onPosted();
    Navigator.pop(context);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Now playing')),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF5B2C83), Color(0xFF1D1040)],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    color: Colors.white.withValues(alpha: 0.12),
                  ),
                  child: const Icon(Icons.music_note_rounded,
                      color: Colors.white, size: 56),
                ),
                const SizedBox(height: 24),
                _field(_title, 'Song title'),
                const SizedBox(height: 12),
                _field(_artist, 'Artist (optional)'),
                const SizedBox(height: 12),
                _field(_caption, 'Say something (optional)'),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _posting ? null : _post,
                    icon: _posting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.send_rounded),
                    label: const Text('Share to story'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String hint) {
    return TextField(
      controller: c,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
