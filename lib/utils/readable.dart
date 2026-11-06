import 'package:flutter/material.dart';

import 'bubble_theme.dart' show bubbleTintOn;

/// Ink for words and icons painted ON a coloured fill (an accent button, a
/// theme-coloured hero, a lit key…), in three tiers by how bright the fill is:
///  • darkish fills  → white ink
///  • normal fills   → a soft graphite (grey) ink
///  • shining fills (neon, pastel, butter…) → black ink
/// The cut between white and graphite sits where both read equally well
/// (relative luminance ≈ 0.227), so every tier keeps a readable contrast.
const Color kInkDark = Color(0xFF111114); // shining fills
const Color kInkGraphite = Color(0xFF2A2A30); // normal fills

Color readableOn(Color bg) {
  final l = bg.computeLuminance();
  if (l < 0.227) return Colors.white;
  if (l < 0.5) return kInkGraphite;
  return kInkDark;
}

/// True when [readableOn] gives white for [bg] (handy for shadows / glows).
bool inkIsLightOn(Color bg) => readableOn(bg) == Colors.white;

/// [tint] shaded (same hue) until it reads as text on [bg] — for accent-
/// coloured words on a light card, a white key, etc.
Color readableTint(Color tint, Color bg, {double min = 4.5}) =>
    bubbleTintOn(tint, bg, min: min);

/// The accent for WORDS and thin icons. Fills (buttons, badges, rings, bars)
/// keep the accent's full strength; but a deep accent — Aluta red, neon red,
/// crimson, plum, navy… — is hard to read as text on Aluta's near-black dark
/// surface. On dark, such an accent is washed toward white (a soft pink for
/// the reds, a pastel of the same hue for others) just until it reads clearly
/// (5:1). Light mode, and accents that already read, come back unchanged.
Color accentInk(ColorScheme s) {
  if (s.brightness != Brightness.dark) return s.primary;
  final key = '${s.primary.toARGB32()}/${s.surface.toARGB32()}';
  return _inkCache[key] ??= _washToRead(s.primary, s.surface);
}

final Map<String, Color> _inkCache = <String, Color>{};

Color _washToRead(Color c, Color on) {
  double contrast(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  if (contrast(c, on) >= 5.0) return c;
  for (var t = 0.05; t <= 0.9; t += 0.05) {
    final x = Color.lerp(c, Colors.white, t)!;
    if (contrast(x, on) >= 5.0) return x;
  }
  return Color.lerp(c, Colors.white, 0.9)!;
}
