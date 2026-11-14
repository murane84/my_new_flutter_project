import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../utils/motion.dart';
import '../utils/radii.dart';

/// Where a message (or anything with an "opened" receipt) stands.
enum BookState { sending, queued, sent, delivered, read, failed }

/// What the book carries: a song / voice note floats a music note when it is
/// played instead of the heart.
enum BookKind { text, music }

/// Aluta's own message status — a little book instead of ticks.
///
///  • sending  — a tiny grey spinner
///  • sent     — the grey closed book flying on outlined wings, leaning
///               toward the friend's side, a soft trail at its lower right
///  • delivered— it lands: tilts upright, wings fold away, settles once
///  • read     — the book opens and washes into the theme colour; in a bond
///               chat (and only on the newest message) a heart floats up
///               once — a music note for songs and voice notes
///  • group    — [openFraction] opens the book partway as members read it,
///               with a small count; fully open when everyone has
///
/// Motion plays only when the state CHANGES while [animate] is on (the
/// newest bubble); everything else, and reduce-motion, shows the final state.
class BookTick extends StatefulWidget {
  const BookTick({
    super.key,
    required this.state,
    required this.muted,
    required this.color,
    this.kind = BookKind.text,
    this.animate = false,
    this.heart = false,
    this.openFraction,
    this.openedCount,
    this.onTap,
    this.size = 22,
  });

  final BookState state;

  /// Grey for waiting states.
  final Color muted;

  /// The theme colour the book washes into when opened.
  final Color color;
  final BookKind kind;
  final bool animate;

  /// Float a heart (or note) when it opens — bond chats, newest message.
  final bool heart;

  /// Groups: share of members who opened it (0–1); null = not a group.
  final double? openFraction;

  /// Groups: how many opened it (shown beside a part-open book).
  final int? openedCount;
  final VoidCallback? onTap;
  final double size;

  @override
  State<BookTick> createState() => _BookTickState();
}

class _BookTickState extends State<BookTick>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1500))
    ..value = 1;
  late BookState _from = widget.state;
  late double _fromOpen = _openOf(widget);

  static double _openOf(BookTick w) {
    if (w.state == BookState.read) return 1;
    final f = w.openFraction;
    if (f != null && f > 0 && w.state == BookState.delivered) {
      return 0.35 + 0.5 * f.clamp(0.0, 1.0);
    }
    return 0;
  }

  @override
  void didUpdateWidget(BookTick old) {
    super.didUpdateWidget(old);
    final changed = old.state != widget.state ||
        _openOf(old) != _openOf(widget);
    if (!changed) return;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.animate && !reduce) {
      _from = old.state;
      _fromOpen = _openOf(old);
      _c.forward(from: 0);
    } else {
      _from = widget.state;
      _fromOpen = _openOf(widget);
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  String get _label => switch (widget.state) {
        BookState.sending => 'Sending',
        BookState.queued => 'Waiting to send',
        BookState.sent => 'Sent',
        BookState.delivered => (widget.openedCount ?? 0) > 0
            ? 'Opened by ${widget.openedCount}'
            : 'Delivered',
        BookState.read =>
          widget.kind == BookKind.music ? 'Played' : 'Read',
        BookState.failed => 'Not sent, tap to retry',
      };

  @override
  Widget build(BuildContext context) {
    final w = widget.size;
    final h = w * 16 / 22;
    Widget icon;
    if (widget.state == BookState.sending) {
      icon = SizedBox(
        width: w,
        height: h,
        child: Center(
          child: SizedBox(
            width: h * 0.7,
            height: h * 0.7,
            child: CircularProgressIndicator(
                strokeWidth: 1.6, color: widget.muted),
          ),
        ),
      );
    } else {
      icon = AnimatedBuilder(
        animation: _c,
        builder: (_, _) => CustomPaint(
          size: Size(w, h),
          painter: _BookPainter(
            from: _from,
            to: widget.state,
            fromOpen: _fromOpen,
            toOpen: _openOf(widget),
            t: _c.value,
            muted: widget.muted,
            color: widget.color,
            kind: widget.kind,
            heart: widget.heart,
          ),
        ),
      );
    }
    final count = widget.openedCount ?? 0;
    if (widget.state == BookState.delivered && count > 0) {
      icon = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          Text('$count',
              style: TextStyle(
                  fontSize: 10,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  color: Color.lerp(widget.muted, widget.color, 0.6))),
        ],
      );
    }
    return Semantics(
      label: _label,
      button: widget.onTap != null,
      child: widget.onTap == null
          ? icon
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
                child: icon,
              ),
            ),
    );
  }
}

