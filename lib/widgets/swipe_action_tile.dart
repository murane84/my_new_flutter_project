import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Samsung-style swipe actions on a list tile.
///
/// Drag RIGHT → [onSwipeRight] (e.g. call), drag LEFT → [onSwipeLeft] (e.g.
/// open the chat). The action's colour blooms out of its icon as a circle and
/// fills the strip the tile uncovers; past [threshold] the icon pops (with a
/// tick) and letting go carries the tile all the way across — the colour then
/// floods the whole tile — and the action fires a beat later, after which
/// the tile glides back. Short of the threshold it springs back, nothing
/// happens. Taps and vertical scrolling pass through untouched.
class SwipeActionTile extends StatefulWidget {
  const SwipeActionTile({
    super.key,
    required this.child,
    this.onSwipeRight,
    this.onSwipeLeft,
    this.rightIcon = Icons.call_rounded,
    this.rightLabel = 'Call',
    this.rightColor = const Color(0xFF2EB84F),
    this.leftIcon = Icons.chat_bubble_rounded,
    this.leftLabel = 'Message',
    this.leftColor = const Color(0xFF2F7FEA),
    this.threshold = 0.32,
  });

  final Widget child;
  final VoidCallback? onSwipeRight;
  final VoidCallback? onSwipeLeft;
  final IconData rightIcon;
  final String rightLabel;
  final Color rightColor;
  final IconData leftIcon;
  final String leftLabel;
  final Color leftColor;
  final double threshold;

  @override
  State<SwipeActionTile> createState() => _SwipeActionTileState();
}

class _SwipeActionTileState extends State<SwipeActionTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ac = AnimationController.unbounded(vsync: this)
    ..addListener(() => setState(() => _dx = _ac.value));
  double _dx = 0;
  double _w = 1;
  bool _armed = false;
  bool _busy = false;

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  bool get _right => _dx > 0;

  void _onStart(DragStartDetails _) {
    if (_busy) return;
    _ac.stop();
  }

  void _onUpdate(DragUpdateDetails d) {
    if (_busy) return;
    var next = _dx + d.delta.dx;
    if (next > 0 && widget.onSwipeRight == null) next = 0;
    if (next < 0 && widget.onSwipeLeft == null) next = 0;
    // A little resistance near the end so it never feels like it'll fly off
    // by accident.
    next = next.clamp(-_w * 0.92, _w * 0.92);
    final armed = next.abs() >= _w * widget.threshold;
    if (armed != _armed) {
      _armed = armed;
      if (armed) HapticFeedback.selectionClick();
    }
    setState(() => _dx = next);
  }

  Future<void> _onEnd(DragEndDetails d) async {
    if (_busy) return;
    final v = d.primaryVelocity ?? 0;
    final flung = v.abs() > 900 && v.sign == _dx.sign && _dx != 0;
    if (!(_armed || flung) || _dx == 0) {
      _armed = false;
      await _animateTo(0, const Duration(milliseconds: 260), Curves.easeOutBack);
      return;
    }
    _busy = true;
    final right = _right;
    HapticFeedback.mediumImpact();
    // Carry across: the colour floods the whole tile.
    await _animateTo(right ? _w : -_w, const Duration(milliseconds: 220),
        Curves.easeOutCubic);
    // A beat with the tile fully coloured, then act.
    await Future<void>.delayed(const Duration(milliseconds: 140));
    if (!mounted) return;
    (right ? widget.onSwipeRight : widget.onSwipeLeft)?.call();
    // Glide back while the next screen / sheet takes over.
    await Future<void>.delayed(const Duration(milliseconds: 260));
    if (!mounted) return;
    _armed = false;
    await _animateTo(0, const Duration(milliseconds: 320), Curves.easeOutCubic);
    _busy = false;
  }

  Future<void> _animateTo(double to, Duration dur, Curve curve) async {
    if (!mounted) return;
    _ac.value = _dx;
    await _ac.animateTo(to, duration: dur, curve: curve);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      _w = c.maxWidth.isFinite && c.maxWidth > 0 ? c.maxWidth : 1;
      final p = (_dx.abs() / _w).clamp(0.0, 1.0);
      final right = _right;
      final color = right ? widget.rightColor : widget.leftColor;
      final icon = right ? widget.rightIcon : widget.leftIcon;
      final label = right ? widget.rightLabel : widget.leftLabel;
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: _onStart,
        onHorizontalDragUpdate: _onUpdate,
        onHorizontalDragEnd: _onEnd,
        child: Stack(
          children: [
            if (_dx != 0)
              Positioned.fill(
                child: ClipRect(
                  clipper: _StripClip(_dx),
                  child: CustomPaint(
                    painter: _BloomPainter(
                      color: color,
                      progress: p,
                      armed: _armed || _busy,
                      fromLeft: right,
                    ),
                    child: Align(
                      alignment:
                          right ? Alignment.centerLeft : Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 22),
                        child: AnimatedScale(
                          scale: (_armed || _busy) ? 1.18 : 0.9,
                          duration: const Duration(milliseconds: 160),
                          curve: Curves.easeOutBack,
                          child: Opacity(
                            opacity: (p * 4).clamp(0.0, 1.0),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(icon, color: Colors.white, size: 24),
                                const SizedBox(height: 2),
                                Text(label,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w700)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            Transform.translate(offset: Offset(_dx, 0), child: widget.child),
          ],
        ),
      );
    });
  }
}

/// Only the strip the tile has uncovered (the tile itself is see-through).
class _StripClip extends CustomClipper<Rect> {
  _StripClip(this.dx);
  final double dx;
  @override
  Rect getClip(Size s) => dx >= 0
      ? Rect.fromLTWH(0, 0, dx.clamp(0, s.width), s.height)
      : Rect.fromLTWH(s.width + dx, 0, -dx.clamp(-s.width, 0), s.height);
  @override
  bool shouldReclip(covariant _StripClip o) => o.dx != dx;
}

/// The action colour blooming as a circle out of the icon's corner: a soft
/// tint while dragging, a full flood once armed / carried across.
class _BloomPainter extends CustomPainter {
  _BloomPainter({
    required this.color,
    required this.progress,
    required this.armed,
    required this.fromLeft,
  });
  final Color color;
  final double progress;
  final bool armed;
  final bool fromLeft;

  @override
  void paint(Canvas c, Size s) {
    // Base tint so the strip is never blank.
    c.drawRect(Offset.zero & s,
        Paint()..color = color.withValues(alpha: 0.35 + 0.35 * progress));
    final centre = Offset(fromLeft ? 40 : s.width - 40, s.height / 2);
    final full = math.sqrt(s.width * s.width + s.height * s.height);
    final r = armed
        ? full
        : (s.height * 0.6 + full * progress * 1.6).clamp(0.0, full);
    c.drawCircle(centre, r, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _BloomPainter o) =>
      o.progress != progress ||
      o.armed != armed ||
      o.color != color ||
      o.fromLeft != fromLeft;
}
