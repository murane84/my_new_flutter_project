import 'dart:io' show File;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import '../../services/audio_handler.dart';
import '../../utils/emoji_field.dart';
import '../api_service.dart';
import '../gif_picker.dart';
import 'camera_capture.dart';

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
    // Scroll-controlled so the sheet sizes to its content and never clips the
    // last option (the old fixed height cut off "Now playing").
    isScrollControlled: true,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      Widget tile(IconData icon, String label, String value, String sub,
              {bool highlight = false}) =>
          ListTile(
            leading: CircleAvatar(
              backgroundColor:
                  highlight ? scheme.primary : scheme.primaryContainer,
              child: Icon(icon,
                  color: highlight
                      ? scheme.onPrimary
                      : scheme.onPrimaryContainer),
            ),
            title: Text(label,
                style: TextStyle(
                    fontWeight:
                        highlight ? FontWeight.bold : FontWeight.w500)),
            subtitle: Text(sub),
            onTap: () => Navigator.pop(ctx, value),
          );
      return SafeArea(
        child: SingleChildScrollView(
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
              // Now playing first — it's Aluta's signature status.
              tile(Icons.music_note_rounded, 'Now playing', 'music',
                  'Share what you\'re listening to', highlight: true),
              tile(Icons.text_fields_rounded, 'Text', 'text',
                  'A colourful text status'),
              tile(Icons.photo_library_rounded, 'Photo', 'gallery',
                  'Pick a picture from your gallery'),
              tile(Icons.photo_camera_rounded, 'Camera', 'camera',
                  'Take a photo now'),
              tile(Icons.videocam_rounded, 'Video clip', 'video',
                  'A short clip (up to 30s)'),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );

  if (choice == null || !context.mounted) return;

  if (choice == 'music') {
    // Auto-capture whatever is playing right now (the handler's placeholder is
    // 'Aluta' when nothing real is loaded → treat that as empty).
    final mi = audioHandler?.mediaItem.value;
    var t = (mi?.title ?? '').trim();
    var a = (mi?.artist ?? '').trim();
    if (t == 'Aluta') t = '';
    if (a == 'Aluta') a = '';
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _MusicStoryPage(
          apiBase: apiBase,
          onPosted: onPosted,
          initialTitle: t,
          initialArtist: a,
        ),
      ),
    );
    return;
  }

  if (choice == 'text') {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _TextStoryPage(onPosted: onPosted),
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
    } else if (choice == 'camera') {
      file = await capturePhoto(context, maxWidth: 1600);
    } else {
      file = await picker.pickImage(
        source: ImageSource.gallery,
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
  VideoPlayerController? _video;
  bool _videoFailed = false; // no playback backend here (e.g. Windows / web)
  bool _showEmoji = false; // inline emoji panel (caption stays visible above)

  void _toggleEmoji() {
    setState(() => _showEmoji = !_showEmoji);
    if (_showEmoji) FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.kind == 'video') _initVideo();
  }

  Future<void> _load() async {
    final b = await widget.file.readAsBytes();
    if (!mounted) return;
    setState(() => _bytes = b);
  }

  Future<void> _initVideo() async {
    // Preview plays from the picked file path (native only); web/desktop with
    // no backend fall back to the filmstrip card.
    if (kIsWeb || widget.file.path.isEmpty) {
      setState(() => _videoFailed = true);
      return;
    }
    final ctrl = VideoPlayerController.file(File(widget.file.path));
    _video = ctrl;
    try {
      await ctrl.initialize();
      if (!mounted) {
        ctrl.dispose();
        return;
      }
      await ctrl.setLooping(true);
      await ctrl.play();
      setState(() {});
    } catch (_) {
      if (!mounted) return;
      setState(() => _videoFailed = true);
    }
  }

  @override
  void dispose() {
    _caption.dispose();
    _video?.dispose();
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
            // The Scaffold already insets for the keyboard (resizeToAvoidBottom
            // Inset), so DON'T add viewInsets here too — that double-counted the
            // keyboard height (image squeezed up + a blank gap). Just a little
            // breathing room; the Scaffold lifts this bar above the keyboard.
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _caption,
                    style: const TextStyle(color: Colors.white),
                    minLines: 1,
                    maxLines: 3,
                    // Tapping the field to type dismisses the emoji panel so the
                    // keyboard can take over.
                    onTap: () {
                      if (_showEmoji) setState(() => _showEmoji = false);
                    },
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
                      suffixIcon: IconButton(
                        icon: Icon(
                            _showEmoji
                                ? Icons.keyboard_rounded
                                : Icons.emoji_emotions_outlined,
                            color: Colors.white.withValues(alpha: 0.75)),
                        tooltip: _showEmoji ? 'Keyboard' : 'Add emoji',
                        onPressed: _toggleEmoji,
                      ),
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
          // Inline emoji panel: the caption bar stays visible directly above and
          // updates live as emojis are tapped (no covering modal sheet).
          if (_showEmoji)
            SizedBox(
              height: 300,
              child: inlineEmojiPicker(context, _caption),
            ),
        ],
      ),
    );
  }

  Widget _videoCard() {
    final v = _video;
    if (v != null && v.value.isInitialized) {
      return ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: v,
        builder: (_, val, _) => GestureDetector(
          onTap: () => val.isPlaying ? v.pause() : v.play(),
          child: Stack(
            alignment: Alignment.center,
            children: [
              AspectRatio(
                aspectRatio: val.aspectRatio == 0 ? 9 / 16 : val.aspectRatio,
                child: VideoPlayer(v),
              ),
              if (!val.isPlaying)
                const Icon(Icons.play_circle_fill_rounded,
                    color: Colors.white70, size: 68),
              Positioned(
                right: 12,
                bottom: 12,
                child: IconButton(
                  icon: Icon(
                    val.volume == 0
                        ? Icons.volume_off_rounded
                        : Icons.volume_up_rounded,
                    color: Colors.white,
                  ),
                  onPressed: () => v.setVolume(val.volume == 0 ? 1 : 0),
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (_videoFailed) return _videoFallbackCard();
    return const CircularProgressIndicator(color: Colors.white);
  }

  Widget _videoFallbackCard() {
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
  final String initialTitle;
  final String initialArtist;

  const _MusicStoryPage({
    required this.apiBase,
    required this.onPosted,
    this.initialTitle = '',
    this.initialArtist = '',
  });

  @override
  State<_MusicStoryPage> createState() => _MusicStoryPageState();
}

class _MusicStoryPageState extends State<_MusicStoryPage> {
  // Tap-to-cycle background gradients (stored as "hex1,hex2"). A wide vibe
  // range — deep/vivid, neon, romantic, warm-white and black — so the text ink
  // adapts to each (see _ink) and stays readable on light backgrounds too.
  static const List<List<Color>> _palettes = [
    // Deep & vivid
    [Color(0xFF5B2C83), Color(0xFF1D1040)], // purple night
    [Color(0xFF11998E), Color(0xFF38EF7D)], // emerald
    [Color(0xFFEE0979), Color(0xFFFF6A00)], // sunset
    [Color(0xFF2193B0), Color(0xFF6DD5ED)], // sky
    [Color(0xFF373B44), Color(0xFF4286F4)], // steel blue
    [Color(0xFF0F2027), Color(0xFF2C5364)], // deep sea
    // Neon
    [Color(0xFFFF2FB9), Color(0xFF00E5FF)], // neon pink → cyan
    [Color(0xFF39FF14), Color(0xFF00E5A0)], // neon green
    [Color(0xFF7F00FF), Color(0xFFE100FF)], // electric violet
    // Romantic
    [Color(0xFFB24592), Color(0xFFF15F79)], // rose wine
    [Color(0xFF870000), Color(0xFF190A05)], // deep love
    [Color(0xFFDA4453), Color(0xFF89216B)], // blush
    // Sun & gold
    [Color(0xFFFFB75E), Color(0xFFED8F03)], // gold sunrise
    // Warm white / cream (light — ink flips dark)
    [Color(0xFFFFF6EC), Color(0xFFFCE9D6)], // warm white
    [Color(0xFFF7F3E9), Color(0xFFF5D9A8)], // gold cream
    // Black & charcoal
    [Color(0xFF000000), Color(0xFF1A1A1A)], // black
    [Color(0xFF232526), Color(0xFF414345)], // charcoal
  ];

  final TextEditingController _title = TextEditingController();
  final TextEditingController _artist = TextEditingController();
  final TextEditingController _caption = TextEditingController();
  int _bg = 0;
  String? _stickerUrl; // chosen GIF/sticker (animates with the song)
  bool _posting = false;
  bool _showEmoji = false; // inline emoji panel (field stays visible above it)
  final ScrollController _scroll = ScrollController();

  void _toggleEmoji() {
    final opening = !_showEmoji;
    setState(() => _showEmoji = opening);
    if (opening) {
      // Hide the keyboard, then scroll the caption field (bottom of the form)
      // into view just above the panel so you can see what you're typing.
      FocusManager.instance.primaryFocus?.unfocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  /// Tap anywhere on the form (outside a field / the panel) → drop the keyboard
  /// and the emoji panel.
  void _dismissInput() {
    FocusManager.instance.primaryFocus?.unfocus();
    if (_showEmoji) setState(() => _showEmoji = false);
  }

  @override
  void initState() {
    super.initState();
    // Pre-fill from the currently playing track (empty if nothing is playing).
    _title.text = widget.initialTitle;
    _artist.text = widget.initialArtist;
  }

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _caption.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String _hex(Color c) => '#${c.toARGB32().toRadixString(16).padLeft(8, '0')}';
  String _bgValue() => '${_hex(_palettes[_bg][0])},${_hex(_palettes[_bg][1])}';

  /// Foreground "ink" for a gradient: near-black on light backgrounds (warm
  /// white / cream), white on dark ones — so overlaid text is always legible.
  static Color _ink(List<Color> pair) {
    final l =
        (pair[0].computeLuminance() + pair[1].computeLuminance()) / 2;
    return l > 0.55 ? const Color(0xFF15171C) : Colors.white;
  }

  Future<void> _pickSticker() async {
    final url = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.6,
          child: GifPicker(
            onSelected: (gif) => Navigator.pop(ctx, gif.fullUrl),
          ),
        ),
      ),
    );
    if (url != null && mounted) setState(() => _stickerUrl = url);
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
      background: _bgValue(),
      musicArtUrl: _stickerUrl,
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
    final ink = _ink(_palettes[_bg]);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: ink,
        title: const Text('Now playing'),
        actions: [
          IconButton(
            tooltip: 'Background colour',
            icon: const Icon(Icons.palette_rounded),
            onPressed: () =>
                setState(() => _bg = (_bg + 1) % _palettes.length),
          ),
          IconButton(
            tooltip: 'Add a GIF / sticker',
            icon: const Icon(Icons.gif_box_outlined),
            onPressed: _pickSticker,
          ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: _palettes[_bg],
          ),
        ),
        // Fill the whole screen so the gradient has no black blank below the
        // short form on tall desktop/web windows.
        child: SizedBox.expand(
          child: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _dismissInput,
                    child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        const SizedBox(height: 8),
                        // Sticker/GIF (animates) if chosen, else a note tile.
                        GestureDetector(
                          onTap: _pickSticker,
                          child: SizedBox(
                            width: 150,
                            height: 150,
                            child: _stickerUrl != null
                                ? Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      ClipRRect(
                                        borderRadius:
                                            BorderRadius.circular(18),
                                        child: Image.network(
                                          _stickerUrl!,
                                          width: 150,
                                          height: 150,
                                          fit: BoxFit.contain,
                                        ),
                                      ),
                                      Positioned(
                                        top: -8,
                                        right: -8,
                                        child: IconButton(
                                          icon: const Icon(Icons.cancel,
                                              color: Colors.white),
                                          onPressed: () => setState(
                                              () => _stickerUrl = null),
                                        ),
                                      ),
                                    ],
                                  )
                                : Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(18),
                                      color: ink.withValues(alpha: 0.12),
                                    ),
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.gif_box_outlined,
                                            color: ink, size: 46),
                                        const SizedBox(height: 6),
                                        Text('Add a sticker',
                                            style: TextStyle(
                                                color: ink
                                                    .withValues(alpha: 0.7),
                                                fontSize: 12)),
                                      ],
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 22),
                        _field(_title, 'Song title', ink),
                        const SizedBox(height: 12),
                        _field(_artist, 'Artist (optional)', ink),
                        const SizedBox(height: 12),
                        _field(_caption, 'Say something (optional)', ink,
                            onEmoji: _toggleEmoji),
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
                // Inline emoji panel: the caption stays visible above and
                // updates live as emojis are tapped (no covering modal).
                if (_showEmoji)
                  SizedBox(
                    height: 300,
                    child: inlineEmojiPicker(context, _caption),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String hint, Color ink,
      {VoidCallback? onEmoji}) {
    return TextField(
      controller: c,
      style: TextStyle(color: ink),
      onTap: () {
        if (_showEmoji) setState(() => _showEmoji = false);
      },
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: ink.withValues(alpha: 0.6)),
        filled: true,
        fillColor: ink.withValues(alpha: 0.12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        suffixIcon: onEmoji == null
            ? null
            : IconButton(
                icon: Icon(
                    _showEmoji
                        ? Icons.keyboard_rounded
                        : Icons.emoji_emotions_outlined,
                    color: ink.withValues(alpha: 0.75)),
                tooltip: _showEmoji ? 'Keyboard' : 'Add emoji',
                onPressed: onEmoji,
              ),
      ),
    );
  }
}

// ── Text-only status ─────────────────────────────────────────────────────────
class _TextStoryPage extends StatefulWidget {
  final VoidCallback onPosted;

  const _TextStoryPage({required this.onPosted});

  @override
  State<_TextStoryPage> createState() => _TextStoryPageState();
}

class _TextStoryPageState extends State<_TextStoryPage> {
  static const List<Color> _colors = [
    Color(0xFF5B2C83),
    Color(0xFF0F2027),
    Color(0xFFEE5522),
    Color(0xFF11998E),
    Color(0xFF3A2CA0),
    Color(0xFFED213A),
    Color(0xFF232526),
    Color(0xFF1E88E5),
  ];

  final TextEditingController _text = TextEditingController();
  int _bg = 0;
  bool _posting = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String _hex(Color c) => '#${c.toARGB32().toRadixString(16).padLeft(8, '0')}';

  Future<void> _post() async {
    final text = _text.text.trim();
    if (text.isEmpty) {
      _toast('Type something first');
      return;
    }
    setState(() => _posting = true);
    final created = await ApiService().createStory(
      kind: 'text',
      caption: text,
      background: _hex(_colors[_bg]),
    );
    if (!mounted) return;
    setState(() => _posting = false);
    if (created == null) {
      _toast('Could not post status');
      return;
    }
    widget.onPosted();
    Navigator.pop(context);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _colors[_bg],
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        title: const Text('Text status'),
        actions: [
          IconButton(
            tooltip: 'Background colour',
            icon: const Icon(Icons.palette_rounded),
            onPressed: () =>
                setState(() => _bg = (_bg + 1) % _colors.length),
          ),
          IconButton(
            tooltip: 'Add emoji',
            icon: const Icon(Icons.emoji_emotions_outlined),
            onPressed: () => showEmojiPickerSheet(context, _text),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: TextField(
              controller: _text,
              autofocus: true,
              textAlign: TextAlign.center,
              maxLines: null,
              cursorColor: Colors.white,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w600),
              decoration: const InputDecoration(
                hintText: 'Type a status',
                hintStyle: TextStyle(color: Colors.white54, fontSize: 24),
                border: InputBorder.none,
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _posting ? null : _post,
        child: _posting
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.send_rounded),
      ),
    );
  }
}
