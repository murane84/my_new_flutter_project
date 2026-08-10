import 'package:flutter/material.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';

/// Open an emoji picker that inserts the tapped emoji into [controller] at the
/// cursor. Reusable anywhere a plain field wants emoji input (group name,
/// username, …) — especially handy on desktop, which has no on-screen emoji key.
Future<void> showEmojiPickerSheet(
    BuildContext context, TextEditingController controller) {
  final scheme = Theme.of(context).colorScheme;
  return showModalBottomSheet(
    context: context,
    backgroundColor: scheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => SafeArea(
      top: false,
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
  );
}

/// A ready-made emoji button for a TextField's suffixIcon.
Widget emojiSuffixButton(
    BuildContext context, TextEditingController controller) {
  return IconButton(
    icon: const Icon(Icons.emoji_emotions_outlined),
    tooltip: 'Add emoji',
    onPressed: () => showEmojiPickerSheet(context, controller),
  );
}
