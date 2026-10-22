import 'package:flutter/material.dart';

/// Aluta's one colour palette — used by the app accent (Appearance), message
/// bubble colours and Our Space themes, so every picker shows the SAME
/// colours in the SAME places.
///
/// Nine families of six, each ordered deep → light, plus a Neon family of
/// twelve (two rows of six). Every swatch has a stable [AlutaSwatch.key]
/// (Our Space stores it on the server — never rename one; add new ones).
class AlutaSwatch {
  const AlutaSwatch(this.key, this.name, this.color);
  final String key;
  final String name;
  final Color color;
}

class AlutaFamily {
  const AlutaFamily(this.title, this.swatches, {this.glow = false});
  final String title;
  final List<AlutaSwatch> swatches;

  /// Neon: swatches glow like the colour they set.
  final bool glow;
}

const List<AlutaFamily> kAlutaFamilies = [
  AlutaFamily('Reds', [
    AlutaSwatch('red', 'Aluta red', Color(0xFFD90429)),
    AlutaSwatch('crimson', 'Crimson', Color(0xFFE11D48)),
    AlutaSwatch('punch', 'Punch', Color(0xFFF43F5E)),
    AlutaSwatch('coral', 'Coral', Color(0xFFFF5A5F)),
    AlutaSwatch('sunset', 'Sunset', Color(0xFFFB7185)),
    AlutaSwatch('blush', 'Blush', Color(0xFFFDA4AF)),
  ]),
  AlutaFamily('Pinks', [
    AlutaSwatch('fuchsia', 'Fuchsia', Color(0xFFD946EF)),
    AlutaSwatch('magenta', 'Magenta', Color(0xFFEC4899)),
    AlutaSwatch('rose', 'Rose', Color(0xFFFF4D8D)),
    AlutaSwatch('flamingo', 'Flamingo', Color(0xFFFF6FA3)),
    AlutaSwatch('bubblegum', 'Bubblegum', Color(0xFFFF7AC6)),
    AlutaSwatch('petal', 'Petal', Color(0xFFF9A8D4)),
  ]),
  AlutaFamily('Purples', [
    AlutaSwatch('grape', 'Grape', Color(0xFF9333EA)),
    AlutaSwatch('plum', 'Plum', Color(0xFF8B5CF6)),
    AlutaSwatch('orchid', 'Orchid', Color(0xFFA855F7)),
    AlutaSwatch('violet', 'Violet', Color(0xFF8E7CFF)),
    AlutaSwatch('mauve', 'Mauve', Color(0xFFC084FC)),
    AlutaSwatch('lavender', 'Lavender', Color(0xFFC4B5FD)),
  ]),
  AlutaFamily('Blues', [
    AlutaSwatch('cobalt', 'Cobalt', Color(0xFF2563EB)),
    AlutaSwatch('denim', 'Denim', Color(0xFF4F6FE5)),
    AlutaSwatch('indigo', 'Indigo', Color(0xFF6366F1)),
    AlutaSwatch('azure', 'Azure', Color(0xFF3B82F6)),
    AlutaSwatch('sky', 'Sky', Color(0xFF38BDF8)),
    AlutaSwatch('periwinkle', 'Periwinkle', Color(0xFF9DA8FF)),
  ]),
  AlutaFamily('Teals & cyans', [
    AlutaSwatch('teal', 'Teal', Color(0xFF1FB6A6)),
    AlutaSwatch('cyan', 'Cyan', Color(0xFF06B6D4)),
    AlutaSwatch('ocean', 'Ocean', Color(0xFF37B0E6)),
    AlutaSwatch('sea', 'Sea', Color(0xFF2DD4BF)),
    AlutaSwatch('aqua', 'Aqua', Color(0xFF22D3EE)),
    AlutaSwatch('mint', 'Mint', Color(0xFF6EE7B7)),
  ]),
  AlutaFamily('Greens', [
    AlutaSwatch('forest', 'Forest', Color(0xFF39B54A)),
    AlutaSwatch('emerald', 'Emerald', Color(0xFF10B981)),
    AlutaSwatch('moss', 'Moss', Color(0xFF5FA14A)),
    AlutaSwatch('olive', 'Olive', Color(0xFF9EB23B)),
    AlutaSwatch('lime', 'Lime', Color(0xFF84CC16)),
    AlutaSwatch('pistachio', 'Pistachio', Color(0xFFA3E635)),
  ]),
  AlutaFamily('Yellows', [
    AlutaSwatch('mustard', 'Mustard', Color(0xFFCA8A04)),
    AlutaSwatch('gold', 'Gold', Color(0xFFEAB308)),
    AlutaSwatch('saffron', 'Saffron', Color(0xFFF4C430)),
    AlutaSwatch('sun', 'Sun', Color(0xFFFACC15)),
    AlutaSwatch('honey', 'Honey', Color(0xFFFFD166)),
    AlutaSwatch('butter', 'Butter', Color(0xFFFDE68A)),
  ]),
  AlutaFamily('Oranges', [
    AlutaSwatch('amber', 'Amber', Color(0xFFF59E0B)),
    AlutaSwatch('marigold', 'Marigold', Color(0xFFF6A609)),
    AlutaSwatch('ember', 'Ember', Color(0xFFFF8A3D)),
    AlutaSwatch('tangerine', 'Tangerine', Color(0xFFFB923C)),
    AlutaSwatch('apricot', 'Apricot', Color(0xFFFFB877)),
    AlutaSwatch('peach', 'Peach', Color(0xFFFFB4A2)),
  ]),
  AlutaFamily('Neutrals', [
    AlutaSwatch('charcoal', 'Charcoal', Color(0xFF334155)),
    AlutaSwatch('graphite', 'Graphite', Color(0xFF475569)),
    AlutaSwatch('slate', 'Slate', Color(0xFF64748B)),
    AlutaSwatch('steel', 'Steel', Color(0xFF7C8AA0)),
    AlutaSwatch('mocha', 'Mocha', Color(0xFF8D6E63)),
    AlutaSwatch('sand', 'Sand', Color(0xFFC2A27A)),
  ]),
  AlutaFamily(
    'Neon',
    [
      AlutaSwatch('neon_red', 'Neon red', Color(0xFFFF073A)),
      AlutaSwatch('neon_pink', 'Neon pink', Color(0xFFFF2E88)),
      AlutaSwatch('neon_magenta', 'Neon magenta', Color(0xFFFF00E5)),
      AlutaSwatch('neon_purple', 'Neon purple', Color(0xFFB026FF)),
      AlutaSwatch('neon_violet', 'Neon violet', Color(0xFF7A00FF)),
      AlutaSwatch('neon_blue', 'Neon blue', Color(0xFF2D7DFF)),
      AlutaSwatch('neon_cyan', 'Neon cyan', Color(0xFF17E9E0)),
      AlutaSwatch('neon_mint', 'Neon mint', Color(0xFF00FFC6)),
      AlutaSwatch('neon_green', 'Neon green', Color(0xFF2BE86B)),
      AlutaSwatch('neon_lime', 'Neon lime', Color(0xFFC6FF00)),
      AlutaSwatch('neon_yellow', 'Neon yellow', Color(0xFFFFE500)),
      AlutaSwatch('neon_orange', 'Neon orange', Color(0xFFFF7A00)),
    ],
    glow: true,
  ),
];

