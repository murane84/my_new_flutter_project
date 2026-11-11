import 'package:flutter/gestures.dart'
    show PointerDeviceKind, PointerScrollEvent;
import 'package:flutter/material.dart';

/// A sideways row of chips / avatars that never makes you hunt for what's
/// hidden past the edge:
///  • a soft fade on the side where more is waiting;
///  • the mouse wheel scrolls it sideways, and a mouse can drag it (desktop);
///  • [EdgeScrollRow.reveal] glides a tapped item fully into view — centred,
///    so its neighbours peek in and the rest of the row follows.
class EdgeScrollRow extends StatefulWidget {
  const EdgeScrollRow({super.key, required this.builder, this.fade = 28});

  /// Build the horizontal scrollable with the row's controller.
  final Widget Function(BuildContext context, ScrollController controller)
      builder;

  /// Width of the edge fade.
  final double fade;

  /// Bring the item built under [itemContext] fully into view (centred).
  static Future<void> reveal(BuildContext itemContext) async {
    // Only the row itself moves — never a page scrolling around it.
    final s = Scrollable.maybeOf(itemContext);
    final ro = itemContext.findRenderObject();
    if (s == null || ro == null || !ro.attached) return;
    await s.position.ensureVisible(ro,
        alignment: 0.5,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic);
  }

  @override
  State<EdgeScrollRow> createState() => _EdgeScrollRowState();
}

class _EdgeScrollRowState extends State<EdgeScrollRow> {
  final ScrollController _c = ScrollController();
  bool _kicked = false; // one re-check once the row has its size

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _wheel(PointerScrollEvent e) {
    if (!_c.hasClients) return;
    final p = _c.position;
    // A plain wheel scrolls vertically: turn it sideways here.
    final d = e.scrollDelta.dx.abs() > e.scrollDelta.dy.abs()
        ? e.scrollDelta.dx
        : e.scrollDelta.dy;
    if (d == 0 || p.maxScrollExtent <= 0) return;
    _c.jumpTo((p.pixels + d).clamp(p.minScrollExtent, p.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    final row = ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        scrollbars: false,
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
        },
      ),
      // Chips added / removed (e.g. "Clear") change what's hidden: re-fade.
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          if (mounted) setState(() {});
          return false;
        },
        child: widget.builder(context, _c),
      ),
    );
    return Listener(
      onPointerSignal: (e) {
        if (e is PointerScrollEvent) _wheel(e);
      },
      child: AnimatedBuilder(
        animation: _c,
        child: row,
        builder: (context, child) {
          var left = false, right = false;
          if (_c.hasClients && _c.position.hasContentDimensions) {
            final p = _c.position;
            left = p.pixels > p.minScrollExtent + 1;
            right = p.pixels < p.maxScrollExtent - 1;
          } else if (!_kicked) {
            // First frame: measure again once the row is laid out.
            _kicked = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() {});
            });
          }
          if (!left && !right) return child!;
          return ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (r) {
              final f = (widget.fade / r.width).clamp(0.0, 0.5);
              return LinearGradient(
                colors: [
                  left ? Colors.transparent : Colors.black,
                  Colors.black,
                  Colors.black,
                  right ? Colors.transparent : Colors.black,
                ],
                stops: [0, f, 1 - f, 1],
              ).createShader(r);
            },
            child: child,
          );
        },
      ),
    );
  }
}
