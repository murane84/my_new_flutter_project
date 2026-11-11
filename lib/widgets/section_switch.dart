import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/section_transition.dart';

/// Switches between sections with the user's chosen transition (Appearance
/// → Section transitions). Give each section's child a distinct key; set
/// [forward] to whether the new one sits further along (it comes from that
/// side). Always clipped to its own box — nothing ever spills over
/// neighbouring panels.
class SectionSwitch extends StatelessWidget {
  const SectionSwitch({
    super.key,
    required this.child,
    required this.forward,
    this.style,
    this.duration = const Duration(milliseconds: 420),
    this.rippleFrom,
  });

  final Widget child;
  final bool forward;
  final SectionTransitionStyle? style; // null = the user's choice
  final Duration duration;
  // Ripple: where it starts across the top, 0..1 (the tapped segment's
  // centre); null = the side it comes from.
  final double? rippleFrom;

  /// A drag just played this change under the finger — the switch that
  /// follows it must not animate it a second time.
  static DateTime? skipUntil;

  @override
  Widget build(BuildContext context) {
    final fixed = style;
    if (fixed != null) return _build(context, fixed);
    return ValueListenableBuilder<SectionTransitionStyle>(
      valueListenable: SectionTransition.instance.style,
      builder: (context, s, _) => _build(context, s),
    );
  }

