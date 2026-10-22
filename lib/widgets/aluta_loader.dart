import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/aluta_mood.dart';
import 'glossy_heart.dart';

/// The Aluta logo loader. One look, four moods (see [AlutaMood.loaderStyle]):
///  • heartbeat — the mark gives a soft "lub-dub" every beat
///  • ripple    — each beat sends one faint ring outward, like sound leaving a speaker
///  • breathe   — slow, calm swell (dawn / late night)
///  • orbit     — a brisker, shorter comet with a slightly bigger head
/// Always: ONE thin comet arc (glowing head) hugging the disc in the theme
/// colour (warmer in the morning, softer at night) over a soft halo. No
/// track ring behind the arc. With system "remove animations" on,
/// it holds still.
/// [completing] closes the ring and pops a little heart — the goodbye.
class AlutaLoader extends StatefulWidget {
  const AlutaLoader({
    super.key,
    required this.style,
    this.size = 56,
    this.completing = false,
  });

  final LoaderStyle style;
  final double size;
  final bool completing;

  @override
  State<AlutaLoader> createState() => _AlutaLoaderState();
}

class _AlutaLoaderState extends State<AlutaLoader>
    with TickerProviderStateMixin {
  late final AnimationController _spin;
  late final AnimationController _pulse;
  late final AnimationController _done = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 420));
  final AlutaMoment _moment = AlutaMood.moment;
  bool _still = false;

  Duration get _spinPeriod => switch (widget.style) {
        LoaderStyle.orbit => const Duration(milliseconds: 1050),
        LoaderStyle.breathe => const Duration(milliseconds: 2300),
        _ => _moment == AlutaMoment.night
            ? const Duration(milliseconds: 1900)
            : const Duration(milliseconds: 1400),
      };

  Duration get _pulsePeriod => switch (widget.style) {
        LoaderStyle.heartbeat => const Duration(milliseconds: 1500),
        LoaderStyle.ripple => const Duration(milliseconds: 1700),
        LoaderStyle.breathe => const Duration(milliseconds: 3400),
        LoaderStyle.orbit => const Duration(milliseconds: 2000),
      };

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(vsync: this, duration: _spinPeriod);
    _pulse = AnimationController(vsync: this, duration: _pulsePeriod);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_still) {
      _spin.stop();
      _pulse.stop();
    } else {
      if (!_spin.isAnimating) _spin.repeat();
      if (!_pulse.isAnimating) _pulse.repeat();
    }
  }

  @override
  void didUpdateWidget(AlutaLoader old) {
    super.didUpdateWidget(old);
    if (widget.completing && !old.completing) _done.forward(from: 0);
  }

  @override
  void dispose() {
    _spin.dispose();
    _pulse.dispose();
    _done.dispose();
    super.dispose();
  }

  /// Logo scale for the current pulse phase.
  double _scale(double t) {
    switch (widget.style) {
      case LoaderStyle.heartbeat:
        // lub (0–.12 up, .12–.22 down) · dub (.22–.30 up, .30–.46 down) · rest
        double bump(double a, double b, double peak) {
          if (t < a || t > b) return 0;
          final x = (t - a) / (b - a);
          return math.sin(x * math.pi) * peak;
        }
        return 1 + bump(0.0, 0.22, 0.05) + bump(0.22, 0.46, 0.032);
      case LoaderStyle.breathe:
        return 1 + 0.035 * (0.5 - 0.5 * math.cos(t * 2 * math.pi));
      case LoaderStyle.ripple:
        return 1 + (t < 0.18 ? math.sin(t / 0.18 * math.pi) * 0.03 : 0);
      case LoaderStyle.orbit:
        return 1 + 0.015 * math.sin(t * 2 * math.pi);
    }
  }

  Color _tint(Color accent) => switch (_moment) {
        AlutaMoment.dawn || AlutaMoment.morning =>
          Color.lerp(accent, const Color(0xFFFFA726), 0.16)!,
        AlutaMoment.night => Color.lerp(accent, const Color(0xFF7E57C2), 0.12)!,
        _ => accent,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = _tint(scheme.primary);
    final s = widget.size;
    final disc = s * 0.74;
    return RepaintBoundary(
      child: SizedBox(
        width: s + 28, // room for ripples / halo
        height: s + 28,
        child: AnimatedBuilder(
          animation: Listenable.merge([_spin, _pulse, _done]),
          builder: (context, _) {
            final p = _still ? 0.0 : _pulse.value;
            final d = Curves.easeOutCubic.transform(_done.value);
            final glow = switch (widget.style) {
              LoaderStyle.breathe => 0.5 + 0.5 * (_scale(p) - 1) / 0.035,
              LoaderStyle.heartbeat => (_scale(p) - 1) / 0.05,
              _ => 0.4,
            };
            return Stack(
              alignment: Alignment.center,
              children: [
                // Halo: the soft theme-colour glow behind the mark, breathing
                // with the beat.
                Container(
                  width: disc + 22,
                  height: disc + 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: accent.withValues(
                            alpha: (isDark ? 0.20 : 0.14) +
                                0.10 * glow.clamp(0.0, 1.0)),
                        blurRadius: 22,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
                CustomPaint(
                  size: Size(s + 28, s + 28),
                  painter: _RingPainter(
                    rot: _still ? 0 : _spin.value,
                    pulse: p,
                    ripple: widget.style == LoaderStyle.ripple && !_still,
                    orbit: widget.style == LoaderStyle.orbit,
                    still: _still,
                    done: d,
                    // The arc rides right on the disc's edge — no gap that
                    // reads as a second ring.
                    ring: disc / 2 + 2.6,
                    disc: disc / 2,
                    color: accent,
                  ),
                ),
                Transform.scale(
                  scale: _scale(p) * (1 - 0.06 * d),
                  child: Container(
                    width: disc,
                    height: disc,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isDark ? const Color(0xFF26222A) : Colors.white,
                      // One soft shadow; on the beat it warms a touch toward
                      // the accent instead of adding another glow layer.
                      boxShadow: [
                        BoxShadow(
                          color: Color.lerp(
                                  Colors.black, accent,
                                  0.35 * glow.clamp(0.0, 1.0))!
                              .withValues(alpha: isDark ? 0.40 : 0.12),
                          blurRadius: 6,
                          offset: const Offset(0, 1.5),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: ClipOval(
                      child: Image.asset(
                        'assets/images/logo.png',
                        width: disc * 0.66,
                        height: disc * 0.66,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.medium,
                        errorBuilder: (_, _, _) => Icon(Icons.favorite_rounded,
                            size: disc * 0.4, color: accent),
                      ),
                    ),
                  ),
                ),
                // Goodbye heart: pops up from the disc and floats off.
                if (d > 0)
                  Transform.translate(
                    offset: Offset(0, -disc * 0.58 - 16 * d),
                    child: Opacity(
                      opacity: (d < 0.6 ? d / 0.6 : (1 - d) / 0.4)
                          .clamp(0.0, 1.0),
                      child: Transform.scale(
                        scale: 0.4 + 0.8 * Curves.elasticOut.transform(d),
                        child: GlossyHeart(size: 20, color: accent),
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

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.rot,
    required this.pulse,
    required this.ripple,
    required this.orbit,
    required this.still,
    required this.done,
    required this.ring,
    required this.disc,
    required this.color,
  });

  final double rot, pulse, done, ring, disc;
  final bool ripple, orbit, still;
  final Color color;

  static const double stroke = 2.6;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = ring - stroke / 2;
    final rect = Rect.fromCircle(center: c, radius: r);

    // Ripple mood: a single faint ring leaving the arc on each beat.
    if (ripple) {
      final t = pulse;
      final rr = r + 12 * Curves.easeOut.transform(t);
      canvas.drawCircle(
        c,
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..color = color.withValues(alpha: 0.22 * (1 - t)),
      );
    }

    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    if (still) {
      canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * 0.3, false,
          arc..color = color);
      return;
    }

    // Comet: a sweep that fades out into its tail; closes to a full ring on
    // done.
    final base = orbit ? 0.55 : 0.62;
    final sweep = base + (1 - base) * done;
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(rot * 2 * math.pi);
    canvas.translate(-c.dx, -c.dy);
    arc.shader = SweepGradient(
      startAngle: 0,
      endAngle: 2 * math.pi * sweep,
      colors: [color.withValues(alpha: done), color],
      tileMode: TileMode.clamp,
    ).createShader(rect);
    canvas.drawArc(rect, 0, 2 * math.pi * sweep, false, arc);
    // The comet's glowing head leading the arc.
    if (done < 0.9) {
      final a = 2 * math.pi * sweep;
      final head = Offset(c.dx + r * math.cos(a), c.dy + r * math.sin(a));
      canvas.drawCircle(head, orbit ? 4.2 : 3.2,
          Paint()..color = color.withValues(alpha: 0.30 * (1 - done)));
      canvas.drawCircle(head, orbit ? 2.4 : 1.9,
          Paint()..color = color.withValues(alpha: 1 - done));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RingPainter o) => true;
}
