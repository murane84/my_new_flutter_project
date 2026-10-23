import 'package:flutter/material.dart';

/// The glossy card that holds a music player's controls (waveform, transport,
/// tools), so they sit contained instead of floating. Same look as the native
/// player's glass — used by the web player, which is its own widget.
class ControlsGlass extends StatelessWidget {
  const ControlsGlass({
    super.key,
    required this.accent,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(10, 14, 10, 14),
  });

  final Color accent;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return CustomPaint(
      painter: _RimPainter(accent: accent, dark: dark),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: dark
                ? [
                    Colors.white.withAlpha(4),
                    Color.alphaBlend(
                        Colors.white.withAlpha(10), accent.withAlpha(16)),
                    Color.alphaBlend(
                        Colors.black.withAlpha(46), accent.withAlpha(22)),
                  ]
                : [
                    Colors.white.withAlpha(30),
                    Color.alphaBlend(accent.withAlpha(10), Colors.white),
                    Color.alphaBlend(accent.withAlpha(24), scheme.surface),
                  ],
            stops: const [0.0, 0.32, 1.0],
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(dark ? 80 : 22),
              blurRadius: 26,
              offset: const Offset(0, 14),
              spreadRadius: -8,
            ),
            BoxShadow(
              color: accent.withAlpha(dark ? 26 : 16),
              blurRadius: 34,
              spreadRadius: -10,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: child,
      ),
    );
  }
}

class _RimPainter extends CustomPainter {
  _RimPainter({required this.accent, required this.dark});
  final Color accent;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(0.5), const Radius.circular(26)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withAlpha(dark ? 60 : 200),
            Colors.white.withAlpha(0),
            Colors.white.withAlpha(0),
            accent.withAlpha(dark ? 50 : 70),
          ],
          stops: const [0.0, 0.3, 0.7, 1.0],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_RimPainter o) => o.accent != accent || o.dark != dark;
}
