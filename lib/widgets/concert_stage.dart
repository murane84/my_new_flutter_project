import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

/// The Listen Together "concert" backdrop: a crowd with hands in the air
/// facing the stage, coloured light beams fanning up behind them and soft
/// bokeh lights floating above — all painted in code (no images), very low
/// contrast in light mode, true silhouettes in dark mode.
///
/// It lives BEHIND the page: the crowd bobs to the beat while [playing],
/// slows to a stop on pause, and throws hands up for a moment each time
/// [cheer] ticks (a reaction was sent). Reduce-motion → a still picture with
/// only the lights gently breathing.
class ConcertStage extends StatefulWidget {
  const ConcertStage({
    super.key,
    required this.playing,
    required this.cheer,
    required this.accent,
    required this.isDark,
    this.groundInset = 80,
    this.compact = false,
  });

  final ValueListenable<bool> playing;
  final ValueListenable<int> cheer;
  final Color accent;
  final bool isDark;

  /// Distance from the bottom edge to the crowd's feet — the controls card
  /// sits in front, so only heads and hands show above it.
  final double groundInset;

  /// Phone: one shorter row, fewer lights.
  final bool compact;

  @override
  State<ConcertStage> createState() => _ConcertStageState();
}

class _Fan {
  _Fan(this.x, this.h, this.head, this.arms, this.phase, this.lift);
  final double x; // 0..1 across
  final double h; // body height factor
  final double head;
  final int arms; // 0 down · 1 one up · 2 both up · 3 clapping
  final double phase;
  final double lift; // how high this one bobs
}

class _Light {
  _Light(this.x, this.y, this.r, this.color, this.phase, this.speed);
  final double x, y, r, phase, speed;
  final Color color;
}