  Widget _build(BuildContext context, SectionTransitionStyle s) {
    final accent = Theme.of(context).colorScheme.primary;
    final dir = forward ? 1.0 : -1.0;
    // The device's "reduce motion" wins over any style: a plain, quick
    // cross-fade.
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      return ClipRect(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          layoutBuilder: _layout,
          // Same hand-over rule as every style: the leaving page is gone
          // by 40 %, the arriving one starts at 15 %, so they never print
          // over each other.
          transitionBuilder: (c, a) => KeyedSubtree(
              key: c.key,
              child: FadeTransition(
                  opacity: a.drive(CurveTween(
                      curve: c.key == child.key
                          ? const Interval(0.15, 1)
                          : const Interval(0.6, 1))),
                  child: c)),
          child: child,
        ),
      );
    }
    final skip = skipUntil != null && DateTime.now().isBefore(skipUntil!);
    final ms = skip
        ? Duration.zero
        : s == SectionTransitionStyle.wave ||
                s == SectionTransitionStyle.ripple ||
                s == SectionTransitionStyle.equaliser
            ? duration + const Duration(milliseconds: 120)
            : duration;
    return ClipRect(
      child: AnimatedSwitcher(
        duration: ms,
        switchInCurve: Curves.linear,
        switchOutCurve: Curves.linear,
        // Switching BACK to a section that is still animating out would put
        // two copies of it in the tree (duplicate GlobalKeys inside, double
        // scroll attachments) — so a leaving copy of the arriving section
        // is simply dropped.
        layoutBuilder: _layout,
        transitionBuilder: (c, anim) {
          final incoming = c.key == child.key;
          return KeyedSubtree(key: c.key, child: AnimatedBuilder(
            animation: anim,
            child: c,
            builder: (context, w) {
              // t: 0 → 1 while coming in; 1 → 0 while going out.
              final t = anim.value;
              final body =
                  frame(s, w!, t, incoming, dir, accent, rippleFrom: rippleFrom);
              return IgnorePointer(ignoring: !incoming, child: body);
            },
          ));
        },
        child: child,
      ),
    );
  }

  static double _ease(double t) => Curves.easeOutCubic.transform(t);

  static Widget _layout(Widget? cur, List<Widget> prev) {
    final ck = cur == null ? null : _innerKey(cur);
    return Stack(fit: StackFit.expand, children: [
      ...prev.where((p) => ck == null || _innerKey(p) != ck),
      ?cur,
    ]);
  }

  /// Our section key, under AnimatedSwitcher's own entry wrapper.
  static Key? _innerKey(Widget w) => (w is KeyedSubtree ? w.child : w).key;

  // ── The hand-over rule (every style) ───────────────────────────────────
  // Real sections are see-through (they sit on the panel's background), so
  // the leaving page and the arriving one must never both be fully drawn in
  // the same place, or their texts print over each other. So:
  //  • fading / moving styles: the leaving page is gone by 40 % of the
  //    change, and the arriving one only starts showing at 15 %;
  //  • revealing styles (ripple, wave, equaliser): the leaving page is cut
  //    to exactly what is not revealed yet, so they never overlap at all.

  /// Leaving page's opacity at its progress [t] (1 → 0 as it leaves).
  static double _outFade(double t) => ((t - 0.6) / 0.4).clamp(0.0, 1.0);

  /// Arriving page's opacity at its progress [t] (0 → 1).
  static double _inFade(double t) =>
      _ease(((t - 0.15) / 0.85).clamp(0.0, 1.0));

  /// The revealed area of a revealing style at reveal progress [r] (0..1);
  /// null for styles that don't reveal.
  static CustomClipper<Path>? _revealClip(
      SectionTransitionStyle s, double r, double dir, double? rippleFrom) {
    switch (s) {
      case SectionTransitionStyle.ripple:
        return _RippleClipper(Curves.easeInOutCubic.transform(r),
            rippleFrom ?? (dir > 0 ? 0.75 : 0.25));
      case SectionTransitionStyle.wave:
        // The sweep starts on the side the new page COMES FROM (forward =
        // from the right, like the slide and a finger dragging left) —
        // the clippers count their own way, hence -dir.
        return _WaveClipper(_ease(r), -dir);
      case SectionTransitionStyle.equaliser:
        return _BarsClipper(r, -dir);
      default:
        return null;
    }
  }

  /// One frame of style [s] at progress [t] (0 → 1 arriving; 1 → 0
  /// leaving) — also driven by a finger in the chat screen's swipe path.
  static Widget frame(SectionTransitionStyle s, Widget w, double t,
      bool incoming, double dir, Color accent,
      {double? rippleFrom}) {
    final e = _ease(t);
    switch (s) {
      case SectionTransitionStyle.slide:
        return _slide(w, t, incoming, dir);
      case SectionTransitionStyle.slideWave:
        return incoming
            ? Stack(fit: StackFit.expand, children: [
                _slide(w, t, incoming, dir),
                _WaveLine(t: t, dir: -dir, color: accent, opacity: 0.45),
              ])
            : _slide(w, t, incoming, dir);
      case SectionTransitionStyle.depth:
        return Opacity(
          opacity: incoming ? _inFade(t) : _outFade(t),
          child: Transform.scale(
            scale: incoming ? 1.05 - 0.05 * e : 0.93 + 0.07 * e,
            child: w,
          ),
        );
      case SectionTransitionStyle.fade:
        // Out fades quickly; in waits a beat, then fades + grows.
        if (!incoming) return Opacity(opacity: (t * 3 - 2).clamp(0.0, 1.0), child: w);
        final k = ((t - 0.3) / 0.7).clamp(0.0, 1.0);
        final ek = _ease(k);
        return Opacity(
          opacity: ek,
          child: Transform.scale(scale: 0.92 + 0.08 * ek, child: w),
        );
      case SectionTransitionStyle.ripple:
      case SectionTransitionStyle.wave:
      case SectionTransitionStyle.equaliser:
        // Leaving: keep only what the arriving page hasn't covered yet
        // (its reveal is at 1 - t).
        if (!incoming) {
          return ClipPath(
            clipper: _Outside(_revealClip(s, 1 - t, dir, rippleFrom)!),
            child: w,
          );
        }
        final revealed =
            ClipPath(clipper: _revealClip(s, t, dir, rippleFrom), child: w);
        if (s != SectionTransitionStyle.wave) return revealed;
        return Stack(fit: StackFit.expand, children: [
          revealed,
          _WaveLine(t: t, dir: -dir, color: accent, opacity: 1),
        ]);
      case SectionTransitionStyle.cube:
        // A real cube: the two pages are neighbouring faces sharing ONE
        // edge, which travels across as the cube turns — the leaving face
        // swings away on one side while the arriving face swings in on the
        // other. Side by side, so they never print over each other, and no
        // fading (the old version faded two tilted pages at once: muddy).
        return _cubeFace(w, incoming ? t : 1 - t, incoming, dir);
    }
  }

  /// How far a cube face turns at the edge (≈ 70°; a full 90° would show
  /// the faces edge-on, which reads as a flicker on a phone).
  static const double _cubeTurn = 1.22;

  /// One face of the cube at change progress [c] (0 → 1 for the whole
  /// change, whichever face this is). Also used under the finger.
  static Widget _cubeFace(Widget w, double c, bool incoming, double dir) {
    final k = Curves.easeInOutCubic.transform(c.clamp(0.0, 1.0));
    // Arriving: comes from the [dir] side, turned in; leaving: goes to the
    // other side, turning away. Both hinge on the edge they share.
    final away = incoming ? 1 - k : k; // 0 = facing me, 1 = turned away
    final shift = incoming ? dir * (1 - k) : -dir * k;
    final angle = (incoming ? dir : -dir) * _cubeTurn * away;
    final hinge = (incoming ? dir > 0 : dir < 0)
        ? Alignment.centerLeft
        : Alignment.centerRight;
    return FractionalTranslation(
      translation: Offset(shift, 0),
      child: Transform(
        alignment: hinge,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.0011)
          ..rotateY(angle),
        // The face turning away dims a little — the cube's own shading,
        // which is what makes the turn read as depth.
        // (Always the same children — a drag must never rebuild the page.)
        child: Stack(fit: StackFit.passthrough, children: [
          w,
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.18 * away)),
            ),
          ),
        ]),
      ),
    );
  }

  /// The page under the finger while a swipe is in progress (p = how far,
  /// 0..1). ONE fixed shape (Opacity › Transform › ClipPath) for every style
  /// and every p — so the page is never rebuilt from scratch as a drag
  /// starts / ends. Follows the same hand-over rule as [frame].
  static Widget dragOutgoing(
      SectionTransitionStyle s, Widget w, double p, double dir) {
    // The cube turns under the finger exactly as it does on a tap.
    if (s == SectionTransitionStyle.cube) return _cubeFace(w, p, false, dir);
    var o = 1.0;
    var m = Matrix4.identity();
    var a = Alignment.center;
    final out = _outFade(1 - p);
    switch (s) {
      case SectionTransitionStyle.slide:
      case SectionTransitionStyle.slideWave:
        o = out;
        m = Matrix4.translationValues(-30 * dir * _ease(p), 0, 0);
      case SectionTransitionStyle.depth:
        o = out;
        m = Matrix4.diagonal3Values(1 - 0.07 * p, 1 - 0.07 * p, 1);
      case SectionTransitionStyle.fade:
        o = (1 - p * 3).clamp(0.0, 1.0);
      case SectionTransitionStyle.cube:
        break; // (handled above)
      case SectionTransitionStyle.ripple:
      case SectionTransitionStyle.wave:
      case SectionTransitionStyle.equaliser:
        // Stays put; only what isn't revealed yet shows (below).
        break;
    }
    final reveal = _revealClip(s, p, dir, null);
    return Opacity(
      opacity: o.clamp(0.0, 1.0),
      child: Transform(
        alignment: a,
        transform: m,
        child: ClipPath(
          clipper: reveal == null ? const _Whole() : _Outside(reveal),
          child: w,
        ),
      ),
    );
  }

  static Widget _slide(Widget w, double t, bool incoming, double dir) {
    final e = _ease(t);
    final dx = (1 - e) * 30 * (incoming ? dir : -dir);
    return Opacity(
      opacity: incoming ? _inFade(t) : _outFade(t),
      child: Transform.translate(offset: Offset(dx, 0), child: w),
    );
  }
}

