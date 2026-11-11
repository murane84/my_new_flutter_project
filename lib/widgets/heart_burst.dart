import 'dart:math';

import 'package:flutter/material.dart';

import '../utils/popup_shell.dart' show gLastTapDownGlobal;
import '../utils/depth.dart';

/// How an emoji moves in its fountain.
enum _Motion { rise, bounce, fall, flicker }

/// Instagram-style reaction fountain. Hearts: a big burst of red hearts
/// rising from the bottom of the screen and sweeping up the page. Any other
/// reaction: a lighter burst of THAT emoji with a touch of personality —
/// 😂 bounces, 🔥 flickers, 😢 drifts down like tears. Runs on the root
/// overlay, never blocks touches, cleans itself up (~1.6 s).
class HeartBurst {
  static OverlayEntry? _live;

  /// Hearts that count as a "like" reaction.
  static bool isHeart(String e) {
    final s = e.replaceAll('️', '').trim();
    return const {'❤', '♥', '💖', '💕', '💞', '💗', '💓', '💘', '💝', '😍', '🥰'}
        .contains(s);
  }

  /// Heart fountain under the spot the user just tapped.
  static void fromTap(BuildContext context) =>
      at(context, gLastTapDownGlobal);

  /// The fountain for any reaction [emoji] (hearts get the full show).
  static void react(BuildContext context, String emoji, {Offset? origin}) {
    final o = origin ?? gLastTapDownGlobal;
    if (isHeart(emoji)) {
      at(context, o);
      return;
    }
    final s = emoji.replaceAll('️', '').trim();
    final motion = switch (s) {
      '😂' || '🤣' || '😆' || '😁' => _Motion.bounce,
      '😢' || '😭' || '🥲' || '😿' => _Motion.fall,
      '🔥' || '⚡' || '✨' => _Motion.flicker,
      _ => _Motion.rise,
    };
    _show(context, o,
        glyph: emoji,
        count: motion == _Motion.fall ? 9 : 14,
        motion: motion);
  }

  /// [fromBottom] (default): rise from the BOTTOM of the screen under the
  /// tapped spot's x and sweep up the whole page. false = burst from the
  /// exact [origin].
  static void at(BuildContext context, Offset? origin,
          {int count = 34, bool fromBottom = true}) =>
      _show(context, origin,
          count: count, motion: _Motion.rise, fromBottom: fromBottom);

  static void _show(BuildContext context, Offset? origin,
      {String? glyph,
      required int count,
      required _Motion motion,
      bool fromBottom = true}) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    // The fountain plays inside the PANEL that was tapped (chat / music on
    // desktop), clipped to it — never spilling over the neighbour panel or
    // the title bar. On a phone that panel is ~the whole screen.
    final area = _areaFor(context);
    final size = area.size;
    final o = origin == null ? null : origin - area.topLeft;
    final x = (o?.dx ?? size.width / 2)
        .clamp(size.width * 0.15, size.width * 0.85)
        .toDouble();
    final from = motion == _Motion.fall
        ? Offset(x, size.height * 0.10) // tears start high and drift down
        : fromBottom
            ? Offset(x, size.height * 0.94)
            : (o ?? Offset(size.width / 2, size.height * 0.6));
    _live?.remove(); // a new reaction restarts the show
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => Positioned.fromRect(
        rect: area,
        child: IgnorePointer(
          child: ClipRect(
            // No Material above the overlay → plain text would get the
            // yellow "missing Material" double underline.
            child: DefaultTextStyle(
              style: const TextStyle(decoration: TextDecoration.none),
              child: _Fountain(
                origin: from,
                space: size,
                count: count,
                glyph: glyph,
                motion: motion,
                onDone: () {
                  if (_live == entry) _live = null;
                  if (entry.mounted) entry.remove();
                },
              ),
            ),
          ),
        ),
      ),
    );
    _live = entry;
    overlay.insert(entry);
  }

  /// Global rect of the panel that holds [context]: the nearest ancestor
  /// box that is panel-sized (tall and reasonably wide). Falls back to the
  /// whole screen.
  static Rect _areaFor(BuildContext context) {
    final screen = Offset.zero & MediaQuery.sizeOf(context);
    RenderObject? ro;
    try {
      ro = context.findRenderObject();
    } catch (_) {
      ro = null;
    }
    while (ro != null) {
      if (ro is RenderBox && ro.attached && ro.hasSize) {
        final s = ro.size;
        if (s.height >= screen.height * 0.6 && s.width >= 260) {
          final r = ro.localToGlobal(Offset.zero) & s;
          final hit = r.intersect(screen);
          return hit.isEmpty ? screen : hit;
        }
      }
      ro = ro.parent;
    }
    return screen;
  }
}

