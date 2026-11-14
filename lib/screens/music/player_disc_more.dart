import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../utils/depth.dart';
import '../../services/song_names.dart';
import '../../widgets/song_art.dart';
import '../home_page.dart' show playProgressNotifier;

/// The centre-art builder every player look shares (the song's cover, or a
/// note while there is none).
typedef DiscArt = Widget Function(double diameter, [Color? noteColor]);

/// The round cover from [art], cropped to a square of [side] (drawn a bit
/// larger so the circle fills the corners) — for the looks with a photo
/// or a window rather than a disc.
Widget _squareArt(DiscArt art, double side, Color bg, double radius) =>
    ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        width: side,
        height: side,
        color: bg,
        child: OverflowBox(
          maxWidth: side * 1.42,
          maxHeight: side * 1.42,
          child: art(side * 1.42),
        ),
      ),
    );

/// One repeating clock per look; it rests while the song is paused.
mixin _Beat<T extends StatefulWidget> on State<T>, SingleTickerProviderStateMixin<T> {
  late final AnimationController beat;
  Duration get period;
  bool get playingNow;

  @override
  void initState() {
    super.initState();
    beat = AnimationController(vsync: this, duration: period);
    if (playingNow) beat.repeat();
  }

  void syncBeat() {
    if (playingNow && !beat.isAnimating) {
      beat.repeat();
    } else if (!playingNow && beat.isAnimating) {
      beat.stop();
    }
  }

  @override
  void dispose() {
    beat.dispose();
    super.dispose();
  }
}

// ── Polaroid ──────────────────────────────────────────────────────────────

/// The cover as an instant photo, pinned and swaying to the music, the
/// song's name written underneath like a keepsake.
class PolaroidDisc extends StatefulWidget {
  const PolaroidDisc({
    super.key,
    required this.side,
    required this.accent,
    required this.isDark,
    required this.playing,
    required this.artBuilder,
    this.caption,
  });
  final double side;
  final Color accent;
  final bool isDark;
  final bool playing;
  final DiscArt artBuilder;

  /// The song's name when it isn't my own song now (Listen Together).
  final String? caption;

  @override
  State<PolaroidDisc> createState() => _PolaroidDiscState();
}

