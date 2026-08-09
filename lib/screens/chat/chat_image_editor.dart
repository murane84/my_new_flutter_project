part of '../chat_page.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Image preview + lightweight annotation editor.
//
// Shown before an image is sent so the user can (a) draw freehand, (b) circle
// something, (c) draw a focus box, (d) drop draggable emoji stickers, and add a
// caption. All marks are stored in FRACTIONAL (0..1) canvas coordinates so they
// stay aligned when the editor is captured at high resolution. On send, if any
// edit exists the annotated image is flattened via RepaintBoundary → PNG so the
// recipient sees exactly what the sender drew; otherwise the original bytes are
// sent untouched. Returns a map {caption, bytes, mime} (or null if cancelled).
// ─────────────────────────────────────────────────────────────────────────────
enum _EditTool { move, pen, circle, box }

class _PenStroke {
  _PenStroke(this.color, this.width);
  final Color color;
  final double width;
  final List<Offset> points = []; // fractional (0..1)
}

class _ShapeMark {
  _ShapeMark(this.color, this.width, this.oval, this.start, this.end);
  final Color color;
  final double width;
  final bool oval; // true = circle/oval, false = rectangle focus box
  Offset start; // fractional
  Offset end; // fractional
}

class _EmojiMark {
  _EmojiMark(this.emoji, this.pos, this.size);
  final String emoji;
  Offset pos; // fractional centre (0..1)
  double size; // logical font size
}

class _ImagePreviewScreen extends StatefulWidget {
  const _ImagePreviewScreen({
    required this.imageBytes,
    required this.friendName,
  });
  final Uint8List imageBytes;
  final String friendName;

  @override
  State<_ImagePreviewScreen> createState() => _ImagePreviewScreenState();
}

class _ImagePreviewScreenState extends State<_ImagePreviewScreen> {
  final GlobalKey _boundaryKey = GlobalKey();
  final TextEditingController _captionCtrl = TextEditingController();
  // HD off = compress before upload (smaller); HD on = send the original.
  bool _hd = false;
  // The editor canvas's on-screen size, captured in the LayoutBuilder. Used to
  // scale strokes/emoji from display units up to the ORIGINAL image resolution
  // when flattening, so the sent image stays sharp (not a blurry screen grab).
  double _canvasW = 1;

  final List<_PenStroke> _strokes = [];
  final List<_ShapeMark> _shapes = [];
  final List<_EmojiMark> _emojis = [];
  // Chronological undo stack: which list the last-added mark went to.
  final List<String> _history = [];

  _EditTool _tool = _EditTool.move;
  Color _color = const Color(0xFFFF3B30);
  double _aspect = 1;
  bool _busy = false;
  bool _showEmojiTray = false;
  _ShapeMark? _drafting; // shape being dragged out right now

  static const List<Color> _palette = [
    Color(0xFFFF3B30), // red
    Color(0xFFFFCC00), // yellow
    Color(0xFF34C759), // green
    Color(0xFF0A84FF), // blue
    Color(0xFFFFFFFF), // white
    Color(0xFF1C1C1E), // near-black
  ];
  static const List<String> _emojiTray = [
    '😀', '😂', '😍', '😎', '🥳', '👍', '🙏', '🔥', '❤️', '⭐',
    '✅', '❌', '❗', '➡️', '⬅️', '⬆️', '⬇️', '⚡', '💯', '🎯',
  ];

  @override
  void initState() {
    super.initState();
    // Learn the image's aspect ratio so the editor canvas matches it exactly
    // (no letterbox baked into the flattened result).
    ui.decodeImageFromList(widget.imageBytes, (img) {
      if (!mounted) return;
      setState(() => _aspect = img.width / img.height);
    });
  }

  @override
  void dispose() {
    _captionCtrl.dispose();
    super.dispose();
  }

