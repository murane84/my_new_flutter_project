import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The "Watermark" chat wallpaper: the Aluta mark, tinted with the user's
/// theme colour and whispered across the chat in a staggered, slightly tilted
/// lattice — plus one larger, even fainter mark in the middle. It reads as
/// texture, never as content: every mark is drawn at a few percent opacity,
/// in ONE flat tint (no logo reds/whites), so bubbles stay the loudest thing.
class AlutaWatermarkWallpaper extends StatelessWidget {
  const AlutaWatermarkWallpaper({
    super.key,
    required this.tint,
    required this.isDark,
    this.strength = 0.6,
  });

  /// The theme colour the marks take on.
  final Color tint;
  final bool isDark;

  /// 0..1 — shares the Appearance "pattern strength" slider with the motif.
  final double strength;

  static const _asset = 'assets/images/logo.png';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = strength.clamp(0.0, 1.0);
    // Very low alphas on purpose — this is a texture.
    final small = (isDark ? 0.045 : 0.055) * (0.55 + s * 0.9);
    final big = (isDark ? 0.030 : 0.035) * (0.55 + s * 0.9);
    final mark = isDark ? Color.lerp(tint, Colors.white, 0.35)! : tint;

    Widget logo(double size, double alpha) => ColorFiltered(
          colorFilter: ColorFilter.mode(
              mark.withValues(alpha: alpha), BlendMode.srcIn),
          child: Image.asset(_asset,
              width: size,
              height: size,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => SizedBox(width: size, height: size)),
        );

    return RepaintBoundary(
      child: DecoratedBox(
        // A barely-there wash of the theme colour so the page feels "theirs".
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.alphaBlend(
                  tint.withValues(alpha: isDark ? 0.07 : 0.05), scheme.surface),
              scheme.surface,
              Color.alphaBlend(
                  tint.withValues(alpha: isDark ? 0.05 : 0.035), scheme.surface),
            ],
          ),
        ),
        child: LayoutBuilder(builder: (ctx, c) {
          const cell = 92.0; // lattice spacing
          const size = 26.0; // small mark
          final cols = (c.maxWidth / cell).ceil() + 1;
          final rows = (c.maxHeight / cell).ceil() + 1;
          final marks = <Widget>[];
          for (var r = 0; r < rows; r++) {
            for (var col = 0; col < cols; col++) {
              // Brick offset every other row → no rigid grid lines.
              final x = col * cell + (r.isOdd ? cell / 2 : 0) - cell / 4;
              final y = r * cell - cell / 4;
              marks.add(Positioned(
                left: x,
                top: y,
                child: Transform.rotate(
                  angle: -12 * math.pi / 180,
                  child: logo(size, small),
                ),
              ));
            }
          }
          final hero = math.min(c.maxWidth, c.maxHeight) * 0.42;
          return ClipRect(
            child: Stack(
              children: [
                ...marks,
                Center(child: logo(hero.clamp(120.0, 320.0), big)),
              ],
            ),
          );
        }),
      ),
    );
  }
}
