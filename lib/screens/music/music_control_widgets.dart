part of '../music_controls.dart';

// Small reusable control widgets pulled out of music_controls.dart
// unchanged: the icon button, the toggle chip, and the playback-speed
// panel. Leaf widgets — values + callbacks in, theme colours out.

// ─── Small reusable widgets ───────────────────────────────────────────────────

/// The lift every player key shares, so the controls read as keys rising out
/// of the glass: a tight contact shadow underneath, a tinted glow, and a
/// catch-light on the top-left rim where the glass meets the key.
List<BoxShadow> _glassLift(ColorScheme scheme, Color tint,
    {bool active = false}) {
  // Crisp, not foggy: one tight contact shadow grounds the key; only an
  // ACTIVE key gets a small, close accent glow. (The old wide tinted glow and
  // blurred white highlight hazed the icons, most visibly in dark mode.)
  final dark = scheme.brightness == Brightness.dark;
  return [
    BoxShadow(
      color: Colors.black.withValues(alpha: dark ? 0.55 : 0.16),
      blurRadius: 3,
      offset: const Offset(0, 2),
    ),
    if (active)
      BoxShadow(
        color: tint.withValues(alpha: dark ? 0.38 : 0.30),
        blurRadius: 8,
        spreadRadius: -1,
        offset: const Offset(0, 2),
      ),
  ];
}

/// Top-lit fill for a raised key: a clean surface gradient (light on top,
/// a shade deeper at the base) with only a whisper of the accent.
LinearGradient _keyFill(ColorScheme scheme, Color tint) {
  final dark = scheme.brightness == Brightness.dark;
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: dark
        ? [
            Color.alphaBlend(tint.withValues(alpha: 0.07),
                Color.lerp(scheme.surface, Colors.white, 0.12)!),
            Color.alphaBlend(tint.withValues(alpha: 0.05),
                Color.lerp(scheme.surface, Colors.black, 0.20)!),
          ]
        : [
            Colors.white,
            Color.alphaBlend(tint.withValues(alpha: 0.07),
                scheme.surfaceContainerHighest),
          ],
  );
}

/// The crisp 1 px key edge: a light rim that reads as a lit bevel.
Color _keyEdge(ColorScheme scheme) => scheme.brightness == Brightness.dark
    ? Colors.white.withValues(alpha: 0.14)
    : Colors.black.withValues(alpha: 0.08);

/// The big play / pause key. Idle: a clean glossy disc with a crisp rim.
/// Playing: a thin light ring orbits it (like a turning record) and the disc
/// breathes very slightly; the icon morphs play ↔ pause with a quick turn.
class _PlayKey extends StatefulWidget {
  const _PlayKey({
    required this.playing,
    required this.buffering,
    required this.accent,
    required this.onTap,
  });
  final bool playing, buffering;
  final Color accent;
  final VoidCallback onTap;
  static const double size = 68;

  @override
  State<_PlayKey> createState() => _PlayKeyState();
}

