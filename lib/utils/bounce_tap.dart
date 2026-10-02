import 'package:flutter/material.dart';

/// Reusable tactile feedback for taps.
///
/// Two complementary widgets:
///
///  * [BounceTap] — a *tap target*. It owns the tap: pass [onTap] (and
///    optionally [onLongPress]) and it fires them while playing a quick
///    scale "pop" (press-in, elastic bounce back). Use it for bare icons /
///    small toggles that don't already have their own gesture handling.
///
///  * [Tactile] — a *pass-through press effect*. It does NOT own the tap; it
///    only adds the press-scale, using a [Listener] (raw pointer events) so it
///    never competes in the gesture arena. Wrap it around any existing button
///    (ElevatedButton, IconButton, a GestureDetector/InkWell, a custom
///    control…) and that button keeps handling its own tap exactly as before,
///    now with a springy press. This is what lets the whole app get a
///    consistent tactile bounce without rerouting every callback.
class BounceTap extends StatefulWidget {
  const BounceTap(
      {super.key, required this.child, required this.onTap, this.onLongPress});
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  State<BounceTap> createState() => _BounceTapState();
}

class _BounceTapState extends State<BounceTap>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 260));
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
        tween:
            Tween(begin: 1.0, end: 0.8).chain(CurveTween(curve: Curves.easeOut)),
        weight: 35),
    TweenSequenceItem(
        tween: Tween(begin: 0.8, end: 1.0)
            .chain(CurveTween(curve: Curves.elasticOut)),
        weight: 65),
  ]).animate(_c);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        _c.forward(from: 0);
        widget.onTap();
      },
      onLongPress: widget.onLongPress,
      child: ScaleTransition(scale: _scale, child: widget.child),
    );
  }
}

/// Pass-through press-scale. Wrap any tappable widget; the wrapped widget
/// keeps handling its own tap (we listen to raw pointer events only, so we
/// never win or block the gesture arena). On press it eases down to
/// [pressedScale]; on release it springs back with a small elastic overshoot.
/// Set [enabled] to false (e.g. a disabled button) to skip the effect.
class Tactile extends StatefulWidget {
  const Tactile({
    super.key,
    required this.child,
    this.pressedScale = 0.92,
    this.enabled = true,
  });

  final Widget child;
  final double pressedScale;
  final bool enabled;

  @override
  State<Tactile> createState() => _TactileState();
}

class _TactileState extends State<Tactile> with TickerProviderStateMixin {
  // Press-in: 1.0 -> pressedScale, driven by _press (0..1).
  late final AnimationController _press = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 90));
  // Release: pressedScale -> 1.0 with an elastic overshoot.
  late final AnimationController _release = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 340));
  late final Animation<double> _releaseAnim =
      Tween<double>(begin: widget.pressedScale, end: 1.0)
          .chain(CurveTween(curve: Curves.elasticOut))
          .animate(_release);

  bool _releasing = false;

  double get _pressScale =>
      1.0 - _press.value * (1.0 - widget.pressedScale);

  void _onDown(PointerDownEvent _) {
    if (!widget.enabled) return;
    _release.stop();
    _releasing = false;
    _press.forward();
  }

  void _onUp([PointerEvent? _]) {
    if (!widget.enabled || (!_press.isAnimating && _press.value == 0.0)) {
      // Never pressed (e.g. pointer moved off before down registered).
      return;
    }
    _press.stop();
    _press.value = 0.0;
    _releasing = true;
    _release.forward(from: 0.0);
  }

  @override
  void dispose() {
    _press.dispose();
    _release.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Listener(
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: _onDown,
      onPointerUp: _onUp,
      onPointerCancel: _onUp,
      child: AnimatedBuilder(
        animation: Listenable.merge([_press, _release]),
        builder: (context, child) {
          final s = _releasing ? _releaseAnim.value : _pressScale;
          return Transform.scale(scale: s, child: child);
        },
        child: widget.child,
      ),
    );
  }
}
