import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import 'package:visibility_detector/visibility_detector.dart';

/// A "secret heart" message bubble (message_type == 'heart'). Arrives covered
/// with a soft "tap to open" shimmer and a gentle heartbeat pulse that runs
/// ONLY while it's scrolled into view. Tapping reveals the note: a short note
/// shows inside the heart; a long one blooms a scrollable "genie" card that
/// collapses back into the heart on tap-outside / swipe / back.
class HeartBubble extends StatefulWidget {
  const HeartBubble({
    super.key,
    required this.text,
    required this.isMe,
    required this.accent,
    this.bonded = false,
    this.heartKeySeed,
    this.onLoveBack,
  });

  final String text;
  final bool isMe;
  final Color accent;
  final bool bonded;
  final String? heartKeySeed;

  /// Bonded-space gesture: double-tap the heart to "love back" (a reaction +
  /// haptic + a little rising-hearts burst). Null = gesture disabled.
  final VoidCallback? onLoveBack;

  /// A note longer than this (or spanning more than one line) opens the genie
  /// card instead of revealing inside the heart — a heart only holds a few
  /// words cleanly.
  static const int longThreshold = 42;

  @override
  State<HeartBubble> createState() => _HeartBubbleState();
}

class _HeartBubbleState extends State<HeartBubble>
    with TickerProviderStateMixin {
  late final AnimationController _beat = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400));
  late final Animation<double> _scale = TweenSequence<double>([
    // lub-dub: two quick beats then rest.
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.07), weight: 8),
    TweenSequenceItem(tween: Tween(begin: 1.07, end: 1.0), weight: 10),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.05), weight: 7),
    TweenSequenceItem(tween: Tween(begin: 1.05, end: 1.0), weight: 10),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 55),
  ]).animate(_beat);

  // A slow continuous clock for the drifting star field around the heart.
  late final AnimationController _stars = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 7200));

  final GlobalKey _heartKey = GlobalKey();
  bool _revealedInHeart = false;
  bool _visible = false;
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _syncBeat();
  }

  void _syncBeat() {
    if (_visible && !_reduceMotion && !_revealedInHeart) {
      if (!_beat.isAnimating) _beat.repeat();
    } else {
      if (_beat.isAnimating) {
        _beat.stop();
        _beat.value = 0;
      }
    }
    final starsOn = _visible && !_reduceMotion;
    if (starsOn) {
      if (!_stars.isAnimating) _stars.repeat();
    } else if (_stars.isAnimating) {
      _stars.stop();
    }
  }

  @override
  void dispose() {
    _stars.dispose();
    _beat.dispose();
    super.dispose();
  }

  bool get _isLong =>
      widget.text.trim().length > HeartBubble.longThreshold ||
      widget.text.contains('\n');

  void _onTap() {
    if (_isLong) {
      final box = _heartKey.currentContext?.findRenderObject() as RenderBox?;
      Rect origin;
      if (box != null && box.hasSize) {
        final tl = box.localToGlobal(Offset.zero);
        origin = tl & box.size;
      } else {
        origin = Rect.zero;
      }
      showHeartGenie(context,
          originRect: origin, text: widget.text, accent: widget.accent);
    } else {
      setState(() => _revealedInHeart = !_revealedInHeart);
      _syncBeat();
    }
  }

  void _loveBack() {
    HapticFeedback.mediumImpact();
    final box = _heartKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      _showLoveBurst(context, box.localToGlobal(Offset.zero) & box.size,
          widget.accent);
    }
    widget.onLoveBack?.call();
  }

  @override
  Widget build(BuildContext context) {
    final revealed = _revealedInHeart && !_isLong;
    return VisibilityDetector(
      key: Key('heart-${widget.heartKeySeed ?? widget.text.hashCode}'),
      onVisibilityChanged: (info) {
        final v = info.visibleFraction > 0.15;
        if (v != _visible) {
          _visible = v;
          if (mounted) _syncBeat();
        }
      },
      child: GestureDetector(
        onTap: _onTap,
        onDoubleTap: widget.onLoveBack == null ? null : _loveBack,
        child: _withStars(revealed),
      ),
    );
  }

  Widget _withStars(bool revealed) {
    final heart = AnimatedBuilder(
      animation: _scale,
      builder: (context, _) => Transform.scale(
        scale: revealed ? 1.0 : _scale.value,
        child: _heart(revealed),
      ),
    );
    if (_reduceMotion) return heart;
    return SizedBox(
      width: 160,
      height: 142,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _stars,
                  builder: (context, _) => CustomPaint(
                    painter: _StarsPainter(_stars.value, widget.accent),
                  ),
                ),
              ),
            ),
          ),
          heart,
        ],
      ),
    );
  }

  Widget _heart(bool revealed) {
    return SizedBox(
      key: _heartKey,
      width: 160,
      height: 142,
      child: CustomPaint(
        painter: _HeartPainter(widget.accent),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 30, 20, 34),
          child: Center(
            child: revealed
                ? SingleChildScrollView(
                    child: Text(
                      widget.text,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                          height: 1.2,
                          fontWeight: FontWeight.w600),
                    ),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.lock_rounded,
                          color: Colors.white, size: 20),
                      const SizedBox(height: 4),
                      Text(
                        _isLong ? 'tap to open' : 'tap to reveal',
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.95),
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.3),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _HeartPainter extends CustomPainter {
  _HeartPainter(this.accent);
  final Color accent;

  static Path heartPath(Size s) {
    final w = s.width, h = s.height;
    final path = Path();
    path.moveTo(0.5 * w, 0.34 * h);
    path.cubicTo(0.16 * w, -0.05 * h, -0.28 * w, 0.36 * h, 0.5 * w, 0.95 * h);
    path.cubicTo(1.28 * w, 0.36 * h, 0.84 * w, -0.05 * h, 0.5 * w, 0.34 * h);
    path.close();
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = heartPath(size);
    final rect = Offset.zero & size;
    final w = size.width, h = size.height;

    // 1) Soft coloured glow behind the heart — premium lift off the wallpaper.
    canvas.drawPath(
      path,
      Paint()
        ..color = accent.withValues(alpha: 0.38)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
    // 2) Grounding contact shadow.
    canvas.drawShadow(path.shift(const Offset(0, 6)), Colors.black87, 10, false);

    // 3) Volume: radial gradient lit from the upper-left so the lobes read as
    //    rounded, with a deep shaded bottom tip.
    final base = RadialGradient(
      center: const Alignment(-0.35, -0.62),
      radius: 1.25,
      colors: [
        Color.lerp(accent, Colors.white, 0.72)!,
        Color.lerp(accent, Colors.white, 0.28)!,
        accent,
        Color.lerp(accent, Colors.black, 0.4)!,
        Color.lerp(accent, Colors.black, 0.68)!,
      ],
      stops: const [0.0, 0.22, 0.52, 0.8, 1.0],
    );
    canvas.drawPath(path, Paint()..shader = base.createShader(rect));

    // 4) Inside-the-heart shading: clip to the heart, then sculpt the volume.
    canvas.save();
    canvas.clipPath(path);
    // 4a) Deep core shadow pooled at the bottom tip → real sense of mass.
    final tip = Offset(w * 0.5, h * 0.82);
    canvas.drawCircle(
      tip,
      w * 0.6,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.black.withValues(alpha: 0.42),
            Colors.black.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromCircle(center: tip, radius: w * 0.6)),
    );
    // 4b) Gentle overall bottom darken for grounding.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.center,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.26)],
        ).createShader(rect),
    );
    // 4c) Big soft specular sheen on the upper-left lobe.
    final hlCenter = Offset(w * 0.33, h * 0.22);
    canvas.drawCircle(
      hlCenter,
      w * 0.32,
      Paint()
        ..shader = RadialGradient(colors: [
          Colors.white.withValues(alpha: 0.6),
          Colors.white.withValues(alpha: 0.0),
        ]).createShader(Rect.fromCircle(center: hlCenter, radius: w * 0.32))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );
    // 4d) Secondary smaller glossy catch on the right lobe → both bumps lit.
    final hl2 = Offset(w * 0.66, h * 0.26);
    canvas.drawCircle(
      hl2,
      w * 0.17,
      Paint()
        ..shader = RadialGradient(colors: [
          Colors.white.withValues(alpha: 0.32),
          Colors.white.withValues(alpha: 0.0),
        ]).createShader(Rect.fromCircle(center: hl2, radius: w * 0.17))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    // 4e) Crisp hotspot sparkle on the main lobe.
    canvas.drawCircle(
      Offset(w * 0.3, h * 0.18),
      w * 0.05,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.85)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    canvas.restore();

    // 5) Bright rim light along the edge (top-left catches the light).
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.5),
            Colors.white.withValues(alpha: 0.05),
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_HeartPainter old) => old.accent != accent;
}

