import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:linkify/linkify.dart' show linkify;
import '../../utils/loose_url_linkifier.dart';
import '../../utils/readable.dart' show accentInk;
import '../../services/song_names.dart';

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

/// The unicode glyph for a simple fraction like "1/2" → "½", or null if there
/// isn't a dedicated one. Used by the composer's live auto-convert.
String? fractionGlyph(String frac) => _fractionGlyphs[frac];

/// Public: swap simple "1/2"-style fractions for their unicode glyphs.
/// Used by the chat to spot a fraction-only message that should render big
/// and bubble-less, the same as a lone emoji.
String applyFractions(String s) => _applyFractions(s);

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

/// Who "me" is for @-mention highlighting. Set once the signed-in user's
/// Aluta username is known (home_page `_loadUserData`). A mention of me (or
/// "@all") renders as a filled chip so I can spot it at a glance.
class MentionSelf {
  MentionSelf._();
  static String? username;

  /// How *I* see each tagged member: lowercase Aluta username → the name I
  /// saved for them in my phone book (falls back to their profile name, i.e.
  /// the username itself, when they aren't saved). Filled by the chat page
  /// from the group's members. The message TEXT keeps the canonical
  /// "@username" (same for everyone); only the rendering is personal.
  static final Map<String, String> names = {};

  /// The reverse, for the composer: lowercase name I see (my phone-book
  /// name) → their username. The composer shows "@My Sister"; sending turns
  /// it back into the canonical "@username". Only unambiguous names.
  static final Map<String, String> usernameOfShown = {};

  /// Tapping a tag in a bubble (the open group chat sets this): gets the
  /// lower-case username ("all" for @all).
  static void Function(String key)? onTap;
}

// An @-mention token. The picker inserts the member's Aluta USERNAME (the same
// for every reader, unlike phone-book names), with any inner spaces joined by
// a non-breaking space (U+00A0) so "@John\u00A0Doe" stays one run. Only counts
// at the start of a word, so emails / "a@b" aren't highlighted, and trailing
// punctuation ("@Juma,") is left out of the token.
final RegExp _mentionRe = RegExp(
    r'(?<![^\s(\[{"\u0027])@[^\s@.,!?;:)\]}"\u0027]+(?:\u00A0[^\s@.,!?;:)\]}"\u0027]+)*',
    unicode: true);

/// The same @-tag pattern, for the chat page (composer → usernames).
RegExp get mentionTokenRe => _mentionRe;

/// True when [text] tags me (my username) or @all — drives the chat's "@"
/// stepper and badges.
bool mentionsMe(String text) {
  if (!text.contains('@')) return false;
  for (final m in _mentionRe.allMatches(text)) {
    if (_isSelfMention(m.group(0)!)) return true;
  }
  return false;
}

/// [text] with each "@username" shown the way *I* know that member — my
/// phone-book name, else their profile name (same rule as rendered bubbles).
/// For plain-text surfaces (the heart letter) that don't use the span renderer.
String displayMentions(String text) {
  if (!text.contains('@')) return text;
  return text.replaceAllMapped(_mentionRe, (m) {
    final tok = m.group(0)!;
    final key = tok.substring(1).replaceAll('\u00A0', ' ').toLowerCase();
    final shown = key == 'all' ? null : MentionSelf.names[key];
    return shown == null ? tok : '@$shown';
  });
}

bool _isSelfMention(String token) {
  final t = token.substring(1).replaceAll('\u00A0', ' ').toLowerCase();
  if (t == 'all') return true;
  final me = MentionSelf.username?.trim().toLowerCase();
  return me != null && me.isNotEmpty && t == me;
}

