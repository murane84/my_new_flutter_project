import 'package:flutter/material.dart';

import '../services/section_transition.dart';
import '../utils/motion.dart';
import 'section_switch.dart';

/// A swipe between sections that FOLLOWS THE FINGER — the chat screen's
/// Harmony ← [All · Status · Listening · Circle] → Glow on phones, and the
/// Legal & About hub's Privacy · Terms · About: the next page
/// slides / reveals in under the drag in the chosen transition style, a
/// release past a third of the width (or a flick) finishes it, an early
/// release springs back with nothing changed, and past either end the page
/// stretches a little and bounces back. Inner horizontal lists (the story
/// strip, Your Spaces, Glow's filters) keep their own swipes.
class SectionSwipePath extends StatefulWidget {
  const SectionSwipePath({
    super.key,
    required this.current,
    required this.hasNeighbor,
    required this.neighbor,
    required this.commit,
  });

  final Widget current;

  /// Is there a page that way? (Cheap — no building.)
  final bool Function(bool forward) hasNeighbor;

  /// The page a swipe would bring in (forward = finger moving left), or
  /// null at that end of the path.
  final Widget? Function(bool forward) neighbor;

  /// Make [forward]'s neighbour the current page (no second animation).
  final void Function(bool forward) commit;

  @override
  State<SectionSwipePath> createState() => _SectionSwipePathState();
}

class _SectionSwipePathState extends State<SectionSwipePath>
    with SingleTickerProviderStateMixin {
  late final AnimationController _p = AnimationController(
      vsync: this, duration: Motion.standard);
  double _dx = 0; // raw finger travel this drag
  bool? _fwd; // which way this drag is going
  bool _hasNext = false; // a page exists the way this drag goes
  Widget? _next; // that page — built in build() (never in a gesture
  // callback: its rows read providers, which belongs in the build phase)
  double _w = 1;
  bool _settling = false;
  double _rubber = 0; // past an end: a small stretch

  @override
  void didUpdateWidget(SectionSwipePath old) {
    super.didUpdateWidget(old);
    // The home rebuilt (a new message, someone went live…) — rebuild the
    // page under the finger from fresh data on the next frame.
    _next = null;
  }

  @override
  void dispose() {
    _p.dispose();
    super.dispose();
  }

  void _start(DragStartDetails d) {
    if (_settling) return;
    _p.stop();
    _dx = 0;
    _fwd = null;
    _hasNext = false;
    _next = null;
  }

  void _update(DragUpdateDetails d) {
    if (_settling) return;
    _dx += d.delta.dx;
    final fwd = _dx < 0;
    if (_fwd != fwd) {
      _fwd = fwd;
      _hasNext = widget.hasNeighbor(fwd);
      _next = null; // (re)built for this direction in build()
    }
    setState(() {
      if (!_hasNext) {
        _p.value = 0;
        _rubber = (_dx * 0.25).clamp(-40.0, 40.0);
      } else {
        _rubber = 0;
        _p.value = (_dx.abs() / _w).clamp(0.0, 1.0);
      }
    });
  }

  void _end(DragEndDetails d) {
    if (_settling) return;
    final fwd = _fwd;
    if (fwd == null || !_hasNext) {
      setState(() => _rubber = 0); // bounce back (animated below)
      _reset();
      return;
    }
    final v = d.primaryVelocity ?? 0;
    final flick = fwd ? v < -600 : v > 600;
    final back = fwd ? v > 300 : v < -300;
    final go = !back && (_p.value > 0.33 || flick);
    _settling = true;
    final run = go
        ? _p.animateTo(1, curve: Curves.easeOutCubic)
        : _p.animateBack(0, curve: Curves.easeOutCubic);
    run.whenComplete(() {
      if (!mounted) return;
      if (go) {
        // (The tab tick comes from the switch itself — once, as on a tap.)
        // The page already arrived under the finger: the switch that
        // follows the state change must not play it again.
        SectionSwitch.skipUntil =
            DateTime.now().add(const Duration(milliseconds: 350));
        widget.commit(fwd);
      }
      _reset();
    });
  }

  void _reset() {
    setState(() {
      _dx = 0;
      _fwd = null;
      _hasNext = false;
      _next = null;
      _settling = false;
      _p.value = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final accent = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(builder: (context, cons) {
      _w = cons.maxWidth <= 0 ? 1 : cons.maxWidth;
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: _start,
        onHorizontalDragUpdate: _update,
        onHorizontalDragEnd: _end,
        onHorizontalDragCancel: () {
          if (!_settling) _reset();
        },
        child: ValueListenableBuilder<SectionTransitionStyle>(
          valueListenable: SectionTransition.instance.style,
          builder: (context, style, _) => AnimatedBuilder(
            animation: _p,
            builder: (context, _) {
              final p = _p.value;
              final dir = (_fwd ?? true) ? 1.0 : -1.0;
              // Reduce motion: the finger still drives it, as a plain fade.
              final st = reduce ? SectionTransitionStyle.fade : style;
              final fwd = _fwd;
              final next = (fwd != null && _hasNext && p > 0)
                  ? (_next ??= widget.neighbor(fwd))
                  : null;
              return ClipRect(
                child: Stack(fit: StackFit.expand, children: [
                  TweenAnimationBuilder<double>(
                    tween: Tween(end: _rubber),
                    duration: _rubber == 0
                        ? const Duration(milliseconds: 260)
                        : Duration.zero,
                    curve: Curves.easeOutBack,
                    builder: (context, r, child) => Transform.translate(
                        offset: Offset(r, 0), child: child),
                    child: SectionSwitch.dragOutgoing(
                        st, widget.current, p, dir),
                  ),
                  if (next != null && p > 0)
                    IgnorePointer(
                      child: SectionSwitch.frame(
                          st, next, p, true, dir, accent, finger: true),
                    ),
                ]),
              );
            },
          ),
        ),
      );
    });
  }
}