class _PolaroidDiscState extends State<PolaroidDisc>
    with SingleTickerProviderStateMixin, _Beat {
  @override
  Duration get period => const Duration(milliseconds: 2600);
  @override
  bool get playingNow => widget.playing;

  @override
  void didUpdateWidget(covariant PolaroidDisc old) {
    super.didUpdateWidget(old);
    syncBeat();
  }

  @override
  Widget build(BuildContext context) {
    final side = widget.side;
    final w = side * 0.72;
    final photo = w * 0.86;
    final pad = (w - photo) / 2;
    final paper = widget.isDark ? const Color(0xFFF4EFEA) : Colors.white;
    final card = Container(
      width: w,
      padding: EdgeInsets.fromLTRB(pad, pad, pad, 0),
      decoration: BoxDecoration(
        color: paper,
        borderRadius: BorderRadius.circular(side * 0.025),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: widget.isDark ? 0.5 : 0.2),
              blurRadius: Depth.lg,
              offset: Offset(0, side * 0.04)),
          BoxShadow(
              color: widget.accent.withValues(alpha: 0.25),
              blurRadius: Depth.xl),
        ],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _squareArt(
            widget.artBuilder,
            photo,
            Color.lerp(widget.accent, Colors.black, 0.25)!,
            side * 0.012),
        SizedBox(
          height: w * 0.2,
          child: Center(
            child: ValueListenableBuilder(
              valueListenable: SongArt.now,
              builder: (_, now, _) {
                // A song someone sent me is signed by them; else its name.
                final from =
                    now == null ? null : SongNames.instance.fromWhom(now.path);
                final name =
                    now == null ? '' : SongArt.splitLabel(now.title).title;
                final given = widget.caption;
                return Text(
                  given != null
                      ? (given.isEmpty ? '♡' : '$given ♡')
                      : from != null
                      ? 'from $from ♡'
                      : (name.isEmpty ? '♡' : '$name ♡'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: (w * 0.075).clamp(9.0, 22.0),
                    fontStyle: FontStyle.italic,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF4A4245),
                  ),
                );
              },
            ),
          ),
        ),
      ]),
    );
    return SizedBox(
      width: side,
      height: side,
      child: AnimatedBuilder(
        animation: beat,
        builder: (_, child) {
          // A slow sway around the pin (rests tilted when paused).
          final sway = math.sin(beat.value * 2 * math.pi) * 0.035;
          return Transform.rotate(
            angle: -0.07 + sway,
            alignment: Alignment.topCenter,
            child: child,
          );
        },
        child: Stack(alignment: Alignment.topCenter, children: [
          Padding(padding: EdgeInsets.only(top: side * 0.08), child: card),
          // The pin.
          Positioned(
            top: side * 0.05,
            child: Container(
              width: side * 0.06,
              height: side * 0.06,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  center: const Alignment(-0.4, -0.4),
                  colors: [
                    Color.lerp(widget.accent, Colors.white, 0.5)!,
                    widget.accent,
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 4,
                      offset: const Offset(0, 2)),
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ── Aura ──────────────────────────────────────────────────────────────────

/// Soft glows in the cover's colours drift and breathe around it, calm like
/// a lava lamp.
class AuraDisc extends StatefulWidget {
  const AuraDisc({
    super.key,
    required this.side,
    required this.accent,
    required this.isDark,
    required this.playing,
    required this.artBuilder,
  });
  final double side;
  final Color accent;
  final bool isDark;
  final bool playing;
  final DiscArt artBuilder;

  @override
  State<AuraDisc> createState() => _AuraDiscState();
}

class _AuraDiscState extends State<AuraDisc>
    with SingleTickerProviderStateMixin, _Beat {
  @override
  Duration get period => const Duration(seconds: 9);
  @override
  bool get playingNow => widget.playing;

  @override
  void didUpdateWidget(covariant AuraDisc old) {
    super.didUpdateWidget(old);
    syncBeat();
  }

  Color _turn(Color c, double deg) {
    final h = HSLColor.fromColor(c);
    return h.withHue((h.hue + deg) % 360).toColor();
  }

  @override
  Widget build(BuildContext context) {
    final side = widget.side;
    final a = widget.accent;
    final colours = [a, _turn(a, 40), _turn(a, -45)];
    final artD = side * 0.56;
    return SizedBox(
      width: side,
      height: side,
      child: AnimatedBuilder(
        animation: beat,
        builder: (_, _) {
          final t = beat.value * 2 * math.pi;
          return Stack(alignment: Alignment.center, children: [
            for (var i = 0; i < 3; i++)
              Transform.translate(
                offset: Offset(
                  math.cos(t + i * 2.1) * side * 0.12,
                  math.sin(t * (i.isEven ? 1 : -1) + i * 1.7) * side * 0.10,
                ),
                child: Transform.scale(
                  scale: 1 + 0.08 * math.sin(t * 2 + i),
                  child: Container(
                    width: side * (0.78 - i * 0.08),
                    height: side * (0.78 - i * 0.08),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(colors: [
                        colours[i]
                            .withValues(alpha: widget.isDark ? 0.55 : 0.45),
                        colours[i].withValues(alpha: 0),
                      ]),
                    ),
                  ),
                ),
              ),
            Container(
              width: artD,
              height: artD,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Color.lerp(a, Colors.black, 0.2),
                border: Border.all(
                    color: Colors.white
                        .withValues(alpha: widget.isDark ? 0.35 : 0.75),
                    width: side * 0.014),
                boxShadow: [
                  BoxShadow(
                      color: a.withValues(alpha: 0.45),
                      blurRadius: Depth.xl,
                      spreadRadius: 2),
                ],
              ),
              child: ClipOval(
                  child: Center(child: widget.artBuilder(artD * 0.98))),
            ),
          ]);
        },
      ),
    );
  }
}

// ── Sunset ────────────────────────────────────────────────────────────────

/// The cover is a sun sinking into a quiet sea: it lowers as the song plays
/// and sets on the last note.
class SunsetDisc extends StatefulWidget {
  const SunsetDisc({
    super.key,
    required this.side,
    required this.accent,
    required this.isDark,
    required this.playing,
    required this.artBuilder,
    this.progress,
  });
  final double side;
  final Color accent;
  final bool isDark;
  final bool playing;
  final DiscArt artBuilder;
  final ValueListenable<double>? progress;

  @override
  State<SunsetDisc> createState() => _SunsetDiscState();
}

class _SunsetDiscState extends State<SunsetDisc>
    with SingleTickerProviderStateMixin, _Beat {
  @override
  Duration get period => const Duration(milliseconds: 3200);
  @override
  bool get playingNow => widget.playing;

  @override
  void didUpdateWidget(covariant SunsetDisc old) {
    super.didUpdateWidget(old);
    syncBeat();
  }

  @override
  Widget build(BuildContext context) {
    final side = widget.side;
    final a = widget.accent;
    final sunD = side * 0.46;
    final horizon = side * 0.64;
    final sky = [
      Color.lerp(a, Colors.white, widget.isDark ? 0.45 : 0.72)!,
      Color.lerp(a, const Color(0xFFFFB070), 0.45)!,
      Color.lerp(a, Colors.black, 0.15)!,
    ];
    final sea = Color.lerp(a, const Color(0xFF1A0F2A), 0.78)!;
    return SizedBox(
      width: side,
      height: side,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(side * 0.08),
        child: AnimatedBuilder(
          animation: Listenable.merge(
              [beat, widget.progress ?? playProgressNotifier]),
          builder: (_, _) {
            final p = (widget.progress ?? playProgressNotifier)
                .value
                .clamp(0.0, 1.0);
            // Sun centre: high in the sky at the start, half under the sea
            // at the end.
            final cy = side * 0.36 + (horizon - side * 0.36) * p;
            final shimmer = beat.value * 2 * math.pi;
            return Stack(children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: sky,
                      stops: const [0.0, 0.45, 0.64],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: (side - sunD) / 2,
                top: cy - sunD / 2,
                child: Container(
                  width: sunD,
                  height: sunD,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: a,
                    boxShadow: [
                      BoxShadow(
                          color: const Color(0xFFFFC27A)
                              .withValues(alpha: 0.75),
                          blurRadius: side * 0.14,
                          spreadRadius: side * 0.03),
                    ],
                  ),
                  child: ClipOval(
                      child: Center(child: widget.artBuilder(sunD))),
                ),
              ),
              // The sea, over the sun's lower half.
              Positioned(
                left: 0,
                right: 0,
                top: horizon,
                bottom: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color.lerp(sea, a, 0.25)!,
                        sea,
                      ],
                    ),
                  ),
                ),
              ),
              // The sun's light on the water, shimmering.
              for (var i = 0; i < 4; i++)
                Positioned(
                  top: horizon + side * (0.05 + i * 0.07),
                  left: side * (0.24 + i * 0.05) +
                      math.sin(shimmer + i) * side * 0.02,
                  right: side * (0.24 + i * 0.05) -
                      math.sin(shimmer + i) * side * 0.02,
                  child: Container(
                    height: (side * 0.012).clamp(1.5, 5.0),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      color: const Color(0xFFFFD2A0).withValues(
                          alpha: (0.55 - i * 0.1) *
                              (0.7 + 0.3 * math.sin(shimmer * 2 + i))),
                    ),
                  ),
                ),
            ]);
          },
        ),
      ),
    );
  }
}

