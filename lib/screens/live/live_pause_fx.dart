import 'package:flutter/material.dart';

/// Listen Together — how a pause, a slow connection and a restart LOOK, so
/// nobody has to read to know which is which.

/// A soft ring pulsing around the record while the music is catching up
/// (network), never while someone paused it.
class CatchingUpRing extends StatefulWidget {
  const CatchingUpRing({super.key, required this.color, required this.size});
  final Color color;
  final double size;

  @override
  State<CatchingUpRing> createState() => _CatchingUpRingState();
}

class _CatchingUpRingState extends State<CatchingUpRing>
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
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) {
          final t = Curves.easeOut.transform(_c.value);
          return Container(
            width: widget.size * (1.0 + 0.16 * t),
            height: widget.size * (1.0 + 0.16 * t),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: widget.color.withValues(alpha: 0.55 * (1 - t)),
                width: 3,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 3 · 2 · 1 over the record — the music drops on the same beat for all.
class CountdownBadge extends StatelessWidget {
  const CountdownBadge({super.key, required this.value, required this.color});
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        transitionBuilder: (child, a) => ScaleTransition(
          scale: Tween<double>(begin: 1.6, end: 1).animate(
              CurvedAnimation(parent: a, curve: Curves.easeOutBack)),
          child: FadeTransition(opacity: a, child: child),
        ),
        child: Container(
          key: ValueKey(value),
          width: 64,
          height: 64,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            boxShadow: [
              BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 24),
            ],
          ),
          child: Text('$value',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w900)),
        ),
      ),
    );
  }
}

/// A small breathing green dot on someone's photo: still here, just paused.
class StillHereDot extends StatefulWidget {
  const StillHereDot({super.key});

  @override
  State<StillHereDot> createState() => _StillHereDotState();
}

class _StillHereDotState extends State<StillHereDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1600))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: Colors.green,
          shape: BoxShape.circle,
          border: Border.all(
              color: Theme.of(context).colorScheme.surface, width: 2),
          boxShadow: [
            BoxShadow(
                color: Colors.green.withValues(alpha: 0.25 + 0.4 * _c.value),
                blurRadius: 4 + 6 * _c.value),
          ],
        ),
      ),
    );
  }
}

/// Why I paused, one tap — shown to everyone ("⏸ Juma paused · brb ☕").
const pauseReasons = <String, String>{
  'brb': 'brb ☕',
  'call': 'a call 📞',
  'love': 'love this part 🔁',
};
