import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The look of the big rotating "now playing" glyph. The user can switch
/// between these from the player; the choice is remembered across launches.
enum PlayerDiscStyle {
  orb,
  modernVinyl,
  classicVinyl,
  cd,
  cassette,
  halo,
  pulse,
}

extension PlayerDiscStyleX on PlayerDiscStyle {
  String get id => switch (this) {
        PlayerDiscStyle.orb => 'orb',
        PlayerDiscStyle.modernVinyl => 'modern_vinyl',
        PlayerDiscStyle.classicVinyl => 'classic_vinyl',
        PlayerDiscStyle.cd => 'cd',
        PlayerDiscStyle.cassette => 'cassette',
        PlayerDiscStyle.halo => 'halo',
        PlayerDiscStyle.pulse => 'pulse',
      };

  String get label => switch (this) {
        PlayerDiscStyle.orb => 'Default',
        PlayerDiscStyle.modernVinyl => 'Modern vinyl',
        PlayerDiscStyle.classicVinyl => 'Classic vinyl',
        PlayerDiscStyle.cd => 'CD',
        PlayerDiscStyle.cassette => 'Cassette',
        PlayerDiscStyle.halo => 'Halo',
        PlayerDiscStyle.pulse => 'Pulse',
      };

  /// Round styles get the circular progress ring; the cassette does not.
  bool get roundRing =>
      this != PlayerDiscStyle.cassette &&
      this != PlayerDiscStyle.classicVinyl;

  static PlayerDiscStyle fromId(String? s) => PlayerDiscStyle.values
      .firstWhere((e) => e.id == s, orElse: () => PlayerDiscStyle.orb);
}

/// Remembers the chosen disc style and notifies the player when it changes.
class PlayerStyleController extends ChangeNotifier {
  PlayerStyleController._();
  static final PlayerStyleController instance = PlayerStyleController._();

  static const _key = 'player_disc_style_v1';
  static const _dimKey = 'player_orb_dimmed_v1';
  PlayerDiscStyle _style = PlayerDiscStyle.orb;
  bool _orbDimmed = false;
  bool _loaded = false;

  PlayerDiscStyle get style => _style;
  bool get orbDimmed => _orbDimmed;
  bool get loaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final p = await SharedPreferences.getInstance();
      _style = PlayerDiscStyleX.fromId(p.getString(_key));
      _orbDimmed = p.getBool(_dimKey) ?? false;
    } catch (_) {
      // Keep the default on any read failure.
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setStyle(PlayerDiscStyle s) async {
    if (_style == s) return;
    _style = s;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, s.id);
    } catch (_) {
      // Best-effort — selection still applies this session.
    }
  }

  Future<void> toggleOrbDim() => setOrbDimmed(!_orbDimmed);

  Future<void> setOrbDimmed(bool v) async {
    if (_orbDimmed == v) return;
    _orbDimmed = v;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_dimKey, v);
    } catch (_) {
      // Best-effort — toggle still applies this session.
    }
  }
}

/// Renders the rotating now-playing glyph for a given [style].
///
/// [spin] is the shared disc controller (turns 0..1, repeating while playing,
/// stopped when paused), so every spinning style naturally halts on pause.
/// [playing] additionally drives the classic-vinyl tonearm lift/drop.
/// [artBuilder] yields the centre album art / note sized to the diameter asked.
class PlayerDisc extends StatelessWidget {
  const PlayerDisc({
    super.key,
    required this.style,
    required this.side,
    required this.accent,
    required this.scheme,
    required this.isDark,
    required this.spin,
    required this.artBuilder,
    this.playing = true,
    this.dimmed = false,
  });

  final PlayerDiscStyle style;
  final double side;
  final Color accent;
  final ColorScheme scheme;
  final bool isDark;
  final Animation<double> spin;
  final Widget Function(double diameter, [Color? noteColor]) artBuilder;
  final bool playing;
  final bool dimmed;

