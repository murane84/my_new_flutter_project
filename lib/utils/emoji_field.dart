import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:flutter/gestures.dart' show GestureBinding, PointerDownEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'radii.dart';
import 'motion.dart';
import 'adaptive_sheet.dart';
import 'depth.dart';

/// Desktop apps and wide web: emoji pickers float as a card by the button
/// (like the chat's 😊 card) instead of rising from the bottom.
bool emojiFloats(BuildContext context) {
  final mobileOs = defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  if (!kIsWeb) return !mobileOs;
  return MediaQuery.sizeOf(context).width >= 600;
}

/// Where the last click / tap went down, app-wide — so a floating card can
/// grow out of whatever opened it, even when the caller has no button
/// context to hand.
Offset? _lastPointer;
bool _tracking = false;

/// Start remembering where clicks land (call once at start-up).
void startPointerTracking() {
  _trackPointer();
  emojiStartTabRefresh();
}

/// Pickers open on Recent once you have some; before that, on Smileys
/// (an empty "No recent emoji yet" page was the first thing you saw).
bool _hasRecents = false;
Category emojiStartTab() => _hasRecents ? Category.RECENT : Category.SMILEYS;

/// Re-check after picks so the next picker opens on Recent.
void emojiStartTabRefresh() {
  EmojiPickerUtils()
      .getRecentEmojis()
      .then((r) => _hasRecents = r.isNotEmpty)
      .catchError((_) => _hasRecents);
}

void _trackPointer() {
  if (_tracking) return;
  _tracking = true;
  GestureBinding.instance.pointerRouter.addGlobalRoute((e) {
    if (e is PointerDownEvent) _lastPointer = e.position;
  });
}

/// A small card floating by [anchor] (a widget's context; else where I last
/// clicked): below it if there's room, else above; it grows out of that
/// corner, and a click outside or Esc closes it. Pop it with a value
/// (Navigator.pop(ctx, value)) to return one.
Future<T?> showFloatingCard<T>(
  BuildContext context, {
  required double width,
  required double height,
  required WidgetBuilder builder,
  BuildContext? anchor,
}) {
  _trackPointer();
  final screen = MediaQuery.sizeOf(context);
  final box = anchor?.findRenderObject() as RenderBox?;
  final at = (box != null && box.hasSize)
      ? box.localToGlobal(Offset.zero) & box.size
      : Rect.fromCenter(
          center: _lastPointer ?? screen.center(Offset.zero),
          width: 0,
          height: 0);
  final w = math.min(width, screen.width - 16);
  final h = math.min(height, screen.height - 16);
  final below = screen.height - at.bottom - 8 >= h;
  final onRight = at.center.dx > screen.width / 2;
  final left = (onRight ? at.right - w : at.left)
      .clamp(8.0, math.max(8.0, screen.width - w - 8));
  final top = (below ? at.bottom + 6 : at.top - h - 6)
      .clamp(8.0, math.max(8.0, screen.height - h - 8));
  final grow = Alignment(onRight ? 1 : -1, below ? -1 : 1);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.transparent,
    transitionDuration: Motion.standard,
    pageBuilder: (ctx, anim, _) {
      final scheme = Theme.of(ctx).colorScheme;
      final card = Material(
        color: scheme.surface,
        elevation: Depth.high,
        shadowColor: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(Radii.lg),
        clipBehavior: Clip.antiAlias,
        child: builder(ctx),
      );
      return Stack(children: [
        Positioned(
          left: left,
          top: top,
          width: w,
          height: h,
          child: AnimatedBuilder(
            animation: anim,
            child: card,
            builder: (_, child) {
              final v = Motion.enter.transform(anim.value);
              return Opacity(
                opacity: v,
                child: Transform.scale(
                    scale: 0.9 + 0.1 * v, alignment: grow, child: child),
              );
            },
          ),
        ),
      ]);
    },
    transitionBuilder: (ctx, a, _, child) => child,
  );
}

/// Open an emoji picker that inserts the tapped emoji into [controller] at the
/// cursor. Reusable anywhere a plain field wants emoji input (group name,
/// username, …) — especially handy on desktop, which has no on-screen emoji key.
Future<void> showEmojiPickerSheet(
    BuildContext context, TextEditingController controller) {
  final scheme = Theme.of(context).colorScheme;
  if (emojiFloats(context)) return _showEmojiCard(context, controller);
  return showAdaptiveSheet(
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
          onEmojiSelected: (_, _) => emojiStartTabRefresh(),
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
              initCategory: emojiStartTab(),
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
    BuildContext context, TextEditingController controller,
    {double height = 300}) {
  final scheme = Theme.of(context).colorScheme;
  return EmojiPicker(
    onEmojiSelected: (_, _) => emojiStartTabRefresh(),
    textEditingController: controller,
    config: Config(
      height: height,
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
        initCategory: emojiStartTab(),
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

/// The desktop card for a plain field: floats by its emoji button.
Future<void> _showEmojiCard(
        BuildContext context, TextEditingController controller) =>
    showFloatingCard<void>(context,
        anchor: context,
        width: 380,
        height: 300, // the inline picker's own height
        builder: (ctx) => inlineEmojiPicker(ctx, controller));

/// Every composer's 😊 / ⌨ (status, story reply, notes…) — the same rules as the chat composer:
/// desktop → the floating emoji card by the button; phone → the panel
/// trades places with the keyboard, and ⌨ goes straight back to typing.
/// Returns the new open state of the inline panel.
bool toggleComposerEmoji({
  required BuildContext button,
  required TextEditingController controller,
  required FocusNode focus,
  required bool open,
}) {
  if (emojiFloats(button)) {
    showEmojiPickerSheet(button, controller);
    return false;
  }
  if (!open) {
    FocusManager.instance.primaryFocus?.unfocus();
    return true;
  }
  focus.requestFocus();
  SystemChannels.textInput.invokeMethod<void>('TextInput.show');
  return false;
}
