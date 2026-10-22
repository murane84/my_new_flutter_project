import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The splash's living field: glossy 3D hearts that turn as they rise, lit
/// music notes, twinkling sparkles and soft bokeh in the distance — dozens of
/// them, at different depths (near ones bigger, brighter and faster; far
/// ones small, dim and slow), drifting up around the logo like music leaving
/// a speaker — faint and slow, a welcome backdrop behind the logo rather
/// than a show of its own. One painter, one ticker, its own layer.
class SplashParticles extends StatefulWidget {
  const SplashParticles({
    super.key,
    required this.color,
    this.reveal,
    this.count = 56,
  });

  /// Brand colour the hearts and notes are lit in.
  final Color color;

  /// Optional entrance (0 → 1) that fades the whole field in.
  final Animation<double>? reveal;
  final int count;

  @override
  State<SplashParticles> createState() => _SplashParticlesState();
}

enum _Kind { heart, note, sparkle, bokeh }

class _P {
  _P(this.kind, this.x, this.z, this.speed, this.phase, this.sway, this.spin,
      this.tint);
  final _Kind kind;
  final double x; // 0..1 across
  final double z; // depth 0.25 (far) .. 1 (near)
  final double speed; // screen-heights per loop
  final double phase; // 0..1
  final double sway; // sideways travel (fraction of width)
  final double spin; // 3D turn speed
  final Color tint;
}

class _SplashParticlesState extends State<SplashParticles>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
      vsync: this, duration: const Duration(seconds: 44))
    ..repeat();
  late List<_P> _ps;

  @override
  void initState() {
    super.initState();
    _build();
  }

  @override
  void didUpdateWidget(SplashParticles old) {
    super.didUpdateWidget(old);
    if (old.color != widget.color || old.count != widget.count) _build();
  }

  void _build() {
    final r = math.Random(7); // stable layout every launch
    final c = widget.color;
    final pink = Color.lerp(c, const Color(0xFFFF7AB6), 0.55)!;
    const gold = Color(0xFFFFC857);
    const white = Color(0xFFFFF4F6);
    _ps = List.generate(widget.count, (i) {
      final k = i % 7 == 0
          ? _Kind.bokeh
          : (i % 3 == 0
              ? _Kind.note
              : (i % 5 == 0 ? _Kind.sparkle : _Kind.heart));
      final z = k == _Kind.bokeh
          ? 0.25 + r.nextDouble() * 0.25
          : 0.3 + r.nextDouble() * 0.7;
      final tint = switch (k) {
        _Kind.heart => r.nextDouble() < 0.6 ? c : pink,
        _Kind.note => r.nextDouble() < 0.5 ? white : pink,
        _Kind.sparkle => r.nextDouble() < 0.7 ? white : gold,
        _Kind.bokeh => r.nextDouble() < 0.5 ? c : pink,
      };
      return _P(
        k,
        r.nextDouble(),
        z,
        (0.55 + r.nextDouble() * 0.6) * (0.6 + 0.6 * z),
        r.nextDouble(),
        0.015 + r.nextDouble() * 0.04,
        0.6 + r.nextDouble() * 1.4,
        tint,
      );
    })
      // Paint far → near so nearer particles sit on top.
      ..sort((a, b) => a.z.compareTo(b.z));
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still) _t.stop();
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: Listenable.merge([_t, ?widget.reveal]),
          builder: (_, _) => CustomPaint(
            painter: _FieldPainter(
              _ps,
              still ? 0.35 : _t.value,
              (widget.reveal?.value ?? 1).clamp(0.0, 1.0),
            ),
            size: Size.infinite,
          ),
        ),
      ),
    );
  }
}

class _FieldPainter extends CustomPainter {
  _FieldPainter(this.ps, this.t, this.reveal);
  final List<_P> ps;
  final double t;
  final double reveal;

  static Path _heart(double w, double h) => Path()
    ..moveTo(0, -0.16 * h)
    ..cubicTo(-0.34 * w, -0.55 * h, -0.78 * w, -0.14 * h, 0, 0.45 * h)
    ..cubicTo(0.78 * w, -0.14 * h, 0.34 * w, -0.55 * h, 0, -0.16 * h)
    ..close();

