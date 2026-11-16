import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/section_transition.dart';
import '../utils/emoji_field.dart' show lastPointer, lastPointerAt;
import '../utils/radii.dart';

// ── Skeletons ───────────────────────────────────────────────────────────────
// Loading placeholders in the SHAPE of what's coming, one family for every
// page. Rules (Anesius, 16 Nov):
//  • only when a page is genuinely slow — a fast page just finishes its
//    normal transition ([SkeletonGate]: ~280 ms grace, then ≥ 300 ms shown);
//  • the content BLENDS in over the skeleton along the same direction;
//  • the light wash follows the transition that brought the page: a side
//    slide / waveform → that way, a ripple / heartbeat / a page opened from
//    a tap → a ring from the tap point, rising styles → upward, fade → a
//    gentle glow in place. Reduce-motion → still.

/// How the wash moves.
enum SkeletonSweep { ltr, rtl, up, radial, glow, diagonal }

/// The latest motion hint (who brought this page in, and from where).
class SkeletonFlow {
  SkeletonFlow._();

  static SkeletonSweep _sweep = SkeletonSweep.diagonal;
  static Offset? _origin;
  static DateTime _at = DateTime.fromMillisecondsSinceEpoch(0);
  static Key? _lastKey;

  /// Called by SectionSwitch: the section it's switching to (by key), the
  /// user's transition style and which way it travels.
  static void hintSection(Key? key, SectionTransitionStyle style,
      {required bool forward}) {
    if (key == _lastKey) return; // same section rebuilding
    _lastKey = key;
    _at = DateTime.now();
    _origin = lastPointer;
    _sweep = switch (style) {
      SectionTransitionStyle.slide ||
      SectionTransitionStyle.wave ||
      SectionTransitionStyle.cube =>
        forward ? SkeletonSweep.rtl : SkeletonSweep.ltr,
      SectionTransitionStyle.ripple ||
      SectionTransitionStyle.heartbeat =>
        SkeletonSweep.radial,
      SectionTransitionStyle.depth ||
      SectionTransitionStyle.equaliser =>
        SkeletonSweep.up,
      SectionTransitionStyle.fade => SkeletonSweep.glow,
    };
  }

  /// The sweep for a skeleton appearing now: the last section change if it
  /// was the latest thing that happened; a tap after it (opening a page /
  /// sheet) → a ring from that tap; nothing recent → a calm diagonal.
  static (SkeletonSweep, Offset?) current() {
    final now = DateTime.now();
    final tapAt = lastPointerAt;
    final tapNewer =
        tapAt != null && tapAt.isAfter(_at.add(const Duration(milliseconds: 300)));
    if (tapNewer && now.difference(tapAt) < const Duration(seconds: 3)) {
      return (SkeletonSweep.radial, lastPointer);
    }
    if (now.difference(_at) < const Duration(seconds: 3)) {
      return (_sweep, _origin);
    }
    return (SkeletonSweep.diagonal, null);
  }
}

