import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-chosen message-bubble colours.
///
/// When [bubbleCustomEnabled] is false the chat uses the built-in brand theme
/// (rose/maroon for "me", neutral for "them"). When true, every chat paints
/// outgoing bubbles [bubbleSentColor] and incoming bubbles [bubbleRecvColor],
/// with text, links and ticks derived automatically for legibility — so the
/// same pick reads correctly in both light and dark mode.
///
/// Bumped whenever the bubble theme changes so open chats repaint live.
final ValueNotifier<int> bubbleThemeRevision = ValueNotifier<int>(0);

const String _kBubbleCustom = 'bubble_custom_v1';
const String _kBubbleSent = 'bubble_sent_color_v1';
const String _kBubbleRecv = 'bubble_recv_color_v1';

// Pleasant seeds shown the first time the user opens the picker: a soft brand
// rose for "me" and a cool slate for "them". These are only the *starting*
// swatches — the user can pick anything.
const int _kDefaultSent = 0xFFEF5F6B; // warm brand rose/red
const int _kDefaultRecv = 0xFF2B3240; // cool slate

bool _custom = false;
int _sent = _kDefaultSent;
int _recv = _kDefaultRecv;

bool get bubbleCustomEnabled => _custom;
Color get bubbleSentColor => Color(_sent);
Color get bubbleRecvColor => Color(_recv);

/// Load the saved bubble theme. Call once at startup alongside the other
/// preference loaders.
Future<void> loadBubbleTheme() async {
  try {
    final p = await SharedPreferences.getInstance();
    _custom = p.getBool(_kBubbleCustom) ?? false;
    _sent = p.getInt(_kBubbleSent) ?? _kDefaultSent;
    _recv = p.getInt(_kBubbleRecv) ?? _kDefaultRecv;
  } catch (_) {
    // Keep the defaults on any read failure.
  }
  bubbleThemeRevision.value++;
}

Future<void> setBubbleCustomEnabled(bool v) async {
  _custom = v;
  bubbleThemeRevision.value++;
  try {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kBubbleCustom, v);
  } catch (_) {}
}

Future<void> setBubbleSentColor(Color c) async {
  _sent = _argb(c);
  bubbleThemeRevision.value++;
  try {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kBubbleSent, _sent);
  } catch (_) {}
}

Future<void> setBubbleRecvColor(Color c) async {
  _recv = _argb(c);
  bubbleThemeRevision.value++;
  try {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kBubbleRecv, _recv);
  } catch (_) {}
}

/// Turn the custom theme off and restore the seed swatches.
Future<void> resetBubbleTheme() async {
  _custom = false;
  _sent = _kDefaultSent;
  _recv = _kDefaultRecv;
  bubbleThemeRevision.value++;
  try {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kBubbleCustom, false);
    await p.setInt(_kBubbleSent, _sent);
    await p.setInt(_kBubbleRecv, _recv);
  } catch (_) {}
}

int _argb(Color c) =>
    (((c.a * 255).round() & 0xff) << 24) |
    (((c.r * 255).round() & 0xff) << 16) |
    (((c.g * 255).round() & 0xff) << 8) |
    ((c.b * 255).round() & 0xff);

/// WCAG contrast ratio between two opaque colours (1 = none, 21 = max).
double bubbleContrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Color _bestOn(Color bg, List<Color> candidates) {
  var best = candidates.first;
  var bestC = 0.0;
  for (final c in candidates) {
    final r = bubbleContrast(Color.alphaBlend(c, bg), bg);
    if (r > bestC) {
      bestC = r;
      best = c;
    }
  }
  return best;
}

/// A readable text colour for content painted on [bg]: whichever of near-black
/// or near-white contrasts MORE with it. (A plain luminance cut-off picked white
/// on mid tones like amber or teal, where it was hard to read.)
Color bubbleTextOn(Color bg) =>
    _bestOn(bg, const [Color(0xFF17191C), Color(0xFFF4F1F2)]);

/// A muted variant of the on-bubble text colour, for timestamps, "edited" and
/// the sent/delivered ticks — faded, but never below a readable contrast.
Color bubbleMutedOn(Color bg) {
  final base = bubbleTextOn(bg);
  for (var a = 0.6; a < 1.0; a += 0.05) {
    final c = base.withValues(alpha: a);
    if (bubbleContrast(Color.alphaBlend(c, bg), bg) >= 3.4) return c;
  }
  return base;
}

/// The blue "read" double-tick, picked to stand out on [bg]. On a bubble that
/// is itself blue (so no blue would show), it falls back to the full-strength
/// text colour — still clearly brighter than the muted unread ticks.
Color bubbleReadTickOn(Color bg) {
  const blues = [
    Color(0xFF1565C0),
    Color(0xFF0D47A1),
    Color(0xFF64B5F6),
    Color(0xFF9FD0FF),
  ];
  final b = _bestOn(bg, blues);
  return bubbleContrast(Color.alphaBlend(b, bg), bg) >= 3.0
      ? b
      : bubbleTextOn(bg);
}

/// A link colour that stays legible on [bg] and still reads as a link (blue
/// when one contrasts enough, else the text colour; links are underlined).
Color bubbleLinkOn(Color bg) {
  final b = _bestOn(bg, const [Color(0xFF0B57D0), Color(0xFF9FD0FF)]);
  return bubbleContrast(Color.alphaBlend(b, bg), bg) >= 3.5
      ? b
      : bubbleTextOn(bg);
}

/// A hairline border that lifts a custom bubble off the wallpaper without
/// fighting its colour.
Color bubbleBorderOn(Color bg) => bg.computeLuminance() > 0.5
    ? const Color(0x14000000)
    : const Color(0x1FFFFFFF);

/// The curated palette offered in the picker — a spectrum of calm, saturated
/// tones plus a neutral ramp, so a choice always looks intentional.
/// Neon collection: vivid, glowing tones. Text, time and ticks on them are
/// picked by contrast (see [bubbleTextOn] / [bubbleMutedOn]), so they stay
/// readable even on the brightest ones.
const List<int> bubbleNeonPalette = <int>[
  0xFFFF2E97, // electric pink
  0xFFFF00E5, // hot magenta
  0xFFB026FF, // neon purple
  0xFF7A00FF, // electric violet
  0xFF00B3FF, // laser blue
  0xFF00F0FF, // cyan
  0xFF00FFC6, // aqua mint
  0xFF39FF14, // neon green
  0xFFC6FF00, // acid lime
  0xFFFFF000, // electric yellow
  0xFFFF6A00, // neon orange
  0xFFFF073A, // neon red
];

const List<int> bubblePalette = <int>[
  0xFFEF5F6B, // rose red
  0xFFE2557B, // raspberry
  0xFFB85C9E, // orchid
  0xFF8E6FD8, // violet
  0xFF6472E8, // indigo
  0xFF4A90E2, // blue
  0xFF2DA3C9, // teal blue
  0xFF27AE95, // teal
  0xFF3FAE6B, // green
  0xFF9BB33B, // lime olive
  0xFFE0A33E, // amber
  0xFFE57A3C, // orange
  0xFFBF5A48, // terracotta
  0xFF8D7B68, // taupe
  0xFF5B6472, // steel
  0xFF2B3240, // slate (dark)
  0xFF1F2430, // ink
  0xFFF3EDE7, // warm paper
  0xFFE7E9EE, // cool paper
  0xFFFFFFFF, // white
];