List<InlineSpan> _mentionize(
    String s, TextStyle base, TextStyle mentionStyle) {
  if (s.isEmpty || !s.contains('@')) {
    return [TextSpan(text: s, style: base)];
  }
  final out = <InlineSpan>[];
  int cursor = 0;
  for (final m in _mentionRe.allMatches(s)) {
    if (m.start > cursor) {
      out.add(TextSpan(text: s.substring(cursor, m.start), style: base));
    }
    final tok = m.group(0)!;
    final key = tok.substring(1).replaceAll('\u00A0', ' ').toLowerCase();
    final shown = key == 'all' ? null : MentionSelf.names[key];
    final label = shown == null ? tok : '@$shown';
    // Inside ==highlight== (a background of its own): plain accent text.
    if (mentionStyle.backgroundColor != null ||
        mentionStyle.background != null) {
      out.add(TextSpan(text: label, style: mentionStyle));
    } else {
      out.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: _MentionChip(
            label: label,
            base: base,
            mine: _isSelfMention(tok),
            tapKey: key),
      ));
    }
    cursor = m.end;
  }
  if (cursor < s.length) {
    out.add(TextSpan(text: s.substring(cursor), style: base));
  }
  return out;
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
      final mentionStyle =
          base.copyWith(color: linkStyle.color, fontWeight: FontWeight.w700);
      out.addAll(_mentionize(e.text, base, mentionStyle));
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
    this.searchTerm = '',
    this.searchBg,
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
  /// In-chat search: every case-insensitive occurrence is marked with
  /// [searchBg] (empty = off).
  final String searchTerm;
  final Color? searchBg;

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
        TextSpan(children: _markSearch(_spans(text, base))),
        textScaler: widget.textScaler ?? MediaQuery.textScalerOf(context),
      );

  // Split plain TextSpans around search matches (recognizers kept, so links
  // inside a match stay tappable). Matches straddling two spans aren't
  // marked — rare, and the bubble still flashes.
  List<InlineSpan> _markSearch(List<InlineSpan> spans) {
    final q = widget.searchTerm.toLowerCase();
    final bg = widget.searchBg;
    if (q.length < 2 || bg == null) return spans;
    InlineSpan walk(InlineSpan sp) {
      if (sp is! TextSpan) return sp;
      // A still-hidden spoiler stays hidden — a highlight would reveal it.
      if (sp.style?.background?.color == widget.spoilerCover) return sp;
      final kids = sp.children?.map(walk).toList();
      final t = sp.text;
      if (t == null || t.isEmpty || !t.toLowerCase().contains(q)) {
        return kids == null
            ? sp
            : TextSpan(
                text: t,
                style: sp.style,
                recognizer: sp.recognizer,
                children: kids);
      }
      final lower = t.toLowerCase();
      final parts = <InlineSpan>[];
      var at = 0;
      while (true) {
        final k = lower.indexOf(q, at);
        if (k < 0) break;
        if (k > at) {
          parts.add(TextSpan(text: t.substring(at, k), recognizer: sp.recognizer));
        }
        parts.add(TextSpan(
          text: t.substring(k, k + q.length),
          recognizer: sp.recognizer,
          style: TextStyle(
              backgroundColor: bg, fontWeight: FontWeight.w700),
        ));
        at = k + q.length;
      }
      if (at < t.length) {
        parts.add(TextSpan(text: t.substring(at), recognizer: sp.recognizer));
      }
      return TextSpan(
          style: sp.style,
          children: [...parts, ...?kids]);
    }

    return [for (final sp in spans) walk(sp)];
  }

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

