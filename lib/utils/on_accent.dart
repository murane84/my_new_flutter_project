import 'package:flutter/material.dart';

/// White or near-black, whichever reads on [c] — for icons / text on a solid
/// accent fill. Works for every theme colour, in light and dark mode (a tint
/// of the accent under an accent-coloured icon vanished on some themes).
Color onAccent(Color c) =>
    ThemeData.estimateBrightnessForColor(c) == Brightness.dark
        ? Colors.white
        : const Color(0xFF1C1B1F);