  static Path _star(double r) {
    final p = Path();
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4 - math.pi / 2;
      final rr = i.isEven ? r : r * 0.28;
      final o = Offset(math.cos(a) * rr, math.sin(a) * rr);
      i == 0 ? p.moveTo(o.dx, o.dy) : p.lineTo(o.dx, o.dy);
    }
    return p..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (reveal <= 0) return;
    final w = size.width, h = size.height;
    final unit = math.min(w, h);
    for (final p in ps) {
      // Rise from below the bottom edge to above the top, looping.
      final travel = (t * p.speed * 3 + p.phase) % 1.0;
      final y = h * (1.08 - travel * 1.2);
      final ang = (t * 2 * math.pi * p.spin) + p.phase * 6.283;
      final x = w * (p.x + math.sin(ang * 0.7) * p.sway);
      if (x < -60 || x > w + 60) continue;
      // Fade in near the bottom, out near the top; far ones dimmer.
      final edge = (math.min(travel / 0.12, (1 - travel) / 0.18)).clamp(0.0, 1.0);
      // Keep a calm pocket around the logo + wordmark so the field frames
      // them instead of crossing over the words.
      final dx = (x - w / 2) / (unit * 0.38), dy = (y - h * 0.49) / (unit * 0.62);
      final d = math.sqrt(dx * dx + dy * dy);
      final clear = d >= 1 ? 1.0 : 0.05 + 0.95 * d * d * d;
      final alpha =
          (edge * (0.08 + 0.32 * p.z) * reveal * clear).clamp(0.0, 1.0);
      if (alpha <= 0.01) continue;
      final s = unit * (0.010 + 0.024 * p.z); // base radius
      canvas.save();
      canvas.translate(x, y);
      switch (p.kind) {
        case _Kind.bokeh:
          final rr = s * 3.2;
          canvas.drawCircle(
            Offset.zero,
            rr,
            Paint()
              ..shader = RadialGradient(colors: [
                p.tint.withValues(alpha: 0.28 * alpha),
                p.tint.withValues(alpha: 0.0),
              ]).createShader(Rect.fromCircle(center: Offset.zero, radius: rr)),
          );
        case _Kind.heart:
          // Turns in 3D around its vertical axis: the width breathes with
          // cos(), and the highlight slides to the lit side.
          final turn = math.cos(ang);
          final sx = 0.35 + 0.65 * turn.abs();
          canvas.rotate(math.sin(ang * 0.5) * 0.25);
          canvas.scale(sx, 1);
          final hw = s * 2.1, hh = s * 2.0;
          final path = _heart(hw, hh);
          final rect = Rect.fromCenter(
              center: Offset.zero, width: hw * 1.6, height: hh * 1.1);
          // Soft glow
          canvas.drawCircle(
            Offset.zero,
            hw * 1.4,
            Paint()
              ..shader = RadialGradient(colors: [
                p.tint.withValues(alpha: 0.30 * alpha),
                p.tint.withValues(alpha: 0.0),
              ]).createShader(
                  Rect.fromCircle(center: Offset.zero, radius: hw * 1.4)),
          );
          final light = turn >= 0 ? -0.4 : 0.4;
          canvas.drawPath(
            path,
            Paint()
              ..shader = RadialGradient(
                center: Alignment(light, -0.55),
                radius: 1.1,
                colors: [
                  Color.lerp(p.tint, Colors.white, 0.7)!.withValues(alpha: alpha),
                  p.tint.withValues(alpha: alpha),
                  Color.lerp(p.tint, Colors.black, 0.55)!
                      .withValues(alpha: alpha),
                ],
                stops: const [0.0, 0.5, 1.0],
              ).createShader(rect),
          );
          // Specular dot on the lit lobe.
          canvas.drawCircle(
            Offset(hw * (turn >= 0 ? -0.34 : 0.34), -hh * 0.2),
            hw * 0.12,
            Paint()..color = Colors.white.withValues(alpha: 0.6 * alpha),
          );
        case _Kind.note:
          canvas.rotate(math.sin(ang) * 0.3);
          final r = s * 0.5;
          final paint = Paint()
            ..shader = LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: alpha),
                p.tint.withValues(alpha: alpha),
              ],
            ).createShader(Rect.fromCircle(center: Offset.zero, radius: r * 4));
          // Two beamed notes (♫): heads, stems, beam.
          final h1 = Offset(-r * 1.3, r * 1.6), h2 = Offset(r * 1.3, r * 1.2);
          for (final hd in [h1, h2]) {
            canvas.save();
            canvas.translate(hd.dx, hd.dy);
            canvas.rotate(-0.45);
            canvas.drawOval(
                Rect.fromCenter(
                    center: Offset.zero, width: r * 2.0, height: r * 1.4),
                paint);
            canvas.restore();
          }
          final stem = r * 0.32;
          canvas.drawRect(
              Rect.fromLTWH(h1.dx + r * 0.8, h1.dy - r * 4, stem, r * 4), paint);
          canvas.drawRect(
              Rect.fromLTWH(h2.dx + r * 0.8, h2.dy - r * 4, stem, r * 4), paint);
          canvas.drawPath(
            Path()
              ..moveTo(h1.dx + r * 0.8, h1.dy - r * 4)
              ..lineTo(h2.dx + r * 0.8 + stem, h2.dy - r * 4)
              ..lineTo(h2.dx + r * 0.8 + stem, h2.dy - r * 3.1)
              ..lineTo(h1.dx + r * 0.8, h1.dy - r * 3.1)
              ..close(),
            paint,
          );
        case _Kind.sparkle:
          final tw = 0.6 + 0.4 * math.sin(ang * 1.4);
          canvas.rotate(ang * 0.15);
          canvas.scale(tw, tw);
          final rr = s * 1.6;
          canvas.drawPath(
            _star(rr),
            Paint()
              ..shader = RadialGradient(colors: [
                Colors.white.withValues(alpha: alpha),
                p.tint.withValues(alpha: 0.9 * alpha),
                p.tint.withValues(alpha: 0.0),
              ], stops: const [0.0, 0.45, 1.0])
                  .createShader(Rect.fromCircle(center: Offset.zero, radius: rr)),
          );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_FieldPainter o) => o.t != t || o.reveal != reveal;
}


