import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../utils/motion.dart';
import '../utils/depth.dart';

/// How long one calm "here it is" breath lasts. Every highlight in Aluta
/// (⌖ Find the playing song, the row you came back from, a message you
/// jumped to, freshly found songs, a Circle pill that went up) uses it.
const Duration kCalmBreath = Duration(milliseconds: 1100);

/// The breath itself, for t in 0…1: rises over the first 35 % and settles
/// more slowly than it rose. It happens once and never flashes twice.
double calmBreath(double t) {
  if (t <= 0 || t >= 1) return 0;
  return t < 0.35
      ? Curves.easeOut.transform(t / 0.35)
      : 1 - Curves.easeInOut.transform((t - 0.35) / 0.65);
}

/// Tells a [NowGlow] to breathe once. [ping] after the list has finished
/// scrolling to the playing song; `soft` when it was already in view (a
/// small nudge instead of the full glow).
class NowGlowController extends ChangeNotifier {
  double _strength = 1;
  double get strength => _strength;

  void ping({bool soft = false}) {
    _strength = soft ? 0.45 : 1;
    notifyListeners();
  }
}

/// The "here it is" for ⌖ Find the playing song — Aluta-style, never a
/// flashing alarm: the row breathes ONCE (warm accent wash + soft halo that
/// swell and settle over ~1 s, a hair of lift) and a little ♪ floats up
/// off its trailing edge and fades. Used by the playlist, Up next and the
/// Listen Together queue so all three answer ⌖ the same way.
class NowGlow extends StatefulWidget {
  const NowGlow({
    super.key,
    required this.controller,
    required this.child,
    this.radius = 14,
    this.color,
  });

  final NowGlowController controller;
  final Widget child;
  final double radius;
  final Color? color; // defaults to the theme's primary

  @override
  State<NowGlow> createState() => _NowGlowState();
}

class _NowGlowState extends State<NowGlow> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(
      vsync: this, duration: kCalmBreath);
  double _strength = 1;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_ping);
  }

  @override
  void didUpdateWidget(NowGlow old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_ping);
      widget.controller.addListener(_ping);
    }
  }

  void _ping() {
    _strength = widget.controller.strength;
    _a.forward(from: 0);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_ping);
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.color ?? Theme.of(context).colorScheme.primary;
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return AnimatedBuilder(
      animation: _a,
      child: widget.child,
      builder: (context, child) {
        final t = _a.value;
        if (t == 0 || t == 1) return child!;
        // One breath: swells, then settles slower than it rose.
        final i = calmBreath(t) * _strength;
        // The ♪ drifts up and fades over the whole breath.
        final noteT = Curves.easeOut.transform(t);
        return Transform.scale(
          scale: still ? 1 : 1 + 0.012 * i,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(widget.radius),
                  color: c.withValues(alpha: 0.16 * i),
                  border: Border.all(
                      color: c.withValues(alpha: 0.55 * i), width: 1.2),
                  boxShadow: [
                    BoxShadow(
                      color: c.withValues(alpha: 0.35 * i),
                      blurRadius: Depth.md,
                      spreadRadius: 0.5,
                    ),
                  ],
                ),
                child: child,
              ),
              if (_strength >= 0.9 && !still)
                Positioned(
                  right: 10,
                  top: -4 - 14 * noteT,
                  child: IgnorePointer(
                    child: Opacity(
                      opacity:
                          (math.sin(math.pi * noteT)).clamp(0.0, 1.0) * 0.9,
                      child: Text('♪',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: c)),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The calm "here it is" for anything that isn't the ⌖ button itself: the
/// row you came back from, a moment you jumped to in Our Space. When
/// [active] turns on (or [pulse] changes while it is on) the child breathes
/// ONCE with [kCalmBreath]: a soft wash, rim and halo, and a hair of lift.
/// With [hearts] (bonded partner only) three small hearts also circle the
/// rim once. Reduce-motion keeps the glow but drops the lift and hearts.
/// Costs nothing while idle.
class BreathGlow extends StatefulWidget {
  const BreathGlow({
    super.key,
    required this.active,
    required this.color,
    required this.child,
    this.pulse = 0,
    this.radius = 18,
    this.hearts = false,
  });

  final bool active;
  final int pulse;
  final Color color;
  final double radius;
  final bool hearts;
  final Widget child;

  static const Color rose = Color(0xFFFF5C8A);
  static const Color gold = Color(0xFFF2A541);

  @override
  State<BreathGlow> createState() => _BreathGlowState();
}

class _BreathGlowState extends State<BreathGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);

  // The hearts need a little longer to go round, so with them the single
  // breath is stretched to match. It is still one swell.
  void _play() {
    _c.duration =
        widget.hearts ? const Duration(milliseconds: 1600) : kCalmBreath;
    _c.forward(from: 0);
  }

  @override
  void initState() {
    super.initState();
    if (widget.active) _play();
  }

  @override
  void didUpdateWidget(covariant BreathGlow old) {
    super.didUpdateWidget(old);
    if (widget.active && (!old.active || widget.pulse != old.pulse)) _play();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        final t = _c.value;
        if (t <= 0 || t >= 1) return child!;
        final i = calmBreath(t);
        final c = widget.color;
        final glow = DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            color: c.withValues(alpha: 0.14 * i),
            border:
                Border.all(color: c.withValues(alpha: 0.55 * i), width: 1.2),
            boxShadow: [
              BoxShadow(
                  color: c.withValues(alpha: 0.32 * i),
                  blurRadius: Depth.md,
                  spreadRadius: 0.5),
            ],
          ),
          child: child,
        );
        return Transform.scale(
          scale: still ? 1 : 1 + 0.012 * i,
          child: !widget.hearts || still
              ? glow
              : Stack(clipBehavior: Clip.none, children: [
                  glow,
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _RimHeartsPainter(t: t, radius: widget.radius),
                      ),
                    ),
                  ),
                ]),
        );
      },
    );
  }
}