  Widget _rotate(Widget child) => AnimatedBuilder(
        animation: spin,
        builder: (_, c) =>
            Transform.rotate(angle: spin.value * 2 * math.pi, child: c),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    return switch (style) {
      PlayerDiscStyle.orb => _orb(),
      PlayerDiscStyle.modernVinyl => _modernVinyl(),
      PlayerDiscStyle.classicVinyl => _ClassicVinyl(
          side: side,
          accent: accent,
          isDark: isDark,
          spin: spin,
          playing: playing,
          artBuilder: artBuilder,
        ),
      PlayerDiscStyle.cd => _cd(),
      PlayerDiscStyle.cassette => _cassette(),
      PlayerDiscStyle.halo => _halo(),
      PlayerDiscStyle.pulse => _PulseDisc(
          side: side,
          accent: accent,
          scheme: scheme,
          isDark: isDark,
          playing: playing,
          artBuilder: artBuilder,
        ),
    };
  }

  // ── Default glossy orb ────────────────────────────────────────────────────
  Widget _orb() {
    if (dimmed) return _orbDim();
    return _rotate(Container(
      width: side,
      height: side,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: const Alignment(-0.32, -0.40),
          radius: 0.95,
          colors: [
            Color.lerp(accent, Colors.white, 0.58)!,
            accent,
            Color.lerp(accent, Colors.black, 0.46)!,
          ],
          stops: const [0.0, 0.55, 1.0],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: isDark ? 0.14 : 0.40),
          width: 1.6,
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.42),
            blurRadius: 46,
            spreadRadius: 2,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.50 : 0.22),
            blurRadius: 16,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipOval(child: Center(child: artBuilder(side * 0.86))),
    ));
  }

  // Muted "transport-button" finish for the orb — a soft top-lit accent disc
  // instead of the bright glossy ball, so a neon accent in dark mode isn't
  // blinding. Still spins, still carries the accent side-glow.
  Widget _orbDim() {
    final d = side * 0.86;
    final glyph = isDark
        ? Color.lerp(accent, Colors.white, 0.38)!
        : Color.lerp(accent, Colors.black, 0.32)!;
    return _rotate(Container(
      width: side,
      height: side,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
                accent.withValues(alpha: isDark ? 0.16 : 0.10), scheme.surface),
            Color.alphaBlend(accent.withValues(alpha: isDark ? 0.26 : 0.18),
                scheme.surfaceContainerHighest),
          ],
        ),
        border: Border.all(
          color: accent.withValues(alpha: isDark ? 0.34 : 0.26),
          width: 1.6,
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: isDark ? 0.28 : 0.18),
            blurRadius: 34,
            spreadRadius: 1,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.20),
            blurRadius: 16,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipOval(child: Center(child: artBuilder(d, glyph))),
    ));
  }

  // ── Modern vinyl: glossy accent record with a centre label ────────────────
  Widget _modernVinyl() {
    final labelD = side * 0.46;
    return Container(
      width: side,
      height: side,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.40),
            blurRadius: 42,
            spreadRadius: 1,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.24),
            blurRadius: 16,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: _rotate(Stack(
        alignment: Alignment.center,
        children: [
          // Glossy coloured disc body.
          Container(
            width: side,
            height: side,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                center: const Alignment(-0.3, -0.4),
                radius: 1.0,
                colors: [
                  Color.lerp(accent, Colors.white, 0.42)!,
                  accent,
                  Color.lerp(accent, Colors.black, 0.40)!,
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: isDark ? 0.14 : 0.35),
                width: 1.4,
              ),
            ),
          ),
          // Faint grooves.
          SizedBox(
            width: side,
            height: side,
            child: CustomPaint(
              painter: _GroovePainter(
                color: Colors.white.withValues(alpha: 0.12),
                innerFrac: labelD / side * 1.1,
              ),
            ),
          ),
          // Glossy specular streaks — give it life and make the spin read.
          Container(
            width: side,
            height: side,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: SweepGradient(
                colors: [
                  Colors.transparent,
                  Colors.white.withValues(alpha: 0.0),
                  Colors.white.withValues(alpha: 0.35),
                  Colors.white.withValues(alpha: 0.0),
                  Colors.transparent,
                  Colors.white.withValues(alpha: 0.0),
                  Colors.white.withValues(alpha: 0.18),
                  Colors.white.withValues(alpha: 0.0),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.11, 0.14, 0.17, 0.5, 0.61, 0.64, 0.67, 1.0],
              ),
            ),
          ),
          // Centre label — an inset dark disc with the art, or a cleanly
          // centred glyph (no clashing spindle dot).
          Container(
            width: labelD,
            height: labelD,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  Color.alphaBlend(accent.withValues(alpha: 0.40),
                      const Color(0xFF101017)),
                  Color.alphaBlend(accent.withValues(alpha: 0.58),
                      const Color(0xFF1C1C26)),
                ],
              ),
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.16), width: 1),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 8,
                    spreadRadius: -2),
              ],
            ),
            child: ClipOval(child: Center(child: artBuilder(labelD * 0.6))),
          ),
        ],
      )),
    );
  }

  // ── CD: iridescent disc ───────────────────────────────────────────────────
  Widget _cd() {
    return Container(
      width: side,
      height: side,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.38),
            blurRadius: 40,
            spreadRadius: 1,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.24),
            blurRadius: 16,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: _rotate(Stack(
        alignment: Alignment.center,
        children: [
          // Iridescent sweep.
          Container(
            width: side,
            height: side,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: SweepGradient(
                colors: [
                  Color.lerp(accent, const Color(0xFF8E7BFF), 0.6)!,
                  const Color(0xFF59E0C8),
                  const Color(0xFFFFE08A),
                  Color.lerp(accent, const Color(0xFFFF7AA8), 0.6)!,
                  const Color(0xFF7AC7FF),
                  Color.lerp(accent, const Color(0xFF8E7BFF), 0.6)!,
                ],
                stops: const [0.0, 0.2, 0.4, 0.6, 0.8, 1.0],
              ),
            ),
          ),
          // Darkening + sheen so it reads as a shiny disc, not flat colour.
          Container(
            width: side,
            height: side,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                center: const Alignment(-0.3, -0.4),
                radius: 1.1,
                colors: [
                  Colors.white.withValues(alpha: 0.28),
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.42),
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
            ),
          ),
          // Two bright specular streaks so the spin is clearly visible — a
          // smooth iridescent sweep alone looks static as it turns.
          Container(
            width: side,
            height: side,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: SweepGradient(
                colors: [
                  Colors.transparent,
                  Colors.white.withValues(alpha: 0.0),
                  Colors.white.withValues(alpha: 0.6),
                  Colors.white.withValues(alpha: 0.0),
                  Colors.transparent,
                  Colors.white.withValues(alpha: 0.0),
                  Colors.white.withValues(alpha: 0.35),
                  Colors.white.withValues(alpha: 0.0),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.10, 0.13, 0.16, 0.5, 0.60, 0.63, 0.66, 1.0],
              ),
            ),
          ),
          // Faint read-track rings.
          SizedBox(
            width: side,
            height: side,
            child: CustomPaint(
              painter: _GroovePainter(
                  color: Colors.white.withValues(alpha: 0.08), innerFrac: 0.26),
            ),
          ),
          // Silver hub ring + clear centre + hole.
          Container(
            width: side * 0.34,
            height: side * 0.34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const RadialGradient(
                colors: [Color(0xFFF2F3F7), Color(0xFFB9BCC8)],
              ),
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.6), width: 1.2),
            ),
          ),
          Container(
            width: side * 0.19,
            height: side * 0.19,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDark ? const Color(0xFF14141A) : const Color(0xFF2A2A30),
            ),
          ),
          Container(
            width: side * 0.07,
            height: side * 0.07,
            decoration: const BoxDecoration(
                shape: BoxShape.circle, color: Color(0xFF0B0B0E)),
          ),
        ],
      )),
    );
  }

  // ── Cassette: fixed shell, spinning reels ─────────────────────────────────
  Widget _cassette() {
    final w = side;
    final h = side * 0.66;
    final reelD = h * 0.42;
    final windowY = h * 0.5;
    return Center(
      child: Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(side * 0.07),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [const Color(0xFF3A3A42), const Color(0xFF26262C)]
                : [const Color(0xFF50505A), const Color(0xFF34343C)],
          ),
          border: Border.all(
              color: Colors.white.withValues(alpha: 0.10), width: 1),
          boxShadow: [
            BoxShadow(
              color: accent.withValues(alpha: 0.30),
              blurRadius: 34,
              spreadRadius: 1,
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.26),
              blurRadius: 14,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Stack(
          children: [
            // Label strip at the top.
            Positioned(
              left: w * 0.1,
              right: w * 0.1,
              top: h * 0.1,
              height: h * 0.2,
              child: Container(
                decoration: BoxDecoration(
                  color: Color.alphaBlend(
                      accent.withValues(alpha: 0.35), Colors.white),
                  borderRadius: BorderRadius.circular(side * 0.015),
                ),
                child: Center(
                  child: Container(
                    height: 2,
                    width: w * 0.5,
                    color: Colors.black.withValues(alpha: 0.25),
                  ),
                ),
              ),
            ),
            // Tape window with the two reels.
            Positioned(
              left: w * 0.14,
              right: w * 0.14,
              top: windowY,
              height: reelD * 1.4,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(side * 0.03),
                  border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08), width: 1),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _reel(reelD),
                    _reel(reelD),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _reel(double d) => _rotate(SizedBox(
        width: d,
        height: d,
        child: CustomPaint(
          painter: _ReelPainter(
              tape: const Color(0xFF1C1C22), hub: accent),
        ),
      ));

  // ── Halo: a glowing rotating ring hugging the album art ───────────────────
  Widget _halo() {
    final artD = side * 0.6;
    return Stack(
      alignment: Alignment.center,
      children: [
        _rotate(Container(
          width: side,
          height: side,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: SweepGradient(
              colors: [
                accent.withValues(alpha: 0.0),
                accent,
                Color.lerp(accent, Colors.white, 0.6)!,
                accent,
                accent.withValues(alpha: 0.0),
              ],
              stops: const [0.0, 0.3, 0.5, 0.7, 1.0],
            ),
          ),
        )),
        // Punch the centre out so only a glowing annulus shows.
        Container(
          width: side * 0.74,
          height: side * 0.74,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.surface,
            boxShadow: [
              BoxShadow(
                  color: accent.withValues(alpha: 0.5),
                  blurRadius: 26,
                  spreadRadius: -6),
            ],
          ),
        ),
        Container(
          width: artD,
          height: artD,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.surfaceContainerHighest,
            border: Border.all(
                color: Colors.white.withValues(alpha: isDark ? 0.12 : 0.30),
                width: 1.4),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.18),
                  blurRadius: 14,
                  offset: const Offset(0, 8)),
            ],
          ),
          child: ClipOval(child: Center(child: artBuilder(artD, accent))),
        ),
      ],
    );
  }
}