// ── Live formatting inside the composer ─────────────────────────────────────
// A TextEditingController that styles the text AS YOU TYPE: the marked ranges
// render bold / italic / etc. and the markers themselves dim, like a code
// editor. The characters are preserved exactly (markers stay in the text), so
// the cursor and editing stay correct — only the STYLE changes. Fractions and
// marker-hiding are deliberately NOT applied here (that would change the text
// length and break the caret); they still render in the sent bubble.
class FormattingTextController extends TextEditingController {
  FormattingTextController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    final scheme = Theme.of(context).colorScheme;
    final onColor = base.color ?? scheme.onSurface;
    return TextSpan(
      style: base,
      children: _composerSpans(
        text,
        base,
        marker: onColor.withValues(alpha: 0.35),
        codeBg: onColor.withValues(alpha: 0.12),
        highlightBg: const Color(0x66FFC107),
        spoilerBg: scheme.primary.withValues(alpha: 0.16),
        mention: accentInk(scheme),
      ),
    );
  }

  /// A finished tag ("@all", "@Juma") goes in one backspace — like a chip —
  /// instead of letter by letter. A tag still being typed edits normally.
  @override
  set value(TextEditingValue v) {
    super.value = _wholeTagDelete(super.value, v) ?? v;
  }

  static TextEditingValue? _wholeTagDelete(
      TextEditingValue old, TextEditingValue v) {
    if (v.text.length != old.text.length - 1) return null;
    if (!old.selection.isCollapsed || !v.selection.isCollapsed) return null;
    final p = v.selection.baseOffset;
    if (p < 0 || old.selection.baseOffset != p + 1) return null;
    if (old.text.substring(0, p) + old.text.substring(p + 1) != v.text) {
      return null;
    }
    for (final m in _mentionRe.allMatches(old.text)) {
      if (m.end != p + 1) continue;
      final key =
          m.group(0)!.substring(1).replaceAll('\u00A0', ' ').toLowerCase();
      if (key != 'all' && !MentionSelf.names.containsKey(key)) return null;
      return TextEditingValue(
        text: old.text.replaceRange(m.start, m.end, ''),
        selection: TextSelection.collapsed(offset: m.start),
      );
    }
    return null;
  }
}

List<InlineSpan> _composerSpans(
  String s,
  TextStyle base, {
  required Color marker,
  required Color codeBg,
  required Color highlightBg,
  required Color spoilerBg,
  Color? mention,
}) {
  List<InlineSpan> recurse(String inner, TextStyle st) => _composerSpans(
        inner, st,
        marker: marker,
        codeBg: codeBg,
        highlightBg: highlightBg,
        spoilerBg: spoilerBg,
        mention: mention,
      );

  // Plain text, with any @-tag shown in the accent ink (the text itself is
  // untouched — the composer must keep every character where it is).
  List<InlineSpan> plain(String t, TextStyle st) {
    if (mention == null || !t.contains('@')) {
      return [TextSpan(text: t, style: st)];
    }
    final spans = <InlineSpan>[];
    var c = 0;
    for (final m in _mentionRe.allMatches(t)) {
      if (m.start > c) spans.add(TextSpan(text: t.substring(c, m.start), style: st));
      spans.add(TextSpan(
          text: m.group(0),
          style: st.copyWith(color: mention, fontWeight: FontWeight.w700)));
      c = m.end;
    }
    if (c < t.length) spans.add(TextSpan(text: t.substring(c), style: st));
    return spans;
  }

  final out = <InlineSpan>[];
  var cursor = 0;
  while (cursor < s.length) {
    _Found? found;
    for (var i = cursor; i < s.length; i++) {
      final m = _markerAt(s, i);
      if (m == null) continue;
      final close = s.indexOf(m.token, i + m.token.length);
      if (close < 0 || close <= i + m.token.length) continue;
      final inner = s.substring(i + m.token.length, close);
      if (inner.trim().isEmpty) continue;
      if (m.wordGuard && (inner.startsWith(' ') || inner.endsWith(' '))) {
        continue;
      }
      found = _Found(i, close, m, inner);
      break;
    }
    if (found == null) {
      out.addAll(plain(s.substring(cursor), base));
      break;
    }
    if (found.start > cursor) {
      out.addAll(plain(s.substring(cursor, found.start), base));
    }
    final tok = found.marker.token;
    final markerStyle = base.copyWith(color: marker);
    out.add(TextSpan(text: tok, style: markerStyle)); // opening delimiter

    if (found.marker.kind == 'code') {
      out.add(TextSpan(
        text: found.inner,
        style: base.copyWith(
          fontFamily: 'monospace',
          fontFamilyFallback: const ['monospace', 'Courier'],
          letterSpacing: 0,
          background: Paint()..color = codeBg,
        ),
      ));
    } else {
      TextStyle innerBase;
      switch (found.marker.kind) {
        case 'highlight':
          innerBase = base.copyWith(background: Paint()..color = highlightBg);
          break;
        case 'spoiler':
          innerBase = base.copyWith(background: Paint()..color = spoilerBg);
          break;
        case 'underline':
          innerBase = base.copyWith(
              decoration: _mergeDec(base.decoration, TextDecoration.underline));
          break;
        case 'bold':
          innerBase = base.copyWith(fontWeight: FontWeight.w700);
          break;
        case 'italic':
          innerBase = base.copyWith(fontStyle: FontStyle.italic);
          break;
        case 'strike':
          innerBase = base.copyWith(
              decoration:
                  _mergeDec(base.decoration, TextDecoration.lineThrough));
          break;
        default:
          innerBase = base;
      }
      out.addAll(recurse(found.inner, innerBase));
    }

    out.add(TextSpan(text: tok, style: markerStyle)); // closing delimiter
    cursor = found.close + tok.length;
  }
  return out;
}

