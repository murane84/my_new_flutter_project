import 'dart:math' as math;

import 'package:flutter/material.dart';

/// What a panel's wallpaper is about — it follows the page that's open.
enum AmbientMotif {
  /// Harmony: hearts resting in a corner, a warm glow.
  harmony,

  /// Circle · All: a faint record in the corner, notes drifting.
  circle,

  /// Circle · Status: soft story rings, like the status tray's.
  stories,

  /// Circle · Listening: the Listen Together room's corner — record + EQ.
  listening,

  /// Circle · chats: soft speech bubbles and hearts.
  chats,

  /// Glow: soft light — bokeh and sparkles.
  glow,
}

/// The motif for Circle's open section.
AmbientMotif circleMotif(String view) => switch (view) {
      'stories' => AmbientMotif.stories,
      'listening' => AmbientMotif.listening,
      'chats' => AmbientMotif.chats,
      _ => AmbientMotif.circle,
    };

/// A quiet painted wallpaper for the big panels, in the spirit of the
/// Listen Together room — so a short list on a wide screen sits in a
/// room, not on a glaring white sheet. Barely there (accent at a few %
/// alpha), static, never takes a tap; fades over when the page changes.
///
/// [right]: desktop's two columns — [motif] paints the left 5/11
/// (Harmony), [right] the rest (Circle's open section).
class AmbientBackdrop extends StatelessWidget {
  const AmbientBackdrop({super.key, required this.motif, this.right});
  final AmbientMotif motif;
  final AmbientMotif? right;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Phones: quieter still, and the scatter thins out — the big pieces
    // (hearts, record, rings) rest in the corners, so the tiles stand out
    // against a soft tint instead of competing with it.
    final phone = MediaQuery.sizeOf(context).width < 600;
    return IgnorePointer(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 360),
        child: RepaintBoundary(
          key: ValueKey('$motif/$right'),
          child: CustomPaint(
            size: Size.infinite,
            painter: _AmbientPainter(
              motif: motif,
              right: right,
              accent: scheme.primary,
              second: scheme.tertiary,
              // Subtle: just enough to take the glare off a white sheet;
              // dark already rests the eyes, so less there.
              strength: (dark ? 0.55 : 0.8) * (phone ? 0.65 : 1),
              sparse: phone,
            ),
          ),
        ),
      ),
    );
  }
}

class _AmbientPainter extends CustomPainter {
  _AmbientPainter({
    required this.motif,
    required this.right,
    required this.accent,
    required this.second,
    required this.strength,
    this.sparse = false,
  });
  final AmbientMotif motif;
  final AmbientMotif? right;
  final Color accent;
  final Color second;
  final double strength;
  final bool sparse;

