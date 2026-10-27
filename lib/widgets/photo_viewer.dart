import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Full-screen photo view: pinch / wheel to zoom, double-tap to zoom in/out,
/// back arrow (and system Back / Esc) to leave, and a swipe to dismiss (when
/// not zoomed) — the photo follows the finger and fades. With several
/// [gallery] photos, swipe left/right moves between them (down dismisses).
/// [caption] (or [captions] per photo) reads along the bottom.
Future<void> showPhotoViewer(
  BuildContext context,
  ImageProvider image, {
  List<Widget> actions = const [],
  String? caption,
  List<ImageProvider>? gallery,
  List<String?>? captions,
  int initialIndex = 0,
}) {
  final images = (gallery != null && gallery.isNotEmpty) ? gallery : [image];
  final caps = captions ?? [caption];
  return Navigator.of(context).push(PageRouteBuilder<void>(
    opaque: false,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (_, _, _) => _PhotoViewer(
      images: images,
      captions: caps,
      initial: initialIndex.clamp(0, images.length - 1),
      actions: actions,
    ),
    transitionsBuilder: (_, a, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: a, curve: Curves.easeOut),
      child: ScaleTransition(
        scale: Tween(begin: 0.94, end: 1.0)
            .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: child,
      ),
    ),
  ));
}

class _PhotoViewer extends StatefulWidget {
  const _PhotoViewer({
    required this.images,
    required this.captions,
    required this.initial,
    required this.actions,
  });
  final List<ImageProvider> images;
  final List<String?> captions;
  final int initial;
  final List<Widget> actions;

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer>
    with SingleTickerProviderStateMixin {
  late final PageController _pages = PageController(initialPage: widget.initial);
  late int _at = widget.initial;
  bool _zoomed = false;
  late final AnimationController _back = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 200));
  Offset _drag = Offset.zero;
  Offset _dragFrom = Offset.zero;

  bool get _many => widget.images.length > 1;

  @override
  void initState() {
    super.initState();
    _back.addListener(() {
      setState(() => _drag = Offset.lerp(_dragFrom, Offset.zero, _back.value)!);
    });
  }

  @override
  void dispose() {
    _pages.dispose();
    _back.dispose();
    super.dispose();
  }

  // One finger on an un-zoomed photo drags it toward dismissal: any way for
  // a single photo, down only in a gallery (left/right turns the page).
  void _drag1(Offset delta) {
    if (_zoomed) return;
    setState(() => _drag += _many ? Offset(0, delta.dy) : delta);
  }

  void _dragEnd(Offset velocity) {
    if (_drag == Offset.zero) return;
    final size = MediaQuery.sizeOf(context);
    final far = _drag.dx.abs() > size.width * 0.22 ||
        _drag.dy > size.height * 0.18 ||
        (!_many && velocity.dx.abs() > 900) ||
        velocity.dy > 900;
    if (far) {
      Navigator.of(context).maybePop();
    } else {
      _dragFrom = _drag;
      _back.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dist = (_drag.dx.abs() / size.width + _drag.dy.abs() / size.height)
        .clamp(0.0, 1.0);
    final bg = (1 - dist * 1.6).clamp(0.25, 1.0);
    final cap = _at < widget.captions.length ? widget.captions[_at] : null;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        if (_many)
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              _pages.nextPage(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic),
        if (_many)
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
              _pages.previousPage(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic),
      },
      child: Focus(
        autofocus: true,
        child: Material(
          color: Colors.black.withValues(alpha: 0.96 * bg),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Transform.translate(
                offset: _drag,
                child: Transform.scale(
                  scale: 1 - dist * 0.25,
                  child: PageView.builder(
                    controller: _pages,
                    physics: _zoomed || !_many
                        ? const NeverScrollableScrollPhysics()
                        : const PageScrollPhysics(),
                    itemCount: widget.images.length,
                    onPageChanged: (i) => setState(() {
                      _at = i;
                      _zoomed = false;
                    }),
                    itemBuilder: (_, i) => _ZoomPage(
                      image: widget.images[i],
                      onZoomChanged: (z) => setState(() => _zoomed = z),
                      onDrag: _drag1,
                      onDragEnd: _dragEnd,
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Back',
                        style: IconButton.styleFrom(
                            backgroundColor:
                                Colors.black.withValues(alpha: 0.35)),
                        icon: const Icon(Icons.arrow_back_rounded,
                            color: Colors.white),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      if (_many)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text('${_at + 1} / ${widget.images.length}',
                              style: const TextStyle(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w600)),
                        ),
                      const Spacer(),
                      ...widget.actions,
                    ],
                  ),
                ),
              ),
              if ((cap ?? '').trim().isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: bg,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(20, 28, 20, 22),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.7),
                              Colors.transparent,
                            ],
                          ),
                        ),
                        child: SafeArea(
                          top: false,
                          child: Text(cap!.trim(),
                              textAlign: TextAlign.center,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  height: 1.4)),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One zoomable photo page (pinch / wheel / double-tap).