/// Everything EXCEPT [inner]'s area (the part not revealed yet).
class _Outside extends CustomClipper<Path> {
  _Outside(this.inner);
  final CustomClipper<Path> inner;
  @override
  Path getClip(Size s) => Path.combine(PathOperation.difference,
      Path()..addRect(Offset.zero & s), inner.getClip(s));
  @override
  bool shouldReclip(_Outside o) =>
      o.inner.runtimeType != inner.runtimeType ||
      inner.shouldReclip(o.inner);
}

/// The whole box (a no-op clip, so the drag's widget shape never changes).
class _Whole extends CustomClipper<Path> {
  const _Whole();
  @override
  Path getClip(Size s) => Path()..addRect(Offset.zero & s);
  @override
  bool shouldReclip(_Whole o) => false;
}

/// A circle growing out of the switcher (top, on the tapped side).
class _RippleClipper extends CustomClipper<Path> {
  _RippleClipper(this.t, this.fx);
  final double t, fx;
  @override
  Path getClip(Size s) {
    final c = Offset(s.width * fx, -s.height * 0.08);
    final r = math.sqrt(s.width * s.width + s.height * s.height) * 1.15 * t;
    return Path()..addOval(Rect.fromCircle(center: c, radius: r));
  }

  @override
  bool shouldReclip(_RippleClipper o) => o.t != t || o.fx != fx;
}

double _waveX(double t, double w, double dir) =>
    dir > 0 ? w * t : w * (1 - t);

