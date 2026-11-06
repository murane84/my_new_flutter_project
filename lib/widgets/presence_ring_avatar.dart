import 'dart:math' as math;

import 'package:flutter/material.dart';

/// What the circle around a friend's photo is saying.
enum RingMode {
  /// No music ring (story ring / online dot are drawn by the caller).
  none,

  /// They're playing music: the play key's orbiting comet circles the rim
  /// (progress shows on the card's bottom line), plus a mini spinning vinyl.
  listening,

  /// Listening together with ME: two arcs weave in opposite directions.
  together,

  /// A call is live (group call): a full theme ring that breathes, with a
  /// small call badge at the corner.
  call,

  /// They're playing the SAME song I am right now: a matched pair of arcs
  /// turning in step, with a tiny heart at the corner.
  sameSong,

  /// They're typing to me: a ring of dots shimmering round the rim.
  typing,
}

/// A friend's photo with its status ring, sized to a fixed [slot] so a row
/// never shifts when the ring comes or goes. [face] is the photo's diameter;
/// the ring lives in the 4 px around it.
class PresenceRingAvatar extends StatefulWidget {
  const PresenceRingAvatar({
    super.key,
    required this.child,
    required this.face,
    this.mode = RingMode.none,
    this.color = const Color(0xFFE8505B),
    this.color2 = const Color(0xFFF2A541),
    this.progress,
    this.glow = false,
    this.paused = false,
    this.gapColor,
  });

  /// Listening, but paused: the ring freezes and dims, the vinyl stops.
  final bool paused;

  /// The photo, already [face] px wide.
  final Widget child;
  final double face;
  final RingMode mode;

  /// Ring colour (listening) / first arc (together).
  final Color color;

  /// Second arc when together.
  final Color color2;

  /// 0..1 song progress, read every frame; null = unknown (slow sweep).
  final double? Function()? progress;

  /// Bonded + quiet: a thin breathing theme ring just around the photo,
  /// inside the rim (ignored while a music ring shows).
  final bool glow;

  /// Page colour behind the mini vinyl's edge.
  final Color? gapColor;

  double get slot => face + 8;

  @override
  State<PresenceRingAvatar> createState() => _PresenceRingAvatarState();
}

