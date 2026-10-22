import 'package:flutter/material.dart';

import 'bubble_theme.dart' show bubbleContrast, bubbleTintOn;

/// Text / icon colour for anything painted ON a coloured fill (an accent
/// button, a theme-coloured hero, a lit key…): white whenever it reads (≥3:1,
/// the large/bold-text bar), otherwise a near-black — so a pale theme like
/// Butter, Petal or Neon yellow never swallows its own labels.
const Color kInkDark = Color(0xFF17191C);

Color readableOn(Color bg) {
  final w = bubbleContrast(Colors.white, bg);
  if (w >= 3.0) return Colors.white;
  return bubbleContrast(kInkDark, bg) > w ? kInkDark : Colors.white;
}

/// [tint] shaded (same hue) until it reads as text on [bg] — for accent-
/// coloured words on a light card, a white key, etc.
Color readableTint(Color tint, Color bg, {double min = 4.5}) =>
    bubbleTintOn(tint, bg, min: min);
