import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Full-screen photo view: pinch / wheel to zoom, double-tap to zoom in/out,
/// back arrow (and system Back / Esc) to leave, and a swipe left/right/down
/// (when not zoomed) to dismiss — the photo follows the finger and fades.
Future<void> showPhotoViewer(
  BuildContext context,
  ImageProvider image, {
  List<Widget> actions = const [],
}) {
  return Navigator.of(context).push(PageRouteBuilder<void>(
    opaque: false,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (_, _, _) => _PhotoViewer(image: image, actions: actions),
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
  const _PhotoViewer({required this.image, required this.actions});
  final ImageProvider image;
  final List<Widget> actions;

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer>
    with SingleTickerProviderStateMixin {
  final _tc = TransformationController();
  late final AnimationController _back = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 200));
  Offset _drag = Offset.zero;
  Offset _dragFrom = Offset.zero;
  TapDownDetails? _tapAt;

  bool get _zoomed => _tc.value.getMaxScaleOnAxis() > 1.01;

  @override
  void initState() {
    super.initState();
    _back.addListener(() {
      setState(() => _drag = Offset.lerp(_dragFrom, Offset.zero, _back.value)!);
    });
  }

  @override
  void dispose() {
    _tc.dispose();
    _back.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    if (_zoomed) {
      _tc.value = Matrix4.identity();
      return;
    }
    final p = _tapAt?.localPosition ?? Offset.zero;
    const s = 2.5;
    _tc.value = Matrix4.identity()
      ..translateByDouble(-p.dx * (s - 1), -p.dy * (s - 1), 0, 1)
      ..scaleByDouble(s, s, 1, 1);
  }

  // One finger on an un-zoomed photo drags it toward dismissal (the viewer's
  // own pan only runs while zoomed), so pinch/zoom and swipe never fight.
  void _onUpdate(ScaleUpdateDetails d) {
    if (_zoomed || d.pointerCount != 1) return;
    setState(() => _drag += d.focalPointDelta);
  }

  void _onEnd(ScaleEndDetails d) {
    if (_drag == Offset.zero) {
      setState(() {}); // zoom state may have changed
      return;
    }
    final size = MediaQuery.sizeOf(context);
    final v = d.velocity.pixelsPerSecond;
    final far = _drag.dx.abs() > size.width * 0.22 ||
        _drag.dy > size.height * 0.18 ||
        v.dx.abs() > 900 ||
        v.dy > 900;
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
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: Material(
          color: Colors.black.withValues(alpha: 0.96 * bg),
          child: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                onDoubleTapDown: (d) => _tapAt = d,
                onDoubleTap: _toggleZoom,
                child: Transform.translate(
                  offset: _drag,
                  child: Transform.scale(
                    scale: 1 - dist * 0.25,
                    child: InteractiveViewer(
                      transformationController: _tc,
                      minScale: 1,
                      maxScale: 5,
                      // Pan only while zoomed; otherwise drags dismiss.
                      panEnabled: _zoomed,
                      onInteractionUpdate: _onUpdate,
                      onInteractionEnd: _onEnd,
                      child: Center(
                        child: Image(
                          image: widget.image,
                          fit: BoxFit.contain,
                          width: size.width,
                          height: size.height,
                          errorBuilder: (_, _, _) => const Icon(
                              Icons.broken_image_rounded,
                              color: Colors.white54,
                              size: 48),
                        ),
                      ),
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
                      const Spacer(),
                      ...widget.actions,
                    ],
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
  });

  final ImageProvider image;
  final double width;
  final double maxHeight;
  final List<Widget> actions;

  /// Override how it opens (default: [showPhotoViewer]).
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    void open() =>
        onOpen != null ? onOpen!() : showPhotoViewer(context, image, actions: actions);
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