// ── Drawing (a 48 × 48 design grid, cropped to the book's band) ───────────

double _seg(double t, double a, double b) =>
    ((t - a) / (b - a)).clamp(0.0, 1.0);

class _BookPainter extends CustomPainter {
  _BookPainter({
    required this.from,
    required this.to,
    required this.fromOpen,
    required this.toOpen,
    required this.t,
    required this.muted,
    required this.color,
    required this.kind,
    required this.heart,
  });

  final BookState from, to;
  final double fromOpen, toOpen, t;
  final Color muted, color;
  final BookKind kind;
  final bool heart;

  static const _w = 1.15; // strokes a touch firmer at bubble size

  Paint _stroke(Color c, double width, [double alpha = 1]) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width * _w
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..color = c.withValues(alpha: c.a * alpha);

  Paint _fill(Color c, [double alpha = 1]) => Paint()
    ..style = PaintingStyle.fill
    ..color = c.withValues(alpha: c.a * alpha);

  static Path _heartPath(double x, double y, double s) {
    final p = Path()
      ..moveTo(0, -2.2)
      ..cubicTo(-1, -3.8, -3.6, -3.2, -3.4, -1.2)
      ..cubicTo(-3.2, 0.5, 0, 2.3, 0, 2.3)
      ..cubicTo(0, 2.3, 3.2, 0.5, 3.4, -1.2)
      ..cubicTo(3.6, -3.2, 1, -3.8, 0, -2.2)
      ..close();
    final m = Matrix4.identity()
      ..translateByDouble(x, y, 0, 1)
      ..scaleByDouble(s, s, 1, 1);
    return p.transform(m.storage);
  }

  static final Path _wingL = Path()
    ..moveTo(15, 23.5)
    ..cubicTo(12, 17.5, 7, 13.5, 1.5, 11.5)
    ..cubicTo(2.5, 15.5, 4.5, 17.5, 6.5, 18.6)
    ..cubicTo(4.7, 18.7, 3.5, 19.2, 2.5, 19.8)
    ..cubicTo(4.5, 22.4, 7, 23.4, 9.2, 23.5)
    ..cubicTo(7.8, 24.4, 7.1, 25.4, 6.7, 26.4)
    ..cubicTo(9.5, 28, 12.4, 28.6, 15, 28.2);

  static final Path _wingR = _wingL.transform((Matrix4.identity()
        ..translateByDouble(48, 0, 0, 1)
        ..scaleByDouble(-1, 1, 1, 1))
      .storage);

  static final Path _pageL = Path()
    ..moveTo(24, 16)
    ..cubicTo(21, 13.5, 16, 12.5, 11, 13.5)
    ..lineTo(11, 34.5)
    ..cubicTo(16, 33.5, 21, 34.5, 24, 37)
    ..close();

  static final Path _pageR = _pageL.transform((Matrix4.identity()
        ..translateByDouble(48, 0, 0, 1)
        ..scaleByDouble(-1, 1, 1, 1))
      .storage);

  void _closed(Canvas c, Color col, double alpha) {
    if (alpha <= 0) return;
    c.drawRRect(
        RRect.fromRectAndRadius(
            const Rect.fromLTWH(15, 12, 18, 24), const Radius.circular(2.5)),
        _stroke(col, 2.6, alpha));
    c.drawLine(const Offset(19, 12), const Offset(19, 36),
        _stroke(col, 2.2, alpha));
    c.drawPath(_heartPath(26.5, 23, 1.05), _fill(col, alpha));
  }

  void _wings(Canvas c, Color col, double flap, double fold) {
    if (fold >= 1) return;
    final a = 1 - fold;
    final p = _stroke(col, 2.2, a);
    void one(Path path, double pivotX, double dir) {
      c.save();
      c.translate(pivotX, 26);
      c.rotate(dir * (flap - fold * 80) * math.pi / 180);
      final s = 1 - 0.85 * fold;
      c.scale(s, s);
      c.translate(-pivotX, -26);
      c.drawPath(path, p);
      c.restore();
    }

    one(_wingL, 15, 1);
    one(_wingR, 33, -1);
  }

  void _trail(Canvas c, Color col, double alpha, double dx) {
    if (alpha <= 0) return;
    final p = _stroke(col, 1.6, 0.55 * alpha);
    c.drawLine(Offset(37 + dx, 32), Offset(44 + dx, 32), p);
    c.drawLine(Offset(38 + dx, 35.5), Offset(44 + dx, 35.5), p);
    c.drawLine(Offset(40 + dx, 39), Offset(43 + dx, 39), p);
  }

