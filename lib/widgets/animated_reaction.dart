import 'dart:math' as math;
import 'package:flutter/material.dart';

// ── Animated reactions ───────────────────────────────────────────────────────
// Emoji are font glyphs (their pixels can't be repainted), so we animate the
// WHOLE glyph to imitate its meaning — a heartbeat pulse for love, a wobble for
// laughter, a sway for music, a flicker for fire — and add light particle
// effects where they sell the gesture (falling tears for crying, twinkling
// sparkles for stars). Shared by Listen Together, DMs and group chats. Only
// visible reactions animate (lists build on demand), so the cost stays bounded.
enum _ReactMotion { heart, laugh, cry, fire, star, clap, music, pulse }

class AnimatedReaction extends StatefulWidget {
  const AnimatedReaction({super.key, required this.emoji, this.size = 40});
  final String emoji;
  final double size;

  @override
  State<AnimatedReaction> createState() => _AnimatedReactionState();
}

class _AnimatedReactionState extends State<AnimatedReaction>
    with SingleTickerProviderStateMixin {
  late final _ReactMotion _m;
  late final AnimationController _c;

  static const Set<int> _heart = {
    0x2764, 0x1F9E1, 0x1F49B, 0x1F49A, 0x1F499, 0x1F49C, 0x1F5A4, 0x1F90D,
    0x1F90E, 0x1F496, 0x1F497, 0x1F493, 0x1F495, 0x1F49E, 0x1F498, 0x1F49D,
    0x1F60D, 0x1F970, 0x1F618, 0x1F63B, 0x1F60B,
  };
  static const Set<int> _laugh = {
    0x1F602, 0x1F923, 0x1F606, 0x1F604, 0x1F601, 0x1F605, 0x1F639, 0x1F638,
    0x1F600, 0x1F603,
  };
  static const Set<int> _cry = {
    0x1F62D, 0x1F622, 0x1F979, 0x1F972, 0x1F63F, 0x1F629, 0x1F614, 0x1F97A,
  };
  static const Set<int> _fire = {0x1F525};
  static const Set<int> _star = {
    0x2B50, 0x1F31F, 0x2728, 0x1F929, 0x1F4AB, 0x1F320,
  };
  static const Set<int> _clap = {
    0x1F44F, 0x1F64C, 0x1F389, 0x1F973, 0x1F38A, 0x1F64F, 0x1F91F,
  };
  static const Set<int> _music = {
    0x1F3B8, 0x1F3B5, 0x1F3B6, 0x1F3B7, 0x1F3BA, 0x1F941, 0x1F3A4, 0x1F3B9,
    0x1F3BC,
  };

  _ReactMotion _classify(String e) {
    final cp = e.runes.isEmpty ? 0 : e.runes.first;
    if (_heart.contains(cp)) return _ReactMotion.heart;
    if (_laugh.contains(cp)) return _ReactMotion.laugh;
    if (_cry.contains(cp)) return _ReactMotion.cry;
    if (_fire.contains(cp)) return _ReactMotion.fire;
    if (_star.contains(cp)) return _ReactMotion.star;
    if (_clap.contains(cp)) return _ReactMotion.clap;
    if (_music.contains(cp)) return _ReactMotion.music;
    return _ReactMotion.pulse;
  }

  Duration _durationFor(_ReactMotion m) {
    switch (m) {
      case _ReactMotion.heart:
        return const Duration(milliseconds: 1200);
      case _ReactMotion.laugh:
        return const Duration(milliseconds: 900);
      case _ReactMotion.cry:
        return const Duration(milliseconds: 1800);
      case _ReactMotion.fire:
        return const Duration(milliseconds: 700);
      case _ReactMotion.star:
        return const Duration(milliseconds: 1500);
      case _ReactMotion.clap:
        return const Duration(milliseconds: 650);
      case _ReactMotion.music:
        return const Duration(milliseconds: 1200);
      case _ReactMotion.pulse:
        return const Duration(milliseconds: 1700);
    }
  }

  @override
  void initState() {
    super.initState();
    _m = _classify(widget.emoji);
    _c = AnimationController(vsync: this, duration: _durationFor(_m))..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  double _heartbeat(double t) {
    if (t < 0.12) return math.sin(t / 0.12 * math.pi);
    if (t < 0.24) return 0.6 * math.sin((t - 0.12) / 0.12 * math.pi);
    return 0.0;
  }

  @override
  Widget build(BuildContext context) {
    final box = widget.size * 1.4;
    return SizedBox(
      width: box,
      height: box,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          double scale = 1, rot = 0, dx = 0, dy = 0;
          switch (_m) {
            case _ReactMotion.heart:
              scale = 1 + 0.22 * _heartbeat(t);
              break;
            case _ReactMotion.laugh:
              rot = 0.16 * math.sin(t * 2 * math.pi * 3);
              scale = 1 + 0.05 * math.sin(t * 2 * math.pi * 3).abs();
              break;
            case _ReactMotion.cry:
              dy = 1.5 * math.sin(t * 2 * math.pi);
              break;
            case _ReactMotion.fire:
              scale = 1 + 0.06 * math.sin(t * 2 * math.pi * 5);
              dy = -1.2 * math.sin(t * 2 * math.pi * 6).abs();
              break;
            case _ReactMotion.star:
              scale = 1 + 0.12 * (0.5 + 0.5 * math.sin(t * 2 * math.pi * 2));
              rot = 0.08 * math.sin(t * 2 * math.pi);
              break;
            case _ReactMotion.clap:
              dy = -5 * math.sin(t * math.pi).abs();
              scale = 1 + 0.05 * math.sin(t * 2 * math.pi);
              break;
            case _ReactMotion.music:
              rot = 0.14 * math.sin(t * 2 * math.pi);
              break;
            case _ReactMotion.pulse:
              scale = 1 + 0.08 * math.sin(t * 2 * math.pi);
              break;
          }
          return Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              if (_m == _ReactMotion.star)
                CustomPaint(
                    size: Size(box, box), painter: _SparklePainter(t)),
              if (_m == _ReactMotion.cry)
                CustomPaint(
                    size: Size(box, box),
                    painter: _TearPainter(t, widget.size)),
              Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..translate(dx, dy)
                  ..rotateZ(rot)
                  ..scale(scale),
                child: Text(widget.emoji,
                    style: TextStyle(fontSize: widget.size)),
              ),
            ],
          );
        },
      ),
    );
  }
}

