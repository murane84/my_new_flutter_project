import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A dense scatter of tiny hearts + music notes + cherry blossoms + sparkle-
/// hearts tiled across an area, drawn in one faint colour so it reads as
/// barely-there romantic texture. Shared by Our Space and the chat wallpaper.
class RomanticPatternPainter extends CustomPainter {
  final Color color;
  RomanticPatternPainter({required this.color});

  // Deterministic layout (fixed seed) so the confetti doesn't reshuffle every
  // repaint — the pattern stays put as the page scrolls or rebuilds.
  static const int _seed = 0xA1A;

  void _heart(Canvas c, Offset o, double s, double rot, Paint p) {
    c.save();
    c.translate(o.dx, o.dy);
    c.rotate(rot);
    c.scale(s / 16.0);
    final path = Path()
      ..moveTo(0, 4)
      ..cubicTo(-2, -1, -8, -1, -8, -5)
      ..cubicTo(-8, -9, -3, -9, 0, -4.5)
      ..cubicTo(3, -9, 8, -9, 8, -5)
      ..cubicTo(8, -1, 2, -1, 0, 4)
      ..close();
    c.drawPath(path, p);
    c.restore();
  }

  void _note(Canvas c, Offset o, double s, double rot, Paint p, Paint stroke) {
    c.save();
    c.translate(o.dx, o.dy);
    c.rotate(rot);
    c.scale(s / 16.0);
    c.drawOval(
        Rect.fromCenter(center: const Offset(-3, 5), width: 6, height: 4.4), p);
    final stem = Path()
      ..moveTo(0, 5)
      ..lineTo(0, -7);
    c.drawPath(stem, stroke);
    final flag = Path()
      ..moveTo(0, -7)
      ..quadraticBezierTo(5, -5.5, 4, -1);
    c.drawPath(flag, stroke);
    c.restore();
  }

  void _blossom(Canvas c, Offset o, double s, double rot, Paint p, Paint core) {
    c.save();
    c.translate(o.dx, o.dy);
    c.rotate(rot);
    c.scale(s / 16.0);
    final petal = Path()
      ..moveTo(0, -3)
      ..cubicTo(3.4, -3, 4.6, -6.5, 3.2, -8.6)
      ..cubicTo(2.2, -10, 0.9, -9.6, 0, -8.2)
      ..cubicTo(-0.9, -9.6, -2.2, -10, -3.2, -8.6)
      ..cubicTo(-4.6, -6.5, -3.4, -3, 0, -3)
      ..close();
    for (int i = 0; i < 5; i++) {
      c.save();
      c.rotate(i * 2 * math.pi / 5);
      c.drawPath(petal, p);
      c.restore();
    }
    c.drawCircle(Offset.zero, 1.7, core);
    c.restore();
  }

  void _sparkHeart(Canvas c, Offset o, double s, double rot, Paint p) {
    _heart(c, o, s, rot, p);
    c.save();
    c.translate(o.dx, o.dy);
    c.rotate(rot);
    c.scale(s / 16.0);
    final spark = Path()
      ..moveTo(7, -7)
      ..lineTo(8, -9.4)
      ..lineTo(9, -7)
      ..lineTo(11.4, -6)
      ..lineTo(9, -5)
      ..lineTo(8, -2.6)
      ..lineTo(7, -5)
      ..lineTo(4.6, -6)
      ..close();
    c.drawPath(spark, p);
    c.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final rnd = math.Random(_seed);
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final core = Paint()
      ..color = color.withValues(alpha: color.a * 0.55)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    const cell = 40.0;
    final cols = (size.width / cell).ceil() + 1;
    final rows = (size.height / cell).ceil() + 1;
    for (int gy = 0; gy < rows; gy++) {
      for (int gx = 0; gx < cols; gx++) {
        final jx = (rnd.nextDouble() - 0.5) * cell * 0.9;
        final jy = (rnd.nextDouble() - 0.5) * cell * 0.9;
        final o = Offset(gx * cell + jx, gy * cell + jy);
        final s = 9.0 + rnd.nextDouble() * 6.0;
        final rot = (rnd.nextDouble() - 0.5) * 0.9;
        final pick = rnd.nextInt(10);
        if (pick < 4) {
          _heart(canvas, o, s, rot, fill);
        } else if (pick < 6) {
          _note(canvas, o, s, rot, fill, stroke);
        } else if (pick < 8) {
          _blossom(canvas, o, s * 1.05, rot, fill, core);
        } else {
          _sparkHeart(canvas, o, s, rot, fill);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant RomanticPatternPainter old) =>
      old.color != color;
}
