import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Rings that ripple OUTWARD from a widget in its own outline — the chat's
/// "here it is" when you jump to a replied / pinned / searched message. Like
/// the player disc's rings: a few soft strokes leave the edge one after
/// another, grow and fade. Nothing behind the bubble changes colour.
///
/// Give the outline either as a [shape] (a bubble's ShapeBorder, tail and
/// all) or as [pathFor] (a custom outline in the child's own box, e.g. the
/// heart). Bump [trigger] to fire once; 0 = idle.
class JumpRings extends StatefulWidget {
  const JumpRings({
    super.key,
    required this.trigger,
    required this.color,
    required this.child,
    this.shape,
    this.pathFor,
    this.neon = false,
  });

  /// Neon style: a soft glow around each ring plus a thin white inner halo,
  /// so a bright colour still reads on any bubble / wallpaper.
  final bool neon;

  /// The house ripple colour for ordinary bubbles (hearts use their mood).
  static const Color neonRed = Color(0xFFFF1744);

  final int trigger;
  final Color color;
  final ShapeBorder? shape;
  final Path Function(Size size)? pathFor;
  final Widget child;

  @override
  State<JumpRings> createState() => _JumpRingsState();
}

class _JumpRingsState extends State<JumpRings>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1500));

  @override
  void initState() {
    super.initState();
    if (widget.trigger > 0) _c.forward(from: 0);
  }

  @override
  void didUpdateWidget(JumpRings old) {
    super.didUpdateWidget(old);
    if (widget.trigger > 0 && widget.trigger != old.trigger) {
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) => CustomPaint(
        foregroundPainter: (_c.isAnimating || (_c.value > 0 && _c.value < 1))
            ? _RingsPainter(
                t: _c.value,
                color: widget.color,
                shape: widget.shape,
                pathFor: widget.pathFor,
                still: still,
                neon: widget.neon,
              )
            : null,
        child: child,
      ),
      child: widget.child,
    );
  }
}

class _RingsPainter extends CustomPainter {
  _RingsPainter({
    required this.t,
    required this.color,
    this.shape,
    this.pathFor,
    this.still = false,
    this.neon = false,
  });

  final bool neon;
  final double t;
  final Color color;
  final ShapeBorder? shape;
  final Path Function(Size)? pathFor;
  final bool still;

  Path _outline(Size size, double grow) {
    if (shape != null) {
      return shape!.getOuterPath(Rect.fromLTWH(
          -grow, -grow, size.width + grow * 2, size.height + grow * 2));
    }
    final base = pathFor?.call(size) ??
        (Path()..addRRect(RRect.fromRectAndRadius(
            Offset.zero & size, const Radius.circular(18))));
    // Scale the outline about its centre so it grows by [grow] at the edges.
    final sx = (size.width + grow * 2) / size.width;
    final sy = (size.height + grow * 2) / size.height;
    final c = size.center(Offset.zero);
    final m = Matrix4.identity()
      ..translateByDouble(c.dx, c.dy, 0, 1)
      ..scaleByDouble(sx, sy, 1, 1)
      ..translateByDouble(-c.dx, -c.dy, 0, 1);
    return base.transform(m.storage);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // Reduced motion: one gentle outline that fades, no travel.
    if (still) {
      final a = (1 - t).clamp(0.0, 1.0);
      canvas.drawPath(
        _outline(size, 3),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color.withValues(alpha: 0.7 * a),
      );
      return;
    }
    const rings = 3;
    const stagger = 0.17;
    const span = 1 - stagger * (rings - 1);
    for (var k = 0; k < rings; k++) {
      final p = ((t - k * stagger) / span).clamp(0.0, 1.0);
      if (p <= 0 || p >= 1) continue;
      final e = Curves.easeOutCubic.transform(p);
      final grow = 1.5 + 24 * e;
      final fade = math.pow(1 - p, 1.4).toDouble();
      final w = 2.8 * (1 - p) + 0.6;
      if (neon) {
        // The glow: a wide, blurred stroke behind the ring.
        canvas.drawPath(
          _outline(size, grow),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = w * 3.2
            ..color = color.withValues(alpha: 0.38 * fade)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
        );
        // The thin white halo just inside it (crisp on pink / red bubbles).
        canvas.drawPath(
          _outline(size, grow - w * 0.9),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.9
            ..color = Colors.white.withValues(alpha: 0.55 * fade),
        );
      }
      canvas.drawPath(
        _outline(size, grow),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w
          ..color = color.withValues(alpha: (neon ? 0.95 : 0.75) * fade)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.2),
      );
    }
  }

  @override
  bool shouldRepaint(_RingsPainter o) =>
      o.t != t || o.color != color || o.still != still || o.neon != neon;
}