/// A gentle field of tiny twinkling stars drifting down around the heart.
class _StarsPainter extends CustomPainter {
  _StarsPainter(this.t, this.accent);
  final double t; // 0..1 loop phase
  final Color accent;

  static const int _count = 13;

  double _hash(int i) {
    final x = math.sin(i * 12.9898) * 43758.5453;
    return x - x.floorToDouble();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final tint = Color.lerp(Colors.white, accent, 0.2)!;
    const tau = math.pi * 2;
    for (int i = 0; i < _count; i++) {
      final fx = _hash(i * 2 + 1);
      final speed = 0.45 + _hash(i * 7 + 3) * 0.75;
      final phase = _hash(i * 5 + 2);
      final scale = 0.6 + _hash(i * 3 + 4) * 1.0;
      final fy = (phase + t * speed) % 1.0;
      final x = fx * w + math.sin((t * speed + phase) * tau) * 3.0;
      final y = fy * h;
      // fade in/out at the top and bottom edges
      final edge = (fy < 0.12
              ? fy / 0.12
              : (fy > 0.88 ? (1 - fy) / 0.12 : 1.0))
          .clamp(0.0, 1.0);
      // twinkle
      final tw = 0.3 + 0.7 * (0.5 + 0.5 * math.sin((t * speed * 3 + phase) * tau));
      final a = (0.9 * edge * tw).clamp(0.0, 1.0);
      if (a <= 0.02) continue;
      final r = 1.1 * scale;
      final color = tint.withValues(alpha: a);
      // soft glow
      canvas.drawCircle(
        Offset(x, y),
        r * 2.4,
        Paint()
          ..color = tint.withValues(alpha: a * 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      );
      // four-point sparkle cross
      final p = Paint()
        ..color = color
        ..strokeCap = StrokeCap.round
        ..strokeWidth = r * 0.7;
      final arm = r * 2.2;
      canvas.drawLine(Offset(x - arm, y), Offset(x + arm, y), p);
      canvas.drawLine(Offset(x, y - arm), Offset(x, y + arm), p);
      // bright core
      canvas.drawCircle(
          Offset(x, y), r * 0.7, Paint()..color = Colors.white.withValues(alpha: a));
    }
  }

  @override
  bool shouldRepaint(_StarsPainter old) => old.t != t || old.accent != accent;
}

/// Bloom a decorated "genie" card out of the heart at [originRect], with the
/// note scrolling independently. Dismisses (collapsing back into the heart) on
/// tap-outside, swipe-down, or the system/hardware back button.
void showHeartGenie(
  BuildContext context, {
  required Rect originRect,
  required String text,
  required Color accent,
}) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _HeartGenie(
      originRect: originRect,
      text: text,
      accent: accent,
      onClosed: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
}

class _HeartGenie extends StatefulWidget {
  const _HeartGenie({
    required this.originRect,
    required this.text,
    required this.accent,
    required this.onClosed,
  });
  final Rect originRect;
  final String text;
  final Color accent;
  final VoidCallback onClosed;

