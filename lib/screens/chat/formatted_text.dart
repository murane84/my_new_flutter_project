import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:linkify/linkify.dart' show linkify;
import '../../utils/loose_url_linkifier.dart';

/// Renders a chat message with lightweight, WhatsApp/Telegram-style formatting:
///   *bold*  _italic_  ~strike~  __underline__  `code`  ==highlight==  ||spoiler||
/// plus block quotes (`> `), bulleted (`- ` / `* ` / `• `) and numbered
/// (`1. ` / `1) `) lists, auto-linked URLs/emails, and unicode fractions
/// (1/2 → ½, …). Spoilers are tappable to reveal (state lives here).
typedef LinkTap = void Function(String url);

const Map<String, String> _fractionGlyphs = {
  '1/2': '½', '1/3': '⅓', '2/3': '⅔', '1/4': '¼', '3/4': '¾',
  '1/5': '⅕', '2/5': '⅖', '3/5': '⅗', '4/5': '⅘', '1/6': '⅙',
  '5/6': '⅚', '1/7': '⅐', '1/8': '⅛', '3/8': '⅜', '5/8': '⅝',
  '7/8': '⅞', '1/9': '⅑', '1/10': '⅒',
};
final RegExp _fractionRe = RegExp(r'\b(\d{1,3})/(\d{1,3})\b');

String _applyFractions(String s) {
  if (!s.contains('/')) return s;
  return s.replaceAllMapped(
      _fractionRe, (m) => _fractionGlyphs[m.group(0)] ?? m.group(0)!);
}

TextDecoration _mergeDec(TextDecoration? a, TextDecoration b) {
  if (a == null || a == TextDecoration.none) return b;
  return TextDecoration.combine([a, b]);
}

/// A tiny mutable counter so a message's spoilers keep stable ids across
/// rebuilds (nth spoiler = id n), which is what makes "revealed" persist.
class _SpoilerCtr {
  int n = 0;
}

class _Marker {
  const _Marker(this.token, this.kind, {this.wordGuard = false});
  final String token;
  final String kind; // bold|italic|strike|underline|code|highlight|spoiler
  final bool wordGuard;
}

// 2-char tokens are tested before 1-char so `__`/`==`/`||` win over `_`/…
const List<_Marker> _markers = [
  _Marker('||', 'spoiler'),
  _Marker('==', 'highlight'),
  _Marker('__', 'underline'),
  _Marker('`', 'code'),
  _Marker('*', 'bold', wordGuard: true),
  _Marker('_', 'italic', wordGuard: true),
  _Marker('~', 'strike', wordGuard: true),
];

_Marker? _markerAt(String s, int i) {
  for (final m in _markers) {
    if (i + m.token.length <= s.length &&
        s.startsWith(m.token, i)) {
      return m;
    }
  }
  return null;
}

class _Found {
  _Found(this.start, this.close, this.marker, this.inner);
  final int start;
  final int close;
  final _Marker marker;
  final String inner;
}

/// Linkify-aware plain run → spans (also applies fraction glyphs).
List<InlineSpan> _plain(
  String s,
  TextStyle base, {
  required TextStyle linkStyle,
  required LinkTap onOpenLink,
  List<TapGestureRecognizer>? sink,
}) {
  if (s.isEmpty) return const [];
  final s2 = _applyFractions(s);
  final elements = linkify(
    s2,
    options: const LinkifyOptions(humanize: false),
    linkifiers: const [UrlLinkifier(), EmailLinkifier(), LooseUrlLinkifier()],
  );
  final out = <InlineSpan>[];
  for (final e in elements) {
    if (e is LinkableElement) {
      final rec = TapGestureRecognizer()..onTap = () => onOpenLink(e.url);
      sink?.add(rec);
      out.add(TextSpan(
          text: e.text,
          style: linkStyle.copyWith(background: base.background),
          recognizer: rec));
    } else {
      out.add(TextSpan(text: e.text, style: base));
    }
  }
  return out;
}