/// Classic turntable: a spinning black record under a tonearm that drops onto
/// it while playing and lifts away to rest when paused.
class _ClassicVinyl extends StatefulWidget {
  const _ClassicVinyl({
    required this.side,
    required this.accent,
    required this.isDark,
    required this.spin,
    required this.playing,
    required this.artBuilder,
  });

  final double side;
  final Color accent;
  final bool isDark;
  final Animation<double> spin;
  final bool playing;
  final Widget Function(double diameter, [Color? noteColor]) artBuilder;

  @override
  State<_ClassicVinyl> createState() => _ClassicVinylState();
}

class _ClassicVinylState extends State<_ClassicVinyl>
    with SingleTickerProviderStateMixin {
  // 0 = tonearm resting on the record (playing), 1 = lifted away (paused).
  late final AnimationController _arm = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
    value: widget.playing ? 0.0 : 1.0,
  );
  late final Animation<double> _lift =
      CurvedAnimation(parent: _arm, curve: Curves.easeInOut);

  @override
  void didUpdateWidget(covariant _ClassicVinyl old) {
    super.didUpdateWidget(old);
    if (widget.playing != old.playing) {
      widget.playing ? _arm.reverse() : _arm.forward();
    }
  }

  @override
  void dispose() {
    _arm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final side = widget.side;
    final accent = widget.accent;
    final isDark = widget.isDark;
    final rd = side * 0.78;
    final labelD = rd * 0.46;

    final record = Container(
      width: rd,
      height: rd,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const RadialGradient(
          center: Alignment(-0.3, -0.4),
          radius: 1.0,
          colors: [Color(0xFF262630), Color(0xFF141418), Color(0xFF0A0A0C)],
          stops: [0.0, 0.6, 1.0],
        ),
        border: Border.all(
            color: Colors.white.withValues(alpha: 0.06), width: 1.4),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.30),
            blurRadius: 44,
            spreadRadius: 1,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.55 : 0.30),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Grooves.
          SizedBox(
            width: rd,
            height: rd,
            child: CustomPaint(
              painter: _GroovePainter(
                color: Colors.white.withValues(alpha: 0.06),
                innerFrac: labelD / rd * 1.12,
              ),
            ),
          ),
          // Glossy specular sweep — two bright glints that ride round with the
          // vinyl so the spin is clearly visible on the black surface.
          Container(
            width: rd,
            height: rd,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: SweepGradient(
                colors: [
                  Colors.transparent,
                  Colors.white.withValues(alpha: 0.0),
                  Colors.white.withValues(alpha: 0.16),
                  Colors.white.withValues(alpha: 0.0),
                  Colors.transparent,
                  Colors.white.withValues(alpha: 0.0),
                  Colors.white.withValues(alpha: 0.09),
                  Colors.white.withValues(alpha: 0.0),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.10, 0.14, 0.18, 0.5, 0.60, 0.64, 0.68, 1.0],
              ),
            ),
          ),
          // Diagonal sheen.
          Container(
            width: rd,
            height: rd,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: 0.06),
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.18),
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          ),
          // Centre label with art.
          Container(
            width: labelD,
            height: labelD,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                center: const Alignment(-0.25, -0.3),
                colors: [
                  Color.alphaBlend(accent.withValues(alpha: 0.55),
                      const Color(0xFF20202B)),
                  Color.alphaBlend(accent.withValues(alpha: 0.42),
                      const Color(0xFF101017)),
                ],
              ),
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.12), width: 1),
            ),
            child: ClipOval(
              child: Center(
                  child: widget.artBuilder(labelD * 0.82, Colors.transparent))),
          ),
          // Spindle hole.
          Container(
            width: rd * 0.045,
            height: rd * 0.045,
            decoration: const BoxDecoration(
                shape: BoxShape.circle, color: Color(0xFF060608)),
          ),
        ],
      ),
    );

    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        AnimatedBuilder(
          animation: widget.spin,
          builder: (_, child) => Transform.rotate(
              angle: widget.spin.value * 2 * math.pi, child: child),
          child: record,
        ),
        // Tonearm — fixed save for the lift swing around its pivot.
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _lift,
            builder: (_, _) => Transform.rotate(
              angle: -_lift.value * 1.30,
              alignment: const Alignment(0.76, -0.80),
              child: CustomPaint(
                painter: _TonearmPainter(
                  metal: const Color(0xFFEAEBF1),
                  joint: const Color(0xFF9A9CA8),
                  accent: accent,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Painters ────────────────────────────────────────────────────────────────

class _GroovePainter extends CustomPainter {
  _GroovePainter({required this.color, this.innerFrac = 0.3});
  final Color color;
  final double innerFrac;

  @override
  void paint(Canvas c, Size s) {
    const rings = 16;
    final ctr = Offset(s.width / 2, s.height / 2);
    final r = s.width / 2;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = color;
    for (int i = 0; i < rings; i++) {
      final t = rings == 1 ? 0.0 : i / (rings - 1);
      final rr = r * (innerFrac + (0.97 - innerFrac) * t);
      if (rr > 0) c.drawCircle(ctr, rr, p);
    }
  }

  @override
  bool shouldRepaint(covariant _GroovePainter o) =>
      o.color != color || o.innerFrac != innerFrac;
}

class _ReelPainter extends CustomPainter {
  _ReelPainter({required this.tape, required this.hub});
  final Color tape;
  final Color hub;

  @override
  void paint(Canvas c, Size s) {
    final ctr = Offset(s.width / 2, s.height / 2);
    final r = s.width / 2;
    c.drawCircle(ctr, r, Paint()..color = tape);
    c.drawCircle(
        ctr, r * 0.9, Paint()..color = const Color(0xFF2A2A32));
    c.drawCircle(ctr, r * 0.42, Paint()..color = hub);
    final spoke = Paint()
      ..color = tape
      ..strokeWidth = r * 0.14
      ..strokeCap = StrokeCap.round;
    for (int i = 0; i < 6; i++) {
      final a = i * math.pi / 3;
      final dir = Offset(math.cos(a), math.sin(a));
      c.drawLine(ctr + dir * (r * 0.12), ctr + dir * (r * 0.42), spoke);
    }
    c.drawCircle(ctr, r * 0.1, Paint()..color = tape);
  }

  @override
  bool shouldRepaint(covariant _ReelPainter o) =>
      o.tape != tape || o.hub != hub;
}

class _TonearmPainter extends CustomPainter {
  _TonearmPainter(
      {required this.metal, required this.joint, required this.accent});
  final Color metal;
  final Color joint;
  final Color accent;

  @override
  void paint(Canvas c, Size s) {
    final side = s.width;
    final pivot = Offset(side * 0.88, side * 0.10);
    final head = Offset(side * 0.46, side * 0.30);
    final d = head - pivot;
    final len = d.distance;
    final u = len == 0 ? const Offset(0, 0) : d / len;

    // Arm shaft.
    c.drawLine(
      pivot,
      head,
      Paint()
        ..color = metal
        ..strokeWidth = side * 0.035
        ..strokeCap = StrokeCap.round,
    );
    // Counterweight stub behind the pivot.
    final back = pivot - u * (side * 0.14);
    c.drawLine(
      pivot,
      back,
      Paint()
        ..color = joint
        ..strokeWidth = side * 0.06
        ..strokeCap = StrokeCap.round,
    );
    // Pivot base.
    c.drawCircle(pivot, side * 0.085, Paint()..color = metal);
    c.drawCircle(pivot, side * 0.05, Paint()..color = joint);
    c.drawCircle(pivot, side * 0.022, Paint()..color = accent);
    // Headshell.
    c.drawCircle(head, side * 0.042, Paint()..color = metal);
    final perp = Offset(-u.dy, u.dx);
    c.drawLine(
      head + perp * (side * 0.045),
      head - perp * (side * 0.045),
      Paint()
        ..color = metal
        ..strokeWidth = side * 0.03
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _TonearmPainter o) =>
      o.metal != metal || o.joint != joint || o.accent != accent;
}

/// Pulse: a calm centre coin with sonar rings that emanate only while playing.
class _PulseDisc extends StatefulWidget {
  const _PulseDisc({
    required this.side,
    required this.accent,
    required this.scheme,
    required this.isDark,
    required this.playing,
    required this.artBuilder,
  });

  final double side;
  final Color accent;
  final ColorScheme scheme;
  final bool isDark;
  final bool playing;
  final Widget Function(double diameter, [Color? noteColor]) artBuilder;

  @override
  State<_PulseDisc> createState() => _PulseDiscState();
}

class _PulseDiscState extends State<_PulseDisc>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1800));

  @override
  void initState() {
    super.initState();
    if (widget.playing) _c.repeat();
  }

  @override
  void didUpdateWidget(covariant _PulseDisc old) {
    super.didUpdateWidget(old);
    if (widget.playing && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.playing && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final side = widget.side;
    final accent = widget.accent;
    final artD = side * 0.5;
    return SizedBox(
      width: side,
      height: side,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: AnimatedOpacity(
              opacity: widget.playing ? 1 : 0,
              duration: const Duration(milliseconds: 260),
              child: AnimatedBuilder(
                animation: _c,
                builder: (_, _) => CustomPaint(
                  painter: _PulseRingsPainter(
                      progress: _c.value, accent: accent, innerFrac: 0.5),
                ),
              ),
            ),
          ),
          Container(
            width: artD,
            height: artD,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                center: const Alignment(-0.3, -0.4),
                radius: 0.95,
                colors: [
                  Color.lerp(accent, Colors.white, 0.45)!,
                  accent,
                  Color.lerp(accent, Colors.black, 0.35)!,
                ],
                stops: const [0.0, 0.55, 1.0],
              ),
              border: Border.all(
                  color: Colors.white.withValues(alpha: widget.isDark ? 0.14 : 0.4),
                  width: 1.4),
              boxShadow: [
                BoxShadow(
                    color: accent.withValues(alpha: widget.playing ? 0.5 : 0.3),
                    blurRadius: 30,
                    spreadRadius: 1),
              ],
            ),
            child: ClipOval(child: Center(child: widget.artBuilder(artD * 0.9))),
          ),
        ],
      ),
    );
  }
}