/// The first heartbeat after the app icon is tapped: a glowing shock-ring
/// leaves the logo and a ring of glossy hearts and sparks bursts outward,
/// slowing and fading as the field takes over. [progress] runs 0 → 1.
class SplashBurst extends StatelessWidget {
  const SplashBurst({super.key, required this.progress, required this.color});
  final Animation<double> progress;
  final Color color;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: progress,
            builder: (_, _) => CustomPaint(
              painter: _BurstPainter(progress.value, color),
              size: Size.infinite,
            ),
          ),
        ),
      );
}

class _BurstPainter extends CustomPainter {
  _BurstPainter(this.b, this.color);
  final double b;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (b <= 0 || b >= 1) return;
    final c = size.center(Offset.zero);
    final unit = math.min(size.width, size.height);
    final out = Curves.easeOutCubic.transform(b);
    final fade = math.pow(1 - b, 1.3).toDouble();
    // Shock-rings (two, a beat apart).
    for (final lag in [0.0, 0.16]) {
      final k = ((b - lag) / (1 - lag)).clamp(0.0, 1.0);
      if (k <= 0) continue;
      final rr = unit * (0.16 + 0.5 * Curves.easeOutCubic.transform(k));
      canvas.drawCircle(
        c,
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5 * (1 - k) + 0.5
          ..color = color.withValues(alpha: 0.7 * (1 - k))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
    }
    final pink = Color.lerp(color, const Color(0xFFFF7AB6), 0.55)!;
    const n = 18;
    for (var i = 0; i < n; i++) {
      final a = i / n * 2 * math.pi + (i.isEven ? 0 : 0.17);
      final far = unit * (i.isEven ? 0.44 : 0.33);
      final pos = c + Offset(math.cos(a), math.sin(a)) * (unit * 0.1 + far * out);
      final s = unit * (i.isEven ? 0.034 : 0.02) * (1 - 0.4 * b);
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      if (i % 3 == 2) {
        canvas.rotate(b * 3);
        canvas.drawPath(
          _FieldPainter._star(s * 1.4),
          Paint()
            ..color = Colors.white.withValues(alpha: 0.95 * fade),
        );
      } else {
        // A glossy heart that turns as it flies.
        final turn = math.cos(b * 7 + i);
        canvas.scale(0.4 + 0.6 * turn.abs(), 1);
        final tint = i.isEven ? color : pink;
        final path = _FieldPainter._heart(s * 2.1, s * 2.0);
        final rect = Rect.fromCenter(
            center: Offset.zero, width: s * 3.4, height: s * 2.2);
        canvas.drawPath(
          path,
          Paint()
            ..shader = RadialGradient(
              center: Alignment(turn >= 0 ? -0.4 : 0.4, -0.55),
              radius: 1.1,
              colors: [
                Color.lerp(tint, Colors.white, 0.7)!.withValues(alpha: fade),
                tint.withValues(alpha: fade),
                Color.lerp(tint, Colors.black, 0.55)!.withValues(alpha: fade),
              ],
              stops: const [0.0, 0.5, 1.0],
            ).createShader(rect),
        );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_BurstPainter o) => o.b != b || o.color != color;
}