  void _addEmoji(String e) {
    setState(() {
      _emojis.add(_EmojiMark(e, const Offset(0.5, 0.5), 44));
      _history.add('emoji');
      _showEmojiTray = false;
    });
  }

  void _undo() {
    if (_history.isEmpty) return;
    setState(() {
      final last = _history.removeLast();
      if (last == 'pen' && _strokes.isNotEmpty) {
        _strokes.removeLast();
      } else if (last == 'shape' && _shapes.isNotEmpty) {
        _shapes.removeLast();
      } else if (last == 'emoji' && _emojis.isNotEmpty) {
        _emojis.removeLast();
      }
    });
  }

  bool get _hasEdits =>
      _strokes.isNotEmpty || _shapes.isNotEmpty || _emojis.isNotEmpty;

  Future<void> _send() async {
    setState(() => _busy = true);
    Uint8List outBytes = widget.imageBytes;
    String mime = 'image/jpeg';
    if (_hasEdits) {
      final rendered = await _renderAnnotated();
      if (rendered != null) {
        outBytes = rendered;
        mime = 'image/png';
      }
    }
    if (!mounted) return;
    Navigator.of(context).pop(<String, dynamic>{
      'caption': _captionCtrl.text,
      'bytes': outBytes,
      'mime': mime,
      // Honour the HD toggle: off = compress on upload (smaller), on = original.
      'hd': _hd,
    });
  }

