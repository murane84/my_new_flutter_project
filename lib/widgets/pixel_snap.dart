import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Paints its child at a WHOLE physical-pixel origin.
///
/// On desktop/web with fractional display scaling (125%, 150%…) a panel can
/// land on a fraction of a pixel; the engine then rounds it one way when the
/// picture is cached and another way while something animates, so the whole
/// area twitches by 1px whenever anything inside animates. Snapping the
/// origin removes that flip. Layout is untouched (paint offset only, < 1px).
class PixelSnap extends SingleChildRenderObjectWidget {
  const PixelSnap({super.key, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPixelSnap(MediaQuery.devicePixelRatioOf(context));

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderPixelSnap).dpr =
        MediaQuery.devicePixelRatioOf(context);
  }
}

class _RenderPixelSnap extends RenderProxyBox {
  _RenderPixelSnap(this._dpr);

  double _dpr;
  set dpr(double v) {
    if (v == _dpr) return;
    _dpr = v;
    markNeedsPaint();
  }

  Offset _snap(Offset o) => Offset(
        (o.dx * _dpr).roundToDouble() / _dpr,
        (o.dy * _dpr).roundToDouble() / _dpr,
      );

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    context.paintChild(child!, _snap(offset));
  }

  // Hit testing keeps the layout positions (the nudge is under 1px).
}