  void _open(Canvas c, Color col, double open) {
    if (open <= 0) return;
    final p = _stroke(col, 2.6);
    for (final page in [_pageL, _pageR]) {
      c.save();
      c.translate(24, 30);
      c.scale(0.1 + 0.9 * open, 1);
      c.translate(-24, -30);
      c.drawPath(page, p);
      c.restore();
    }
    c.drawLine(const Offset(24, 16), const Offset(24, 37), _stroke(col, 2));
  }

  void _float(Canvas c, double k) {
    if (k <= 0 || k >= 1) return;
    // in fast, drift up, fade away
    final up = k < 0.3 ? k / 0.3 : 1.0;
    final alpha = k < 0.3 ? up : 1 - (k - 0.3) / 0.7;
    final y = k < 0.3 ? 6 - 8 * up : -2 - 12 * (k - 0.3) / 0.7;
    final s = k < 0.3 ? 0.4 + 0.6 * up : 1 - 0.15 * (k - 0.3) / 0.7;
    c.save();
    c.translate(24, 10 + y);
    c.scale(s, s);
    if (kind == BookKind.music) {
      final f = _fill(color, alpha);
      c.drawOval(
          Rect.fromCenter(
              center: const Offset(-1.5, 3), width: 5, height: 3.6),
          f);
      c.drawLine(const Offset(0.6, 3), const Offset(0.6, -5),
          _stroke(color, 1.4, alpha));
      c.drawLine(const Offset(0.6, -5), const Offset(4, -3),
          _stroke(color, 1.4, alpha));
    } else {
      c.drawPath(_heartPath(0, 0, 1.4), _fill(color, alpha));
    }
    c.restore();
  }