class _ZoomPage extends StatefulWidget {
  const _ZoomPage({
    required this.image,
    required this.onZoomChanged,
    required this.onDrag,
    required this.onDragEnd,
  });
  final ImageProvider image;
  final ValueChanged<bool> onZoomChanged;
  final ValueChanged<Offset> onDrag;
  final ValueChanged<Offset> onDragEnd;

  @override
  State<_ZoomPage> createState() => _ZoomPageState();
}

class _ZoomPageState extends State<_ZoomPage> {
  final _tc = TransformationController();
  TapDownDetails? _tapAt;
  bool _was = false;

  bool get _zoomed => _tc.value.getMaxScaleOnAxis() > 1.01;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  void _report() {
    final z = _zoomed;
    if (z != _was) {
      _was = z;
      widget.onZoomChanged(z);
      setState(() {});
    }
  }

  void _toggleZoom() {
    if (_zoomed) {
      _tc.value = Matrix4.identity();
    } else {
      final p = _tapAt?.localPosition ?? Offset.zero;
      const s = 2.5;
      _tc.value = Matrix4.identity()
        ..translateByDouble(-p.dx * (s - 1), -p.dy * (s - 1), 0, 1)
        ..scaleByDouble(s, s, 1, 1);
    }
    _report();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return GestureDetector(
      onDoubleTapDown: (d) => _tapAt = d,
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _tc,
        minScale: 1,
        maxScale: 5,
        // Pan only while zoomed; otherwise a drag dismisses / turns pages.
        panEnabled: _zoomed,
        onInteractionUpdate: (d) {
          if (!_zoomed && d.pointerCount == 1) widget.onDrag(d.focalPointDelta);
        },
        onInteractionEnd: (d) {
          _report();
          widget.onDragEnd(d.velocity.pixelsPerSecond);
        },
        child: Center(
          child: Image(
            image: widget.image,
            fit: BoxFit.contain,
            width: size.width,
            height: size.height,
            errorBuilder: (_, _, _) => const Icon(Icons.broken_image_rounded,
                color: Colors.white54, size: 48),
          ),
        ),
      ),
    );
  }
}

/// A photo that fits its card WHOLE (never taller than [maxHeight], so the
/// words below stay in view). Double-tap, or the corner expand button,
/// opens it full screen in [showPhotoViewer].
class CompactPhoto extends StatelessWidget {
  const CompactPhoto({
    super.key,
    required this.image,
    required this.width,
    required this.maxHeight,
    this.actions = const [],
    this.onOpen,
    this.caption,
  });

  /// Shown along the bottom of the full-size view.
  final String? caption;
  final ImageProvider image;
  final double width;
  final double maxHeight;
  final List<Widget> actions;

  /// Override how it opens (default: [showPhotoViewer]).
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    void open() =>
        onOpen != null
        ? onOpen!()
        : showPhotoViewer(context, image, actions: actions, caption: caption);
    return GestureDetector(
      onDoubleTap: open,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width, maxHeight: maxHeight),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Image(
              image: image,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const SizedBox(height: 40),
            ),
            Positioned(
              right: 6,
              bottom: 6,
              child: Material(
                color: Colors.black.withValues(alpha: 0.38),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: open,
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(Icons.open_in_full_rounded,
                        size: 16, color: Colors.white),
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