// ── Plain-text strip (for chat-list previews, notifications, etc.) ───────────
String _stripInline(String s) {
  final out = StringBuffer();
  var cursor = 0;
  while (cursor < s.length) {
    _Found? found;
    for (var i = cursor; i < s.length; i++) {
      final m = _markerAt(s, i);
      if (m == null) continue;
      final close = s.indexOf(m.token, i + m.token.length);
      if (close < 0 || close <= i + m.token.length) continue;
      final inner = s.substring(i + m.token.length, close);
      if (inner.trim().isEmpty) continue;
      if (m.wordGuard && (inner.startsWith(' ') || inner.endsWith(' '))) {
        continue;
      }
      found = _Found(i, close, m, inner);
      break;
    }
    if (found == null) {
      out.write(s.substring(cursor));
      break;
    }
    out.write(s.substring(cursor, found.start));
    out.write(found.marker.kind == 'code'
        ? found.inner
        : _stripInline(found.inner));
    cursor = found.close + found.marker.token.length;
  }
  return out.toString();
}

/// Remove all formatting markers (and block prefixes) for a clean one-line
/// preview: `*Hello* _world_` → `Hello world`, `> quote` → `quote`,
/// `- item` → `item`, plus unicode fractions.
String stripMessageFormatting(String text) {
  final lines = text.split('\n').map((l) {
    final q = _quoteRe.firstMatch(l);
    if (q != null) return q.group(1) ?? '';
    final b = _bulletRe.firstMatch(l);
    if (b != null) return b.group(1) ?? '';
    final n = _numberRe.firstMatch(l);
    if (n != null) return n.group(2) ?? '';
    return l;
  });
  var s = _stripInline(lines.join(' '));
  s = _applyFractions(s);
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

// ── Styled one-line preview (chat list) ─────────────────────────────────────
List<InlineSpan> _previewInline(
  String s,
  TextStyle base, {
  required Color codeBg,
  required Color highlightBg,
  Color? mention,
}) {
  List<InlineSpan> recurse(String inner, TextStyle st) => _previewInline(
      inner, st,
      codeBg: codeBg, highlightBg: highlightBg, mention: mention);

  // Plain words, with @-tags in the accent ink (names as I know them).
  List<InlineSpan> plain(String t, TextStyle st) {
    t = _applyFractions(t);
    if (mention == null || !t.contains('@')) {
      return [TextSpan(text: t, style: st)];
    }
    final spans = <InlineSpan>[];
    var c = 0;
    for (final m in _mentionRe.allMatches(t)) {
      if (m.start > c) {
        spans.add(TextSpan(text: t.substring(c, m.start), style: st));
      }
      final tok = m.group(0)!;
      final key = tok.substring(1).replaceAll('\u00A0', ' ').toLowerCase();
      final shown = key == 'all' ? null : MentionSelf.names[key];
      spans.add(TextSpan(
          text: shown == null ? tok : '@$shown',
          style: st.copyWith(color: mention, fontWeight: FontWeight.w700)));
      c = m.end;
    }
    if (c < t.length) spans.add(TextSpan(text: t.substring(c), style: st));
    return spans;
  }

  final out = <InlineSpan>[];
  var cursor = 0;
  while (cursor < s.length) {
    _Found? found;
    for (var i = cursor; i < s.length; i++) {
      final m = _markerAt(s, i);
      if (m == null) continue;
      final close = s.indexOf(m.token, i + m.token.length);
      if (close < 0 || close <= i + m.token.length) continue;
      final inner = s.substring(i + m.token.length, close);
      if (inner.trim().isEmpty) continue;
      if (m.wordGuard && (inner.startsWith(' ') || inner.endsWith(' '))) {
        continue;
      }
      found = _Found(i, close, m, inner);
      break;
    }
    if (found == null) {
      out.addAll(plain(s.substring(cursor), base));
      break;
    }
    if (found.start > cursor) {
      out.addAll(plain(s.substring(cursor, found.start), base));
    }
    switch (found.marker.kind) {
      case 'code':
        out.add(TextSpan(
          text: found.inner,
          style: base.copyWith(
              fontFamily: 'monospace',
              fontFamilyFallback: const ['monospace', 'Courier'],
              background: Paint()..color = codeBg),
        ));
        break;
      case 'highlight':
        out.addAll(recurse(
            found.inner, base.copyWith(background: Paint()..color = highlightBg)));
        break;
      case 'underline':
        out.addAll(recurse(
            found.inner,
            base.copyWith(
                decoration:
                    _mergeDec(base.decoration, TextDecoration.underline))));
        break;
      case 'bold':
        out.addAll(
            recurse(found.inner, base.copyWith(fontWeight: FontWeight.w700)));
        break;
      case 'italic':
        out.addAll(
            recurse(found.inner, base.copyWith(fontStyle: FontStyle.italic)));
        break;
      case 'strike':
        out.addAll(recurse(
            found.inner,
            base.copyWith(
                decoration:
                    _mergeDec(base.decoration, TextDecoration.lineThrough))));
        break;
      case 'spoiler':
        // In a tiny list preview, just show the words (styled plain).
        out.addAll(recurse(found.inner, base));
        break;
    }
    cursor = found.close + found.marker.token.length;
  }
  return out;
}

/// Inline-styled spans for a single-line chat-list preview: *bold* _italic_
/// etc. render, markers are gone, blocks collapse to one line, fractions apply.
/// No links/recognizers (safe in a list that rebuilds constantly).
List<InlineSpan> previewSpans(
  String text,
  TextStyle base, {
  required Color codeBg,
  required Color highlightBg,
  Color? mention,
}) {
  final oneLine = text
      .split('\n')
      .map((l) {
        final q = _quoteRe.firstMatch(l);
        if (q != null) return q.group(1) ?? '';
        final b = _bulletRe.firstMatch(l);
        if (b != null) return '• ${b.group(1) ?? ''}';
        final n = _numberRe.firstMatch(l);
        if (n != null) return '${n.group(1) ?? ''}. ${n.group(2) ?? ''}';
        return l;
      })
      .join('  ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  // A leading type emoji (📞 Missed call, 🎵 Song, 📷 Photo…) becomes a real
  // icon: emoji glyphs take the preview's faded colour and some (🎵 is near
  // black on Windows) vanish on a dark theme. Icons stay crisp in both.
  // Tagged me (or @all) → a small accent "@" leads the line, so a mention
  // stands out in the list before the chat is even opened.
  final lead = <InlineSpan>[
    if (mention != null && mentionsMe(oneLine))
      TextSpan(
          text: '@ ',
          style: base.copyWith(color: mention, fontWeight: FontWeight.w900)),
  ];
  for (final e in _previewIcons.entries) {
    if (!oneLine.startsWith(e.key)) continue;
    var rest = oneLine.substring(e.key.length).trimLeft();
    // A song reads by its tidy name, as in the chat and the playlist
    // ("Nandy - Asante_064918" → "Asante — Nandy").
    if ((e.key == '🎵' || e.key == '🎶') && rest.isNotEmpty) {
      final i = rest.indexOf(' — ');
      if (i <= 0) {
        final n = SongNames.instance.parseName(rest);
        if (n.title.isNotEmpty) {
          rest = n.artist.isEmpty ? n.title : '${n.title} — ${n.artist}';
        }
      }
    }
    final low = rest.toLowerCase();
    final bad = e.key == '📞' &&
        const ['missed', 'declined', 'no answer', 'unreachable', 'failed',
               'busy', 'cancelled']
            .any(low.contains);
    final c = base.color ?? const Color(0xFF8A8A8A);
    final iconColor = bad
        ? const Color(0xFFE5484D) // readable red on light and dark
        : c.withValues(alpha: c.a < 0.78 ? 0.78 : c.a);
    final size = (base.fontSize ?? 12.5) + 1.5;
    return [
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Icon(
            bad && e.key == '📞' ? Icons.call_missed_rounded : e.value,
            size: size,
            color: iconColor,
          ),
        ),
      ),
      // A voice note gets a tiny waveform beside the mic: "🎤 ▁▃▅▂▄ 0:12".
      if (e.key == '🎤')
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(right: 5),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (final h in const [0.35, 0.7, 1.0, 0.55, 0.85, 0.4, 0.65])
                Container(
                  width: 2,
                  height: size * 0.8 * h,
                  margin: const EdgeInsets.symmetric(horizontal: 0.75),
                  decoration: BoxDecoration(
                    color: iconColor,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
            ]),
          ),
        ),
      ..._previewInline(rest, base,
          codeBg: codeBg, highlightBg: highlightBg, mention: mention),
    ];
  }
  return [
    ...lead,
    ..._previewInline(oneLine, base,
        codeBg: codeBg, highlightBg: highlightBg, mention: mention),
  ];
}