  /// Flatten the annotations onto the ORIGINAL full-resolution image (rather
  /// than screen-grabbing the small on-screen editor, which lost detail and
  /// looked blurry). All marks are stored as fractional (0..1) coordinates, so
  /// they map cleanly onto the real pixel dimensions; stroke/emoji sizes are
  /// scaled by (imageWidth / canvasWidth) so the result matches what was drawn.
  Future<Uint8List?> _renderAnnotated() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.imageBytes);
      final frame = await codec.getNextFrame();
      final ui.Image src = frame.image;
      final w = src.width.toDouble();
      final h = src.height.toDouble();
      final scale = _canvasW > 0 ? w / _canvasW : 1.0;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));
      canvas.drawImageRect(
        src,
        Rect.fromLTWH(0, 0, w, h),
        Rect.fromLTWH(0, 0, w, h),
        Paint(),
      );

      for (final st in _strokes) {
        if (st.points.isEmpty) continue;
        final paint = Paint()
          ..color = st.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = st.width * scale
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
        final path = Path();
        for (var i = 0; i < st.points.length; i++) {
          final o = Offset(st.points[i].dx * w, st.points[i].dy * h);
          if (i == 0) {
            path.moveTo(o.dx, o.dy);
          } else {
            path.lineTo(o.dx, o.dy);
          }
        }
        canvas.drawPath(path, paint);
      }

      void drawShape(_ShapeMark sh) {
        final paint = Paint()
          ..color = sh.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = sh.width * scale;
        final rect = Rect.fromPoints(
          Offset(sh.start.dx * w, sh.start.dy * h),
          Offset(sh.end.dx * w, sh.end.dy * h),
        );
        if (sh.oval) {
          canvas.drawOval(rect, paint);
        } else {
          canvas.drawRRect(
              RRect.fromRectAndRadius(rect, Radius.circular(8 * scale)), paint);
        }
      }

      for (final sh in _shapes) {
        drawShape(sh);
      }

      for (final em in _emojis) {
        final tp = TextPainter(
          text: TextSpan(
              text: em.emoji, style: TextStyle(fontSize: em.size * scale)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas,
            Offset(em.pos.dx * w - tp.width / 2, em.pos.dy * h - tp.height / 2));
      }

      final picture = recorder.endRecording();
      final outImg = await picture.toImage(w.toInt(), h.toInt());
      final bd = await outImg.toByteData(format: ui.ImageByteFormat.png);
      return bd?.buffer.asUint8List();
    } catch (_) {
      return null; // fall back to the original bytes
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text('Send to ${widget.friendName}',
            style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            tooltip: 'Undo',
            onPressed: _history.isEmpty ? null : _undo,
            icon: Icon(Icons.undo_rounded,
                color: _history.isEmpty ? Colors.white30 : Colors.white),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Canvas ──────────────────────────────────────────────────────
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: _aspect,
                child: RepaintBoundary(
                  key: _boundaryKey,
                  child: LayoutBuilder(builder: (ctx, c) {
                    final w = c.maxWidth, h = c.maxHeight;
                    _canvasW = w;
                    Offset frac(Offset local) => Offset(
                        (local.dx / w).clamp(0.0, 1.0),
                        (local.dy / h).clamp(0.0, 1.0));
                    final drawing = _tool != _EditTool.move;
                    return Stack(
                      children: [
                        Positioned.fill(
                          child: Image.memory(widget.imageBytes,
                              fit: BoxFit.fill),
                        ),
                        // Drawing layer (pen / circle / box).
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanStart: !drawing
                                ? null
                                : (d) {
                                    final f = frac(d.localPosition);
                                    setState(() {
                                      if (_tool == _EditTool.pen) {
                                        final st = _PenStroke(_color, 3);
                                        st.points.add(f);
                                        _strokes.add(st);
                                        _history.add('pen');
                                      } else {
                                        _drafting = _ShapeMark(
                                            _color,
                                            3,
                                            _tool == _EditTool.circle,
                                            f,
                                            f);
                                      }
                                    });
                                  },
                            onPanUpdate: !drawing
                                ? null
                                : (d) {
                                    final f = frac(d.localPosition);
                                    setState(() {
                                      if (_tool == _EditTool.pen &&
                                          _strokes.isNotEmpty) {
                                        _strokes.last.points.add(f);
                                      } else if (_drafting != null) {
                                        _drafting!.end = f;
                                      }
                                    });
                                  },
                            onPanEnd: !drawing
                                ? null
                                : (_) {
                                    setState(() {
                                      if (_drafting != null) {
                                        _shapes.add(_drafting!);
                                        _history.add('shape');
                                        _drafting = null;
                                      }
                                    });
                                  },
                            child: CustomPaint(
                              painter: _AnnotationPainter(
                                  _strokes, _shapes, _drafting),
                            ),
                          ),
                        ),
                        // Emoji stickers (draggable).
                        ..._emojis.map((em) => Positioned(
                              left: em.pos.dx * w - em.size / 2,
                              top: em.pos.dy * h - em.size / 2,
                              child: GestureDetector(
                                onPanUpdate: (d) {
                                  setState(() {
                                    em.pos += Offset(
                                        d.delta.dx / w, d.delta.dy / h);
                                    em.pos = Offset(em.pos.dx.clamp(0.0, 1.0),
                                        em.pos.dy.clamp(0.0, 1.0));
                                  });
                                },
                                child: Text(em.emoji,
                                    style: TextStyle(fontSize: em.size)),
                              ),
                            )),
                      ],
                    );
                  }),
                ),
              ),
            ),
          ),
          // ── Emoji tray (toggled) ────────────────────────────────────────
          if (_showEmojiTray)
            Container(
              height: 52,
              color: Colors.black,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: _emojiTray.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (_, i) => GestureDetector(
                  onTap: () => _addEmoji(_emojiTray[i]),
                  child: Center(
                    child: Text(_emojiTray[i],
                        style: const TextStyle(fontSize: 26)),
                  ),
                ),
              ),
            ),
          // ── Tool + colour bar ───────────────────────────────────────────
          Container(
            color: Colors.black,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                _toolBtn(Icons.pan_tool_alt_rounded, _EditTool.move, 'Move'),
                _toolBtn(Icons.edit_rounded, _EditTool.pen, 'Draw'),
                _toolBtn(Icons.circle_outlined, _EditTool.circle, 'Circle'),
                _toolBtn(
                    Icons.crop_square_rounded, _EditTool.box, 'Focus box'),
                IconButton(
                  tooltip: 'Emoji',
                  onPressed: () =>
                      setState(() => _showEmojiTray = !_showEmojiTray),
                  icon: Icon(Icons.emoji_emotions_rounded,
                      color: _showEmojiTray
                          ? scheme.primary
                          : Colors.white70),
                ),
                const Spacer(),
                // Colour swatches.
                for (final col in _palette)
                  GestureDetector(
                    onTap: () => setState(() => _color = col),
                    child: Container(
                      width: 22,
                      height: 22,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: col,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _color == col
                              ? Colors.white
                              : Colors.white24,
                          width: _color == col ? 2.5 : 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // ── Caption + send ──────────────────────────────────────────────
          Container(
            color: Colors.black,
            padding: EdgeInsets.only(
              left: 12,
              right: 12,
              top: 6,
              bottom: MediaQuery.of(context).viewInsets.bottom + 10,
            ),
            child: Row(
              children: [
                // HD toggle: off = compressed (smaller), on = original quality.
                Tooltip(
                  message: _hd
                      ? 'HD on — sending original quality'
                      : 'Send compressed · tap for HD (original)',
                  child: GestureDetector(
                    onTap: () => setState(() => _hd = !_hd),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 12),
                      decoration: BoxDecoration(
                        color: _hd ? scheme.primary : Colors.white10,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.hd_rounded,
                              size: 16,
                              color: _hd ? scheme.onPrimary : Colors.white70),
                          const SizedBox(width: 3),
                          Text('HD',
                              style: TextStyle(
                                  color:
                                      _hd ? scheme.onPrimary : Colors.white70,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _captionCtrl,
                    minLines: 1,
                    maxLines: 4,
                    style: const TextStyle(color: Colors.white),
                    cursorColor: scheme.primary,
                    decoration: InputDecoration(
                      hintText: 'Add a caption…',
                      hintStyle: const TextStyle(color: Colors.white54),
                      filled: true,
                      fillColor: Colors.white10,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _busy ? null : _send,
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: _busy
                        ? const Padding(
                            padding: EdgeInsets.all(13),
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.send_rounded,
                            color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolBtn(IconData icon, _EditTool tool, String tip) {
    final selected = _tool == tool;
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tip,
      onPressed: () => setState(() => _tool = tool),
      icon: Icon(icon, color: selected ? scheme.primary : Colors.white70),
    );
  }
}

class _AnnotationPainter extends CustomPainter {
  _AnnotationPainter(this.strokes, this.shapes, this.draft);
  final List<_PenStroke> strokes;
  final List<_ShapeMark> shapes;
  final _ShapeMark? draft;

  @override
  void paint(Canvas canvas, Size size) {
    for (final st in strokes) {
      if (st.points.isEmpty) continue;
      final paint = Paint()
        ..color = st.color
        ..strokeWidth = st.width
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      for (var i = 0; i < st.points.length; i++) {
        final o = Offset(
            st.points[i].dx * size.width, st.points[i].dy * size.height);
        if (i == 0) {
          path.moveTo(o.dx, o.dy);
        } else {
          path.lineTo(o.dx, o.dy);
        }
      }
      canvas.drawPath(path, paint);
    }
    void drawShape(_ShapeMark sh) {
      final paint = Paint()
        ..color = sh.color
        ..strokeWidth = sh.width
        ..style = PaintingStyle.stroke;
      final rect = Rect.fromPoints(
        Offset(sh.start.dx * size.width, sh.start.dy * size.height),
        Offset(sh.end.dx * size.width, sh.end.dy * size.height),
      );
      if (sh.oval) {
        canvas.drawOval(rect, paint);
      } else {
        canvas.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(8)), paint);
      }
    }

    for (final sh in shapes) {
      drawShape(sh);
    }
    if (draft != null) drawShape(draft!);
  }

  @override
  bool shouldRepaint(covariant _AnnotationPainter old) => true;
}
