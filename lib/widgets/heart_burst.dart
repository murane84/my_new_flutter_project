import 'dart:math';

import 'package:flutter/material.dart';

import '../utils/popup_shell.dart' show gLastTapDownGlobal;

/// Instagram-style heart fountain: a burst of red hearts of mixed sizes
/// shoots up and out from [origin] (the tapped spot), sways as it rises up
/// the screen, and fades out near the top. Runs on the root overlay, never
/// blocks touches, and cleans itself up (~1.6 s).
class HeartBurst {
  static OverlayEntry? _live;

  /// Hearts that count as a "like" reaction.
  static bool isHeart(String e) {
    final s = e.replaceAll('\uFE0F', '').trim();
    return const {'❤', '♥', '💖', '💕', '💞', '💗', '💓', '💘', '💝', '😍', '🥰'}
        .contains(s);
  }

  /// Fountain from the spot the user just tapped (anywhere in the app).
  static void fromTap(BuildContext context) =>
      at(context, gLastTapDownGlobal);

  /// [fromBottom] (default): the hearts rise from the BOTTOM of the screen,
  /// under the tapped spot's x, and sweep up across the whole page — like
  /// Instagram's story reaction — wherever the heart was tapped (a heart at
  /// the top would otherwise fly straight off-screen). false = burst from
  /// the exact [origin].
  static void at(BuildContext context, Offset? origin,
      {int count = 34, bool fromBottom = true}) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final size = MediaQuery.sizeOf(context);
    final x = (origin?.dx ?? size.width / 2)
        .clamp(size.width * 0.15, size.width * 0.85)
        .toDouble();
    final from = fromBottom
        ? Offset(x, size.height * 0.94)
        : (origin ?? Offset(size.width / 2, size.height * 0.6));
    _live?.remove(); // a new tap restarts the show
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => IgnorePointer(
        child: _HeartFountain(
          origin: from,
          count: count,
          onDone: () {
            if (_live == entry) _live = null;
            if (entry.mounted) entry.remove();
          },
        ),
      ),
    );
    _live = entry;
    overlay.insert(entry);
  }
}

class _Heart {
  _Heart(Random r, Size screen)
      : delay = r.nextDouble() * 0.35,
        size = 14 + r.nextDouble() * 26,
        dx = (r.nextDouble() - 0.5) * screen.width * 0.9,
        rise = screen.height * (0.55 + r.nextDouble() * 0.45),
        sway = (r.nextDouble() - 0.5) * 60,
        swayFreq = 1 + r.nextDouble() * 2,
        tilt = (r.nextDouble() - 0.5) * 0.9,
        shade = r.nextDouble();
  final double delay, size, dx, rise, sway, swayFreq, tilt, shade;
}

class _HeartFountain extends StatefulWidget {
  const _HeartFountain(
      {required this.origin, required this.count, required this.onDone});
  final Offset origin;
  final int count;
  final VoidCallback onDone;

  @override
  State<_HeartFountain> createState() => _HeartFountainState();
}

class _HeartFountainState extends State<_HeartFountain>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1600))
    ..forward().whenComplete(widget.onDone);
  List<_Heart>? _hearts;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final r = Random();
    final hearts =
        _hearts ??= List.generate(widget.count, (_) => _Heart(r, screen));
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final children = <Widget>[];
        for (final h in hearts) {
          // Each heart has its own start (staggered) and life (≈1.2 s).
          final t = ((_c.value - h.delay) / (1 - h.delay)).clamp(0.0, 1.0);
          if (t <= 0) continue;
          final up = Curves.easeOutCubic.transform(t);
          final x = widget.origin.dx +
              h.dx * Curves.easeOut.transform(t) +
              sin(t * pi * h.swayFreq) * h.sway;
          final y = widget.origin.dy - h.rise * up;
          // Pop in (overshoot), then fade over the last third.
          final pop = t < 0.18
              ? Curves.easeOutBack.transform(t / 0.18)
              : 1.0;
          final fade = t < 0.66 ? 1.0 : (1 - (t - 0.66) / 0.34);
          final color = Color.lerp(
              const Color(0xFFFF2D55), const Color(0xFFE0102F), h.shade)!;
          children.add(Positioned(
            left: x - h.size / 2,
            top: y - h.size / 2,
            child: Opacity(
              opacity: fade.clamp(0.0, 1.0),
              child: Transform.rotate(
                angle: h.tilt * (1 - t * 0.5),
                child: Transform.scale(
                  scale: pop,
                  child: Icon(Icons.favorite_rounded,
                      size: h.size,
                      color: color,
                      shadows: const [
                        Shadow(
                            color: Color(0x55000000),
                            blurRadius: 4,
                            offset: Offset(0, 1)),
                      ]),
                ),
              ),
            ),
          ));
        }
        return Stack(children: children);
      },
    );
  }
}
