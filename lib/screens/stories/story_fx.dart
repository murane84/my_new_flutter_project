import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Little moments for the status viewer: a reaction that floats up over the
/// photo, a confetti burst for an occasion, and the spinning record of a
/// status's song.

/// One emoji rising from the reply card and fading — a reaction you SEE.
class RisingReaction extends StatefulWidget {
  const RisingReaction(
      {super.key,
      required this.emoji,
      required this.x,
      this.size = 46,
      this.delay = Duration.zero,
      required this.onDone});
  final String emoji;
  final double x; // 0..1 across the width
  final double size;
  final Duration delay;
  final VoidCallback onDone;

  @override
  State<RisingReaction> createState() => _RisingReactionState();
}

class _RisingReactionState extends State<RisingReaction>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1700));

  @override
  void initState() {
    super.initState();
    Future.delayed(widget.delay, () {
      if (mounted) _c.forward().whenComplete(widget.onDone);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, box) {
      return AnimatedBuilder(
        animation: _c,
        builder: (_, _) {
          final t = Curves.easeOutCubic.transform(_c.value);
          final y = box.maxHeight * (0.78 - 0.5 * t);
          final sway = math.sin(_c.value * math.pi * 2) * 14;
          final scale = _c.value < 0.15 ? _c.value / 0.15 : 1.0;
          final fade = _c.value > 0.6 ? 1 - (_c.value - 0.6) / 0.4 : 1.0;
          return Stack(children: [
            Positioned(
              left: box.maxWidth * widget.x - widget.size / 2 + sway,
              top: y,
              child: Opacity(
                opacity: fade.clamp(0.0, 1.0),
                child: Transform.scale(
                  scale: 0.6 + 0.6 * scale,
                  child: Text(widget.emoji,
                      style: TextStyle(fontSize: widget.size)),
                ),
              ),
            ),
          ]);
        },
      );
    });
  }
}

/// A short confetti fall (an occasion: birthday, anniversary…).
class ConfettiBurst extends StatefulWidget {
  const ConfettiBurst({super.key, required this.colors, required this.onDone});
  final List<Color> colors;
  final VoidCallback onDone;

  @override
  State<ConfettiBurst> createState() => _ConfettiBurstState();
}

class _ConfettiBurstState extends State<ConfettiBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2200))
    ..forward().whenComplete(widget.onDone);
  final int _seed = DateTime.now().millisecondsSinceEpoch;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _ConfettiPainter(_c, widget.colors, _seed),
        ),
      );
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.anim, this.colors, this.seed) : super(repaint: anim);
  final Animation<double> anim;
  final List<Color> colors;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(seed);
    final t = anim.value;
    final fade = t > 0.75 ? 1 - (t - 0.75) / 0.25 : 1.0;
    final p = Paint();
    for (var i = 0; i < 70; i++) {
      final x0 = rnd.nextDouble() * size.width;
      final speed = 0.55 + rnd.nextDouble() * 0.6;
      final drift = (rnd.nextDouble() - 0.5) * 80;
      final spin = rnd.nextDouble() * 10;
      final w = 5 + rnd.nextDouble() * 6, h = 8 + rnd.nextDouble() * 8;
      final y = -20 + t * speed * (size.height + 40);
      final x = x0 + drift * t + math.sin(t * 8 + i) * 10;
      p.color = colors[i % colors.length].withValues(alpha: fade.clamp(0, 1));
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(spin * t * 3);
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(
              center: Offset.zero, width: w, height: h), const Radius.circular(2)),
          p);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => false;
}

/// The status song's little record: spins while it plays.
class SpinningDisc extends StatefulWidget {
  const SpinningDisc(
      {super.key, required this.spinning, this.size = 28, required this.accent});
  final bool spinning;
  final double size;
  final Color accent;

  @override
  State<SpinningDisc> createState() => _SpinningDiscState();
}

class _SpinningDiscState extends State<SpinningDisc>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 3));

  @override
  void initState() {
    super.initState();
    if (widget.spinning) _c.repeat();
  }

  @override
  void didUpdateWidget(SpinningDisc oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.spinning && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.spinning && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return RotationTransition(
      turns: _c,
      child: Container(
        width: s,
        height: s,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [
            widget.accent,
            widget.accent,
            const Color(0xFF1C1114),
            const Color(0xFF2A1A1F),
            const Color(0xFF1C1114),
          ], stops: const [0, 0.22, 0.24, 0.6, 1]),
          boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 6)],
        ),
        child: Center(
          child: Container(
            width: s * 0.08,
            height: s * 0.08,
            decoration: const BoxDecoration(
                color: Colors.black, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }
}