// ── Boombox ───────────────────────────────────────────────────────────────

/// A pocket boombox: the speakers pump with the beat, the cover sits in the
/// tape window and the level lights dance.
class BoomboxDisc extends StatefulWidget {
  const BoomboxDisc({
    super.key,
    required this.side,
    required this.accent,
    required this.isDark,
    required this.playing,
    required this.artBuilder,
  });
  final double side;
  final Color accent;
  final bool isDark;
  final bool playing;
  final DiscArt artBuilder;

  @override
  State<BoomboxDisc> createState() => _BoomboxDiscState();
}

class _BoomboxDiscState extends State<BoomboxDisc>
    with SingleTickerProviderStateMixin, _Beat {
  @override
  Duration get period => const Duration(milliseconds: 1000);
  @override
  bool get playingNow => widget.playing;

  @override
  void didUpdateWidget(covariant BoomboxDisc old) {
    super.didUpdateWidget(old);
    syncBeat();
  }

  Widget _speaker(double d, double pump) {
    final a = widget.accent;
    return Container(
      width: d,
      height: d,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF1A1517),
        border: Border.all(color: a, width: d * 0.05),
      ),
      child: Center(
        child: Transform.scale(
          scale: 1 + pump * 0.12,
          child: Container(
            width: d * 0.66,
            height: d * 0.66,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const RadialGradient(colors: [
                Color(0xFF6A6062),
                Color(0xFF2E2729),
                Color(0xFF151112),
              ], stops: [0.0, 0.35, 1.0]),
            ),
            child: Center(
              child: Container(
                width: d * 0.18,
                height: d * 0.18,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color.lerp(a, Colors.black, 0.3)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final side = widget.side;
    final a = widget.accent;
    final bw = side * 0.94;
    final bh = side * 0.56;
    final spk = bh * 0.68;
    final win = bh * 0.46;
    final body = widget.isDark ? const Color(0xFF241D20) : const Color(0xFF2B2326);
    return SizedBox(
      width: side,
      height: side,
      child: AnimatedBuilder(
        animation: beat,
        builder: (_, _) {
          final t = beat.value;
          // Two kicks a beat: a quick pump that eases back.
          final pump = widget.playing
              ? math.pow(math.max(0.0, math.cos(t * 4 * math.pi)), 6).toDouble()
              : 0.0;
          return Center(
            child: Transform.scale(
              scale: 1 + pump * 0.015,
              child: SizedBox(
                width: bw,
                height: bh + side * 0.1,
                child: Stack(alignment: Alignment.bottomCenter, children: [
                  // Handle.
                  Positioned(
                    top: 0,
                    left: bw * 0.26,
                    right: bw * 0.26,
                    height: side * 0.16,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: body, width: side * 0.03),
                        borderRadius: BorderRadius.vertical(
                            top: Radius.circular(side * 0.06)),
                      ),
                    ),
                  ),
                  Container(
                    width: bw,
                    height: bh,
                    decoration: BoxDecoration(
                      color: body,
                      borderRadius: BorderRadius.circular(side * 0.07),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: Depth.lg,
                            offset: Offset(0, side * 0.03)),
                        BoxShadow(
                            color: a.withValues(alpha: 0.2 + pump * 0.25),
                            blurRadius: Depth.xl),
                      ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _speaker(spk, pump),
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _squareArt(widget.artBuilder, win,
                                Color.lerp(a, Colors.black, 0.3)!, win * 0.16),
                            SizedBox(height: bh * 0.07),
                            // Level lights.
                            SizedBox(
                              height: bh * 0.14,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  for (var i = 0; i < 5; i++)
                                    Container(
                                      margin: EdgeInsets.symmetric(
                                          horizontal: win * 0.025),
                                      width: win * 0.1,
                                      height: bh *
                                          0.14 *
                                          (widget.playing
                                              ? 0.3 +
                                                  0.7 *
                                                      (0.5 +
                                                              0.5 *
                                                                  math.sin(t *
                                                                          2 *
                                                                          math.pi *
                                                                          (2 + i % 3) +
                                                                      i * 1.3))
                                                          .abs()
                                              : 0.3),
                                      decoration: BoxDecoration(
                                        color: a,
                                        borderRadius:
                                            BorderRadius.circular(win * 0.03),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        _speaker(spk, pump),
                      ],
                    ),
                  ),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }
}
