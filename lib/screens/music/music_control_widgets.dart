part of '../music_controls.dart';

// Small reusable control widgets pulled out of music_controls.dart
// unchanged: the icon button, the toggle chip, and the playback-speed
// panel. Leaf widgets — values + callbacks in, theme colours out.

// ─── Small reusable widgets ───────────────────────────────────────────────────

class _CtrlBtn extends StatelessWidget {
  final IconData icon;
  final double size;
  final Color color;
  final VoidCallback? onTap;
  final String tooltip;

  const _CtrlBtn({
    required this.icon,
    required this.size,
    required this.color,
    required this.tooltip,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final enabled = onTap != null;
    return Tactile(enabled: enabled, child: Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 1),
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // A soft, top-lit accent-tinted disc so the bare transport icons
            // read as raised 3D chips (and never wash out in light mode),
            // matching the shuffle/repeat chips. Disabled = flat & faint.
            gradient: enabled
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.alphaBlend(
                        scheme.primary
                            .withValues(alpha: isDark ? 0.13 : 0.09),
                        scheme.surface,
                      ),
                      Color.alphaBlend(
                        scheme.primary
                            .withValues(alpha: isDark ? 0.22 : 0.16),
                        scheme.surfaceContainerHighest,
                      ),
                    ],
                  )
                : null,
            color: enabled
                ? null
                : scheme.surfaceContainerHighest.withValues(alpha: 0.30),
            border: Border.all(
              color: enabled
                  ? scheme.primary.withValues(alpha: isDark ? 0.30 : 0.22)
                  : scheme.outlineVariant.withValues(alpha: 0.30),
              width: 1,
            ),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: scheme.primary
                          .withValues(alpha: isDark ? 0.20 : 0.13),
                      blurRadius: 7,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Icon(icon, size: size, color: color),
        ),
      ),
    ));
  }
}

/// A soft equalizer that gently "dances" while a track plays and rests as a
/// row of faint bars when paused — used to give the player panel's base a
/// finished, musical feel instead of empty space. Self-contained (owns its
/// ticker) so it never touches the main player state.
class _MiniEqualizer extends StatefulWidget {
  final bool active;
  final Color color;
  const _MiniEqualizer({required this.active, required this.color});

  @override
  State<_MiniEqualizer> createState() => _MiniEqualizerState();
}

class _MiniEqualizerState extends State<_MiniEqualizer>
    with SingleTickerProviderStateMixin {
  static const int _n = 9;
  late final AnimationController _c;
  // A staggered phase per bar (0..1) so they don't pulse in unison.
  static const List<double> _phase = [
    0.00, 0.62, 0.24, 0.86, 0.40, 0.10, 0.72, 0.34, 0.52,
  ];

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 950));
    if (widget.active) _c.repeat();
  }

  @override
  void didUpdateWidget(covariant _MiniEqualizer old) {
    super.didUpdateWidget(old);
    if (widget.active && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.active && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  // Triangle wave 0..1 (no dart:math needed).
  double _wave(double x) {
    x = x - x.floorToDouble();
    return x < 0.5 ? x * 2 : (1 - x) * 2;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (int i = 0; i < _n; i++) ...[
                _bar(i),
                if (i < _n - 1) const SizedBox(width: 4),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _bar(int i) {
    final level = widget.active
        ? 0.30 + 0.70 * _wave(_c.value + _phase[i])
        : 0.22;
    final h = 6.0 + level * 18.0;
    return Container(
      width: 4,
      height: h,
      decoration: BoxDecoration(
        color: widget.color
            .withValues(alpha: widget.active ? 0.55 : 0.28),
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

class _CtrlChip extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color activeColor;
  final VoidCallback onTap;
  final String tooltip;

  const _CtrlChip({
    required this.icon,
    required this.active,
    required this.activeColor,
    required this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    return Tactile(child: Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            // A raised, gently top-lit chip — accent-glowing when active, a
            // subtle surface gradient when idle, so the controls feel alive
            // instead of flat grey (especially in light mode).
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: active
                  ? [
                      activeColor.withValues(alpha: 0.30),
                      activeColor.withValues(alpha: 0.15),
                    ]
                  : [
                      // Idle chips carry a faint wash of the app accent so the
                      // control cluster feels themed and alive instead of a
                      // flat grey box — most visible in light mode.
                      Color.alphaBlend(
                        scheme.primary
                            .withValues(alpha: isDark ? 0.10 : 0.07),
                        scheme.surface,
                      ),
                      Color.alphaBlend(
                        scheme.primary
                            .withValues(alpha: isDark ? 0.18 : 0.13),
                        scheme.surfaceContainerHighest,
                      ),
                    ],
            ),
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: active
                  ? activeColor.withValues(alpha: 0.85)
                  : scheme.primary.withValues(alpha: isDark ? 0.32 : 0.24),
              width: active ? 1.6 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: active
                    ? activeColor.withValues(alpha: 0.32)
                    : scheme.primary
                        .withValues(alpha: isDark ? 0.22 : 0.14),
                blurRadius: active ? 12 : 7,
                offset: Offset(0, active ? 4 : 3),
              ),
            ],
          ),
          child: Icon(
            icon,
            size: 20,
            color: active
                ? activeColor
                : Color.alphaBlend(
                    scheme.primary.withValues(alpha: 0.35),
                    scheme.onSurface.withValues(alpha: 0.78),
                  ),
          ),
        ),
      ),
    ));
  }
}

