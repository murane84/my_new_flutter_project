import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'radii.dart';
import 'motion.dart';

/// Desktop apps and wide web: emoji pickers float as a card by the button
/// (like the chat's 😊 card) instead of rising from the bottom.
bool emojiFloats(BuildContext context) {
  final mobileOs = defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  if (!kIsWeb) return !mobileOs;
  return MediaQuery.sizeOf(context).width >= 600;
}

/// Open an emoji picker that inserts the tapped emoji into [controller] at the
/// cursor. Reusable anywhere a plain field wants emoji input (group name,
/// username, …) — especially handy on desktop, which has no on-screen emoji key.
Future<void> showEmojiPickerSheet(
    BuildContext context, TextEditingController controller) {
  final scheme = Theme.of(context).colorScheme;
  if (emojiFloats(context)) return _showEmojiCard(context, controller);
  return showModalBottomSheet(
    context: context,
    backgroundColor: scheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl)),
    ),
    builder: (_) => SafeArea(
      top: false,
      // Centre + cap the width so the grid stays compact on wide/desktop
      // windows (a full-width sheet scattered the 8 columns far apart).
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SizedBox(
        height: 320,
        // EmojiPicker inserts the tapped emoji into the controller (at the
        // cursor) itself when `textEditingController` is set — so onEmojiSelected
        // stays a no-op to avoid inserting twice.
        child: EmojiPicker(
          onEmojiSelected: (_, _) {},
          textEditingController: controller,
          config: Config(
            height: 320,
            emojiViewConfig: EmojiViewConfig(
              emojiSizeMax: 26,
              columns: 8,
              backgroundColor: scheme.surface,
              buttonMode: ButtonMode.MATERIAL,
              recentsLimit: 40,
              noRecents: Text(
                'No recent emoji yet',
                style:
                    TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ),
            categoryViewConfig: CategoryViewConfig(
              backgroundColor: scheme.surfaceContainerHighest,
              indicatorColor: scheme.primary,
              iconColor: scheme.onSurfaceVariant,
              iconColorSelected: scheme.primary,
              dividerColor: scheme.outlineVariant.withAlpha(80),
            ),
            bottomActionBarConfig: BottomActionBarConfig(
              backgroundColor: scheme.surfaceContainerHighest,
              buttonColor: scheme.surfaceContainerHighest,
              buttonIconColor: scheme.primary,
            ),
            searchViewConfig: SearchViewConfig(
              backgroundColor: scheme.surfaceContainerHighest,
              buttonIconColor: scheme.primary,
              hintText: 'Search emoji',
            ),
          ),
        ),
      ),
        ),
      ),
    ),
  );
}

/// The emoji picker as an INLINE widget (not a modal), so the target field
/// stays visible above it and updates live as emojis are tapped. The caller
/// sizes it (e.g. wrap in a SizedBox ~300 high) and places it below the field.
Widget inlineEmojiPicker(
    BuildContext context, TextEditingController controller) {
  final scheme = Theme.of(context).colorScheme;
  return EmojiPicker(
    onEmojiSelected: (_, _) {},
    textEditingController: controller,
    config: Config(
      height: 300,
      emojiViewConfig: EmojiViewConfig(
        emojiSizeMax: 26,
        columns: 8,
        backgroundColor: scheme.surface,
        buttonMode: ButtonMode.MATERIAL,
        recentsLimit: 40,
        noRecents: Text(
          'No recent emoji yet',
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
      ),
      categoryViewConfig: CategoryViewConfig(
        backgroundColor: scheme.surfaceContainerHighest,
        indicatorColor: scheme.primary,
        iconColor: scheme.onSurfaceVariant,
        iconColorSelected: scheme.primary,
        dividerColor: scheme.outlineVariant.withAlpha(80),
      ),
      bottomActionBarConfig: BottomActionBarConfig(
        backgroundColor: scheme.surfaceContainerHighest,
        buttonColor: scheme.surfaceContainerHighest,
        buttonIconColor: scheme.primary,
      ),
      searchViewConfig: SearchViewConfig(
        backgroundColor: scheme.surfaceContainerHighest,
        buttonIconColor: scheme.primary,
        hintText: 'Search emoji',
      ),
    ),
  );
}

/// A ready-made emoji button for a TextField's suffixIcon.
Widget emojiSuffixButton(
    BuildContext context, TextEditingController controller) {
  // Its own context, so a desktop card can grow out of THIS button.
  return Builder(
    builder: (btnCtx) => IconButton(
      icon: const Icon(Icons.emoji_emotions_outlined),
      tooltip: 'Add emoji',
      onPressed: () => showEmojiPickerSheet(btnCtx, controller),
    ),
  );
}

/// The desktop card: floats by the button (below it if there's room, else
/// above), grows out of it; a click outside or Esc closes it.
Future<void> _showEmojiCard(
    BuildContext context, TextEditingController controller) {
  final box = context.findRenderObject() as RenderBox?;
  final screen = MediaQuery.sizeOf(context);
  final anchor = box == null || !box.hasSize
      ? Rect.fromCenter(
          center: screen.center(Offset.zero), width: 0, height: 0)
      : box.localToGlobal(Offset.zero) & box.size;
  const w = 380.0, h = 300.0; // the inline picker's own height
  final below = screen.height - anchor.bottom - 8 >= h;
  final left = (anchor.right - w).clamp(8.0, math.max(8.0, screen.width - w - 8));
  final top = below
      ? anchor.bottom + 6
      : math.max(8.0, anchor.top - h - 6);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close emoji',
    barrierColor: Colors.transparent,
    transitionDuration: Motion.standard,
    pageBuilder: (ctx, anim, _) {
      final scheme = Theme.of(ctx).colorScheme;
      final card = Material(
        color: scheme.surface,
        elevation: 10,
        shadowColor: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(Radii.lg),
        clipBehavior: Clip.antiAlias,
        child: inlineEmojiPicker(ctx, controller),
      );
      return Stack(children: [
        Positioned(
          left: left,
          top: top,
          width: w,
          height: h,
          // Grows out of the button's corner.
          child: AnimatedBuilder(
            animation: anim,
            child: card,
            builder: (_, child) {
              final v = Motion.enter.transform(anim.value);
              return Opacity(
                opacity: v,
                child: Transform.scale(
                  scale: 0.9 + 0.1 * v,
                  alignment:
                      below ? Alignment.topRight : Alignment.bottomRight,
                  child: child,
                ),
              );
            },
          ),
        ),
      ]);
    },
    transitionBuilder: (ctx, a, _, child) => child,
  );
}