class _ConcertStageState extends State<ConcertStage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
      vsync: this, duration: const Duration(seconds: 60));
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  double _energy = 0; // 0 still … 1 dancing
  double _cheerAt = -100;
  double _lastT = 0;
  double _elapsed = 0;
  late List<_Fan> _back, _front;
  late List<_Light> _lights;

  @override
  void initState() {
    super.initState();
    _seed();
    _clock.addListener(_tick);
    widget.playing.addListener(_wake);
    widget.cheer.addListener(_onCheer);
    WidgetsBinding.instance.addPostFrameCallback((_) => _wake());
  }

  void _seed() {
    final rnd = math.Random(7);
    List<_Fan> row(int n, double hMin, double hMax) => [
          for (var i = 0; i < n; i++)
            _Fan(
              (i + 0.5 + (rnd.nextDouble() - 0.5) * 0.6) / n,
              hMin + rnd.nextDouble() * (hMax - hMin),
              0.85 + rnd.nextDouble() * 0.3,
              [0, 1, 1, 2, 2, 3][rnd.nextInt(6)],
              rnd.nextDouble() * math.pi * 2,
              0.6 + rnd.nextDouble() * 0.8,
            ),
        ];
    _back = widget.compact ? const [] : row(22, 0.70, 0.95);
    _front = widget.compact ? row(14, 0.55, 0.80) : row(18, 0.85, 1.10);
    final palette = widget.isDark
        ? const [
            Color(0xFFFF4D6D),
            Color(0xFFC77DFF),
            Color(0xFF4CC9F0),
            Color(0xFFFFD166),
          ]
        : const [
            Color(0xFFFF4D6D),
            Color(0xFFFF8FAB),
            Color(0xFFC77DFF),
            Color(0xFF7FD1FF),
          ];
    final n = widget.compact ? 9 : 18;
    _lights = [
      for (var i = 0; i < n; i++)
        _Light(
          rnd.nextDouble(),
          // Most float up top (above the title); a few just over the crowd.
          i % 4 == 3 ? 0.66 + rnd.nextDouble() * 0.08 : rnd.nextDouble() * 0.38,
          8 + rnd.nextDouble() * 24,
          palette[rnd.nextInt(palette.length)],
          rnd.nextDouble() * math.pi * 2,
          0.15 + rnd.nextDouble() * 0.35,
        ),
    ];
  }

  @override
  void didUpdateWidget(covariant ConcertStage old) {
    super.didUpdateWidget(old);
    if (old.playing != widget.playing) {
      old.playing.removeListener(_wake);
      widget.playing.addListener(_wake);
    }
    if (old.cheer != widget.cheer) {
      old.cheer.removeListener(_onCheer);
      widget.cheer.addListener(_onCheer);
    }
    if (old.isDark != widget.isDark || old.compact != widget.compact) _seed();
  }

  bool get _still => MediaQuery.disableAnimationsOf(context);

  void _wake() {
    if (!mounted) return;
    if (_still) {
      _clock.stop();
      _frame.value++;
      return;
    }
    if (!_clock.isAnimating) {
      _lastT = _clock.value * 60;
      _clock.repeat();
    }
  }

  void _onCheer() {
    _cheerAt = _elapsed;
    _wake();
  }

  void _tick() {
    final t = _clock.value * 60;
    var dt = t - _lastT;
    if (dt < 0) dt += 60; // wrapped
    _lastT = t;
    dt = dt.clamp(0.0, 0.1);
    _elapsed += dt;
    final target = widget.playing.value ? 1.0 : 0.0;
    // Ease in quickly, wind down gently.
    final k = target > _energy ? 2.5 : 0.9;
    _energy += (target - _energy) * (1 - math.exp(-k * dt));
    _frame.value++;
    // Paused, settled, nothing cheering → stop ticking (battery).
    if (target == 0 &&
        _energy < 0.01 &&
        _elapsed - _cheerAt > 2 &&
        _clock.isAnimating) {
      _energy = 0;
      _clock.stop();
    }
  }

  @override
  void dispose() {
    widget.playing.removeListener(_wake);
    widget.cheer.removeListener(_onCheer);
    _clock.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: ClipRect(
          child: CustomPaint(
            painter: _StagePainter(
              repaint: _frame,
              state: this,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

class _StagePainter extends CustomPainter {
  _StagePainter({required Listenable repaint, required this.state})
      : super(repaint: repaint);
  final _ConcertStageState state;

  @override
  void paint(Canvas canvas, Size size) {
    final w = state.widget;
    final dark = w.isDark;
    final t = state._elapsed;
    final energy = state._energy;
    final double cheer =
        math.exp(-(t - state._cheerAt) * 1.6).clamp(0.0, 1.0).toDouble();
    final ground = size.height - w.groundInset;
    final double scale = w.compact
        ? (size.width / 420).clamp(0.7, 1.0).toDouble() * 0.85
        : (size.width / 700).clamp(0.6, 1.2).toDouble();
    final palette = state._lights.map((l) => l.color).toSet().toList();

    // ── Light beams fanning up from behind the crowd ──────────────────────
    final origin = Offset(size.width / 2, ground - 20 * scale);
    final beamAlpha = dark ? 0.15 : 0.09;
    const angles = [-60.0, -36.0, -13.0, 13.0, 36.0, 60.0];
    for (var i = 0; i < angles.length; i++) {
      final sway = math.sin(t * 0.35 + i * 1.3) * 5;
      final a = (angles[i] + sway) * math.pi / 180;
      final len = size.height * 1.3;
      const spread = 7 * math.pi / 180;
      final p1 = origin + Offset(math.sin(a - spread), -math.cos(a - spread)) * len;
      final p2 = origin + Offset(math.sin(a + spread), -math.cos(a + spread)) * len;
      final c = palette[i % palette.length];
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            c.withValues(alpha: beamAlpha * (0.8 + 0.2 * energy)),
            c.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: origin, radius: len));
      canvas.drawPath(
          Path()
            ..moveTo(origin.dx, origin.dy)
            ..lineTo(p1.dx, p1.dy)
            ..lineTo(p2.dx, p2.dy)
            ..close(),
          paint);
    }

    // ── Bokeh lights ──────────────────────────────────────────────────────
    final bokehAlpha = dark ? 0.32 : 0.20;
    for (final l in state._lights) {
      final dx = math.sin(t * l.speed + l.phase) * 14;
      final dy = math.cos(t * l.speed * 0.8 + l.phase) * 10;
      final tw = 0.55 + 0.45 * math.sin(t * (0.6 + l.speed) + l.phase);
      final r = l.r * scale;
      canvas.drawCircle(
        Offset(l.x * size.width + dx, l.y * size.height + dy),
        r,
        Paint()
          ..color = l.color.withValues(alpha: bokehAlpha * tw)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.45),
      );
    }

    // Warm glow along the crowd's heads.
    canvas.drawOval(
      Rect.fromCenter(
          center: Offset(size.width / 2, ground - 80 * scale),
          width: size.width * 0.8,
          height: 70 * scale),
      Paint()
        ..color = w.accent.withValues(alpha: dark ? 0.22 : 0.12)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 28),
    );

    // ── The crowd ─────────────────────────────────────────────────────────
    final ink = dark
        ? const Color(0xFF07020A)
        : Color.lerp(w.accent, Colors.black, 0.25)!;
    // Each row is drawn opaque into its own layer, then faded as one — so
    // overlapping heads / arms never show darker seams.
    void row(List<_Fan> fans, double baseH, double alpha, double yOff,
        {bool floor = false}) {
      canvas.saveLayer(Offset.zero & size,
          Paint()..color = Colors.black.withValues(alpha: alpha));
      final paint = Paint()..color = ink;
      final arm = Paint()
        ..color = ink
        ..strokeWidth = 8.5 * scale
        ..strokeCap = StrokeCap.round;
      for (final f in fans) {
        // ~2 beats a second; each fan a little out of step.
        final beat = 0.5 + 0.5 * math.sin(t * math.pi * 4 + f.phase);
        final bob = -(energy * (2 + 5 * f.lift) * beat + cheer * 10 * f.lift) *
            scale;
        final x = f.x * size.width;
        final h = baseH * f.h * scale;
        final headR = 14 * f.head * scale;
        final top = ground + yOff - h + bob;
        // Body + head.
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x - 21 * scale, top + headR * 1.5, 42 * scale,
                h + 40 * scale),
            Radius.circular(18 * scale),
          ),
          paint,
        );
        canvas.drawCircle(Offset(x, top + headR * 0.5), headR, paint);
        // Arms: up / clapping; a cheer brings every hand up for a moment.
        final shoulderY = top + headR * 2.3;
        final up = f.arms == 1 || f.arms == 2 || cheer > 0.35;
        final both = f.arms == 2 || (cheer > 0.35 && f.arms != 1);
        if (up) {
          for (final side in both ? const [-1, 1] : [f.phase > math.pi ? 1 : -1]) {
            final wave = math.sin(t * math.pi * 2 + f.phase + side) *
                (6 + 6 * energy) *
                scale;
            final hand = Offset(
                x + side * (24 * scale + wave),
                top - (34 + 14 * f.lift) * scale - cheer * 8 * scale);
            canvas.drawLine(
                Offset(x + side * 15 * scale, shoulderY), hand, arm);
            canvas.drawCircle(hand, 6 * scale, paint);
          }
        } else if (f.arms == 3) {
          final clap = (math.sin(t * math.pi * 4 + f.phase) * 0.5 + 0.5) *
              energy *
              6 *
              scale;
          for (final side in const [-1, 1]) {
            canvas.drawLine(
              Offset(x + side * 14 * scale, shoulderY),
              Offset(x + side * (3 * scale + clap), top - 14 * scale),
              arm,
            );
          }
        }
      }
      if (floor) {
        // The floor they stand on, down to the bottom edge.
        canvas.drawRect(
            Rect.fromLTRB(0, ground + 30 * scale, size.width, size.height),
            paint);
      }
      canvas.restore();
    }

    if (state._back.isNotEmpty) {
      row(state._back, 100, dark ? 0.80 : 0.09, -14 * scale);
    }
    // Wide: heads rise just above the controls card standing in front.
    row(state._front, w.compact ? 80 : 125, dark ? 0.96 : 0.15, 6 * scale,
        floor: true);
  }

  @override
  bool shouldRepaint(covariant _StagePainter old) => old.state != state;
}