/// Message bubbles also need calm paper / ink tones for readable chats.
const AlutaFamily kBubbleBasics = AlutaFamily('Basics', [
  AlutaSwatch('ink', 'Ink', Color(0xFF1F2430)),
  AlutaSwatch('night', 'Night', Color(0xFF2B3240)),
  AlutaSwatch('steel_soft', 'Steel', Color(0xFF5B6472)),
  AlutaSwatch('cool_paper', 'Cool paper', Color(0xFFE7E9EE)),
  AlutaSwatch('warm_paper', 'Warm paper', Color(0xFFF3EDE7)),
  AlutaSwatch('white', 'White', Color(0xFFFFFFFF)),
]);

/// Every palette swatch, in display order.
Iterable<AlutaSwatch> get alutaSwatches =>
    kAlutaFamilies.expand((f) => f.swatches);

AlutaSwatch? alutaSwatchFor(Color c) {
  for (final s in alutaSwatches) {
    if (s.color.toARGB32() == c.toARGB32()) return s;
  }
  return null;
}

/// Lays the families out the same way in every picker: a label and rows of
/// exactly six dots (Neon wraps to two even rows), dots sized to fit the
/// space so rows never break unevenly. Two balanced columns on wide screens
/// (left: the warm-to-cool spectrum, right: the rest), one column on phones
/// with the label on top.
class AlutaPaletteGrid extends StatelessWidget {
  const AlutaPaletteGrid({
    super.key,
    required this.dot,
    this.families = kAlutaFamilies,
    this.leading = const [],
  });