class _PresenceRingAvatarState extends State<PresenceRingAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 6));

  bool get _moving =>
      (widget.mode != RingMode.none || widget.glow) && !widget.paused;

  @override
  void initState() {
    super.initState();
    if (_moving) _c.repeat();
  }

  @override
  void didUpdateWidget(PresenceRingAvatar old) {
    super.didUpdateWidget(old);
    if (_moving && !_c.isAnimating && !_scrolling) {
      _c.repeat();
    } else if (!_moving && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _scroll?.isScrollingNotifier.removeListener(_onScrolling);
    _c.dispose();
    super.dispose();
  }

  // Calm motion: while the list is being scrolled every ring holds still
  // (no wasted frames, nothing swimming under the thumb), then resumes.
  ScrollPosition? _scroll;
  bool _scrolling = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final pos = Scrollable.maybeOf(context)?.position;
    if (pos != _scroll) {
      _scroll?.isScrollingNotifier.removeListener(_onScrolling);
      _scroll = pos;
      _scroll?.isScrollingNotifier.addListener(_onScrolling);
    }
  }

  void _onScrolling() {
    final s = _scroll?.isScrollingNotifier.value ?? false;
    if (s == _scrolling) return;
    _scrolling = s;
    if (s) {
      _c.stop();
    } else if (_moving) {
      _c.repeat();
    }
  }

  @override
  Widget build(BuildContext context) {
    final slot = widget.slot;
    final scheme = Theme.of(context).colorScheme;
    final track = scheme.onSurface.withValues(alpha: 0.10);
    final gap = widget.gapColor ?? scheme.surface;
    final listening = widget.mode == RingMode.listening;
    return SizedBox(
      width: slot,
      height: slot,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final t = _c.value;
          return Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              // Bonded + quiet: a thin theme ring hugging the photo, INSIDE
              // the grey plate's rim (plate outer, bond inner) — breathing
              // gently. Stays within the slot: nothing grows.
              if (widget.glow && widget.mode == RingMode.none)
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Opacity(
                      // 0.55 → 1 → 0.55, a breath every 3 s.
                      opacity: 0.55 +
                          0.45 * (0.5 - 0.5 * math.cos(t * math.pi * 2 * 2)),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: widget.color, width: 2),
                        ),
                      ),
                    ),
                  ),
                ),
              if (widget.mode != RingMode.none)
                Positioned.fill(
                  // Paused: only the RING dims — the photo stays full.
                  child: Opacity(
                    opacity: widget.paused ? 0.5 : 1,
                    child: CustomPaint(
                    painter: _RingPainter(
                      mode: widget.mode,
                      t: t,
                      progress: widget.progress?.call(),
                      color: widget.color,
                      color2: widget.color2,
                      track: track,
                    ),
                  ),
                  ),
                ),
              SizedBox(width: widget.face, height: widget.face, child: child),
              if (widget.mode == RingMode.sameSong)
                Positioned(
                  right: -3,
                  bottom: -3,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.color,
                      border: Border.all(color: gap, width: 2),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(Icons.favorite_rounded,
                        size: 10, color: Colors.white),
                  ),
                ),
              // Listening WITH me: the 🎧 badge (the ring itself is a closed,
              // breathing two-tone circle — connected).
              if (widget.mode == RingMode.together)
                Positioned(
                  right: -3,
                  bottom: -3,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                          colors: [widget.color, widget.color2]),
                      border: Border.all(color: gap, width: 2),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(Icons.headphones_rounded,
                        size: 11, color: Colors.white),
                  ),
                ),
              if (widget.mode == RingMode.call)
                Positioned(
                  right: -3,
                  bottom: -3,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.color,
                      border: Border.all(color: gap, width: 2),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(Icons.call_rounded,
                        size: 11, color: Colors.white),
                  ),
                ),
              if (listening)
                Positioned(
                  right: -3,
                  bottom: -3,
                  child: Opacity(
                    opacity: widget.paused ? 0.6 : 1,
                    // A STILL badge: only the comet moves on the photo.
                    child: Transform.rotate(
                    angle: 0,
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: gap, width: 2),
                        gradient: RadialGradient(
                          colors: [
                            widget.color,
                            widget.color,
                            const Color(0xFF1B1B1B),
                            const Color(0xFF2E2E2E),
                            const Color(0xFF1B1B1B),
                          ],
                          stops: const [0.0, 0.3, 0.31, 0.7, 1.0],
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Container(
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle, color: gap),
                      ),
                    ),
                  ),
                  ),
                ),
            ],
          );
        },
        child: widget.child,
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.mode,
    required this.t,
    required this.progress,
    required this.color,
    required this.color2,
    required this.track,
  });

  final RingMode mode;
  final double t;
  final double? progress;
  final Color color, color2, track;

  @override
  void paint(Canvas canvas, Size size) {
    const w = 3.0;
    final r = size.width / 2 - w / 2;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: r);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round;
    const top = -math.pi / 2;
    const full = math.pi * 2;
    switch (mode) {
      case RingMode.none:
        return;
      case RingMode.listening:
        // The play key's orbit, on their photo: a comet of light circling
        // the rim with a bright head — "music is playing here". (The song's
        // PROGRESS lives on the card's bottom line now, so the ring doesn't
        // repeat it.) Paused: the comet holds still and dims.
        _comet(canvas, rect, r, w, p);
      case RingMode.sameSong:
        // Same motion as listening (they ARE just listening) — the ❤️ badge
        // says "the same song as you".
        _comet(canvas, rect, r, w, p);
      case RingMode.typing:
        // Twelve dots round the rim; a soft wave of brightness travels.
        const n = 12;
        final dot = Paint()..style = PaintingStyle.fill;
        for (var i = 0; i < n; i++) {
          final ang = top + full * i / n;
          final wave = 0.5 + 0.5 * math.cos(full * (i / n - t * 3));
          dot.color = color.withValues(alpha: 0.25 + 0.75 * wave);
          canvas.drawCircle(
              rect.center + Offset(math.cos(ang), math.sin(ang)) * r,
              1.6 + 0.6 * wave,
              dot);
        }
      case RingMode.call:
        // A live call: the whole ring breathes (a heartbeat every 1.5 s).
        final a = 0.45 + 0.55 * (0.5 - 0.5 * math.cos(t * full * 4));
        canvas.drawCircle(
            rect.center, r, p..color = color.withValues(alpha: a));
      case RingMode.together:
        // CONNECTED: a closed, unbroken ring in your colour + the song's,
        // breathing slowly — no comet, so it can never be mistaken for
        // "just listening". (The 🎧 badge says why.)
        final breath = 0.70 + 0.30 * (0.5 - 0.5 * math.cos(full * t * 2));
        p.shader = SweepGradient(colors: [
          color.withValues(alpha: breath),
          color2.withValues(alpha: breath),
          color.withValues(alpha: breath),
        ]).createShader(rect);
        p.strokeWidth = w + 0.6 * breath;
        canvas.drawCircle(rect.center, r, p);
        p.shader = null;
    }
  }

  /// The play key's orbiting comet: faint track + a sweep of light with a
  /// bright head, lapping every 3 s.
  void _comet(Canvas canvas, Rect rect, double r, double w, Paint p) {
    const full = math.pi * 2;
    canvas.drawCircle(rect.center, r, p..color = track);
    final a = -math.pi / 2 + full * t * 2;
    canvas.save();
    canvas.translate(rect.center.dx, rect.center.dy);
    canvas.rotate(a);
    canvas.translate(-rect.center.dx, -rect.center.dy);
    p.shader = SweepGradient(colors: [
      color.withValues(alpha: 0),
      color.withValues(alpha: 0.18),
      Color.lerp(color, Colors.white, 0.35)!,
    ], stops: const [0.0, 0.55, 1.0])
        .createShader(rect);
    canvas.drawArc(rect, 0, full * 0.92, false, p);
    p.shader = null;
    final head =
        rect.center + Offset(math.cos(full * 0.92), math.sin(full * 0.92)) * r;
    canvas.drawCircle(
        head,
        w * 0.85,
        Paint()
          ..color = Color.lerp(color, Colors.white, 0.45)!
          ..style = PaintingStyle.fill);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RingPainter o) =>
      o.t != t ||
      o.progress != progress ||
      o.mode != mode ||
      o.color != color ||
      o.color2 != color2 ||
      o.track != track;
}
