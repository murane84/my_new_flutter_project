import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;

import '../utils/motion.dart';
import '../utils/popup_shell.dart' show gLastTapDownGlobal;

/// Telegram-style profile entrance: the big profile photo FLIES out of the
/// spot the user tapped (the little avatar in a chat header, a friend row,
/// the profile pill) and grows into place while the page fades in; closing
/// plays it backwards, so the photo shrinks home again.
///
/// Wrap the page's big avatar in this. It follows the enclosing route's own
/// animation, so it works for any route type (popup, bottom sheet, page) and
/// both directions come for free. The start spot is, in order: the rect
/// recorded with [AvatarFlight.from] just before opening, else a small circle
/// at the last tap anywhere in the app. With neither, it simply shows.
class AvatarFlight extends StatefulWidget {
  const AvatarFlight({super.key, required this.child, this.startSize = 40});

  final Widget child;

  /// Diameter of the starting circle when only the tap point is known.
  final double startSize;

  static Rect? _pending;

  /// Record [context]'s widget (the small avatar being tapped) as the exact
  /// start of the next flight. Optional — the tap point is used otherwise.
  static void from(BuildContext context) {
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize && box.attached) {
      _pending = box.localToGlobal(Offset.zero) & box.size;
    }
  }

  @override
  State<AvatarFlight> createState() => _AvatarFlightState();
}

class _AvatarFlightState extends State<AvatarFlight> {
  Animation<double>? _anim;
  Rect? _src;
  OverlayEntry? _entry;
  OverlayState? _overlay;

  bool get _flying {
    final a = _anim;
    if (a == null || _src == null) return false;
    return a.status == AnimationStatus.forward ||
        a.status == AnimationStatus.reverse;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_anim != null) return;
    final a = ModalRoute.of(context)?.animation;
    final src = AvatarFlight._pending ??
        (gLastTapDownGlobal == null
            ? null
            : Rect.fromCenter(
                center: gLastTapDownGlobal!,
                width: widget.startSize,
                height: widget.startSize));
    AvatarFlight._pending = null;
    if (a == null || src == null) return;
    _overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (_overlay == null) return;
    _anim = a;
    _src = src;
    a.addListener(_tick);
    a.addStatusListener(_status);
    if (_flying) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _show());
    }
  }

  void _show() {
    if (!mounted || _entry != null || !_flying) return;
    _entry = OverlayEntry(builder: _flight);
    _overlay?.insert(_entry!);
  }

  void _hide() {
    _entry?.remove();
    _entry = null;
  }

  void _tick() => _entry?.markNeedsBuild();

  void _status(AnimationStatus s) {
    if (!mounted) return;
    if (s == AnimationStatus.completed || s == AnimationStatus.dismissed) {
      _hide();
    } else {
      _show(); // closing: fly back home
    }
    setState(() {});
  }

  Widget _flight(BuildContext _) {
    final box = context.findRenderObject();
    final a = _anim;
    final src = _src;
    if (box is! RenderBox || !box.attached || !box.hasSize ||
        a == null || src == null) {
      return const SizedBox.shrink();
    }
    final dst = box.localToGlobal(Offset.zero) & box.size;
    final curve = a.status == AnimationStatus.reverse
        ? Curves.easeInCubic
        : Curves.easeOutCubic;
    final t = curve.transform(a.value.clamp(0.0, 1.0));
    final r = Rect.lerp(src, dst, t)!;
    return Positioned.fromRect(
      rect: r,
      child: IgnorePointer(
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox.fromSize(size: box.size, child: widget.child),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _anim?.removeListener(_tick);
    _anim?.removeStatusListener(_status);
    _hide();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The real avatar waits invisibly in place while its double is in flight.
    return Opacity(opacity: _flying ? 0 : 1, child: widget.child);
  }
}

/// Shared-element continuity for screens that open INSIDE a panel (not as
/// their own page, so a Hero can't fly): the photo I tapped in a list
/// glides into the header of what opens, then the real header photo takes
/// over. The header marks its photo with [AvatarFlightTarget].
/// (Profiles use the route-driven [AvatarFlight] widget above.)
class PanelFlight {
  PanelFlight._();

  static final ValueNotifier<bool> flying = ValueNotifier<bool>(false);
  static Rect? _target;
  static OverlayEntry? _entry;

  /// Fly [face] from [from] (global rect) to wherever the target reports.
  static Future<void> fly(BuildContext context, Rect from, Widget face) async {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    // Measured before waiting, so no context is used across the gap.
    final ovBox = overlay.context.findRenderObject() as RenderBox?;
    _entry?.remove();
    _entry = null;
    _target = null;
    flying.value = true;
    // The header is built on the next frame or two: wait for it to report.
    for (var i = 0; i < 4 && _target == null; i++) {
      await SchedulerBinding.instance.endOfFrame;
    }
    final to = _target;
    if (to == null) {
      flying.value = false;
      return;
    }
    final origin = ovBox?.localToGlobal(Offset.zero) ?? Offset.zero;
    final a = from.shift(-origin), b = to.shift(-origin);
    final done = Completer<void>();
    _entry = OverlayEntry(
      builder: (_) => IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: Motion.emphasized,
          curve: Motion.move,
          onEnd: () {
            _entry?.remove();
            _entry = null;
            flying.value = false;
            if (!done.isCompleted) done.complete();
          },
          builder: (_, v, child) {
            final r = Rect.lerp(a, b, v)!;
            return Stack(children: [
              Positioned.fromRect(rect: r, child: child!),
            ]);
          },
          child: FittedBox(child: face),
        ),
      ),
    );
    overlay.insert(_entry!);
    return done.future;
  }
}

/// Marks the header photo a flight lands on: reports where it is while a
/// flight is on, and stays hidden until the flying photo arrives.
class AvatarFlightTarget extends StatelessWidget {
  const AvatarFlightTarget({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: PanelFlight.flying,
      child: child,
      builder: (context, on, child) {
        if (on) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final box = context.findRenderObject() as RenderBox?;
            if (box != null && box.hasSize && box.attached) {
              final o = box.localToGlobal(Offset.zero);
              // The photo itself sits centred in the slot.
              PanelFlight._target = Rect.fromCenter(
                  center: o + box.size.center(Offset.zero),
                  width: 34,
                  height: 34);
            }
          });
        }
        return Opacity(opacity: on ? 0 : 1, child: child);
      },
    );
  }
}