class _Shimmer extends StatefulWidget {
  const _Shimmer({required this.child});
  final Widget child;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1500))
    ..repeat();
  late final (SkeletonSweep, Offset?) _flow = SkeletonFlow.current();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Shader _shader(Rect r, double t, Color base, Color light) {
    final (sweep, origin) = _flow;
    switch (sweep) {
      case SkeletonSweep.radial:
        // A ring spreading out from the tap point.
        var c = r.center;
        final box = context.findRenderObject() as RenderBox?;
        if (origin != null && box != null && box.attached) {
          c = box.globalToLocal(origin);
        }
        final far = [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]
            .map((p) => (p - c).distance)
            .reduce(math.max);
        final radius = math.max(1.0, far);
        final s = (t * 1.3 - 0.15).clamp(0.0, 1.0);
        return RadialGradient(
          center: Alignment(
            r.width == 0 ? 0 : (c.dx - r.left) / r.width * 2 - 1,
            r.height == 0 ? 0 : (c.dy - r.top) / r.height * 2 - 1,
          ),
          radius: radius / math.max(1.0, r.shortestSide) * 1.0,
          colors: [base, light, base],
          stops: [
            (s - 0.12).clamp(0.0, 1.0),
            s,
            (s + 0.12).clamp(0.0, 1.0),
          ],
        ).createShader(r);
      case SkeletonSweep.glow:
        final v = 0.5 - 0.5 * math.cos(t * 2 * math.pi);
        final c = Color.lerp(base, light, v * 0.8)!;
        return LinearGradient(colors: [c, c]).createShader(r);
      case SkeletonSweep.ltr:
      case SkeletonSweep.rtl:
      case SkeletonSweep.up:
      case SkeletonSweep.diagonal:
        final x = -1.0 + 3.0 * t;
        final (Alignment b, Alignment e) = switch (sweep) {
          SkeletonSweep.ltr => (Alignment(x - 1, 0), Alignment(x + 1, 0)),
          SkeletonSweep.rtl => (Alignment(-x + 1, 0), Alignment(-x - 1, 0)),
          SkeletonSweep.up => (Alignment(0, -x + 1), Alignment(0, -x - 1)),
          _ => (Alignment(x - 1, -0.3), Alignment(x + 1, 0.3)),
        };
        return LinearGradient(
          begin: b,
          end: e,
          colors: [base, light, base],
          stops: const [0.25, 0.5, 0.75],
        ).createShader(r);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final base = scheme.onSurface.withValues(alpha: dark ? 0.08 : 0.07);
    final light = scheme.onSurface.withValues(alpha: dark ? 0.16 : 0.13);
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      return _Tint(color: base, child: widget.child);
    }
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (r) => _shader(r, _c.value, base, light),
        child: child,
      ),
    );
  }
}

class _Tint extends StatelessWidget {
  const _Tint({required this.color, required this.child});
  final Color color;
  final Widget child;
  @override
  Widget build(BuildContext context) => ColorFiltered(
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn), child: child);
}

Widget _bar(double w, double h, {double r = 6}) => Container(
      width: w < 0 ? 0 : w,
      height: h,
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(r)),
    );

/// A skeleton wrapper: shimmer + "Loading" for screen readers, and the
/// grace beat — a page that loads within it never shows a skeleton at all.
Widget _skeleton(String label, Widget child) => _Graced(
      child: Semantics(
        label: label,
        child: ExcludeSemantics(child: _Shimmer(child: child)),
      ),
    );

/// Inside a [SkeletonGate] the gate has already waited — show at once.
class _NoGrace extends InheritedWidget {
  const _NoGrace({required super.child});
  @override
  bool updateShouldNotify(_NoGrace old) => false;
}

/// Nothing for the first ~280 ms (the page's own transition), then the
/// skeleton fades in quickly.
class _Graced extends StatefulWidget {
  const _Graced({required this.child});
  final Widget child;

  @override
  State<_Graced> createState() => _GracedState();
}

class _GracedState extends State<_Graced> {
  bool _show = false;
  Timer? _t;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_show || _t != null) return;
    if (context.getInheritedWidgetOfExactType<_NoGrace>() != null) {
      _show = true;
      return;
    }
    _t = Timer(const Duration(milliseconds: 280), () {
      if (mounted) setState(() => _show = true);
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
        opacity: _show ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: widget.child,
      );
}

// ── The gate: skeleton only when slow, content blends in ──────────────────

/// Shows [child] once [loading] is false. If loading takes longer than
/// [delay] (≈ the page's own transition), [skeleton] shows meanwhile — and
/// stays at least [minShow] so it never flickers — then the content fills in
/// over it along the same direction as the wash.
class SkeletonGate extends StatefulWidget {
  const SkeletonGate({
    super.key,
    required this.loading,
    required this.skeleton,
    required this.child,
    this.delay = const Duration(milliseconds: 280),
    this.minShow = const Duration(milliseconds: 300),
  });

