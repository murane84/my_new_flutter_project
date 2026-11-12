import 'dart:convert' show base64Decode;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// The status ring, the same everywhere (status row, friend list, chat
/// header): one arc per status with small gaps, oldest first from the top,
/// clockwise. Unseen arcs carry the colour, seen ones fade to grey — so
/// "3 posts, 1 watched" reads at a glance, like WhatsApp.
class StoryRingStyle {
  StoryRingStyle._();

  static const List<Color> unseen = [
    Color(0xFFF9A825),
    Color(0xFFE91E63),
    Color(0xFF7B1FA2),
    Color(0xFFF9A825),
  ];

  /// My Harmony partner: warm theme → rose → gold.
  static List<Color> partner(ColorScheme s) => [
        s.primary,
        const Color(0xFFFF5C8A),
        const Color(0xFFF2A541),
        s.primary,
      ];

  static Color seen(ColorScheme s) => s.onSurface.withValues(alpha: 0.28);
  static const Color partnerSeen = Color(0x73FF5C8A);
}

class StoryRingPainter extends CustomPainter {
  StoryRingPainter({
    required this.seen,
    required this.colors,
    required this.seenColor,
    this.stroke = 3,
  });

  /// One entry per status, oldest → newest; true = already watched.
  final List<bool> seen;
  final List<Color> colors; // unseen arcs (a sweep around the ring)
  final Color seenColor;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final n = seen.isEmpty ? 1 : math.min(seen.length, 30);
    const full = math.pi * 2;
    // A clear gap that shrinks when there are many statuses.
    final gap = n == 1 ? 0.0 : math.min(0.11, full / n * 0.28);
    final sweep = (full - n * gap) / n;
    final shader = SweepGradient(
      colors: colors,
      transform: const GradientRotation(-math.pi / 2),
    ).createShader(rect);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt
      ..isAntiAlias = true;
    for (var i = 0; i < n; i++) {
      final watched = seen.isEmpty ? false : seen[i];
      if (watched) {
        p
          ..shader = null
          ..color = seenColor;
      } else {
        p.shader = shader;
      }
      canvas.drawArc(rect, -math.pi / 2 + gap / 2 + i * (sweep + gap),
          sweep, false, p);
    }
  }

  @override
  bool shouldRepaint(StoryRingPainter old) =>
      old.stroke != stroke ||
      old.seenColor != seenColor ||
      old.seen.length != seen.length ||
      !_same(old.seen, seen) ||
      !_same(old.colors, colors);

  static bool _same(List a, List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Decoded video-status previews, kept so a list rebuild never re-decodes.
class StoryThumbs {
  StoryThumbs._();
  static final Map<String, Uint8List> _cache = {};

  static Uint8List? bytes(String id, String? dataUri) {
    if (dataUri == null || dataUri.isEmpty) return null;
    final hit = _cache[id];
    if (hit != null) return hit;
    final i = dataUri.indexOf(',');
    if (i < 0) return null;
    try {
      final b = base64Decode(dataUri.substring(i + 1));
      if (_cache.length > 200) _cache.clear();
      return _cache[id] = b;
    } catch (_) {
      return null;
    }
  }
}