class _PlayKeyState extends State<_PlayKey>
    with SingleTickerProviderStateMixin {
  late final AnimationController _orbit = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 5200));

  @override
  void initState() {
    super.initState();
    if (widget.playing) _orbit.repeat();
  }

  @override
  void didUpdateWidget(covariant _PlayKey old) {
    super.didUpdateWidget(old);
    if (widget.playing && !_orbit.isAnimating) {
      _orbit.repeat();
    } else if (!widget.playing && _orbit.isAnimating) {
      _orbit.stop();
    }
  }

  @override
  void dispose() {
    _orbit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.accent;
    final dark = Theme.of(context).brightness == Brightness.dark;
    const s = _PlayKey.size;
    return Tactile(
      child: GestureDetector(
        onTap: widget.onTap,
        child: SizedBox(
          width: s + 12,
          height: s + 12,
          child: AnimatedBuilder(
            animation: _orbit,
            builder: (context, child) {
              final t = _orbit.value;
              // A slow, barely-there breath while playing.
              final breath = widget.playing
                  ? 1 + 0.025 * (0.5 - (t * 2 % 1 - 0.5).abs()) * 2
                  : 1.0;
              return Stack(
                alignment: Alignment.center,
                children: [
                  // The orbit ring (only while playing).
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 250),
                    opacity: widget.playing ? 1 : 0,
                    child: Transform.rotate(
                      angle: t * 6.283185307179586,
                      child: CustomPaint(
                        size: Size(s + 12, s + 12),
                        painter: _OrbitPainter(a),
                      ),
                    ),
                  ),
                  Transform.scale(scale: breath, child: child),
                ],
              );
            },
            child: Container(
              width: s,
              height: s,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color.lerp(a, Colors.white, 0.28)!,
                    a,
                    Color.lerp(a, Colors.black, 0.22)!,
                  ],
                  stops: const [0.0, 0.5, 1.0],
                ),
                // Crisp rim + a tight, close glow (no fog).
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.35), width: 1.2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: dark ? 0.55 : 0.2),
                    blurRadius: 5,
                    offset: const Offset(0, 3),
                  ),
                  BoxShadow(
                    color: a.withValues(alpha: widget.playing ? 0.55 : 0.32),
                    blurRadius: widget.playing ? 12 : 8,
                    spreadRadius: -2,
                  ),
                ],
              ),
              child: widget.buffering
                  ? const Padding(
                      padding: EdgeInsets.all(18),
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2.5),
                    )
                  : AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      transitionBuilder: (c, an) => RotationTransition(
                        turns: Tween(begin: 0.75, end: 1.0).animate(an),
                        child: ScaleTransition(scale: an, child: c),
                      ),
                      child: Icon(
                        widget.playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        key: ValueKey(widget.playing),
                        size: s * 0.58,
                        color: Colors.white,
                        shadows: [
                          Shadow(
                            color: Colors.black.withValues(alpha: 0.25),
                            blurRadius: 2,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A thin comet of light that orbits the play key while music plays.
class _OrbitPainter extends CustomPainter {
  _OrbitPainter(this.accent);
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(colors: [
        accent.withValues(alpha: 0),
        accent.withValues(alpha: 0.15),
        Color.lerp(accent, Colors.white, 0.45)!,
      ], stops: const [0.0, 0.55, 1.0]).createShader(rect);
    canvas.drawArc(rect, 0, 6.283185307179586 * 0.92, false, paint);
  }

  @override
  bool shouldRepaint(_OrbitPainter old) => old.accent != accent;
}

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
            gradient: enabled ? _keyFill(scheme, scheme.primary) : null,
            color: enabled
                ? null
                : scheme.surfaceContainerHighest.withValues(alpha: 0.30),
            border: Border.all(
              color: enabled
                  ? _keyEdge(scheme)
                  : scheme.outlineVariant.withValues(alpha: 0.30),
              width: 1,
            ),
            boxShadow: enabled ? _glassLift(scheme, scheme.primary) : null,
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
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: active
                  ? [
                      activeColor.withValues(alpha: 0.30),
                      activeColor.withValues(alpha: 0.15),
                    ]
                  : _keyFill(scheme, scheme.primary).colors,
            ),
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: active
                  ? activeColor.withValues(alpha: 0.85)
                  : _keyEdge(scheme),
              width: active ? 1.6 : 1,
            ),
            boxShadow: _glassLift(
                scheme, active ? activeColor : scheme.primary,
                active: active),
          ),
          child: Icon(
            icon,
            size: 20,
            // Full-strength icons: crisp on any background.
            color: active
                ? activeColor
                : Color.alphaBlend(
                    scheme.primary.withValues(alpha: 0.18),
                    scheme.onSurface.withValues(alpha: 0.95),
                  ),
          ),
        ),
      ),
    ));
  }
}

// ─── Speed panel ──────────────────────────────────────────────────────────────

class _SpeedPanel extends StatefulWidget {
  final double currentSpeed;

  /// A preset was tapped (callers usually close the panel).
  final void Function(double) onSelect;

  /// Live changes from the fine slider (panel stays open).
  final void Function(double)? onChanged;
  final VoidCallback onClose;
  final double width;

