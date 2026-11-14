import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:flutter/material.dart';

import 'motion.dart';
import 'radii.dart';

/// Desktop apps and the web on a wide screen: sheets become cards.
bool wideLayout(BuildContext context) {
  final mobileOs = defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  if (!kIsWeb) return !mobileOs;
  return MediaQuery.sizeOf(context).width >= 600;
}

/// Every sheet in Aluta goes through here (same arguments as
/// [showModalBottomSheet]). On a phone it IS a bottom sheet. On desktop /
/// wide web a sheet rising from the bottom edge of a big window reads as
/// out of place, so the same content opens as a centred card instead —
/// like the floating emoji cards: rounded, soft shadow, it eases in, a
/// click outside or Esc closes it, and it pops / returns values exactly as
/// the sheet did.
Future<T?> showAdaptiveSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  ShapeBorder? shape,
  bool isScrollControlled = false,
  bool? showDragHandle,
  bool useRootNavigator = false,
  BoxConstraints? constraints,
  double? elevation,
  Color? barrierColor,
  bool useSafeArea = false,
  bool isDismissible = true,
  bool enableDrag = true,
  AnimationStyle? sheetAnimationStyle,
}) {
  if (!wideLayout(context)) {
    return showModalBottomSheet<T>(
      context: context,
      builder: builder,
      backgroundColor: backgroundColor,
      shape: shape,
      isScrollControlled: isScrollControlled,
      showDragHandle: showDragHandle,
      useRootNavigator: useRootNavigator,
      constraints: constraints,
      elevation: elevation,
      barrierColor: barrierColor,
      useSafeArea: useSafeArea,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      sheetAnimationStyle: sheetAnimationStyle,
    );
  }
  return showGeneralDialog<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    barrierDismissible: isDismissible,
    barrierLabel: 'Close',
    barrierColor: barrierColor ?? Colors.black.withValues(alpha: 0.28),
    transitionDuration: Motion.standard,
    pageBuilder: (ctx, anim, _) {
      final scheme = Theme.of(ctx).colorScheme;
      final screen = MediaQuery.sizeOf(ctx);
      final maxW = (constraints?.maxWidth.isFinite ?? false)
          ? constraints!.maxWidth
          : 520.0;
      final card = Material(
        color: backgroundColor ?? scheme.surface,
        elevation: elevation ?? 12,
        shadowColor: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(Radii.xl),
        clipBehavior: Clip.antiAlias,
        // A sheet's content was written for the screen's bottom edge: no
        // bottom inset to pad for inside a card.
        child: MediaQuery.removePadding(
          context: ctx,
          removeBottom: true,
          removeTop: true,
          child: showDragHandle == true
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  const _CardHandle(),
                  Flexible(child: builder(ctx)),
                ])
              : builder(ctx),
        ),
      );
      // The grab line at the top drags the card down to close it, like
      // the sheet it stands in for (a short pull springs back).
      final movable = isDismissible && enableDrag
          ? _DragToClose(onClose: () => Navigator.of(ctx).maybePop(), child: card)
          : card;
      return SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxW.clamp(280.0, screen.width - 32),
              maxHeight: screen.height * 0.86,
            ),
            child: AnimatedBuilder(
              animation: anim,
              child: movable,
              builder: (_, child) {
                final v = Motion.enter.transform(anim.value);
                return Opacity(
                  opacity: v,
                  child: Transform.scale(scale: 0.96 + 0.04 * v, child: child),
                );
              },
            ),
          ),
        ),
      );
    },
    transitionBuilder: (ctx, a, _, child) => child,
  );
}

/// Material's sheet grab line, for cards whose sheet asked for one.
class _CardHandle extends StatelessWidget {
  const _CardHandle();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 6),
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .onSurfaceVariant
                .withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
}

/// Desktop card: a pull on its top strip (where the grab line sits) moves
/// it down and fades it; far or fast enough closes it, else it springs back.
/// Only the strip listens, so lists, sliders and text inside work as before.
class _DragToClose extends StatefulWidget {
  const _DragToClose({required this.onClose, required this.child});
  final VoidCallback onClose;
  final Widget child;
  @override
  State<_DragToClose> createState() => _DragToCloseState();
}

class _DragToCloseState extends State<_DragToClose>
    with SingleTickerProviderStateMixin {
  late final AnimationController _back = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 220))
    ..addListener(() => setState(() => _dy = _from * (1 - _back.value)));
  double _dy = 0;
  double _from = 0;
  bool _hover = false;

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  void _end(DragEndDetails d) {
    if (_dy > 110 || d.velocity.pixelsPerSecond.dy > 700) {
      widget.onClose();
      return;
    }
    _from = _dy;
    _back.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final fade = (1 - _dy / 400).clamp(0.4, 1.0);
    return Transform.translate(
      offset: Offset(0, _dy),
      child: Opacity(
        opacity: fade,
        child: Stack(children: [
          widget.child,
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 26,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              onEnter: (_) => setState(() => _hover = true),
              onExit: (_) => setState(() => _hover = false),
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragStart: (_) => _back.stop(),
                onVerticalDragUpdate: (d) => setState(() {
                  // Down follows the pointer; up only gives a little.
                  final next = _dy + d.delta.dy;
                  _dy = next < 0 ? next * 0.25 : next;
                }),
                onVerticalDragEnd: _end,
                child: Align(
                  alignment: Alignment.topCenter,
                  // A soft glow under the grab line on hover says "pull me".
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 150),
                    opacity: _hover ? 1 : 0,
                    child: Container(
                      margin: const EdgeInsets.only(top: 6),
                      width: 64,
                      height: 12,
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant
                            .withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
