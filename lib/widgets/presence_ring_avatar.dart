import 'dart:math' as math;

import 'package:flutter/material.dart';

/// What the circle around a friend's photo is saying.
enum RingMode {
  /// No music ring (story ring / online dot are drawn by the caller).
  none,

  /// They're playing music: the ring fills with song progress (or, when the
  /// progress isn't known, a slow sweep turns), plus a mini spinning vinyl.
  listening,

  /// Listening together with ME: two arcs weave in opposite directions.
  together,
}

/// A friend's photo with its status ring, sized to a fixed [slot] so a row
/// never shifts when the ring comes or goes. [face] is the photo's diameter;
/// the ring lives in the 4 px around it.
class PresenceRingAvatar extends StatefulWidget {
  const PresenceRingAvatar({
    super.key,
    required this.child,
    required this.face,
    this.mode = RingMode.none,
    this.color = const Color(0xFFE8505B),
    this.color2 = const Color(0xFFF2A541),
    this.progress,
    this.glow = false,
    this.gapColor,
  });

  /// The photo, already [face] px wide.
  final Widget child;
  final double face;
  final RingMode mode;

  /// Ring colour (listening) / first arc (together).
  final Color color;

  /// Second arc when together.
  final Color color2;

  /// 0..1 song progress, read every frame; null = unknown (slow sweep).
  final double? Function()? progress;

  /// Bonded + quiet: a thin breathing theme ring just around the photo,
  /// inside the rim (ignored while a music ring shows).
  final bool glow;

  /// Page colour behind the mini vinyl's edge.
  final Color? gapColor;

  double get slot => face + 8;

  @override
  State<PresenceRingAvatar> createState() => _PresenceRingAvatarState();
}

class _PresenceRingAvatarState extends State<PresenceRingAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 6));

  bool get _moving => widget.mode != RingMode.none || widget.glow;

  @override
  void initState() {
    super.initState();
    if (_moving) _c.repeat();
  }

  @override
  void didUpdateWidget(PresenceRingAvatar old) {
    super.didUpdateWidget(old);
    if (_moving && !_c.isAnimating) {
      _c.repeat();
    } else if (!_moving && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final slot = widget.slot;
    final scheme = Theme.of(context).colorScheme;
    final track = scheme.onSurface.withValues(alpha: 0.10);
    final gap = widget.gapColor ?? scheme.surface;
    final listening = widget.mode == RingMode.listening;
    return SizedBox(
      width: slot,
      height: slot,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final t = _c.value;
          return Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              // Bonded + quiet: a thin theme ring hugging the photo, INSIDE
              // the grey plate's rim (plate outer, bond inner) — breathing
              // gently. Stays within the slot: nothing grows.
              if (widget.glow && widget.mode == RingMode.none)
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Opacity(
                      // 0.55 → 1 → 0.55, a breath every 3 s.
                      opacity: 0.55 +
                          0.45 * (0.5 - 0.5 * math.cos(t * math.pi * 2 * 2)),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: widget.color, width: 2),
                        ),
                      ),
                    ),
                  ),
                ),
              if (widget.mode != RingMode.none)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _RingPainter(
                      mode: widget.mode,
                      t: t,
                      progress: widget.progress?.call(),
                      color: widget.color,
                      color2: widget.color2,
                      track: track,
                    ),
                  ),
                ),
              SizedBox(width: widget.face, height: widget.face, child: child),
              if (listening)
                Positioned(
                  right: -3,
                  bottom: -3,
                  child: Transform.rotate(
                    angle: t * math.pi * 2 * 2, // ~3 s a turn
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: gap, width: 2),
                        gradient: RadialGradient(
                          colors: [
                            widget.color,
                            widget.color,
                            const Color(0xFF1B1B1B),
                            const Color(0xFF2E2E2E),
                            const Color(0xFF1B1B1B),
                          ],
                          stops: const [0.0, 0.3, 0.31, 0.7, 1.0],
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Container(
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle, color: gap),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
        child: widget.child,
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.mode,
    required this.t,
    required this.progress,
    required this.color,
    required this.color2,
    required this.track,
  });

  final RingMode mode;
  final double t;
  final double? progress;
  final Color color, color2, track;

  @override
  void paint(Canvas canvas, Size size) {
    const w = 3.0;
    final r = size.width / 2 - w / 2;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: r);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round;
    const top = -math.pi / 2;
    const full = math.pi * 2;
    switch (mode) {
      case RingMode.none:
        return;
      case RingMode.listening:
        canvas.drawCircle(rect.center, r, p..color = track);
        final prog = progress;
        if (prog != null) {
          final v = prog.clamp(0.0, 1.0);
          if (v > 0.005) {
            canvas.drawArc(rect, top, full * v, false, p..color = color);
          }
        } else {
          // Unknown progress: a soft comet sweeps round.
          p.shader = SweepGradient(
            colors: [color.withValues(alpha: 0), color],
            transform: GradientRotation(top + full * t),
          ).createShader(rect);
          canvas.drawArc(rect, top + full * t, full * 0.7, false, p);
          p.shader = null;
        }
      case RingMode.together:
        // Two pairs of arcs, turning opposite ways, weaving.
        final a = top + full * t;
        final b = top - full * t * 0.66;
        p.color = color;
        canvas.drawArc(rect, a, full * 0.36, false, p);
        canvas.drawArc(rect, a + full * 0.5, full * 0.36, false, p);
        final inner = rect.deflate(1.6);
        p
          ..color = color2
          ..strokeWidth = 2.2;
        canvas.drawArc(inner, b + full * 0.12, full * 0.26, false, p);
        canvas.drawArc(inner, b + full * 0.62, full * 0.26, false, p);
    }
  }

  @override
  bool shouldRepaint(_RingPainter o) =>
      o.t != t ||
      o.progress != progress ||
      o.mode != mode ||
      o.color != color ||
      o.color2 != color2 ||
      o.track != track;
}
