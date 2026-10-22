import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A short, warm first-run tour: Aluta · Harmony · Circle · Glow · your
/// music has feelings. Shown once; replay from Moments & nudges.
class WelcomeTour {
  static const _seenKey = 'welcome_tour_seen_v1';

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

  static Future<void> show(BuildContext context) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black54,
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
  const _Page(this.icon, this.title, this.body, {this.logo = false});
  final IconData icon;
  final String title;
  final String body;
  final bool logo;
}

const _pages = [
  _Page(Icons.favorite_rounded, 'Welcome to Aluta',
      'Music, chats and the people you love — in one warm place.',
      logo: true),
  _Page(Icons.favorite_rounded, 'Harmony',
      'Your closest bonds. Our Space keeps your moments, your playlist and your streak — and Listen Together plays the same song on both phones.'),
  _Page(Icons.forum_rounded, 'Circle',
      'Your chats and groups. Send secret hearts, voice notes, polls and songs — double-tap your partner’s photo to send a heartbeat 💓'),
  _Page(Icons.auto_awesome_rounded, 'Glow',
      'Love writing, gentle insights and little things to try together — a new card every day.'),
  _Page(Icons.graphic_eq_rounded, 'Your music has feelings',
      'Tell Aluta how a song makes you feel 😍🥹💪😌💔 and it helps you share it with the right person. It all stays on your phone.'),
];

class _TourPages extends StatefulWidget {
  const _TourPages();
  @override
  State<_TourPages> createState() => _TourPagesState();
}

class _TourPagesState extends State<_TourPages> {
  final _ctrl = PageController();
  int _i = 0;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _next() {
    if (_i >= _pages.length - 1) {
      Navigator.of(context).pop();
      return;
    }
    _ctrl.nextPage(
        duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final last = _i == _pages.length - 1;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 360,
          height: 470,
          margin: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: isDark ? scheme.surfaceContainerHigh : Colors.white,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.25),
                  blurRadius: 40,
                  offset: const Offset(0, 14)),
            ],
          ),
          child: Column(
            children: [
              Align(
                alignment: Alignment.topRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Skip'),
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _ctrl,
                  itemCount: _pages.length,
                  onPageChanged: (i) => setState(() => _i = i),
                  itemBuilder: (_, i) => _page(scheme, _pages[i]),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var k = 0; k < _pages.length; k++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: k == _i ? 22 : 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: k == _i
                            ? scheme.primary
                            : scheme.primary.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 22),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _next,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      shape: const StadiumBorder(),
                    ),
                    child: Text(last ? 'Let’s go 💞' : 'Next'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _page(ColorScheme scheme, _Page p) {
    final a = scheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TweenAnimationBuilder<double>(
            key: ValueKey(p.title),
            tween: Tween(begin: 0.6, end: 1),
            duration: const Duration(milliseconds: 520),
            curve: Curves.elasticOut,
            builder: (_, s, child) => Transform.scale(scale: s, child: child),
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color.lerp(a, Colors.white, 0.25)!, a],
                ),
                boxShadow: [
                  BoxShadow(
                      color: a.withValues(alpha: 0.35),
                      blurRadius: 24,
                      offset: const Offset(0, 8)),
                ],
              ),
              alignment: Alignment.center,
              child: p.logo
                  ? ClipOval(
                      child: Image.asset('assets/images/logo.png',
                          width: 64,
                          height: 64,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              Icon(p.icon, size: 44, color: Colors.white)),
                    )
                  : Icon(p.icon, size: 44, color: Colors.white),
            ),
          ),
          const SizedBox(height: 22),
          Text(p.title,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurface)),
          const SizedBox(height: 10),
          Text(p.body,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 14.5,
                  height: 1.45,
                  color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
