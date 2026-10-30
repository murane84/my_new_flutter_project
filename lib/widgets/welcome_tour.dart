import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/on_accent.dart';

/// A short, warm first-run tour: Aluta · Harmony · Circle · Glow · your
/// music has feelings. Shown once; replay from Moments & nudges.
class WelcomeTour {
  static const _seenKey = 'welcome_tour_seen_v1';

  /// True while the tour is on screen (other moments wait).
  static bool showing = false;

  /// Show the tour if this device hasn't seen it yet.
  static Future<void> maybeShow(BuildContext context) async {
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getBool(_seenKey) == true) return;
      await p.setBool(_seenKey, true);
    } catch (_) {
      return;
    }
    if (!context.mounted) return;
    await show(context);
  }

  static Future<void> show(BuildContext context) async {
    showing = true;
    try {
      await _open(context);
    } finally {
      showing = false;
    }
  }

  static Future<void> _open(BuildContext context) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.62),
      transitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (_, _, _) => const _TourPages(),
      transitionBuilder: (_, a, _, child) => FadeTransition(
        opacity: a,
        child: ScaleTransition(
          scale: Tween(begin: 0.94, end: 1.0)
              .animate(CurvedAnimation(parent: a, curve: Curves.easeOutBack)),
          child: child,
        ),
      ),
    );
  }
}

class _Page {
  const _Page(this.icon, this.title, this.body,
      {this.logo = false, required this.tint, this.chips = const []});
  final IconData icon;
  final String title;
  final String body;
  final bool logo;
  // Each step has its own colour, so the tour feels like moving through
  // the app's different places.
  final Color tint;
  final List<(IconData, String)> chips;
}

const _pages = [
  _Page(Icons.favorite_rounded, 'Welcome to Aluta',
      'Music, chats and the people you love — in one warm place.',
      logo: true,
      tint: Color(0xFFE5174A),
      chips: [
        (Icons.music_note_rounded, 'Music'),
        (Icons.forum_rounded, 'Chats'),
        (Icons.favorite_rounded, 'Love'),
      ]),
  _Page(Icons.favorite_rounded, 'Harmony',
      'Your closest bonds. Our Space keeps your moments, your playlist and your streak — and Listen Together plays the same song on both phones.',
      tint: Color(0xFFD81B78),
      chips: [
        (Icons.home_rounded, 'Our Space'),
        (Icons.headphones_rounded, 'Listen Together'),
        (Icons.local_fire_department_rounded, 'Streaks'),
      ]),
  _Page(Icons.forum_rounded, 'Circle',
      'Your chats and groups. Send secret hearts, voice notes, polls and songs — double-tap your partner’s photo to send a heartbeat 💓',
      tint: Color(0xFF1E88E5),
      chips: [
        (Icons.lock_rounded, 'Secret hearts'),
        (Icons.mic_rounded, 'Voice notes'),
        (Icons.call_rounded, 'Calls'),
      ]),
  _Page(Icons.auto_awesome_rounded, 'Glow',
      'Love writing, gentle insights and little things to try together — a new card every day.',
      tint: Color(0xFFF59E0B),
      chips: [
        (Icons.edit_note_rounded, 'Love notes'),
        (Icons.lightbulb_rounded, 'Insights'),
        (Icons.wb_sunny_rounded, 'Daily card'),
      ]),
  _Page(Icons.graphic_eq_rounded, 'Your music has feelings',
      'Tell Aluta how a song makes you feel 😍🥹💪😌💔 and it helps you share it with the right person. It all stays on your phone.',
      tint: Color(0xFF8B5CF6),
      chips: [
        (Icons.mood_rounded, 'Feels'),
        (Icons.insights_rounded, 'Week in music'),
        (Icons.lyrics_rounded, 'Lyrics'),
      ]),
];

class _TourPages extends StatefulWidget {
  const _TourPages();
  @override
  State<_TourPages> createState() => _TourPagesState();
}

