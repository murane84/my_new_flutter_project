import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    with SingleTickerProviderStateMixin {
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
  }

  @override
  void dispose() {
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
        child: AnimatedBuilder(
          animation: _scale,
          builder: (context, _) => Transform.scale(
            scale: revealed ? 1.0 : _scale.value,
            child: _heart(revealed),
          ),
        ),
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
      center: const Alignment(-0.35, -0.5),
      radius: 1.15,
      colors: [
        Color.lerp(accent, Colors.white, 0.5)!,
        accent,
        Color.lerp(accent, Colors.black, 0.55)!,
      ],
      stops: const [0.0, 0.52, 1.0],
    );
    canvas.drawPath(path, Paint()..shader = base.createShader(rect));

    // 4) Inside-the-heart shading: glossy highlight + bottom inner shadow.
    canvas.save();
    canvas.clipPath(path);
    // Bottom inner shadow → depth at the tip.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.center,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.34)],
        ).createShader(rect),
    );
    // Big soft specular sheen on the upper-left lobe.
    final hlCenter = Offset(w * 0.33, h * 0.24);
    canvas.drawCircle(
      hlCenter,
      w * 0.30,
      Paint()
        ..shader = RadialGradient(colors: [
          Colors.white.withValues(alpha: 0.55),
          Colors.white.withValues(alpha: 0.0),
        ]).createShader(Rect.fromCircle(center: hlCenter, radius: w * 0.30))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    // Small crisp sparkle.
    canvas.drawCircle(
      Offset(w * 0.30, h * 0.2),
      w * 0.045,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.75)
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
    return Material(
      color: Colors.transparent,
      child: Container(
        width: (size.width * 0.82).clamp(240.0, 420.0),
        constraints: BoxConstraints(maxHeight: size.height * 0.6),
        padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.lerp(widget.accent, Colors.white, 0.12)!,
              widget.accent,
              Color.lerp(widget.accent, Colors.black, 0.42)!,
            ],
            stops: const [0.0, 0.5, 1.0],
          ),
          boxShadow: [
            BoxShadow(
              color: widget.accent.withValues(alpha: 0.5),
              blurRadius: 34,
              offset: const Offset(0, 16),
            ),
          ],
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(Icons.favorite_rounded, color: Colors.white, size: 26),
            const SizedBox(height: 14),
            Flexible(
              child: SingleChildScrollView(
                child: Text(
                  widget.text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      height: 1.4,
                      fontWeight: FontWeight.w500),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'tap outside to close',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 10.5,
                  letterSpacing: 0.3),
            ),
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
