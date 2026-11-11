import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart' show mergeSort;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/emoji_field.dart' show emojiStartTabRefresh;
import '../utils/motion.dart';
import '../utils/radii.dart';

/// Desktop quick emoji: type ":" and a couple of letters (":hea", ":smi")
/// and a strip of matches rises above the box, the ones you use most first.
/// Tab / Enter puts in the highlighted one, ↑ ↓ move along, Esc hides it,
/// a click picks any. The composer forwards its keys through [handleKey].
class EmojiColonSuggest extends StatefulWidget {
  const EmojiColonSuggest(
      {super.key,
      required this.controller,
      required this.focus,
      this.dark = false});
  final TextEditingController controller;
  final FocusNode focus;
  final bool dark; // on the black story / photo screens

  @override
  State<EmojiColonSuggest> createState() => EmojiColonSuggestState();
}

class EmojiColonSuggestState extends State<EmojiColonSuggest> {
  // ":" at the start or after a space, then 2+ word letters, up to the caret.
  static final _token =
      RegExp(r'(^|\s):([a-z0-9_+\-]{2,})$', caseSensitive: false);

  List<Emoji> _hits = const [];
  int _sel = 0;
  int _start = -1; // where the ":" sits
  int _seq = 0;
  String _hiddenFor = ''; // Esc hides it until the word changes

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
    widget.focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(covariant EmojiColonSuggest oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onText);
      widget.controller.addListener(_onText);
    }
    if (oldWidget.focus != widget.focus) {
      oldWidget.focus.removeListener(_onFocus);
      widget.focus.addListener(_onFocus);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    widget.focus.removeListener(_onFocus);
    super.dispose();
  }

  bool get showing => _hits.isNotEmpty;

  void _clear() {
    _seq++;
    if (_hits.isNotEmpty) setState(() => _hits = const []);
  }

  void _onFocus() {
    if (!widget.focus.hasFocus) _clear();
  }

  Future<void> _onText() async {
    final v = widget.controller.value;
    final sel = v.selection;
    if (!sel.isValid || !sel.isCollapsed || sel.baseOffset > v.text.length) {
      return _clear();
    }
    final m = _token.firstMatch(v.text.substring(0, sel.baseOffset));
    if (m == null) {
      _hiddenFor = '';
      return _clear();
    }
    final word = m.group(2)!;
    if (word == _hiddenFor) return _clear();
    _start = sel.baseOffset - word.length - 1;
    final seq = ++_seq;
    final utils = EmojiPickerUtils();
    final found = await utils.searchEmoji(
        word.replaceAll(RegExp(r'[_\-]'), ' '), defaultEmojiSet,
        checkPlatformCompatibility: false);
    final recents = (await utils.getRecentEmojis())
        .map((r) => r.emoji.emoji)
        .toList();
    if (!mounted || seq != _seq) return;
    // The ones you already use come first, in how often you use them.
    int rank(Emoji e) {
      final i = recents.indexOf(e.emoji);
      return i < 0 ? recents.length : i;
    }

    final sorted = [...found];
    mergeSort(sorted, compare: (a, b) => rank(a).compareTo(rank(b)));
    setState(() {
      _hits = sorted.take(8).toList();
      _sel = 0;
    });
  }

  void _pick(Emoji e) {
    final v = widget.controller.value;
    final caret = v.selection.baseOffset;
    if (_start < 0 || caret < _start || caret > v.text.length) return;
    final text = v.text.replaceRange(_start, caret, e.emoji);
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: _start + e.emoji.length),
    );
    _clear();
    widget.focus.requestFocus();
    emojiStartTabRefresh();
  }

  /// The composer calls this first in its onKeyEvent.
  KeyEventResult handleKey(KeyEvent event) {
    if (_hits.isEmpty || event is KeyUpEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.tab ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter) {
      if (event is KeyDownEvent) _pick(_hits[_sel]);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      setState(() => _sel = (_sel + 1) % _hits.length);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      setState(() => _sel = (_sel - 1 + _hits.length) % _hits.length);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      final m = _token.firstMatch(widget.controller.text
          .substring(0, widget.controller.selection.baseOffset
              .clamp(0, widget.controller.text.length)));
      _hiddenFor = m?.group(2) ?? '';
      _clear();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSize(
      duration: Motion.quick,
      curve: Motion.move,
      alignment: Alignment.bottomCenter,
      child: _hits.isEmpty
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
              child: Row(children: [
                for (var i = 0; i < _hits.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Tooltip(
                      message: _hits[i].name,
                      waitDuration: const Duration(milliseconds: 500),
                      child: Material(
                        color: i == _sel
                            ? scheme.primary
                                .withValues(alpha: widget.dark ? 0.30 : 0.14)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(Radii.md),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(Radii.md),
                          onTap: () => _pick(_hits[i]),
                          onHover: (h) {
                            if (h && _sel != i) setState(() => _sel = i);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 4),
                            child: Text(_hits[i].emoji,
                                style: const TextStyle(fontSize: 22)),
                          ),
                        ),
                      ),
                    ),
                  ),
                const Spacer(),
                Text('Tab ↵',
                    style: TextStyle(
                        fontSize: 11,
                        color: widget.dark
                            ? Colors.white60
                            : scheme.onSurfaceVariant)),
              ]),
            ),
    );
  }
}