  final bool loading;
  final Widget skeleton;
  final Widget child;
  final Duration delay;
  final Duration minShow;

  @override
  State<SkeletonGate> createState() => _SkeletonGateState();
}

class _SkeletonGateState extends State<SkeletonGate>
    with SingleTickerProviderStateMixin {
  bool _showSkeleton = false;
  DateTime? _shownAt;
  Timer? _wait, _hold;
  late final AnimationController _reveal = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 520))
    ..value = 1;
  (SkeletonSweep, Offset?) _flow = (SkeletonSweep.diagonal, null);

  @override
  void initState() {
    super.initState();
    if (widget.loading) _arm();
  }

  void _arm() {
    _wait?.cancel();
    _wait = Timer(widget.delay, () {
      if (!mounted || !widget.loading) return;
      _flow = SkeletonFlow.current();
      setState(() {
        _showSkeleton = true;
        _shownAt = DateTime.now();
      });
    });
  }

  @override
  void didUpdateWidget(SkeletonGate old) {
    super.didUpdateWidget(old);
    if (widget.loading && !old.loading) {
      _arm();
    } else if (!widget.loading && old.loading) {
      _wait?.cancel();
      if (!_showSkeleton) return; // fast: never shown
      final left = widget.minShow -
          DateTime.now().difference(_shownAt ?? DateTime.now());
      _hold?.cancel();
      _hold = Timer(left.isNegative ? Duration.zero : left, () {
        if (!mounted) return;
        final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
        setState(() => _showSkeleton = false);
        if (reduce) {
          _reveal.value = 1;
        } else {
          _reveal.forward(from: 0);
        }
      });
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    _hold?.cancel();
    _reveal.dispose();
    super.dispose();
  }

  /// The content filling in: a soft edge travelling the wash's way.
  Shader _mask(Rect r, double t) {
    final (sweep, origin) = _flow;
    final e = Curves.easeOutCubic.transform(t);
    const soft = 0.25;
    final a = (e * (1 + soft)) - soft; // edge position 0..1
    final stops = [a.clamp(0.0, 1.0), (a + soft).clamp(0.0, 1.0)];
    const colors = [Colors.white, Color(0x00FFFFFF)];
    switch (sweep) {
      case SkeletonSweep.radial:
        var c = r.center;
        final box = context.findRenderObject() as RenderBox?;
        if (origin != null && box != null && box.attached) {
          c = box.globalToLocal(origin);
        }
        final far = [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]
            .map((p) => (p - c).distance)
            .reduce(math.max);
        return RadialGradient(
          center: Alignment(
            r.width == 0 ? 0 : (c.dx - r.left) / r.width * 2 - 1,
            r.height == 0 ? 0 : (c.dy - r.top) / r.height * 2 - 1,
          ),
          radius: math.max(1.0, far) / math.max(1.0, r.shortestSide),
          colors: colors,
          stops: stops,
        ).createShader(r);
      case SkeletonSweep.glow:
        return LinearGradient(colors: [
          Colors.white.withValues(alpha: e),
          Colors.white.withValues(alpha: e),
        ]).createShader(r);
      case SkeletonSweep.ltr:
      case SkeletonSweep.rtl:
      case SkeletonSweep.up:
      case SkeletonSweep.diagonal:
        final (Alignment b, Alignment en) = switch (sweep) {
          SkeletonSweep.ltr => (Alignment.centerLeft, Alignment.centerRight),
          SkeletonSweep.rtl => (Alignment.centerRight, Alignment.centerLeft),
          SkeletonSweep.up => (Alignment.bottomCenter, Alignment.topCenter),
          _ => (Alignment.topLeft, Alignment.bottomRight),
        };
        return LinearGradient(
                begin: b, end: en, colors: colors, stops: stops)
            .createShader(r);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_showSkeleton) return _NoGrace(child: widget.skeleton);
    if (widget.loading) return const SizedBox.shrink(); // the grace beat
    return AnimatedBuilder(
      animation: _reveal,
      child: widget.child,
      builder: (context, child) {
        final t = _reveal.value;
        if (t >= 1) return child!;
        return Stack(children: [
          // The skeleton eases out as the content fills its places.
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                  opacity: (1 - t).clamp(0.0, 1.0),
                  child: _NoGrace(child: widget.skeleton)),
            ),
          ),
          ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (r) => _mask(r, t),
            child: child,
          ),
        ]);
      },
    );
  }
}