  Color _a(Color c, double alpha) =>
      c.withValues(alpha: (alpha * strength).clamp(0.0, 1.0));

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final full = Offset.zero & size;
    canvas.save();
    canvas.clipRect(full);
    if (right == null) {
      _paint(canvas, motif, full);
    } else {
      final split = size.width * 5 / 11; // the Harmony : Circle flex
      _paint(canvas, motif, Rect.fromLTWH(0, 0, split, size.height));
      _paint(canvas, right!,
          Rect.fromLTWH(split, 0, size.width - split, size.height));
    }
    canvas.restore();
  }

  void _paint(Canvas canvas, AmbientMotif m, Rect r) {
    canvas.save();
    canvas.clipRect(r);
    switch (m) {
      case AmbientMotif.harmony:
        _harmony(canvas, r, 11);
      case AmbientMotif.circle:
        _circle(canvas, r, 23, eq: false);
      case AmbientMotif.listening:
        _circle(canvas, r, 31, eq: true);
      case AmbientMotif.stories:
        _stories(canvas, r);
      case AmbientMotif.chats:
        _chats(canvas, r);
      case AmbientMotif.glow:
        _glow(canvas, r);
    }
    canvas.restore();
  }

  // Status: a few big soft story rings (segmented arcs, like the tray's),
  // drifting off the edges, with sparkles.
  void _stories(Canvas canvas, Rect r) {
    _wash(canvas, r, top: true);
    final rnd = math.Random(57);
    final rings = [
      (Offset(r.right - r.width * 0.08, r.bottom - r.height * 0.1), 0.42),
      (Offset(r.left + r.width * 0.1, r.top + r.height * 0.62), 0.22),
      (Offset(r.left + r.width * 0.62, r.top + r.height * 0.3), 0.13),
    ];
    for (final (c, f) in rings) {
      final rad = math.min(r.width, r.height) * f;
      final segs = 3 + rnd.nextInt(4);
      const gap = 0.12;
      final sweep = (2 * math.pi - gap * segs) / segs;
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = math.max(3, rad * 0.07);
      for (var i = 0; i < segs; i++) {
        ring.color = _a(i.isEven ? accent : second, 0.07);
        canvas.drawArc(Rect.fromCircle(center: c, radius: rad),
            -math.pi / 2 + i * (sweep + gap), sweep, false, ring);
      }
      canvas.drawCircle(c, rad * 0.82, Paint()..color = _a(accent, 0.03));
    }
    _scatter(canvas, r, const ['\u2727', '\u2726', '\u22C6', '\u2661'], 61,
        density: 20000);
  }

  // Chats: a couple of soft speech bubbles and hearts drifting.
  void _chats(Canvas canvas, Rect r) {
    _wash(canvas, r, top: false);
    void bubble(Rect b, bool mine, double alpha) {
      final rr = RRect.fromRectAndRadius(b, Radius.circular(b.height * 0.42));
      final tail = Path();
      if (mine) {
        tail
          ..moveTo(b.right - b.height * 0.5, b.bottom - 2)
          ..lineTo(b.right + b.height * 0.12, b.bottom + b.height * 0.22)
          ..lineTo(b.right - b.height * 0.15, b.bottom - b.height * 0.3);
      } else {
        tail
          ..moveTo(b.left + b.height * 0.5, b.bottom - 2)
          ..lineTo(b.left - b.height * 0.12, b.bottom + b.height * 0.22)
          ..lineTo(b.left + b.height * 0.15, b.bottom - b.height * 0.3);
      }
      final paint = Paint()..color = _a(mine ? accent : second, alpha);
      canvas.drawRRect(rr, paint);
      canvas.drawPath(tail, paint);
    }

    final w = r.width, h = r.height;
    bubble(Rect.fromLTWH(r.right - w * 0.46, r.bottom - h * 0.3, w * 0.38,
        h * 0.09), true, 0.05);
    bubble(Rect.fromLTWH(r.right - w * 0.62, r.bottom - h * 0.17, w * 0.3,
        h * 0.075), false, 0.04);
    bubble(Rect.fromLTWH(r.left + w * 0.06, r.top + h * 0.18, w * 0.22,
        h * 0.06), false, 0.035);
    _scatter(canvas, r, const ['\u2661', '\u2665', '\u266A', '\u2727'], 29,
        density: 22000);
  }

  void _wash(Canvas canvas, Rect r, {required bool top}) {
    canvas.drawRect(
      r,
      Paint()
        ..shader = LinearGradient(
          begin: top ? Alignment.topCenter : Alignment.bottomCenter,
          end: top ? Alignment.bottomCenter : Alignment.topCenter,
          colors: [_a(accent, 0.05), _a(accent, 0.0)],
        ).createShader(r),
    );
  }

  // ── pieces ────────────────────────────────────────────────────────────────

  void _blob(Canvas canvas, Offset c, double r, Color color, double alpha) {
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(colors: [
          _a(color, alpha),
          _a(color, 0),
        ]).createShader(Rect.fromCircle(center: c, radius: r)),
    );
  }

  void _scatter(Canvas canvas, Rect r, List<String> glyphs, int seed,
      {double density = 15000, double min = 13, double max = 20}) {
    final rnd = math.Random(seed);
    final count =
        ((r.width * r.height) / (density * (sparse ? 2.2 : 1))).clamp(3, 30).round();
    for (var i = 0; i < count; i++) {
      final tp = TextPainter(
        text: TextSpan(
          text: glyphs[rnd.nextInt(glyphs.length)],
          style: TextStyle(
            fontSize: min + rnd.nextDouble() * max,
            color: _a(accent, 0.035 + rnd.nextDouble() * 0.045),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      canvas.save();
      canvas.translate(r.left + rnd.nextDouble() * r.width,
          r.top + rnd.nextDouble() * r.height);
      canvas.rotate((rnd.nextDouble() - 0.5) * 0.8);
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
    }
  }

  /// A heart outline, centred on [c], [s] wide.
  Path _heart(Offset c, double s) {
    final w = s, h = s * 0.9;
    final x = c.dx - w / 2, y = c.dy - h / 2;
    return Path()
      ..moveTo(x + w / 2, y + h * 0.28)
      ..cubicTo(x + w * 0.1, y - h * 0.12, x - w * 0.22, y + h * 0.48,
          x + w / 2, y + h)
      ..cubicTo(x + w * 1.22, y + h * 0.48, x + w * 0.9, y - h * 0.12,
          x + w / 2, y + h * 0.28)
      ..close();
  }

  // Harmony: a warm glow up top, two big soft hearts resting in the lower
  // corner (one a little behind the other — the two of you), hearts drifting.
  void _harmony(Canvas canvas, Rect r, int seed) {
    canvas.drawRect(
      r,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_a(accent, 0.05), _a(accent, 0.0), _a(accent, 0.045)],
          stops: const [0, 0.5, 1],
        ).createShader(r),
    );
    _blob(canvas, Offset(r.left + r.width * 0.15, r.top + r.height * 0.12),
        r.width * 0.5, accent, 0.06);
    _blob(canvas, Offset(r.right - r.width * 0.1, r.top + r.height * 0.55),
        r.width * 0.4, second, 0.045);

    final s = math.min(r.width * 0.55, r.height * 0.42);
    final c1 = Offset(r.left + s * 0.42, r.bottom - s * 0.22);
    final c2 = c1 + Offset(s * 0.42, s * 0.12);
    canvas.drawPath(_heart(c2, s * 0.8), Paint()..color = _a(second, 0.045));
    canvas.drawPath(_heart(c1, s), Paint()..color = _a(accent, 0.05));
    canvas.drawPath(
      _heart(c1, s * 0.78),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = _a(accent, 0.07),
    );
    _scatter(canvas, r, const ['♡', '♥', '✧', '♪'], seed);
  }

  // Circle: a faint record peeking from the bottom-right corner, EQ bars
  // along the bottom, notes drifting up (the Listen Together room's corner).
  void _circle(Canvas canvas, Rect r, int seed, {required bool eq}) {
    canvas.drawRect(
      r,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [_a(accent, 0.06), _a(accent, 0.0)],
        ).createShader(r),
    );
    _blob(canvas, Offset(r.left + r.width * 0.75, r.top + r.height * 0.1),
        r.width * 0.45, second, 0.04);

    final c = Offset(r.right - r.width * 0.06, r.bottom - r.height * 0.02);
    final rad = math.min(r.width * 0.5, r.height * 0.42);
    canvas.drawCircle(c, rad, Paint()..color = _a(accent, 0.045));
    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = _a(accent, 0.06);
    for (var g = rad * 0.42; g < rad; g += 7) {
      canvas.drawCircle(c, g, groove);
    }
    canvas.drawCircle(c, rad * 0.33, Paint()..color = _a(accent, 0.07));
    canvas.drawCircle(c, rad * 0.05, Paint()..color = _a(accent, 0.12));

    final rnd = math.Random(seed * 7);
    const bw = 5.0, gap = 5.0;
    final bars = eq ? ((r.width * 0.5) / (bw + gap)).floor() : 0;
    for (var i = 0; i < bars; i++) {
      final bh = 8 + rnd.nextDouble() * 40;
      final fade = 1 - i / bars;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(r.left + 16 + i * (bw + gap), r.bottom - 10 - bh,
                bw, bh),
            const Radius.circular(3)),
        Paint()..color = _a(accent, 0.08 * fade + 0.015),
      );
    }
    _scatter(canvas, r, const ['♪', '♫', '♬', '♩'], seed);
  }

  // Glow: soft light — a few bokeh discs and sparkles, warmest at the top.
  void _glow(Canvas canvas, Rect r) {
    canvas.drawRect(
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -1.1),
          radius: 1.2,
          colors: [_a(accent, 0.08), _a(accent, 0.0)],
        ).createShader(r),
    );
    final rnd = math.Random(41);
    for (var i = 0; i < 9; i++) {
      final c = Offset(r.left + rnd.nextDouble() * r.width,
          r.top + rnd.nextDouble() * r.height);
      _blob(canvas, c, 40 + rnd.nextDouble() * 110, i.isEven ? accent : second,
          0.04 + rnd.nextDouble() * 0.03);
    }
    _scatter(canvas, r, const ['✧', '✦', '♡', '⋆'], 77,
        density: 18000);
  }

  @override
  bool shouldRepaint(_AmbientPainter old) =>
      old.motif != motif ||
      old.right != right ||
      old.accent != accent ||
      old.second != second ||
      old.strength != strength ||
      old.sparse != sparse;
}
