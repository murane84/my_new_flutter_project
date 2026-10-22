import 'package:flutter/material.dart';

import 'bubble_theme.dart' show bubbleTintOn;

/// Ink for words and icons painted ON a coloured fill (an accent button, a
/// theme-coloured hero, a lit key…), in three tiers by how bright the fill is:
///  • darkish fills  → white ink
///  • normal fills   → a soft graphite (grey) ink
///  • shining fills (neon, pastel, butter…) → black ink
/// The cut between white and graphite sits where both read equally well
/// (relative luminance ≈ 0.21), so every tier keeps a readable contrast.
const Color kInkDark = Color(0xFF111114); // shining fills
const Color kInkGraphite = Color(0xFF2A2A30); // normal fills

Color readableOn(Color bg) {
  final l = bg.computeLuminance();
  if (l < 0.21) return Colors.white;
  if (l < 0.5) return kInkGraphite;
  return kInkDark;
}

/// True when [readableOn] gives white for [bg] (handy for shadows / glows).
bool inkIsLightOn(Color bg) => readableOn(bg) == Colors.white;

/// [tint] shaded (same hue) until it reads as text on [bg] — for accent-
/// coloured words on a light card, a white key, etc.
Color readableTint(Color tint, Color bg, {double min = 4.5}) =>
    bubbleTintOn(tint, bg, min: min);