class _PulseRingsPainter extends CustomPainter {
  _PulseRingsPainter(
      {required this.progress, required this.accent, required this.innerFrac});
  final double progress;
  final Color accent;
  final double innerFrac;
  static const int _n = 3;

  @override
  void paint(Canvas c, Size s) {
    final ctr = Offset(s.width / 2, s.height / 2);
    final rMax = s.width / 2;
    for (int i = 0; i < _n; i++) {
      final t = (progress + i / _n) % 1.0;
      final r = rMax * (innerFrac + (1.0 - innerFrac) * t);
      final op = (1.0 - t) * 0.5;
      if (op <= 0) continue;
      c.drawCircle(
        ctr,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = rMax * 0.02 * (1.0 - t * 0.5)
          ..color = accent.withValues(alpha: op),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PulseRingsPainter o) =>
      o.progress != progress ||
      o.accent != accent ||
      o.innerFrac != innerFrac;
}

// ── Style picker ──────────────────────────────────────────────────────────

/// Bottom sheet letting the user pick (and live-preview) the disc style.
Future<void> showPlayerStyleSheet(BuildContext context,
    {required Color accent}) {
  final scheme = Theme.of(context).colorScheme;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: scheme.surface,
    constraints: const BoxConstraints(maxWidth: 640),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => _PlayerStyleSheet(accent: accent),
  );
}

class _PlayerStyleSheet extends StatefulWidget {
  const _PlayerStyleSheet({required this.accent});
  final Color accent;
  @override
  State<_PlayerStyleSheet> createState() => _PlayerStyleSheetState();
}

class _PlayerStyleSheetState extends State<_PlayerStyleSheet> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: PlayerStyleController.instance,
      builder: (context, _) {
        final current = PlayerStyleController.instance.style;
        return ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.86),
          child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Row(
                  children: [
                    Icon(Icons.album_rounded, color: widget.accent),
                    const SizedBox(width: 8),
                    Text('Player style',
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface)),
                  ],
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Pick the look of the spinning now-playing glyph.',
                    style:
                        TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                  ),
                ),
                const SizedBox(height: 14),
                Flexible(
                  child: GridView(
                    shrinkWrap: true,
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 190,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 14,
                      childAspectRatio: 0.82,
                    ),
                    children: [
                      for (final st in PlayerDiscStyle.values)
                        _styleCard(st, st == current, scheme, isDark),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        );
      },
    );
  }

  Widget _styleCard(PlayerDiscStyle st, bool selected, ColorScheme scheme,
      bool isDark) {
    final accent = widget.accent;
    return GestureDetector(
      onTap: () => PlayerStyleController.instance.setStyle(st),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.alphaBlend(
                  accent.withValues(alpha: isDark ? 0.20 : 0.12),
                  scheme.surfaceContainerHighest),
              scheme.surface,
            ],
          ),
          border: Border.all(
            color: selected
                ? accent
                : scheme.outlineVariant.withValues(alpha: 0.4),
            width: selected ? 2 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                      color: accent.withValues(alpha: 0.3),
                      blurRadius: 16,
                      spreadRadius: 1),
                ]
              : null,
        ),
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  Center(
                    child: SizedBox(
                      width: 108,
                      height: 108,
                      child: PlayerDisc(
                        style: st,
                        side: 108,
                        accent: accent,
                        scheme: scheme,
                        isDark: isDark,
                        spin: const AlwaysStoppedAnimation<double>(0.0),
                        playing: true,
                        artBuilder: (d, [c]) => Center(
                          child: Icon(Icons.music_note_rounded,
                              size: d * 0.42,
                              color: c ?? Colors.white.withValues(alpha: 0.9)),
                        ),
                      ),
                    ),
                  ),
                  if (selected)
                    Positioned(
                      top: 10,
                      left: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Icon(Icons.check_rounded,
                                size: 14, color: Colors.white),
                            SizedBox(width: 4),
                            Text('Applied',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12, top: 2),
              child: Text(
                st.label,
                style: TextStyle(
                    fontWeight:
                        selected ? FontWeight.w700 : FontWeight.w600,
                    color: scheme.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