  const _SpeedPanel({
    required this.currentSpeed,
    required this.onSelect,
    required this.onClose,
    this.onChanged,
    this.width = 268,
  });

  @override
  State<_SpeedPanel> createState() => _SpeedPanelState();
}

class _SpeedPanelState extends State<_SpeedPanel> {
  late double _v = widget.currentSpeed;

  @override
  void didUpdateWidget(covariant _SpeedPanel old) {
    super.didUpdateWidget(old);
    if (old.currentSpeed != widget.currentSpeed) _v = widget.currentSpeed;
  }

  String get _mood => _v < 0.9
      ? 'Slower — easy to follow lyrics'
      : _v > 1.1
          ? 'Faster'
          : 'Normal speed';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final normal = (_v - 1.0).abs() < 0.01;

    // Just the card — the caller owns the barrier / position / genie scale.
    return GestureDetector(
      onTap: () {}, // absorb inner taps so they don't reach the barrier
      child: Container(
        width: widget.width,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: scheme.primary.withAlpha(110)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(isDark ? 120 : 70),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: scheme.primary.withAlpha(28),
              blurRadius: 20,
              spreadRadius: -6,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header: icon chip · title + mood · big current value · close.
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color.lerp(scheme.primary, Colors.white, 0.18)!,
                        Color.lerp(scheme.primary, Colors.black, 0.15)!,
                      ],
                    ),
                  ),
                  child: const Icon(Icons.speed_rounded,
                      size: 18, color: Colors.white),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Playback speed',
                          style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 13.5,
                              color: scheme.onSurface)),
                      Text(_mood,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                // The current speed as a tinted value pill (the "×" reads as
                // part of a number there, never as a second close button).
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  transitionBuilder: (c, a) =>
                      ScaleTransition(scale: a, child: c),
                  child: Container(
                    key: ValueKey(_speedLabel(_v)),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                          color: scheme.primary.withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      _speedLabel(_v).replaceAll('×', ' ×'),
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          color: scheme.primary),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                  // Close: a separate round grey key, clearly not the value.
                  Material(
                    color: scheme.surfaceContainerHighest,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: widget.onClose,
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(Icons.close_rounded,
                            size: 16, color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            // Presets — a tidy 3-column grid.
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
                            ? _speedChip(scheme, isDark, _speeds[r + c])
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            if (widget.onChanged != null) ...[
              const SizedBox(height: 10),
              // Fine tune in 0.05 steps — live while dragging.
              Row(
                children: [
                  Icon(Icons.slow_motion_video_rounded,
                      size: 16, color: scheme.onSurfaceVariant),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 4,
                        overlayShape: SliderComponentShape.noOverlay,
                        thumbShape:
                            const RoundSliderThumbShape(enabledThumbRadius: 8),
                      ),
                      child: Slider(
                        value: _v.clamp(0.5, 2.0),
                        min: 0.5,
                        max: 2.0,
                        divisions: 30,
                        onChanged: (x) {
                          final snapped = (x * 20).round() / 20;
                          setState(() => _v = snapped);
                          widget.onChanged!(snapped);
                        },
                      ),
                    ),
                  ),
                  Icon(Icons.fast_forward_rounded,
                      size: 16, color: scheme.onSurfaceVariant),
                ],
              ),
              AnimatedCrossFade(
                duration: const Duration(milliseconds: 180),
                crossFadeState: normal
                    ? CrossFadeState.showFirst
                    : CrossFadeState.showSecond,
                firstChild: const SizedBox(width: double.infinity),
                secondChild: Center(
                  child: TextButton.icon(
                    onPressed: () => widget.onSelect(1.0),
                    icon: const Icon(Icons.restart_alt_rounded, size: 16),
                    label: const Text('Back to normal'),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _speedChip(ColorScheme scheme, bool isDark, double s) {
    return _musicPickChip(
      scheme,
      isDark,
      label: _speedLabel(s),
      sub: s == 1.0 ? 'normal' : null,
      active: (s - _v).abs() < 0.01,
      onTap: () {
        setState(() => _v = s);
        widget.onSelect(s);
      },
    );
  }
}

/// The one choice-chip look for the music pickers (speed, sleep timer):
/// tinted tile at rest, a gradient + glow when chosen, ripple + haptic on tap.
Widget _musicPickChip(
  ColorScheme scheme,
  bool isDark, {
  required String label,
  required bool active,
  required VoidCallback onTap,
  String? sub,
}) {
  return Material(
    color: Colors.transparent,
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 9),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: active
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color.lerp(scheme.primary, Colors.white, 0.12)!,
                    Color.lerp(scheme.primary, Colors.black, 0.12)!,
                  ],
                )
              : null,
          color: active
              ? null
              : (isDark
                  ? scheme.surfaceContainerHighest
                  : Color.alphaBlend(scheme.primary.withValues(alpha: 0.04),
                      scheme.surfaceContainerHighest)),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active
                ? scheme.primary
                : scheme.primary.withValues(alpha: isDark ? 0.25 : 0.16),
          ),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.35),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                color: active ? scheme.onPrimary : scheme.onSurface,
              ),
            ),
            if (sub != null)
              Text(sub,
                  style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w600,
                      color: active
                          ? scheme.onPrimary.withValues(alpha: 0.85)
                          : scheme.onSurfaceVariant)),
          ],
        ),
      ),
    ),
  );
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
  // A-B repeat points as fractions of the song (null = not set).
  final double? markA;
  final double? markB;

  const _WaveformSeekBar({
    required this.fraction,
    required this.accent,
    required this.inactive,
    required this.enabled,
    required this.seed,
    required this.onSeek,
    required this.labelFor,
    this.markA,
    this.markB,
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
                // A-B loop: a soft band over the repeating stretch, with a
                // slim A / B tick at each end.
                if (widget.markA != null && widget.markB != null)
                  Positioned(
                    left: widget.markA!.clamp(0.0, 1.0) * w,
                    width: ((widget.markB! - widget.markA!).clamp(0.0, 1.0)) * w,
                    top: -3,
                    bottom: -3,
                    child: IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          color: widget.accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              color: widget.accent.withValues(alpha: 0.35)),
                        ),
                      ),
                    ),
                  ),
                for (final m in [
                  if (widget.markA != null) (widget.markA!, 'A'),
                  if (widget.markB != null) (widget.markB!, 'B'),
                ])
                  Positioned(
                    left: (m.$1.clamp(0.0, 1.0) * w - 6).clamp(0.0, (w - 12).clamp(0.0, w)),
                    top: -14,
                    child: IgnorePointer(
                      child: SizedBox(
                        width: 12,
                        child: Text(m.$2,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: widget.accent,
                                fontSize: 9,
                                fontWeight: FontWeight.w900)),
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
                        style: TextStyle(
                          color: readableOn(widget.accent),
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
    final len = heights.length;
    if (len == 0) return;
    // Wide screens get MORE, thinner bars (≈4 px each) instead of stretching
    // the same few into fat pills that no longer read as a waveform.
    const pitch = 6.5; // bar + gap
    final fit = (size.width / pitch).floor();
    final n = fit > len ? (fit > 240 ? 240 : fit) : len;
    final gap = n > len ? 2.5 : 2.0;
    final barW = (size.width - gap * (n - 1)) / n;
    if (barW <= 0) return;
    double hAt(int i) {
      if (n == len) return heights[i];
      // Resample the track's pattern smoothly, plus a fixed per-bar wobble so
      // it still looks like a real waveform rather than a gentle curve.
      final t = n == 1 ? 0.0 : i * (len - 1) / (n - 1);
      final j = t.floor();
      final k = j + 1 < len ? j + 1 : len - 1;
      final v = heights[j] + (heights[k] - heights[j]) * (t - j);
      final w = ((i * 7919 + 104729) % 1000) / 1000.0;
      final out = v * (0.7 + 0.6 * w);
      return out < 0.18 ? 0.18 : (out > 1.0 ? 1.0 : out);
    }
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
      final h = (hAt(i) * size.height).clamp(3.0, size.height);
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
