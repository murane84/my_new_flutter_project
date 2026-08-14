import 'package:flutter/material.dart';

/// A slowly rotating coral "record edge" ring drawn around [child] while a
/// friend is playing music — the Concept 05 vinyl signal, but tasteful: only the
/// ring turns, the avatar/face stays still. Sizes itself to [child] plus [ring]
/// px on each side, so it drops in wherever an avatar goes.
class SpinningVinylRing extends StatefulWidget {
  final Widget child;
  final double ring;
  final Color color;

  const SpinningVinylRing({
    super.key,
    required this.child,
    this.ring = 3,
    this.color = const Color(0xFFFF5A5F),
  });

  @override
  State<SpinningVinylRing> createState() => _SpinningVinylRingState();
}

class _SpinningVinylRingState extends State<SpinningVinylRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.color;
    return Stack(
      alignment: Alignment.center,
      children: [
        // Rotating sweep-gradient disc; the avatar on top covers the centre so
        // only a thin annulus (the "record edge") shows and spins.
        Positioned.fill(
          child: RotationTransition(
            turns: _c,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: SweepGradient(
                  colors: [
                    c,
                    c.withValues(alpha: 0.0),
                    c.withValues(alpha: 0.55),
                    c,
                  ],
                  stops: const [0.0, 0.4, 0.75, 1.0],
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.all(widget.ring),
          child: widget.child,
        ),
      ],
    );
  }
}