// ── Page shapes ──────────────────────────────────────────────────────────

/// Rows of people / chats / groups: avatar + two lines.
class SkeletonList extends StatelessWidget {
  const SkeletonList({
    super.key,
    this.rows = 7,
    this.avatar = 44,
    this.padding,
    this.square = false,
    this.trailing = false,
  });
  final int rows;
  final double avatar;
  final EdgeInsetsGeometry? padding;

  /// A square cover instead of a round avatar (songs).
  final bool square;

  /// A small time pill on the right (chat lists).
  final bool trailing;

  @override
  Widget build(BuildContext context) {
    return _skeleton(
      'Loading',
      ListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: padding ?? const EdgeInsets.fromLTRB(12, 8, 12, 8),
        itemCount: rows,
        itemBuilder: (_, i) {
          // Varied widths so it reads as content, not a grid.
          final a = 0.45 + ((i * 37) % 30) / 100;
          final b = 0.25 + ((i * 53) % 30) / 100;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: LayoutBuilder(builder: (context, c) {
              final w = c.maxWidth - avatar - 14 - (trailing ? 46 : 0);
              return Row(children: [
                _bar(avatar, avatar, r: square ? Radii.md : avatar / 2),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _bar(w * a, 11),
                      const SizedBox(height: 8),
                      _bar(w * b, 9),
                    ],
                  ),
                ),
                if (trailing) ...[
                  const SizedBox(width: 10),
                  _bar(36, 9),
                ],
              ]);
            }),
          );
        },
      ),
    );
  }
}

/// A chat thread loading: bubbles on both sides, a date pill.
class SkeletonChat extends StatelessWidget {
  const SkeletonChat({super.key});

  @override
  Widget build(BuildContext context) {
    const shape = [
      (false, 0.55, 1), (false, 0.38, 1), (true, 0.5, 1), (false, 0.62, 2),
      (true, 0.34, 1), (true, 0.58, 2), (false, 0.44, 1), (true, 0.4, 1),
    ];
    return _skeleton(
      'Loading messages',
      LayoutBuilder(builder: (context, c) {
        return ListView(
          reverse: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          children: [
            for (final (i, (mine, f, lines)) in shape.indexed) ...[
              Align(
                alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: _bar(c.maxWidth * f, lines == 1 ? 38 : 58,
                      r: Radii.lg),
                ),
              ),
              if (i == 4)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: _bar(78, 22, r: 11),
                  ),
                ),
            ],
          ],
        );
      }),
    );
  }
}

/// A row of story circles with names under them.
class SkeletonStories extends StatelessWidget {
  const SkeletonStories({super.key, this.count = 6, this.size = 64});
  final int count;
  final double size;

  @override
  Widget build(BuildContext context) => _skeleton(
        'Loading',
        SizedBox(
          height: size + 30,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: count,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (_, _) => Column(children: [
              _bar(size, size, r: size / 2),
              const SizedBox(height: 8),
              _bar(size * 0.75, 9),
            ]),
          ),
        ),
      );
}

/// Cards stacked (plans, settings blocks, admin panels): a title, two lines.
class SkeletonCards extends StatelessWidget {
  const SkeletonCards({super.key, this.cards = 3, this.height = 96});
  final int cards;
  final double height;