class _TourPagesState extends State<_TourPages>
    with SingleTickerProviderStateMixin {
  final _ctrl = PageController();
  int _i = 0;
  // Slow breathing of the hero glow + rings.
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2400))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _go(int to) {
    if (to < 0) return;
    if (to >= _pages.length) {
      Navigator.of(context).pop();
      return;
    }
    _ctrl.animateToPage(to,
        duration: const Duration(milliseconds: 360),
        curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final last = _i == _pages.length - 1;
    final tint = _pages[_i].tint;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                _go(_i + 1),
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                _go(_i - 1),
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                Navigator.of(context).pop(),
          },
          child: Focus(
            autofocus: true,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 360),
              constraints: const BoxConstraints(maxWidth: 380, maxHeight: 560),
              margin: const EdgeInsets.all(20),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1C1A1D) : Colors.white,
                borderRadius: BorderRadius.circular(30),
                border: Border.all(
                    color: tint.withValues(alpha: isDark ? 0.35 : 0.18)),
                boxShadow: [
                  BoxShadow(
                      color: tint.withValues(alpha: 0.30),
                      blurRadius: 48,
                      offset: const Offset(0, 18)),
                ],
              ),
              child: Column(
                children: [
                  Expanded(
                    child: PageView.builder(
                      controller: _ctrl,
                      itemCount: _pages.length,
                      onPageChanged: (i) => setState(() => _i = i),
                      itemBuilder: (_, i) =>
                          _page(scheme, isDark, _pages[i], i),
                    ),
                  ),
                  // Footer: Back · step progress · Next.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
                    child: Row(children: [
                      SizedBox(
                        width: 84,
                        child: AnimatedOpacity(
                          opacity: _i == 0 ? 0 : 1,
                          duration: const Duration(milliseconds: 200),
                          child: TextButton.icon(
                            onPressed: _i == 0 ? null : () => _go(_i - 1),
                            icon: const Icon(Icons.arrow_back_rounded,
                                size: 18),
                            label: const Text('Back'),
                            style: TextButton.styleFrom(
                                foregroundColor: scheme.onSurfaceVariant),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            for (var k = 0; k < _pages.length; k++)
                              GestureDetector(
                                onTap: () => _go(k),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 260),
                                  margin:
                                      const EdgeInsets.symmetric(horizontal: 3),
                                  width: k == _i ? 22 : 7,
                                  height: 7,
                                  decoration: BoxDecoration(
                                    color: k <= _i
                                        ? tint
                                        : scheme.onSurface
                                            .withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        child: FilledButton(
                          onPressed: () => _go(_i + 1),
                          style: FilledButton.styleFrom(
                            backgroundColor: tint,
                            // Glyphs pick white or near-black by the
                            // fill, so the arrow / heart never vanish.
                            foregroundColor: onAccent(tint),
                            iconColor: onAccent(tint),
                            minimumSize: const Size(96, 46),
                            shape: const StadiumBorder(),
                            textStyle: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 14.5),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(last ? 'Let’s go' : 'Next'),
                              const SizedBox(width: 6),
                              Icon(
                                  last
                                      ? Icons.favorite_rounded
                                      : Icons.arrow_forward_rounded,
                                  size: 18),
                            ],
                          ),
                        ),
                      ),
                    ]),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _page(ColorScheme scheme, bool isDark, _Page p, int index) {
    final t = p.tint;
    final deep = Color.lerp(t, Colors.black, 0.35)!;
    return Column(children: [
      // Hero: a colour wash with breathing rings around the emblem.
      SizedBox(
        height: 250,
        child: Stack(fit: StackFit.expand, children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color.lerp(t, Colors.white, 0.12)!, deep],
              ),
            ),
          ),
          // Soft light blobs.
          Positioned(
            top: -40,
            left: -30,
            child: _blob(160, Colors.white.withValues(alpha: 0.10)),
          ),
          Positioned(
            bottom: -60,
            right: -40,
            child: _blob(200, Colors.black.withValues(alpha: 0.12)),
          ),
          // Breathing rings + emblem.
          Center(
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (_, child) {
                final v = Curves.easeInOut.transform(_pulse.value);
                return Stack(alignment: Alignment.center, children: [
                  for (final (size, a) in const [(190.0, 0.08), (150.0, 0.12)])
                    Container(
                      width: size + 10 * v,
                      height: size + 10 * v,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: a),
                      ),
                    ),
                  child!,
                ]);
              },
              child: TweenAnimationBuilder<double>(
                key: ValueKey(p.title),
                tween: Tween(begin: 0.6, end: 1),
                duration: const Duration(milliseconds: 620),
                curve: Curves.elasticOut,
                builder: (_, s, child) =>
                    Transform.scale(scale: s, child: child),
                child: Container(
                  width: 104,
                  height: 104,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withValues(alpha: 0.25),
                          blurRadius: 24,
                          offset: const Offset(0, 10)),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: p.logo
                      ? ClipOval(
                          child: Image.asset('assets/images/logo.png',
                              width: 68,
                              height: 68,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  Icon(p.icon, size: 48, color: t)),
                        )
                      : ShaderMask(
                          shaderCallback: (r) => LinearGradient(
                            colors: [Color.lerp(t, Colors.white, 0.15)!, deep],
                          ).createShader(r),
                          child:
                              Icon(p.icon, size: 50, color: Colors.white),
                        ),
                ),
              ),
            ),
          ),
          // Step label + Skip on the colour.
          Positioned(
            top: 14,
            left: 18,
            child: Text('${index + 1} of ${_pages.length}',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4)),
          ),
          Positioned(
            top: 6,
            right: 8,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: Colors.white.withValues(alpha: 0.16),
                visualDensity: VisualDensity.compact,
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                textStyle: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w700),
              ),
              child: const Text('Skip'),
            ),
          ),
        ]),
      ),
      // Text + what's inside.
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 6),
          // Short screens / large text: shrink rather than overflow.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 312,
              child: Column(children: [
                Text(p.title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.2,
                        color: scheme.onSurface)),
                const SizedBox(height: 10),
                Text(p.body,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 14.5,
                        height: 1.5,
                        color: scheme.onSurfaceVariant)),
                if (p.chips.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final (icon, label) in p.chips)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: t.withValues(alpha: isDark ? 0.18 : 0.10),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(icon, size: 14, color: t),
                            const SizedBox(width: 5),
                            Text(label,
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: isDark
                                        ? Color.lerp(t, Colors.white, 0.35)
                                        : deep)),
                          ]),
                        ),
                    ],
                  ),
                ],
              ]),
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _blob(double size, Color c) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: c),
      );
}