  @override
  State<_HeartGenie> createState() => _HeartGenieState();
}

class _HeartGenieState extends State<_HeartGenie>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 320))
    ..forward();
  double _dragDy = 0;

  Future<void> _close() async {
    if (_c.isAnimating && _c.status == AnimationStatus.reverse) return;
    await _c.reverse();
    if (mounted) widget.onClosed();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    // Transform origin = the heart's centre on screen (0..1 alignment).
    final oc = widget.originRect.center;
    final alignX = size.width == 0 ? 0.0 : (oc.dx / size.width) * 2 - 1;
    final alignY = size.height == 0 ? 0.0 : (oc.dy / size.height) * 2 - 1;
    final origin = Alignment(alignX.clamp(-1.0, 1.0), alignY.clamp(-1.0, 1.0));

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = Curves.easeOutBack.transform(_c.value.clamp(0.0, 1.0));
          final fade = _c.value.clamp(0.0, 1.0);
          return Stack(
            children: [
              // Barrier.
              Positioned.fill(
                child: GestureDetector(
                  onTap: _close,
                  child: Container(
                      color: Colors.black.withValues(alpha: 0.55 * fade)),
                ),
              ),
              // Card, growing out of the heart.
              Center(
                child: Transform.translate(
                  offset: Offset(0, _dragDy),
                  child: Transform.scale(
                    scale: (0.2 + 0.8 * t).clamp(0.0, 1.0),
                    alignment: origin,
                    child: Opacity(
                      opacity: fade,
                      child: GestureDetector(
                        onVerticalDragUpdate: (d) =>
                            setState(() => _dragDy += d.delta.dy),
                        onVerticalDragEnd: (d) {
                          if (_dragDy.abs() > 90 ||
                              (d.primaryVelocity ?? 0).abs() > 700) {
                            _close();
                          } else {
                            setState(() => _dragDy = 0);
                          }
                        },
                        child: _card(context),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _card(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final a = widget.accent;
    return Material(
      color: Colors.transparent,
      child: Container(
        width: (size.width * 0.82).clamp(250.0, 420.0),
        constraints: BoxConstraints(maxHeight: size.height * 0.62),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          // Deep, accent-TINTED dark glass — on-theme but never loud/noisy.
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.lerp(a, Colors.black, 0.70)!,
              Color.lerp(a, Colors.black, 0.88)!,
            ],
          ),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          boxShadow: [
            // soft coloured halo + grounding shadow
            BoxShadow(
              color: a.withValues(alpha: 0.32),
              blurRadius: 44,
              spreadRadius: -8,
              offset: const Offset(0, 20),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 22,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: Stack(
            children: [
              // Gentle accent sheen along the top edge.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 96,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [a.withValues(alpha: 0.30), Colors.transparent],
                    ),
                  ),
                ),
              ),
              // Faint decorative motifs tucked into two corners (like the
              // chat wallpaper) — hearts, notes, sparkles.
              const Positioned(top: 8, left: 10, child: _CardMotifs(flip: false)),
              const Positioned(
                  bottom: 8, right: 10, child: _CardMotifs(flip: true)),
              // Content.
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Glass heart badge.
                    Container(
                      padding: const EdgeInsets.all(11),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.12),
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.22)),
                      ),
                      child: Icon(Icons.favorite_rounded,
                          size: 22,
                          color: Color.lerp(a, Colors.white, 0.45)),
                    ),
                    const SizedBox(height: 16),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Text(
                          widget.text,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.96),
                            fontSize: 16.5,
                            height: 1.5,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.close_fullscreen_rounded,
                            size: 11,
                            color: Colors.white.withValues(alpha: 0.5)),
                        const SizedBox(width: 5),
                        Text(
                          'tap outside to close',
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.55),
                              fontSize: 10.5,
                              letterSpacing: 0.5),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Faint corner motifs for the genie card — a tiny scatter of hearts, music
/// notes and sparkles echoing the chat wallpaper.
class _CardMotifs extends StatelessWidget {
  const _CardMotifs({required this.flip});
  final bool flip;

  @override
  Widget build(BuildContext context) {
    final c = Colors.white.withValues(alpha: 0.10);
    final items = flip
        ? const [Icons.music_note_rounded, Icons.favorite_rounded, Icons.auto_awesome_rounded]
        : const [Icons.favorite_rounded, Icons.music_note_rounded, Icons.auto_awesome_rounded];
    return IgnorePointer(
      child: SizedBox(
        width: 76,
        height: 64,
        child: Stack(
          children: [
            Positioned(left: 6, top: 8, child: Icon(items[0], size: 20, color: c)),
            Positioned(left: 40, top: 2, child: Icon(items[1], size: 13, color: c)),
            Positioned(left: 20, top: 34, child: Icon(items[2], size: 15, color: c)),
          ],
        ),
      ),
    );
  }
}

/// A brief burst of little hearts rising + fading from [origin] — the reward
/// for a bonded "love back" double-tap. Self-removing after the animation.
void _showLoveBurst(BuildContext context, Rect origin, Color accent) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _LoveBurst(
      origin: origin,
      accent: accent,
      onDone: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
}

class _LoveBurst extends StatefulWidget {
  const _LoveBurst({
    required this.origin,
    required this.accent,
    required this.onDone,
  });
  final Rect origin;
  final Color accent;
  final VoidCallback onDone;

  @override
  State<_LoveBurst> createState() => _LoveBurstState();
}

class _LoveBurstState extends State<_LoveBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100))
    ..forward().whenComplete(widget.onDone);

  // Per-heart jitter: horizontal drift, size, delay.
  static const _n = 7;
  final List<double> _dx = List.generate(_n, (i) => (i - _n / 2) * 9.0);
  final List<double> _size = List.generate(_n, (i) => 14.0 + (i % 3) * 6.0);
  final List<double> _delay = List.generate(_n, (i) => (i % 4) * 0.08);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cx = widget.origin.center.dx;
    final top = widget.origin.top;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final hearts = <Widget>[];
          for (var i = 0; i < _n; i++) {
            final t = ((_c.value - _delay[i]) / (1 - _delay[i])).clamp(0.0, 1.0);
            if (t <= 0) continue;
            final rise = 70.0 * t;
            final opacity = (t < 0.15 ? t / 0.15 : (1 - t)).clamp(0.0, 1.0);
            hearts.add(Positioned(
              left: cx + _dx[i] * t,
              top: top - rise,
              child: Opacity(
                opacity: opacity,
                child: Transform.scale(
                  scale: 0.6 + 0.6 * t,
                  child: Icon(Icons.favorite_rounded,
                      size: _size[i], color: widget.accent),
                ),
              ),
            ));
          }
          return Stack(children: hearts);
        },
      ),
    );
  }
}