// Falling blue teardrops for a crying reaction.
class _TearPainter extends CustomPainter {
  _TearPainter(this.t, this.emojiSize);
  final double t;
  final double emojiSize;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final topY = size.height / 2 - emojiSize * 0.02;
    final fall = emojiSize * 0.9;
    for (var i = 0; i < 2; i++) {
      final phase = (t + i * 0.5) % 1.0;
      final x = cx + (i == 0 ? -emojiSize * 0.17 : emojiSize * 0.17);
      final y = topY + phase * fall;
      final fade = phase < 0.8 ? 1.0 - phase * 0.4 : (1.0 - phase) / 0.2;
      final r = emojiSize * 0.06 * (1 - phase * 0.3);
      final paint = Paint()
        ..color = const Color(0xFF4FC3F7)
            .withValues(alpha: (fade * 0.9).clamp(0.0, 0.9));
      final path = Path()
        ..moveTo(x, y - r * 1.7)
        ..quadraticBezierTo(x + r, y, x, y + r)
        ..quadraticBezierTo(x - r, y, x, y - r * 1.7)
        ..close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_TearPainter old) => old.t != t;
}

// Twinkling golden sparkles around a star reaction.
class _SparklePainter extends CustomPainter {
  _SparklePainter(this.t);
  final double t;

  static const List<Offset> _pos = [
    Offset(0.16, 0.2),
    Offset(0.84, 0.28),
    Offset(0.78, 0.82),
    Offset(0.2, 0.8),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < _pos.length; i++) {
      final phase = (t + i * 0.25) % 1.0;
      final a = math.sin(phase * math.pi);
      if (a <= 0.03) continue;
      final c = Offset(_pos[i].dx * size.width, _pos[i].dy * size.height);
      final r = size.width * 0.06 * a;
      final paint = Paint()..color = const Color(0xFFFFD54F).withValues(alpha: a);
      final path = Path()
        ..moveTo(c.dx, c.dy - r)
        ..lineTo(c.dx + r * 0.28, c.dy)
        ..lineTo(c.dx, c.dy + r)
        ..lineTo(c.dx - r * 0.28, c.dy)
        ..close()
        ..moveTo(c.dx - r, c.dy)
        ..lineTo(c.dx, c.dy - r * 0.28)
        ..lineTo(c.dx + r, c.dy)
        ..lineTo(c.dx, c.dy + r * 0.28)
        ..close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_SparklePainter old) => old.t != t;
}
