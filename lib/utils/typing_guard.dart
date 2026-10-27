import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// True while the keyboard focus is inside a text field — so page-level key
/// shortcuts (Space = pause, ←/→ = skip) must stand aside and let the keys
/// type. A shortcut that "handles" a key even with an early return swallows
/// the character on desktop (that's how Space stopped typing in replies).
bool isTypingInTextField() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  if (ctx.widget is EditableText) return true;
  return ctx.findAncestorStateOfType<EditableTextState>() != null;
}

/// [CallbackShortcuts] that steps aside while a text field has focus: the key
/// goes to the field instead (Esc still works, so a reply box can be left).
class TypingSafeShortcuts extends StatelessWidget {
  const TypingSafeShortcuts({
    super.key,
    required this.bindings,
    required this.child,
  });

  final Map<ShortcutActivator, VoidCallback> bindings;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is KeyUpEvent) return KeyEventResult.ignored;
        final typing = isTypingInTextField();
        for (final b in bindings.entries) {
          if (b.key.accepts(event, HardwareKeyboard.instance)) {
            if (typing && event.logicalKey != LogicalKeyboardKey.escape) {
              return KeyEventResult.ignored;
            }
            b.value();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}
