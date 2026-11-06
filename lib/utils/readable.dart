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

/// An accent made LEGIBLE on Aluta's dark surfaces: deep picks (the brand
/// red #D90429, crimson, plum…) are too dark as text / thin icons on the
/// near-black background, so they're lifted — same hue and saturation, a
/// touch more lightness — until they reach 4.5:1 contrast. Already-bright
/// accents come back unchanged. Fills (buttons, bars, rings) look the same
/// colour family, only clearer.
Color liftForDark(Color c, {Color on = const Color(0xFF141011)}) {
  double contrast(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  if (contrast(c, on) >= 4.5) return c;
  var hsl = HSLColor.fromColor(c);
  for (var i = 0; i < 30 && contrast(hsl.toColor(), on) < 4.5; i++) {
    final l = hsl.lightness + 0.01;
    if (l > 0.72) break;
    hsl = hsl.withLightness(l);
  }
  return hsl.toColor();
}