List<InlineSpan> _parseInline(
  String s,
  TextStyle base, {
  required TextStyle linkStyle,
  required LinkTap onOpenLink,
  required Color codeBg,
  required Color highlightBg,
  required Color spoilerCover,
  List<TapGestureRecognizer>? sink,
  Set<int>? revealed,
  void Function(int id)? onToggleSpoiler,
  _SpoilerCtr? ctr,
}) {
  final out = <InlineSpan>[];
  var cursor = 0;
  while (cursor < s.length) {
    _Found? found;
    for (var i = cursor; i < s.length; i++) {
      final m = _markerAt(s, i);
      if (m == null) continue;
      final close = s.indexOf(m.token, i + m.token.length);
      if (close < 0 || close <= i + m.token.length) continue; // empty
      final inner = s.substring(i + m.token.length, close);
      if (inner.trim().isEmpty) continue;
      if (m.wordGuard && (inner.startsWith(' ') || inner.endsWith(' '))) {
        continue;
      }
      found = _Found(i, close, m, inner);
      break;
    }
    if (found == null) {
      out.addAll(_plain(s.substring(cursor), base,
          linkStyle: linkStyle, onOpenLink: onOpenLink, sink: sink));
      break;
    }
    if (found.start > cursor) {
      out.addAll(_plain(s.substring(cursor, found.start), base,
          linkStyle: linkStyle, onOpenLink: onOpenLink, sink: sink));
    }

    List<InlineSpan> recurse(TextStyle st) => _parseInline(found!.inner, st,
        linkStyle: linkStyle,
        onOpenLink: onOpenLink,
        codeBg: codeBg,
        highlightBg: highlightBg,
        spoilerCover: spoilerCover,
        sink: sink,
        revealed: revealed,
        onToggleSpoiler: onToggleSpoiler,
        ctr: ctr);

    switch (found.marker.kind) {
      case 'code':
        out.add(TextSpan(
          text: found.inner,
          style: base.copyWith(
            fontFamily: 'monospace',
            fontFamilyFallback: const ['monospace', 'Courier'],
            letterSpacing: 0,
            background: Paint()..color = codeBg,
          ),
        ));
        break;
      case 'highlight':
        out.addAll(recurse(base.copyWith(background: Paint()..color = highlightBg)));
        break;
      case 'underline':
        out.addAll(recurse(base.copyWith(
            decoration: _mergeDec(base.decoration, TextDecoration.underline))));
        break;
      case 'bold':
        out.addAll(recurse(base.copyWith(fontWeight: FontWeight.w700)));
        break;
      case 'italic':
        out.addAll(recurse(base.copyWith(fontStyle: FontStyle.italic)));
        break;
      case 'strike':
        out.addAll(recurse(base.copyWith(
            decoration: _mergeDec(base.decoration, TextDecoration.lineThrough))));
        break;
      case 'spoiler':
        final id = (ctr?.n ?? 0);
        if (ctr != null) ctr.n++;
        final isRevealed = revealed?.contains(id) ?? false;
        if (isRevealed) {
          out.addAll(recurse(base));
        } else {
          TapGestureRecognizer? rec;
          if (onToggleSpoiler != null) {
            rec = TapGestureRecognizer()..onTap = () => onToggleSpoiler(id);
            sink?.add(rec);
          }
          out.add(TextSpan(
            text: found.inner,
            style: base.copyWith(
              color: spoilerCover,
              background: Paint()..color = spoilerCover,
            ),
            recognizer: rec,
          ));
        }
        break;
    }
    cursor = found.close + found.marker.token.length;
  }
  return out;
}

// ── Block model ─────────────────────────────────────────────────────────────
enum _BlockKind { paragraph, bullets, numbers, quote }

class _Block {
  _Block(this.kind, {this.text = '', List<String>? items, List<int>? nums})
      : items = items ?? const [],
        nums = nums ?? const [];
  final _BlockKind kind;
  final String text;
  final List<String> items;
  final List<int> nums;
}

final RegExp _bulletRe = RegExp(r'^\s*[-*•]\s+(.*)$');
final RegExp _numberRe = RegExp(r'^\s*(\d{1,3})[.)]\s+(.*)$');
final RegExp _quoteRe = RegExp(r'^>\s?(.*)$');

List<_Block> _parseBlocks(String text) {
  final lines = text.split('\n');
  final blocks = <_Block>[];
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final q = _quoteRe.firstMatch(line);
    final b = _bulletRe.firstMatch(line);
    final n = _numberRe.firstMatch(line);
    if (q != null) {
      final buf = <String>[];
      while (i < lines.length) {
        final mm = _quoteRe.firstMatch(lines[i]);
        if (mm == null) break;
        buf.add(mm.group(1) ?? '');
        i++;
      }
      blocks.add(_Block(_BlockKind.quote, text: buf.join('\n')));
    } else if (b != null) {
      final items = <String>[];
      while (i < lines.length) {
        final mm = _bulletRe.firstMatch(lines[i]);
        if (mm == null) break;
        items.add(mm.group(1) ?? '');
        i++;
      }
      blocks.add(_Block(_BlockKind.bullets, items: items));
    } else if (n != null) {
      final items = <String>[];
      final nums = <int>[];
      while (i < lines.length) {
        final mm = _numberRe.firstMatch(lines[i]);
        if (mm == null) break;
        nums.add(int.tryParse(mm.group(1) ?? '') ?? (nums.length + 1));
        items.add(mm.group(2) ?? '');
        i++;
      }
      blocks.add(_Block(_BlockKind.numbers, items: items, nums: nums));
    } else {
      final buf = <String>[];
      while (i < lines.length &&
          _quoteRe.firstMatch(lines[i]) == null &&
          _bulletRe.firstMatch(lines[i]) == null &&
          _numberRe.firstMatch(lines[i]) == null) {
        buf.add(lines[i]);
        i++;
      }
      blocks.add(_Block(_BlockKind.paragraph, text: buf.join('\n')));
    }
  }
  return blocks;
}

