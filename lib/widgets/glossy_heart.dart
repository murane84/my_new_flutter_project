import 'package:flutter/material.dart';

/// A small glossy 3D heart — the same lit, sculpted look as the secret heart
/// message, scaled for tiny sizes (blurs and offsets follow the size). Used by
/// the loader's goodbye heart.
class GlossyHeart extends StatelessWidget {
  const GlossyHeart({super.key, required this.size, required this.color});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(size, size * 0.92),
        painter: _GlossyHeartPainter(color),
      );
}

class _GlossyHeartPainter extends CustomPainter {
  _GlossyHeartPainter(this.accent);
  final Color accent;

  static Path _heart(Size s) {
    final w = s.width, h = s.height;
    return Path()
      ..moveTo(0.5 * w, 0.34 * h)
      ..cubicTo(0.16 * w, -0.05 * h, -0.28 * w, 0.36 * h, 0.5 * w, 0.95 * h)
      ..cubicTo(1.28 * w, 0.36 * h, 0.84 * w, -0.05 * h, 0.5 * w, 0.34 * h)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = _heart(size);
    final rect = Offset.zero & size;
    final w = size.width, h = size.height;
    final k = w / 40; // blur/offset scale (tuned at 40px)

    // Soft coloured glow + a small grounding shadow.
    canvas.drawPath(
        path,
        Paint()
          ..color = accent.withValues(alpha: 0.40)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 5 * k));
    canvas.drawPath(
        path.shift(Offset(0, 2 * k)),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.22)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2.5 * k));

    // Volume, lit from the upper-left.
    canvas.drawPath(
        path,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.35, -0.62),
            radius: 1.25,
            colors: [
              Color.lerp(accent, Colors.white, 0.72)!,
              Color.lerp(accent, Colors.white, 0.28)!,
              accent,
              Color.lerp(accent, Colors.black, 0.4)!,
              Color.lerp(accent, Colors.black, 0.66)!,
            ],
            stops: const [0.0, 0.22, 0.52, 0.8, 1.0],
          ).createShader(rect));

    canvas.save();
    canvas.clipPath(path);
    // Mass pooled at the tip.
    final tip = Offset(w * 0.5, h * 0.82);
    canvas.drawCircle(
        tip,
        w * 0.6,
        Paint()
          ..shader = RadialGradient(colors: [
            Colors.black.withValues(alpha: 0.38),
            Colors.black.withValues(alpha: 0.0),
          ]).createShader(Rect.fromCircle(center: tip, radius: w * 0.6)));
    // Sheen on the left lobe, a softer catch on the right, one sparkle.
    final hl = Offset(w * 0.33, h * 0.22);
    canvas.drawCircle(
        hl,
        w * 0.30,
        Paint()
          ..shader = RadialGradient(colors: [
            Colors.white.withValues(alpha: 0.6),
            Colors.white.withValues(alpha: 0.0),
          ]).createShader(Rect.fromCircle(center: hl, radius: w * 0.30)));
    final hl2 = Offset(w * 0.66, h * 0.26);
    canvas.drawCircle(
        hl2,
        w * 0.16,
        Paint()
          ..shader = RadialGradient(colors: [
            Colors.white.withValues(alpha: 0.30),
            Colors.white.withValues(alpha: 0.0),
          ]).createShader(Rect.fromCircle(center: hl2, radius: w * 0.16)));
    canvas.drawCircle(Offset(w * 0.3, h * 0.19), w * 0.055,
        Paint()..color = Colors.white.withValues(alpha: 0.85));
    canvas.restore();

    // Rim light.
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = (0.8 * k).clamp(0.5, 1.4)
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withValues(alpha: 0.55),
              Colors.white.withValues(alpha: 0.05),
            ],
          ).createShader(rect));
  }

  @override
  bool shouldRepaint(_GlossyHeartPainter old) => old.accent != accent;
}
