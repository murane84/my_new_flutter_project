import 'dart:async';

import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/widgets.dart';

import '../utils/motion.dart';

/// Shared-element continuity for screens that open INSIDE a panel (not as
/// their own page, so a Hero can't fly): the photo I tapped in a list
/// glides into the header of what opens, then the real header photo takes
/// over. The header marks its photo with [AvatarFlightTarget].
class AvatarFlight {
  AvatarFlight._();

  static final ValueNotifier<bool> flying = ValueNotifier<bool>(false);
  static Rect? _target;
  static OverlayEntry? _entry;

  /// Fly [face] from [from] (global rect) to wherever the target reports.
  static Future<void> fly(BuildContext context, Rect from, Widget face) async {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
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
    final ovBox = overlay.context.findRenderObject() as RenderBox?;
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
      valueListenable: AvatarFlight.flying,
      child: child,
      builder: (context, on, child) {
        if (on) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final box = context.findRenderObject() as RenderBox?;
            if (box != null && box.hasSize && box.attached) {
              final o = box.localToGlobal(Offset.zero);
              // The photo itself sits centred in the slot.
              AvatarFlight._target = Rect.fromCenter(
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