/// Preview type-emoji → icon (see [previewSpans]). ❤️ stays an emoji: it's
/// already a bright red glyph everywhere.
const Map<String, IconData> _previewIcons = {
  '📞': Icons.call_rounded,
  '🎵': Icons.music_note_rounded,
  '🎶': Icons.music_note_rounded,
  '🎧': Icons.headphones_rounded,
  '🎤': Icons.mic_rounded,
  '📷': Icons.photo_camera_rounded,
  '🎬': Icons.videocam_rounded,
  '🎞️': Icons.gif_box_rounded,
  '🎞': Icons.gif_box_rounded,
  '📎': Icons.attach_file_rounded,
  '📍': Icons.place_rounded,
  '📊': Icons.poll_rounded,
  '👤': Icons.person_rounded,
};

/// An @-mention in a bubble, the Aluta way: the name in the accent ink; when
/// it's me (or @all) a soft rounded accent pill around it — not a flat
/// highlighter box.
class _MentionChip extends StatelessWidget {
  const _MentionChip(
      {required this.label,
      required this.base,
      required this.mine,
      required this.tapKey});
  final String label;
  final TextStyle base;
  final bool mine;
  final String tapKey;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = accentInk(scheme);
    final text = Text(label,
        style: base.copyWith(
            color: ink, fontWeight: FontWeight.w700, height: 1.15));
    final tap = MentionSelf.onTap;
    Widget tappable(Widget w) => tap == null
        ? w
        : MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => tap(tapKey),
                child: w));
    if (!mine) return tappable(text);
    final dark = scheme.brightness == Brightness.dark;
    return tappable(Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0.5),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: dark ? 0.24 : 0.13),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
            color: scheme.primary.withValues(alpha: dark ? 0.40 : 0.24)),
      ),
      child: text,
    ));
  }
}
