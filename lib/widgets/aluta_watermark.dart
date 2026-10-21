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
    this.scroll,
  });

  /// Optional: the chat list's scroll position. The big centre mark drifts
  /// gently against it (parallax) while the small lattice stays put.
  final ScrollController? scroll;

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
    final small = (isDark ? 0.040 : 0.050) * (0.55 + s * 0.9);
    // The hero is huge, so it can carry a little more ink and still whisper.
    final big = (isDark ? 0.050 : 0.065) * (0.55 + s * 0.9);
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
          // Denser, smaller lattice: more marks, each more discreet.
          const cell = 68.0; // lattice spacing
          const size = 20.0; // small mark
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
          // Screen-aware hero (like a brand watermark on a sign-in page):
          // ~85% of the shorter side, so it reads as one big emblem behind
          // the conversation on a phone and a wide desktop alike.
          final hero =
              (math.min(c.maxWidth, c.maxHeight) * 0.85).clamp(200.0, 900.0);
          return ClipRect(
            child: Stack(
              children: [
                // The lattice never moves → its own layer, painted once.
                Positioned.fill(
                  child: RepaintBoundary(child: Stack(children: marks)),
                ),
                Center(
                  child: scroll == null
                      ? logo(hero, big)
                      : AnimatedBuilder(
                          animation: scroll!,
                          builder: (_, child) {
                            final px = scroll!.hasClients
                                ? scroll!.position.pixels
                                : 0.0;
                            // reverse list: scrolling up = larger pixels →
                            // mark sinks a little; capped at ±40px.
                            final dy = (px * 0.06).clamp(0.0, 40.0);
                            return Transform.translate(
                                offset: Offset(0, dy), child: child);
                          },
                          child: logo(hero, big),
                        ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }
}