bool messageHasBlocks(String text) =>
    text.split('\n').any((l) =>
        _quoteRe.hasMatch(l) ||
        _bulletRe.hasMatch(l) ||
        _numberRe.hasMatch(l));

class FormattedText extends StatefulWidget {
  const FormattedText({
    super.key,
    required this.text,
    required this.style,
    required this.linkStyle,
    required this.onOpenLink,
    required this.codeBg,
    required this.highlightBg,
    required this.spoilerCover,
    required this.quoteBar,
    this.selectable = false,
    this.textScaler,
  });

  final String text;
  final TextStyle style;
  final TextStyle linkStyle;
  final LinkTap onOpenLink;
  final Color codeBg;
  final Color highlightBg;
  final Color spoilerCover;
  final Color quoteBar;
  final bool selectable;
  final TextScaler? textScaler;

  @override
  State<FormattedText> createState() => _FormattedTextState();
}

class _FormattedTextState extends State<FormattedText> {
  final Set<int> _revealed = {};
  final List<TapGestureRecognizer> _recognizers = [];
  final _SpoilerCtr _ctr = _SpoilerCtr();

  void _clearRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clearRecognizers();
    super.dispose();
  }

  List<InlineSpan> _spans(String text, TextStyle base) => _parseInline(
        text,
        base,
        linkStyle: widget.linkStyle,
        onOpenLink: widget.onOpenLink,
        codeBg: widget.codeBg,
        highlightBg: widget.highlightBg,
        spoilerCover: widget.spoilerCover,
        sink: _recognizers,
        revealed: _revealed,
        onToggleSpoiler: (id) => setState(() {
          if (!_revealed.remove(id)) _revealed.add(id);
        }),
        ctr: _ctr,
      );

  Widget _rich(String text, TextStyle base) => Text.rich(
        TextSpan(children: _spans(text, base)),
        textScaler: widget.textScaler ?? MediaQuery.textScalerOf(context),
      );

  @override
  Widget build(BuildContext context) {
    _clearRecognizers();
    _ctr.n = 0;
    final blocks = _parseBlocks(widget.text);
    final children = <Widget>[];
    for (var bi = 0; bi < blocks.length; bi++) {
      final b = blocks[bi];
      final topGap = bi == 0 ? 0.0 : 3.0;
      switch (b.kind) {
        case _BlockKind.paragraph:
          children.add(Padding(
            padding: EdgeInsets.only(top: topGap),
            child: _rich(b.text, widget.style),
          ));
          break;
        case _BlockKind.bullets:
          children.add(Padding(
            padding: EdgeInsets.only(top: topGap),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final it in b.items)
                  Padding(
                    padding: const EdgeInsets.only(top: 1, bottom: 1),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 6, left: 2),
                          child: Text('•', style: widget.style),
                        ),
                        Flexible(child: _rich(it, widget.style)),
                      ],
                    ),
                  ),
              ],
            ),
          ));
          break;
        case _BlockKind.numbers:
          children.add(Padding(
            padding: EdgeInsets.only(top: topGap),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var k = 0; k < b.items.length; k++)
                  Padding(
                    padding: const EdgeInsets.only(top: 1, bottom: 1),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 6, left: 2),
                          child: Text('${b.nums[k]}.', style: widget.style),
                        ),
                        Flexible(child: _rich(b.items[k], widget.style)),
                      ],
                    ),
                  ),
              ],
            ),
          ));
          break;
        case _BlockKind.quote:
          children.add(Padding(
            padding: EdgeInsets.only(top: topGap, bottom: 1),
            child: Container(
              padding: const EdgeInsets.only(left: 9),
              decoration: BoxDecoration(
                border: Border(
                    left: BorderSide(color: widget.quoteBar, width: 3)),
              ),
              child: _rich(
                b.text,
                widget.style.copyWith(
                    color: widget.style.color?.withValues(alpha: 0.82),
                    fontStyle: FontStyle.italic),
              ),
            ),
          ));
          break;
      }
    }
    Widget col = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
    if (widget.selectable) col = SelectionArea(child: col);
    return col;
  }
}
