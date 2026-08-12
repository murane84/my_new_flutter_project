import 'package:flutter_linkify/flutter_linkify.dart';

/// Linkifies bare web addresses that DON'T start with `http(s)://` — i.e.
/// `www.example.com` and plain domains ending in a known TLD (`example.com`,
/// `foo.co`, `site.io/path`). Run this AFTER the built-in [UrlLinkifier] and
/// [EmailLinkifier] so real schemes and email addresses are already extracted;
/// it only upgrades the leftover plain text. The emitted URL has no scheme —
/// the opener prepends `https://` (see `_openLink` in chat_page).
///
/// A whitelist of TLDs keeps it from turning ordinary "e.g." / "3.5" / "a.m."
/// text into links; add TLDs here as needed.
class LooseUrlLinkifier extends Linkifier {
  const LooseUrlLinkifier();

  static final RegExp _re = RegExp(
    r'((?:www\.)?[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?'
    r'(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*'
    r'\.(?:com|co|net|org|io|app|dev|me|info|biz|gov|edu|ai|xyz|online|site|'
    r'tech|store|shop|blog|page|link|live|tv|fm|cc|tz|ke|ug|rw|za|ng|gh|uk|'
    r'us|ca|in|cn|ru|de|fr|es|it|nl|se|no|jp|br|au)'
    r'(?:/[^\s]*)?)',
    caseSensitive: false,
  );

  // Sentence punctuation that commonly trails a URL but isn't part of it.
  static const _trailing = '.,!?;:)]}"\'';

  @override
  List<LinkifyElement> parse(
      List<LinkifyElement> elements, LinkifyOptions options) {
    final out = <LinkifyElement>[];
    for (final el in elements) {
      if (el is! TextElement) {
        out.add(el);
        continue;
      }
      final text = el.text;
      final matches = _re.allMatches(text).toList();
      if (matches.isEmpty) {
        out.add(el);
        continue;
      }
      var last = 0;
      for (final m in matches) {
        if (m.start > last) {
          out.add(TextElement(text.substring(last, m.start)));
        }
        var url = m.group(0)!;
        var trail = '';
        while (url.isNotEmpty && _trailing.contains(url[url.length - 1])) {
          trail = url[url.length - 1] + trail;
          url = url.substring(0, url.length - 1);
        }
        if (url.isNotEmpty) {
          out.add(UrlElement(url, url));
        }
        if (trail.isNotEmpty) out.add(TextElement(trail));
        last = m.end;
      }
      if (last < text.length) {
        out.add(TextElement(text.substring(last)));
      }
    }
    return out;
  }
}
