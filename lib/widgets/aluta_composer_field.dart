import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/keystroke_sounds.dart';

/// The chat thread's composer pill, shared by every place you type a message
/// or caption (photo editor, file caption, new story…) so they all look,
/// feel and SOUND the same: the solid lifted pill, the thin brand ring +
/// soft glow while focused, and the keystroke ticks (Appearance setting).
///
/// [dark] forces the dark look on black screens (photo editor, story).
/// [leading] / [trailing] sit inside the pill, like the chat's emoji and "+".
/// [onSubmit]: desktop Enter sends (Shift/Ctrl+Enter = new line).
class AlutaComposerField extends StatefulWidget {
  const AlutaComposerField({
    super.key,
    required this.controller,
    this.hint = 'Message',
    this.focusNode,
    this.minLines = 1,
    this.maxLines = 5,
    this.autofocus = false,
    this.dark,
    this.leading,
    this.trailing,
    this.onSubmit,
    this.onTap,
    this.sendOnAction = false,
  });

  /// The keyboard's action key sends (a quick room chat) instead of adding
  /// a new line.
  final bool sendOnAction;

  final TextEditingController controller;
  final String hint;
  final FocusNode? focusNode;
  final int minLines, maxLines;
  final bool autofocus;
  final bool? dark;
  final Widget? leading, trailing;
  final VoidCallback? onSubmit;
  final VoidCallback? onTap;

  @override
  State<AlutaComposerField> createState() => _AlutaComposerFieldState();
}

class _AlutaComposerFieldState extends State<AlutaComposerField> {
  FocusNode? _own;
  FocusNode get _focus => widget.focusNode ?? (_own ??= FocusNode());
  int _lastLen = 0;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    KeystrokeSounds.instance.init();
    _lastLen = widget.controller.text.length;
    widget.controller.addListener(_onText);
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(AlutaComposerField old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onText);
      widget.controller.addListener(_onText);
      _lastLen = widget.controller.text.length;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    _focus.removeListener(_onFocus);
    _own?.dispose();
    super.dispose();
  }

  // Same rule as the chat composer: longer → tick, shorter → tock.
  void _onText() {
    final len = widget.controller.text.length;
    if (len > _lastLen) {
      KeystrokeSounds.instance.playType();
    } else if (len < _lastLen) {
      KeystrokeSounds.instance.playDelete();
    }
    _lastLen = len;
  }

  void _onFocus() {
    if (mounted && _focus.hasFocus != _focused) {
      setState(() => _focused = _focus.hasFocus);
    }
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final isDark = widget.dark ?? base.brightness == Brightness.dark;
    final primary = base.colorScheme.primary;
    final scheme = base.colorScheme;
    // Forced dark on a light theme (black editor screens): Aluta's dark
    // surface; otherwise the theme's own surface, as in the chat.
    final darkBase = base.brightness == Brightness.dark
        ? scheme.surface
        : const Color(0xFF1E1B20);
    final surface = isDark
        ? Color.alphaBlend(Colors.white.withValues(alpha: 0.06), darkBase)
        : scheme.surface;
    final onColor = isDark ? Colors.white : scheme.onSurface;

    Widget field = TextField(
      controller: widget.controller,
      focusNode: _focus,
      autofocus: widget.autofocus,
      minLines: widget.minLines,
      maxLines: widget.maxLines,
      onTap: widget.onTap,
      textInputAction: widget.sendOnAction
          ? TextInputAction.send
          : TextInputAction.newline,
      keyboardType: TextInputType.multiline,
      onSubmitted: widget.sendOnAction && widget.onSubmit != null
          ? (_) => widget.onSubmit!()
          : null,
      cursorColor: primary,
      style: TextStyle(color: onColor, fontSize: 15),
      decoration: InputDecoration(
        hintText: widget.hint,
        hintMaxLines: 1,
        hintStyle: TextStyle(
            color: (isDark ? Colors.white : scheme.onSurfaceVariant)
                .withValues(alpha: isDark ? 0.55 : 0.7)),
        isDense: true,
        // The pill IS the field — no inner box from the app input theme.
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        contentPadding:
            const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      ),
    );
    if (widget.onSubmit != null) {
      field = Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.enter &&
              !HardwareKeyboard.instance.isShiftPressed &&
              !HardwareKeyboard.instance.isControlPressed) {
            widget.onSubmit!();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: field,
      );
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
            width: 1.0,
            color: _focused
                ? primary.withValues(alpha: isDark ? 0.55 : 0.45)
                : (isDark
                    ? Colors.white.withValues(alpha: 0.10)
                    : Colors.black.withValues(alpha: 0.06))),
        boxShadow: [
          if (_focused)
            BoxShadow(
              color: primary.withValues(alpha: isDark ? 0.14 : 0.08),
              blurRadius: 8,
            ),
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.16),
            blurRadius: 16,
            offset: const Offset(0, 5),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.06),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: IconTheme.merge(
        data: IconThemeData(
            color: isDark ? Colors.white70 : scheme.onSurfaceVariant),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (widget.leading != null)
              widget.leading!
            else
              const SizedBox(width: 14),
            Expanded(child: field),
            if (widget.trailing != null)
              widget.trailing!
            else
              const SizedBox(width: 14),
          ],
        ),
      ),
    );
  }
}
