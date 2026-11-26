import 'package:flutter/material.dart';

/// The "Default" wallpaper: a faint, tiled music doodle (notes, headphones,
/// hearts, discs…) in [tint] — like WhatsApp's doodle background, tuned to
/// Aluta. Used by the chat (the app's theme colour) and Our Space (the
/// Space's colour). Only repaints when the tint or brightness changes.
class AlutaDoodleWallpaper extends StatelessWidget {
  const AlutaDoodleWallpaper({
    super.key,
    required this.tint,
    required this.isDark,
    this.base,
  });

  /// The colour the doodles take on (lifted towards white on dark).
  final Color tint;
  final bool isDark;

  /// The ground under the doodles. Defaults to the chat's warm neutral
  /// (near-black on dark, soft warm off-white on light).
  final Color? base;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: base ??
            (isDark ? const Color(0xFF141011) : const Color(0xFFF3ECEA)),
      ),
      child: CustomPaint(
        painter: _DoodlePainter(isDark: isDark, tint: tint),
        size: Size.infinite,
      ),
    );
  }
}

class _DoodlePainter extends CustomPainter {
  final bool isDark;
  final Color tint;
  const _DoodlePainter({required this.isDark, required this.tint});

  static const List<IconData> _icons = [
    Icons.music_note_rounded,
    Icons.headphones_rounded,
    Icons.favorite_rounded,
    Icons.album_rounded,
    Icons.graphic_eq_rounded,
    Icons.queue_music_rounded,
    Icons.radio_rounded,
    Icons.audiotrack_rounded,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    // Very low alpha keeps it a whisper behind the bubbles. On dark, the
    // theme colour lifted towards white (as the Motif and Watermark do).
    final ink = isDark ? Color.lerp(tint, Colors.white, 0.35)! : tint;
    final color = ink.withAlpha(isDark ? 14 : 15);
    const cell = 66.0;
    var i = 0;
    for (double y = 0; y < size.height + cell; y += cell) {
      final row = (y / cell).floor();
      final xOff = row.isEven ? 0.0 : cell / 2; // brick-lay for organic feel
      for (double x = xOff; x < size.width + cell; x += cell) {
        final icon = _icons[(i * 5 + row * 3) % _icons.length];
        final tilt = (((i * 7 + row * 11) % 7) - 3) * 0.16; // small varied tilt
        final glyphSize = 18.0 + ((i + row) % 3) * 5.0;
        _glyph(canvas, icon, Offset(x, y), glyphSize, color, tilt);
        i++;
      }
    }
  }

  void _glyph(Canvas canvas, IconData icon, Offset c, double glyphSize,
      Color color, double tilt) {
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: glyphSize,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(tilt);
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _DoodlePainter old) =>
      old.isDark != isDark || old.tint != tint;
}
