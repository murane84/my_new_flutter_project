import 'package:flutter/animation.dart';
import 'package:flutter/widgets.dart';

/// A ScrollController whose MOUSE WHEEL glides instead of jumping in steps
/// (desktop / web). Each notch adds to a target the list eases toward, so
/// fast spinning stays fluid and a single notch still feels exact. Touch,
/// drag and trackpads (pan-zoom gestures) are untouched.
class SmoothWheelController extends ScrollController {
  SmoothWheelController({super.initialScrollOffset, super.keepScrollOffset,
      super.debugLabel});

  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics,
      ScrollContext context, ScrollPosition? oldPosition) {
    return _SmoothWheelPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
    );
  }
}

class _SmoothWheelPosition extends ScrollPositionWithSingleContext {
  _SmoothWheelPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  double? _target;

  @override
  void pointerScroll(double delta) {
    // Small deltas are a trackpad / precise wheel (web sends those as
    // scroll events too): they're already smooth — follow them directly.
    if (delta.abs() < 30 || !hasContentDimensions) {
      super.pointerScroll(delta);
      return;
    }
    // Keep adding to where we're heading while a glide is running.
    final from = (_target != null && isScrollingNotifier.value)
        ? _target!
        : pixels;
    final to = (from + delta).clamp(minScrollExtent, maxScrollExtent);
    if (to == pixels) return;
    _target = to;
    animateTo(to,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic);
  }
}
