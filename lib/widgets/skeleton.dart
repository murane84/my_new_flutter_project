import 'package:flutter/material.dart';

import '../utils/radii.dart';

/// Loading placeholders in the SHAPE of what's coming (instead of a lone
/// spinner): the screen keeps its layout, nothing jumps when the real rows
/// arrive, and it feels faster. One soft light sweeps across them; with
/// reduce-motion they simply rest.
class _Shimmer extends StatefulWidget {
  const _Shimmer({required this.child});
  final Widget child;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final base = scheme.onSurface.withValues(alpha: dark ? 0.08 : 0.07);
    final light = scheme.onSurface.withValues(alpha: dark ? 0.16 : 0.13);
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      return _Tint(color: base, child: widget.child);
    }
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        final x = -1.0 + 3.0 * _c.value;
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (r) => LinearGradient(
            begin: Alignment(x - 1, -0.3),
            end: Alignment(x + 1, 0.3),
            colors: [base, light, base],
            stops: const [0.25, 0.5, 0.75],
          ).createShader(r),
          child: child,
        );
      },
    );
  }
}

class _Tint extends StatelessWidget {
  const _Tint({required this.color, required this.child});
  final Color color;
  final Widget child;
  @override
  Widget build(BuildContext context) => ColorFiltered(
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn), child: child);
}

Widget _bar(double w, double h, {double r = 6}) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(r)),
    );

/// Rows of people / chats / groups: avatar + two lines.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.rows = 7, this.avatar = 44, this.padding});
  final int rows;
  final double avatar;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading',
      child: ExcludeSemantics(
        child: _Shimmer(
          child: ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: padding ?? const EdgeInsets.fromLTRB(12, 8, 12, 8),
            itemCount: rows,
            itemBuilder: (_, i) {
              // Varied widths so it reads as content, not a grid.
              final a = 0.45 + ((i * 37) % 30) / 100;
              final b = 0.25 + ((i * 53) % 30) / 100;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: LayoutBuilder(builder: (context, c) {
                  final w = c.maxWidth - avatar - 14;
                  return Row(children: [
                    _bar(avatar, avatar, r: avatar / 2),
                    const SizedBox(width: 14),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _bar(w * a, 11),
                        const SizedBox(height: 8),
                        _bar(w * b, 9),
                      ],
                    ),
                  ]);
                }),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A chat thread loading: bubbles on both sides, like a conversation.
class SkeletonChat extends StatelessWidget {
  const SkeletonChat({super.key});

  @override
  Widget build(BuildContext context) {
    const shape = [
      (false, 0.55, 1), (false, 0.38, 1), (true, 0.5, 1), (false, 0.62, 2),
      (true, 0.34, 1), (true, 0.58, 2), (false, 0.44, 1), (true, 0.4, 1),
    ];
    return Semantics(
      label: 'Loading messages',
      child: ExcludeSemantics(
        child: _Shimmer(
          child: LayoutBuilder(builder: (context, c) {
            return ListView(
              reverse: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              children: [
                for (final (mine, f, lines) in shape)
                  Align(
                    alignment:
                        mine ? Alignment.centerRight : Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: _bar(c.maxWidth * f, lines == 1 ? 38 : 58,
                          r: Radii.lg),
                    ),
                  ),
              ],
            );
          }),
        ),
      ),
    );
  }
}