/// The wave's swing: none at the very start and end, so a finished change
/// leaves no sliver of the old page along the edge (and an unstarted one
/// cuts nothing off the current page).
double _waveAmp(double t) => 7 * math.sin(math.pi * t.clamp(0.0, 1.0));

/// Everything behind a sound-wave edge sweeping across.
class _WaveClipper extends CustomClipper<Path> {
  _WaveClipper(this.t, this.dir);
  final double t, dir;
  @override
  Path getClip(Size s) {
    final x = _waveX(t, s.width, dir);
    final amp = _waveAmp(t);
    final p = Path()..moveTo(dir > 0 ? 0 : s.width, 0);
    for (double y = 0; y <= s.height; y += 6) {
      p.lineTo(x + amp * math.sin(y / 14 + t * 18), y);
    }
    p
      ..lineTo(x, s.height)
      ..lineTo(dir > 0 ? 0 : s.width, s.height)
      ..close();
    return p;
  }

  @override
  bool shouldReclip(_WaveClipper o) => o.t != t || o.dir != dir;
}

/// The accent sound-wave line riding the edge (fades in and out).
class _WaveLine extends StatelessWidget {
  const _WaveLine(
      {required this.t,
      required this.dir,
      required this.color,
      required this.opacity});
  final double t, dir, opacity;
  final Color color;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: CustomPaint(
          painter: _WavePainter(SectionSwitch._ease(t), dir,
              color.withValues(alpha: opacity * math.sin(math.pi * t))),
        ),
      );
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.t, this.dir, this.color);
  final double t, dir;
  final Color color;
  @override
  void paint(Canvas canvas, Size s) {
    if (color.a == 0) return;
    final x = _waveX(t, s.width, dir);
    final amp = _waveAmp(t);
    final p = Path()..moveTo(x + amp * math.sin(t * 18), 0);
    for (double y = 6; y <= s.height; y += 6) {
      p.lineTo(x + amp * math.sin(y / 14 + t * 18), y);
    }
    canvas.drawPath(
        p,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4
          ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_WavePainter o) =>
      o.t != t || o.dir != dir || o.color != color;
}

/// Equaliser bars: the new section rises in strip by strip, in the
/// direction of travel (with a tiny overshoot per bar).
class _BarsClipper extends CustomClipper<Path> {
  _BarsClipper(this.t, this.dir);
  final double t, dir;
  static const n = 8;
  @override
  Path getClip(Size s) {
    final p = Path();
    final w = s.width / n;
    for (var i = 0; i < n; i++) {
      final k = dir > 0 ? i : n - 1 - i;
      final local = ((t - k * 0.06) / (1 - (n - 1) * 0.06)).clamp(0.0, 1.0);
      final h = s.height * Curves.easeOutBack.transform(local).clamp(0.0, 1.2);
      p.addRect(Rect.fromLTWH(i * w, s.height - h, w + 0.5, h));
    }
    return p;
  }

  @override
  bool shouldReclip(_BarsClipper o) => o.t != t || o.dir != dir;
}

/// A looping mini demo of one style (two little "sections" swapping) for
/// the Appearance picker.
class SectionTransitionDemo extends StatefulWidget {
  const SectionTransitionDemo({super.key, required this.style});
  final SectionTransitionStyle style;
  @override
  State<SectionTransitionDemo> createState() => _SectionTransitionDemoState();
}

class _SectionTransitionDemoState extends State<SectionTransitionDemo> {
  bool _b = false;
  late final Stream<int> _tick =
      Stream.periodic(const Duration(milliseconds: 1600), (i) => i);

  Widget _face(ColorScheme scheme, bool live) {
    Widget row() => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2.5),
          child: Row(children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.surfaceContainerHighest,
                border: Border.all(
                    color: live ? scheme.primary : scheme.outlineVariant,
                    width: 1.5),
              ),
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Container(
                height: 10,
                decoration: BoxDecoration(
                  color: live
                      ? scheme.primary.withValues(alpha: 0.35)
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ]),
        );
    return Container(
      key: ValueKey(live),
      color: scheme.surface,
      padding: const EdgeInsets.all(6),
      child: Column(children: [row(), row(), row()]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<int>(
      stream: _tick,
      builder: (context, snap) {
        if (snap.hasData) _b = snap.data!.isOdd;
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 76,
            height: 52,
            child: SectionSwitch(
              style: widget.style,
              forward: _b,
              child: _face(scheme, _b),
            ),
          ),
        );
      },
    );
  }
}
