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
          child: builder(ctx),
        ),
      );
      return SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxW.clamp(280.0, screen.width - 32),
              maxHeight: screen.height * 0.86,
            ),
            child: AnimatedBuilder(
              animation: anim,
              child: card,
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