/// Three small hearts going once round a rounded box's rim, evenly spaced,
/// fading in as they set off and out as they finish.
class _RimHeartsPainter extends CustomPainter {
  _RimHeartsPainter({required this.t, required this.radius});

  final double t;
  final double radius;

  static const _colors = [BreathGlow.rose, BreathGlow.gold, BreathGlow.rose];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(0.6), Radius.circular(radius)));
    final fade = (t < 0.15
            ? t / 0.15
            : t > 0.8
                ? (1 - t) / 0.2
                : 1.0)
        .clamp(0.0, 1.0);
    final travel = Curves.easeInOutSine.transform(t);
    const n = 3;
    for (final m in path.computeMetrics()) {
      final len = m.length;
      for (var k = 0; k < n; k++) {
        final at = m.getTangentForOffset((travel * len + k * len / n) % len)
            ?.position;
        if (at == null) continue;
        final col = _colors[k];
        final tp = TextPainter(
          text: TextSpan(
            text: '\u2665',
            style: TextStyle(
              fontSize: 10,
              height: 1,
              color: col.withValues(alpha: 0.95 * fade),
              shadows: [
                Shadow(color: col.withValues(alpha: 0.6 * fade), blurRadius: Depth.sm),
              ],
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
        tp.dispose();
      }
    }
  }

  @override
  bool shouldRepaint(_RimHeartsPainter o) => o.t != t || o.radius != radius;
}

/// ⌖ Find the playing song — ONE routine for every song list (player
/// queue, playlist, Listen Together, web queue), so it lands the same way:
///  1. the row is already built (on screen or just off) → centre it;
///  2. otherwise jump near it, using the row height MEASURED from the list
///     (its length ÷ its rows — never a fixed guess), and aim again until
///     the row exists;
///  3. centre it precisely on [rowKey] (the first / last rows as close to
///     the middle as the list's ends allow), then [glow] breathes once —
///     softly when it was already in view.
void locatePlayingRow({
  required ScrollController controller,
  required GlobalKey rowKey,
  required int index,
  required int count,
  NowGlowController? glow,
  int tries = 0,
}) {
  if (index < 0 || count <= 0 || !controller.hasClients) return;
  final shown = rowKey.currentContext;
  if (shown != null) {
    _centreRow(shown, glow, soft: tries == 0);
    return;
  }
  final pos = controller.position;
  final row = (pos.maxScrollExtent + pos.viewportDimension) / count;
  controller.jumpTo((index * row + row / 2 - pos.viewportDimension / 2)
      .clamp(0.0, pos.maxScrollExtent));
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final ctx = rowKey.currentContext;
    if (ctx != null) {
      _centreRow(ctx, glow, soft: false);
    } else if (tries < 6) {
      locatePlayingRow(
          controller: controller,
          rowKey: rowKey,
          index: index,
          count: count,
          glow: glow,
          tries: tries + 1);
    }
  });
}

void _centreRow(BuildContext ctx, NowGlowController? glow,
    {required bool soft}) {
  Scrollable.ensureVisible(
    ctx,
    alignment: 0.5,
    duration: Motion.emphasized,
    curve: Curves.easeOutCubic,
  ).then((_) => glow?.ping(soft: soft));
}
