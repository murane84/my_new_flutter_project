import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Tells a [NowGlow] to breathe once. [ping] after the list has finished
/// scrolling to the playing song; `soft` when it was already in view (a
/// small nudge instead of the full glow).
class NowGlowController extends ChangeNotifier {
  double _strength = 1;
  double get strength => _strength;

  void ping({bool soft = false}) {
    _strength = soft ? 0.45 : 1;
    notifyListeners();
  }
}

/// The "here it is" for ⌖ Find the playing song — Aluta-style, never a
/// flashing alarm: the row breathes ONCE (warm accent wash + soft halo that
/// swell and settle over ~1 s, a hair of lift) and a little ♪ floats up
/// off its trailing edge and fades. Used by the playlist, Up next and the
/// Listen Together queue so all three answer ⌖ the same way.
class NowGlow extends StatefulWidget {
  const NowGlow({
    super.key,
    required this.controller,
    required this.child,
    this.radius = 14,
    this.color,
  });

  final NowGlowController controller;
  final Widget child;
  final double radius;
  final Color? color; // defaults to the theme's primary

  @override
  State<NowGlow> createState() => _NowGlowState();
}

class _NowGlowState extends State<NowGlow> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100));
  double _strength = 1;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_ping);
  }

  @override
  void didUpdateWidget(NowGlow old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_ping);
      widget.controller.addListener(_ping);
    }
  }

  void _ping() {
    _strength = widget.controller.strength;
    _a.forward(from: 0);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_ping);
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.color ?? Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _a,
      child: widget.child,
      builder: (context, child) {
        final t = _a.value;
        if (t == 0 || t == 1) return child!;
        // One breath: swells, then settles slower than it rose.
        final rise = Curves.easeOut.transform((t / 0.35).clamp(0.0, 1.0));
        final fall =
            Curves.easeInOut.transform(((t - 0.35) / 0.65).clamp(0.0, 1.0));
        final i = (t < 0.35 ? rise : 1 - fall) * _strength;
        // The ♪ drifts up and fades over the whole breath.
        final noteT = Curves.easeOut.transform(t);
        return Transform.scale(
          scale: 1 + 0.014 * i,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(widget.radius),
                  color: c.withValues(alpha: 0.16 * i),
                  border: Border.all(
                      color: c.withValues(alpha: 0.55 * i), width: 1.2),
                  boxShadow: [
                    BoxShadow(
                      color: c.withValues(alpha: 0.35 * i),
                      blurRadius: 16,
                      spreadRadius: 0.5,
                    ),
                  ],
                ),
                child: child,
              ),
              if (_strength >= 0.9)
                Positioned(
                  right: 10,
                  top: -4 - 14 * noteT,
                  child: IgnorePointer(
                    child: Opacity(
                      opacity:
                          (math.sin(math.pi * noteT)).clamp(0.0, 1.0) * 0.9,
                      child: Text('♪',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: c)),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