class _Particle {
  _Particle(Random r, Size screen, {required bool emoji})
      : delay = r.nextDouble() * 0.35,
        size = emoji ? 22 + r.nextDouble() * 18 : 14 + r.nextDouble() * 26,
        dx = (r.nextDouble() - 0.5) * screen.width * (emoji ? 0.7 : 0.9),
        rise = screen.height * (0.55 + r.nextDouble() * 0.45),
        sway = (r.nextDouble() - 0.5) * 60,
        swayFreq = 1 + r.nextDouble() * 2,
        tilt = (r.nextDouble() - 0.5) * 0.9,
        shade = r.nextDouble(),
        phase = r.nextDouble() * pi * 2;
  final double delay, size, dx, rise, sway, swayFreq, tilt, shade, phase;
}

class _Fountain extends StatefulWidget {
  const _Fountain({
    required this.origin,
    required this.space,
    required this.count,
    required this.motion,
    required this.onDone,
    this.glyph,
  });
  final Offset origin;
  final Size space; // the panel the fountain plays in
  final int count;
  final _Motion motion;
  final String? glyph; // null = red hearts
  final VoidCallback onDone;

  @override
  State<_Fountain> createState() => _FountainState();
}

class _FountainState extends State<_Fountain>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this,
      duration: Duration(
          milliseconds: widget.motion == _Motion.fall ? 1900 : 1600))
    ..forward().whenComplete(widget.onDone);
  List<_Particle>? _parts;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screen = widget.space;
    final r = Random();
    final parts = _parts ??= List.generate(widget.count,
        (_) => _Particle(r, screen, emoji: widget.glyph != null));
    final m = widget.motion;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final children = <Widget>[];
        for (final p in parts) {
          final t = ((_c.value - p.delay) / (1 - p.delay)).clamp(0.0, 1.0);
          if (t <= 0) continue;
          final travel = Curves.easeOutCubic.transform(t);
          var x = widget.origin.dx +
              p.dx * Curves.easeOut.transform(t) +
              sin(t * pi * p.swayFreq) * p.sway;
          double y;
          var scale = 1.0;
          var opacity = t < 0.66 ? 1.0 : (1 - (t - 0.66) / 0.34);
          switch (m) {
            case _Motion.fall:
              // Tears: drift DOWN about half the screen, gently swaying.
              y = widget.origin.dy + p.rise * 0.55 * Curves.easeIn.transform(t);
              x = widget.origin.dx + p.dx * 0.5 + sin(t * pi * 2) * 14;
            case _Motion.bounce:
              // Laughing: rise with a little hop.
              y = widget.origin.dy -
                  p.rise * travel -
                  (sin(t * pi * 6 + p.phase).abs() * 16 * (1 - t));
            case _Motion.flicker:
              y = widget.origin.dy - p.rise * travel;
              scale = 0.85 + 0.25 * sin(t * pi * 10 + p.phase).abs();
              opacity *= 0.75 + 0.25 * sin(t * pi * 12 + p.phase).abs();
            case _Motion.rise:
              y = widget.origin.dy - p.rise * travel;
          }
          final pop =
              t < 0.18 ? Curves.easeOutBack.transform(t / 0.18) : 1.0;
          final Widget glyph = widget.glyph == null
              ? Icon(Icons.favorite_rounded,
                  size: p.size,
                  color: Color.lerp(const Color(0xFFFF2D55),
                      const Color(0xFFE0102F), p.shade),
                  shadows: const [
                    Shadow(
                        color: Color(0x55000000),
                        blurRadius: Depth.xs,
                        offset: Offset(0, 1)),
                  ])
              : Text(widget.glyph!,
                  style: TextStyle(
                      fontSize: p.size,
                      height: 1,
                      decoration: TextDecoration.none));
          children.add(Positioned(
            left: x - p.size / 2,
            top: y - p.size / 2,
            child: Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: Transform.rotate(
                angle: p.tilt * (1 - t * 0.5),
                child: Transform.scale(scale: pop * scale, child: glyph),
              ),
            ),
          ));
        }
        return Stack(children: children);
      },
    );
  }
}