  void _badge(Canvas c, BookState s) {
    if (s == BookState.failed) {
      c.drawCircle(const Offset(35, 34), 6, _fill(const Color(0xFFE8173F)));
      final p = _stroke(Colors.white, 1.8);
      c.drawLine(const Offset(35, 30.8), const Offset(35, 34.4), p);
      c.drawLine(const Offset(35, 36.8), const Offset(35, 37), p);
    } else if (s == BookState.queued) {
      c.drawCircle(const Offset(35, 34), 5.6, _fill(muted));
      final p = _stroke(Colors.white, 1.4);
      c.drawLine(const Offset(35, 34), const Offset(35, 31), p);
      c.drawLine(const Offset(35, 34), const Offset(37.2, 35.2), p);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 48;
    canvas.save();
    canvas.scale(k);
    canvas.translate(0, size.height / 2 / k - 25);

    final wasFlying = from == BookState.sent;
    switch (to) {
      case BookState.sent:
        final pop = from == BookState.sent
            ? 1.0
            : Curves.easeOutBack.transform(_seg(t, 0, 0.25));
        final fl = _seg(t, 0.1, 0.55);
        final flap = fl < 0.35
            ? 18 * fl / 0.35
            : fl < 0.7
                ? 18 - 26 * (fl - 0.35) / 0.35
                : -8 + 8 * (fl - 0.7) / 0.3;
        final tr = _seg(t, 0.35, 0.7);
        canvas.save();
        canvas.translate(24, 27);
        canvas.scale(pop, pop);
        canvas.rotate(-12 * math.pi / 180);
        canvas.translate(-24, -27);
        _wings(canvas, muted, flap, 0);
        _closed(canvas, muted, 1);
        canvas.restore();
        _trail(canvas, muted, tr, -3 * (1 - tr));
      case BookState.delivered:
      case BookState.read:
        final open = toOpen;
        // Landing first when it was still flying (sent → delivered / read).
        final landEnd = wasFlying ? (to == BookState.read ? 0.35 : 0.8) : 0.0;
        final lt = landEnd == 0 ? 1.0 : _seg(t, 0, landEnd);
        final tilt = wasFlying
            ? -12 * (1 - Curves.easeOutBack.transform(_seg(lt, 0, 0.5)))
            : 0.0;
        final fold = wasFlying ? Curves.easeIn.transform(_seg(lt, 0, 0.55)) : 1.0;
        final settle = wasFlying ? _seg(lt, 0.55, 1) : 1.0;
        final sq = math.sin(settle * math.pi) * 0.05;
        final pop = (from == BookState.sending || from == BookState.queued ||
                from == BookState.failed)
            ? Curves.easeOutBack.transform(_seg(t, 0, 0.3))
            : 1.0;
        final openFrom = (from == BookState.read ||
                from == BookState.delivered)
            ? fromOpen
            : 0.0;
        final ot = open == openFrom
            ? 1.0
            : Curves.easeOutCubic.transform(_seg(t, landEnd, landEnd + 0.4));
        final o = openFrom + (open - openFrom) * ot;
        // Washes into the colour as it opens; part-open (a group) stays
        // part-tinted, fully open is the full theme colour.
        final col = Color.lerp(muted, color, o >= 0.999 ? 1.0 : o * 0.85)!;
        if (wasFlying) _trail(canvas, muted, 1 - _seg(lt, 0, 0.3), 0);
        canvas.save();
        canvas.translate(24, 27);
        canvas.scale(pop, pop);
        canvas.rotate(tilt * math.pi / 180);
        canvas.translate(-24, -27);
        _wings(canvas, muted, 0, fold);
        canvas.save();
        canvas.translate(24, 36);
        canvas.scale(1 + sq * 0.8, 1 - sq);
        canvas.translate(-24, -36);
        // closed book hands over to the opening one
        final closedA = o <= 0 ? 1.0 : (1 - (o / 0.35)).clamp(0.0, 1.0);
        if (closedA > 0) {
          canvas.save();
          canvas.translate(24, 24);
          canvas.scale(1 - 0.4 * (1 - closedA), 1);
          canvas.translate(-24, -24);
          _closed(canvas, muted, closedA);
          canvas.restore();
        }
        _open(canvas, col, o);
        canvas.restore();
        canvas.restore();
        if (to == BookState.read && heart && from != BookState.read) {
          _float(canvas, _seg(t, landEnd + 0.25, 1));
        }
      case BookState.queued:
      case BookState.failed:
      case BookState.sending:
        _closed(canvas, muted, 1);
        _badge(canvas, to);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BookPainter o) =>
      o.t != t ||
      o.from != from ||
      o.to != to ||
      o.fromOpen != fromOpen ||
      o.toOpen != toOpen ||
      o.muted != muted ||
      o.color != color ||
      o.heart != heart ||
      o.kind != kind;
}

// ── Tap the book → when it arrived / was opened ───────────────────────────

OverlayEntry? _timesEntry;

/// A small Aluta card popping from the book: "Delivered 6:09 PM · Opened
/// 6:12 PM" (or, in a group, who has opened it). [lines] loads the rows.
void showBookTimes(
  BuildContext context, {
  required Future<List<(String, String)>> lines,
}) {
  _timesEntry?.remove();
  _timesEntry = null;
  final box = context.findRenderObject() as RenderBox?;
  final overlay = Overlay.maybeOf(context);
  if (box == null || overlay == null || !box.attached) return;
  final at = box.localToGlobal(Offset.zero);
  final screen = MediaQuery.sizeOf(context);
  final scheme = Theme.of(context).colorScheme;
  Timer? auto;
  void close() {
    auto?.cancel();
    _timesEntry?.remove();
    _timesEntry = null;
  }

  final right = (screen.width - at.dx - box.size.width).clamp(8.0, screen.width);
  final fromTop = at.dy > 140;
  _timesEntry = OverlayEntry(
    builder: (_) => Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: close,
          ),
        ),
        Positioned(
          right: right,
          top: fromTop ? null : at.dy + box.size.height + 6,
          bottom: fromTop ? screen.height - at.dy + 6 : null,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: Motion.quick,
            curve: Motion.spring,
            builder: (_, v, child) => Opacity(
              opacity: v.clamp(0.0, 1.0),
              child: Transform.scale(
                scale: 0.85 + 0.15 * v,
                alignment:
                    fromTop ? Alignment.bottomRight : Alignment.topRight,
                child: child,
              ),
            ),
            child: Material(
              color: scheme.surfaceContainerHigh,
              elevation: 6,
              borderRadius: BorderRadius.circular(Radii.lg),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  child: FutureBuilder<List<(String, String)>>(
                    future: lines,
                    builder: (_, snap) {
                      if (!snap.hasData) {
                        return SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 1.6, color: scheme.primary),
                        );
                      }
                      final rows = snap.data!;
                      if (rows.isEmpty) {
                        return Text('On its way',
                            style: TextStyle(
                                fontSize: 12.5,
                                color: scheme.onSurfaceVariant));
                      }
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final (k, v) in rows)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 1.5),
                              child: Text.rich(
                                TextSpan(children: [
                                  TextSpan(
                                      text: '$k  ',
                                      style: TextStyle(
                                          color: scheme.onSurfaceVariant)),
                                  TextSpan(
                                      text: v,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700)),
                                ]),
                                style: TextStyle(
                                    fontSize: 12.5, color: scheme.onSurface),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
  overlay.insert(_timesEntry!);
  auto = Timer(const Duration(seconds: 5), close);
}