  /// Builds one dot at [size] (the caller owns selection + tap).
  final Widget Function(AlutaSwatch swatch, double size, bool glow) dot;
  final List<AlutaFamily> families;

  /// Extra families shown first (e.g. bubble Basics).
  final List<AlutaFamily> leading;

  static const double _gap = 10;
  static const int _perRow = 6;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final all = [...leading, ...families];
    return LayoutBuilder(builder: (context, c) {
      final twoCols = c.maxWidth >= 820;
      final labelW = twoCols ? 116.0 : (c.maxWidth >= 520 ? 116.0 : 0.0);
      final colW = twoCols ? (c.maxWidth - 28) / 2 : c.maxWidth;
      final dotsW = colW - labelW;
      final size = ((dotsW - _gap * (_perRow - 1)) / _perRow).clamp(26.0, 40.0);

      Widget rows(AlutaFamily f) {
        final chunks = <List<AlutaSwatch>>[];
        for (var i = 0; i < f.swatches.length; i += _perRow) {
          chunks.add(f.swatches.sublist(
              i, (i + _perRow).clamp(0, f.swatches.length)));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var r = 0; r < chunks.length; r++)
              Padding(
                padding: EdgeInsets.only(top: r == 0 ? 0 : _gap),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < chunks[r].length; i++) ...[
                      if (i > 0) const SizedBox(width: _gap),
                      dot(chunks[r][i], size, f.glow),
                    ],
                  ],
                ),
              ),
          ],
        );
      }

      Widget label(String t) => Text(t,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant));

      Widget family(AlutaFamily f) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: labelW == 0
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      label(f.title),
                      const SizedBox(height: 8),
                      rows(f),
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: labelW,
                        child: Padding(
                          padding: EdgeInsets.only(top: size / 2 - 8),
                          child: label(f.title),
                        ),
                      ),
                      rows(f),
                    ],
                  ),
          );

      Widget column(List<AlutaFamily> fs) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < fs.length; i++) ...[
                if (i > 0)
                  Divider(
                      height: 1,
                      color: scheme.outlineVariant.withValues(alpha: 0.35)),
                family(fs[i]),
              ],
            ],
          );

      if (!twoCols) return column(all);
      // Balance by rows: fill the left column until it holds about half.
      int rowsOf(AlutaFamily f) => (f.swatches.length / _perRow).ceil();
      final total = all.fold<int>(0, (n, f) => n + rowsOf(f));
      var acc = 0, split = 0;
      while (split < all.length && acc + rowsOf(all[split]) <= (total + 1) ~/ 2) {
        acc += rowsOf(all[split]);
        split++;
      }
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: column(all.sublist(0, split))),
            VerticalDivider(
                width: 28,
                color: scheme.outlineVariant.withValues(alpha: 0.35)),
            Expanded(child: column(all.sublist(split))),
          ],
        ),
      );
    });
  }
}