// ─── Speed panel ──────────────────────────────────────────────────────────────

class _SpeedPanel extends StatelessWidget {
  final double currentSpeed;
  final void Function(double) onSelect;
  final VoidCallback onClose;

  const _SpeedPanel({
    required this.currentSpeed,
    required this.onSelect,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Just the card now — the caller owns the tap-outside barrier, the
    // position (just above the speed button) and the genie scale, so this
    // widget is a clean leaf that scales/collapses into the button.
    return GestureDetector(
      onTap: () {}, // absorb inner taps so they don't reach the barrier
      child: Container(
        width: 236,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: scheme.primary.withAlpha(110)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(90),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.speed_rounded, size: 16, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Playback speed',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: scheme.onSurface),
                  ),
                ),
                InkWell(
                  onTap: onClose,
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.close_rounded,
                        size: 18, color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // A tidy 3-column grid (two rows of three) so the panel fits its
            // content with no empty gap.
            for (int r = 0; r < _speeds.length; r += 3)
              Padding(
                padding: EdgeInsets.only(
                    bottom: r + 3 < _speeds.length ? 8 : 0),
                child: Row(
                  children: [
                    for (int c = 0; c < 3; c++) ...[
                      if (c > 0) const SizedBox(width: 8),
                      Expanded(
                        child: (r + c) < _speeds.length
                            ? _speedChip(scheme, _speeds[r + c])
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _speedChip(ColorScheme scheme, double s) {
    final active = (s - currentSpeed).abs() < 0.01;
    return GestureDetector(
      onTap: () => onSelect(s),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 11),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active
                ? scheme.primary
                : scheme.outlineVariant.withAlpha(90),
          ),
        ),
        child: Text(
          _speedLabel(s),
          style: TextStyle(
            fontSize: 13,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? scheme.onPrimary : scheme.onSurface,
          ),
        ),
      ),
    );
  }
}

// ─── Waveform seek bar ────────────────────────────────────────────────────────

/// A SoundCloud-style waveform that doubles as the seek control: static bars
/// (a stable per-track pattern) fill with the accent up to the play position
/// and are faint beyond it; drag or tap anywhere to scrub, with a small time
/// bubble following the finger.
class _WaveformSeekBar extends StatefulWidget {
  final double fraction; // 0..1 played
  final Color accent;
  final Color inactive;
  final bool enabled;
  final int seed; // stable bar pattern per track
  final ValueChanged<double> onSeek;
  final String Function(double fraction) labelFor;

  const _WaveformSeekBar({
    required this.fraction,
    required this.accent,
    required this.inactive,
    required this.enabled,
    required this.seed,
    required this.onSeek,
    required this.labelFor,
  });

  @override
  State<_WaveformSeekBar> createState() => _WaveformSeekBarState();
}

class _WaveformSeekBarState extends State<_WaveformSeekBar> {
  static const int _bars = 44;
  double? _dragFrac; // non-null while scrubbing
  late List<double> _heights;

  @override
  void initState() {
    super.initState();
    _heights = _gen(widget.seed);
  }

  @override
  void didUpdateWidget(covariant _WaveformSeekBar old) {
    super.didUpdateWidget(old);
    if (old.seed != widget.seed) _heights = _gen(widget.seed);
  }

  // Deterministic pseudo-random bar heights (0.25..1.0) for a stable look.
  List<double> _gen(int seed) {
    var x = (seed & 0x7fffffff) | 1;
    final out = <double>[];
    for (var i = 0; i < _bars; i++) {
      x = (x * 1103515245 + 12345) & 0x7fffffff;
      out.add(0.26 + (x % 1000) / 1000.0 * 0.74);
    }
    return out;
  }

  void _setFromDx(double dx, double w) {
    if (w <= 0) return;
    setState(() => _dragFrac = (dx / w).clamp(0.0, 1.0));
  }

  void _commit() {
    final f = _dragFrac;
    if (f != null) widget.onSeek(f);
    setState(() => _dragFrac = null);
  }

  @override
  Widget build(BuildContext context) {
    final frac = (_dragFrac ?? widget.fraction).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (ctx, c) {
        final w = c.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: widget.enabled ? (d) => _setFromDx(d.localPosition.dx, w) : null,
          onTapUp: widget.enabled ? (_) => _commit() : null,
          onTapCancel: widget.enabled ? () => setState(() => _dragFrac = null) : null,
          onHorizontalDragStart:
              widget.enabled ? (d) => _setFromDx(d.localPosition.dx, w) : null,
          onHorizontalDragUpdate:
              widget.enabled ? (d) => _setFromDx(d.localPosition.dx, w) : null,
          onHorizontalDragEnd: widget.enabled ? (_) => _commit() : null,
          child: SizedBox(
            height: 34,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _WavePainter(
                      heights: _heights,
                      fraction: frac,
                      accent: widget.accent,
                      inactive: widget.inactive,
                    ),
                  ),
                ),
                if (_dragFrac != null)
                  Positioned(
                    left: (frac * w - 24).clamp(0.0, (w - 48).clamp(0.0, w)),
                    top: -24,
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: widget.accent,
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.25),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Text(
                        widget.labelFor(frac),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _WavePainter extends CustomPainter {
  final List<double> heights;
  final double fraction;
  final Color accent;
  final Color inactive;

  _WavePainter({
    required this.heights,
    required this.fraction,
    required this.accent,
    required this.inactive,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = heights.length;
    if (n == 0) return;
    const gap = 2.0;
    final barW = (size.width - gap * (n - 1)) / n;
    if (barW <= 0) return;
    final playedX = fraction * size.width;
    final mid = size.height / 2;
    final aPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = accent;
    final iPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = inactive;
    for (var i = 0; i < n; i++) {
      final x = i * (barW + gap);
      final h = (heights[i] * size.height).clamp(3.0, size.height);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, mid - h / 2, barW, h),
        Radius.circular(barW / 2),
      );
      canvas.drawRRect(rect, (x + barW) <= playedX ? aPaint : iPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.fraction != fraction ||
      old.accent != accent ||
      old.inactive != inactive ||
      old.heights != heights;
}

/// A thin elapsed-progress arc hugging the full-screen disc: a faint full-circle
/// track with a bright arc sweeping from the top clockwise as the track plays.
class _DiscRingPainter extends CustomPainter {
  _DiscRingPainter(
      {required this.fraction, required this.accent, required this.isDark});
  final double fraction;
  final Color accent;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 5;
    if (r <= 0) return;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: isDark ? 0.16 : 0.26);
    canvas.drawCircle(center, r, track);
    if (fraction > 0) {
      final prog = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: 0.95);
      canvas.drawArc(Rect.fromCircle(center: center, radius: r), -pi / 2,
          fraction * 2 * pi, false, prog);
    }
  }

  @override
  bool shouldRepaint(_DiscRingPainter old) =>
      old.fraction != fraction ||
      old.accent != accent ||
      old.isDark != isDark;
}