  @override
  Widget build(BuildContext context) => _skeleton(
        'Loading',
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.all(14),
          itemCount: cards,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (_, i) => LayoutBuilder(builder: (context, c) {
            final w = c.maxWidth;
            return Container(
              height: height,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(Radii.xl),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _bar(w * (0.4 + (i % 3) * 0.1), 13),
                  const SizedBox(height: 10),
                  _bar(w * 0.7, 9),
                  const SizedBox(height: 7),
                  _bar(w * 0.5, 9),
                ],
              ),
            );
          }),
        ),
      );
}

/// A grid of tiles (moments, photos).
class SkeletonGrid extends StatelessWidget {
  const SkeletonGrid({super.key, this.tiles = 6, this.columns = 3});
  final int tiles;
  final int columns;

  @override
  Widget build(BuildContext context) => _skeleton(
        'Loading',
        GridView.count(
          crossAxisCount: columns,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          children: [
            for (var i = 0; i < tiles; i++)
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(Radii.lg),
                ),
              ),
          ],
        ),
      );
}

/// Our Space: the hero card, a strip of moment tiles, playlist rows.
class SkeletonSpace extends StatelessWidget {
  const SkeletonSpace({super.key});

  @override
  Widget build(BuildContext context) => _skeleton(
        'Loading Our Space',
        LayoutBuilder(builder: (context, c) {
          final w = c.maxWidth;
          return ListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.all(14),
            children: [
              _bar(w, 168, r: Radii.xxl),
              const SizedBox(height: 16),
              _bar(w * 0.35, 12),
              const SizedBox(height: 10),
              Row(children: [
                for (var i = 0; i < 3; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(child: _bar(double.infinity, 96, r: Radii.lg)),
                ],
              ]),
              const SizedBox(height: 18),
              _bar(w * 0.3, 12),
              for (var i = 0; i < 3; i++)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(children: [
                    _bar(42, 42, r: Radii.md),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _bar(w * (0.45 - i * 0.05), 11),
                        const SizedBox(height: 7),
                        _bar(w * 0.25, 9),
                      ],
                    ),
                  ]),
                ),
            ],
          );
        }),
      );
}

/// A profile / friend sheet: big avatar, name, a line, action buttons.
class SkeletonProfile extends StatelessWidget {
  const SkeletonProfile({super.key, this.actions = 3});
  final int actions;

  @override
  Widget build(BuildContext context) => _skeleton(
        'Loading',
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _bar(96, 96, r: 48),
              const SizedBox(height: 14),
              _bar(160, 14),
              const SizedBox(height: 8),
              _bar(110, 10),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < actions; i++) ...[
                    if (i > 0) const SizedBox(width: 14),
                    _bar(52, 52, r: 26),
                  ],
                ],
              ),
            ],
          ),
        ),
      );
}

/// Now Playing: the disc, title + artist, the waveform, the controls.
class SkeletonNowPlaying extends StatelessWidget {
  const SkeletonNowPlaying({super.key});

  @override
  Widget build(BuildContext context) => _skeleton(
        'Loading',
        LayoutBuilder(builder: (context, c) {
          final d = math.min(220.0, c.maxWidth * 0.6);
          return Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 24),
            _bar(d, d, r: d / 2),
            const SizedBox(height: 22),
            _bar(150, 16),
            const SizedBox(height: 8),
            _bar(100, 11),
            const SizedBox(height: 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < 28; i++) ...[
                  if (i > 0) const SizedBox(width: 3),
                  _bar(4, 10.0 + (i * 7 % 22), r: 2),
                ],
              ],
            ),
            const SizedBox(height: 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _bar(44, 44, r: 22),
                const SizedBox(width: 18),
                _bar(68, 68, r: 34),
                const SizedBox(width: 18),
                _bar(44, 44, r: 22),
              ],
            ),
          ]);
        }),
      );
}
