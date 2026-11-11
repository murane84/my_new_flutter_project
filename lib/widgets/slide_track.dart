import 'package:flutter/material.dart';

import '../utils/readable.dart' show readableOn;
import '../utils/motion.dart';
import '../utils/depth.dart';

/// Aluta's ONE "pick one of these" control: a sunken track with a raised,
/// lit key that slides (with a little spring) to the chosen segment.
/// Used by Circle's All · Status · Listening · Circle, Glow's categories and
/// search's kinds — so every such row looks and moves exactly alike.
///
/// The top-level Harmony · Circle · Glow pills stay separate floating pills
/// (they move between whole areas); this track is always the level below.
class SlideTrack extends StatelessWidget {
  const SlideTrack({
    super.key,
    required this.count,
    required this.selected,
    required this.segment,
    this.fold = false,
    this.height = 38,
  });

  final int count;
  final int selected;

  /// Builds segment [i]. [labelled]: there's room for its label (with
  /// [fold], only the chosen one gets it on a narrow track). [onKey]: the
  /// readable colour on the lit key.
  final Widget Function(BuildContext context, int i, bool selected,
      bool labelled, Color onKey) segment;

  /// Narrow track → the chosen segment opens to icon + label, the others
  /// fold to icons; all still fit, no sideways scroll.
  final bool fold;
  final double height;

  /// Below this a segment can't hold icon + label.
  static const double labelWidth = 74;

  /// The text / icon colour on the lit key.
  static Color onKey(ColorScheme scheme) => readableOn(scheme.primary);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final thumbTop = Color.lerp(scheme.primary, Colors.white, 0.22)!;
    final thumbBot = Color.lerp(scheme.primary, Colors.black, 0.22)!;
    final on = onKey(scheme);
    final sel = selected.clamp(0, count - 1);
    return LayoutBuilder(builder: (context, cons) {
      final w = cons.maxWidth;
      final even = w / count;
      final folded = fold && even < labelWidth;
      // Segment widths: even, or (folded) the chosen one wider.
      final weights = [
        for (var i = 0; i < count; i++) folded ? (i == sel ? 7.0 : 3.0) : 1.0
      ];
      final total = weights.fold<double>(0, (a, b) => a + b);
      final widths = [for (final f in weights) w * f / total];
      var left = 0.0;
      for (var i = 0; i < sel; i++) {
        left += widths[i];
      }
      const dur = Motion.emphasized;
      return SizedBox(
        height: height,
        child: DecoratedBox(
          // The sunken track: darker at the top (an inset shadow).
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(height / 2),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: isDark
                  ? [
                      Color.lerp(scheme.surface, Colors.black, 0.45)!,
                      scheme.surfaceContainerHigh,
                    ]
                  : [
                      Color.lerp(
                          scheme.surfaceContainerHighest, Colors.black, 0.10)!,
                      scheme.surfaceContainerHighest,
                    ],
            ),
            border:
                Border.all(color: scheme.outlineVariant.withValues(alpha: 0.45)),
          ),
          child: Stack(children: [
            // The raised, lit key — slides (with a little spring).
            AnimatedPositioned(
              duration: dur,
              curve: Curves.easeOutBack,
              left: left + 3,
              top: 3,
              bottom: 3,
              width: widths[sel] - 6,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(height / 2 - 3),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [thumbTop, scheme.primary, thumbBot],
                    stops: const [0.0, 0.55, 1.0],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.45),
                      blurRadius: Depth.sm,
                      offset: const Offset(0, 3),
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.30),
                      blurRadius: Depth.xs,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                // A glassy highlight along its top edge.
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    height: 1.2,
                    margin: const EdgeInsets.symmetric(horizontal: 10),
                    color: Colors.white.withValues(alpha: 0.35),
                  ),
                ),
              ),
            ),
            Row(children: [
              for (var i = 0; i < count; i++)
                AnimatedContainer(
                  duration: dur,
                  curve: Curves.easeOutCubic,
                  width: widths[i],
                  height: height,
                  child: segment(context, i, i == sel,
                      folded ? i == sel : even >= labelWidth, on),
                ),
            ]),
          ]),
        ),
      );
    });
  }
}

/// The standard inside of a [SlideTrack] segment: icon (+ label), tap.
class SlideTrackSegment extends StatelessWidget {
  const SlideTrackSegment({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.labelled,
    required this.onKey,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool labelled;
  final Color onKey;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? onKey : scheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip ?? (labelled ? '' : label),
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedScale(
                  duration: Motion.standard,
                  curve: Curves.easeOutBack,
                  scale: selected ? 1.12 : 1,
                  child: Icon(icon, size: 15, color: fg),
                ),
                if (labelled) ...[
                  const SizedBox(width: 5),
                  Flexible(
                    child: AnimatedDefaultTextStyle(
                      duration: Motion.quick,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight:
                              selected ? FontWeight.w800 : FontWeight.w600,
                          color: fg),
                      child: Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.fade,
                          softWrap: false),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
