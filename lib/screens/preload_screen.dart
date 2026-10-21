import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/song_library.dart';
import '../services/app_busy.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'home_page.dart';
import 'api_service.dart';
import '../services/connected_contacts_service.dart';

/// The post-unlock warm-up gate.
///
/// Opens on a black stage that matches the native splash (so the hand-off is
/// seamless), then comes alive: the Aluta mark pulses with a soft heartbeat,
/// a scatter of music notes, hearts, chat bubbles and flowers drifts up behind
/// it, and a weighted progress bar fills as the data Home actually SHOWS
/// (profile, circle, statuses) warms up.
///
/// Speed first: the heavy on-device scans (music library, contacts match) no
/// longer block the gate — they run in the background and the app fills them in
/// as they finish. A warm relaunch (cache present) opens Home almost instantly;
/// only a fresh install does the fuller warm-up. A ceiling still guarantees the
/// user is never trapped.
class PreloadScreen extends StatefulWidget {
  static const String routeName = '/preload';
  const PreloadScreen({super.key});

  @override
  State<PreloadScreen> createState() => _PreloadScreenState();
}

class _PreloadScreenState extends State<PreloadScreen>
    with TickerProviderStateMixin {
  // Task weights (sum = 1.0) — only the pieces Home paints with gate the bar.
  static const double _wInit = 0.08;
  static const double _wProfile = 0.24;
  static const double _wCircle = 0.40; // friends + conversations + spaces
  static const double _wStories = 0.20;
  static const double _wFinal = 0.08;

  double _target = 0; // where the bar should be as tasks complete
  double _shown = 0; // eased, displayed value
  String _stage = 'Waking up…';
  String _name = ''; // cached username → "Welcome back, <first>"
  Timer? _ticker;
  bool _done = false;

  // Reveal (content + decor fade/rise in after the native-matching first frame)
  // and a gentle heartbeat pulse on the mark.
  late final AnimationController _reveal = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 750));
  late final AnimationController _beat = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1700))
    ..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    splashOnScreen.value++; // no extra logo spinner over the preload screen
    _ticker = Timer.periodic(const Duration(milliseconds: 40), (_) {
      if (!mounted) return;
      final diff = _target - _shown;
      if (diff.abs() < 0.0015) return;
      setState(() => _shown += diff * 0.18);
    });
    // Hold the native-identical first frame for a beat, then wake the screen.
    Future.delayed(const Duration(milliseconds: 180), () {
      if (mounted) _reveal.forward();
    });
    _run();
  }

  void _bump(double add, String stage) {
    if (!mounted) return;
    setState(() {
      _target = (_target + add).clamp(0.0, 1.0);
      _stage = stage;
    });
  }

  Future<void> _guard(Future<dynamic> f, {int seconds = 15}) async {
    try {
      await f.timeout(Duration(seconds: seconds));
    } catch (_) {}
  }

  Future<bool> _isOnline() async {
    try {
      final r = await Connectivity()
          .checkConnectivity()
          .timeout(const Duration(seconds: 3));
      return r.any((x) => x != ConnectivityResult.none);
    } catch (_) {
      return true; // assume online if we can't tell — network tasks self-timeout
    }
  }

  Future<void> _run() async {
    final prefs = await SharedPreferences.getInstance();
    // Fresh install (no warm cache yet) genuinely has more to pull.
    final firstRun = prefs.getString('cached_friends_v1') == null;
    final cached = (prefs.getString('username') ?? '').trim();
    if (cached.isNotEmpty && mounted) setState(() => _name = cached);

    // Show the branded moment for at least this long so the hand-off + animation
    // read smoothly even when everything loads instantly (web / warm relaunch).
    final minShow = DateTime.now().add(const Duration(milliseconds: 1300));

    _bump(_wInit, firstRun ? 'Waking up…' : 'Welcome back…');
    final online = await _isOnline();
    final api = ApiService();

    // Heavy DEVICE scans run in the BACKGROUND now — they are not needed to
    // paint Home, so they never hold the user behind a long music/contacts
    // scan. They populate their singletons; the app fills them in as they land.
    if (!kIsWeb) {
      // Warm the heavy device scans AFTER Home is interactive, not during the
      // relaunch. Contacts/music queries do real work on the UI isolate, so
      // firing them the instant Home appears janked the first taps (ANRs).
      // A few seconds' grace keeps reopen smooth; the services self-throttle
      // repeat scans, so this still pre-warms them.
      Future.delayed(const Duration(seconds: 5), () {
        unawaited(appBusy
            .runMajor(() => ConnectedContactsService.instance.refresh())
            .then((_) {}).catchError((_) {}));
        unawaited(appBusy
            .runMajor(() => SongLibrary.songs())
            .then((_) {}).catchError((_) {}));
      });
    }

    if (firstRun) {
      // COLD START — warm exactly what Home shows before revealing it, with a
      // ceiling so a hung request can never trap the user.
      final ceilingTimer = Timer(const Duration(seconds: 45), _finish);

      final tProfile = () async {
        if (online) await _guard(api.getUserData());
        _bump(_wProfile, 'Loading your space…');
      }();
      final tCircle = () async {
        if (online) {
          await Future.wait([
            _guard(api.fetchUsers()),
            _guard(api.listConversations()),
            _guard(api.listSpaces()),
          ]);
        }
        _bump(_wCircle, 'Syncing your circle…');
      }();
      final tStories = () async {
        if (online) await _guard(api.fetchStoriesFeed());
        _bump(_wStories, 'Catching up on status…');
      }();

      await Future.wait([tProfile, tCircle, tStories]);
      ceilingTimer.cancel();
    } else {
      // WARM START — paint Home fast; refresh everything silently in the
      // background from cache so the lists are already full on open.
      if (online) {
        unawaited(appBusy.runMajor(() => Future.wait([
          _guard(api.getUserData()),
          _guard(api.fetchUsers()),
          _guard(api.listConversations()),
          _guard(api.listSpaces()),
          _guard(api.fetchStoriesFeed()),
        ])));
      }
      _bump(_wProfile + _wCircle + _wStories, 'Getting things ready…');
    }

    _bump(_wFinal, 'Almost there…');
    // Hold until the eased bar reaches full AND the minimum moment has shown,
    // with a safety cap so a stalled tick can never trap us.
    final capAt = DateTime.now().add(const Duration(milliseconds: 2400));
    while (mounted &&
        (_shown < 0.995 || DateTime.now().isBefore(minShow)) &&
        DateTime.now().isBefore(capAt)) {
      await Future.delayed(const Duration(milliseconds: 40));
    }
    if (mounted) setState(() => _shown = 1.0);
    await Future.delayed(const Duration(milliseconds: 260));
    _finish();
  }

  void _finish() {
    if (_done || !mounted) return;
    _done = true;
    _ticker?.cancel();
    Navigator.pushReplacementNamed(context, HomePage.routeName);
  }

  @override
  void dispose() {
    splashOnScreen.value = (splashOnScreen.value - 1).clamp(0, 99);
    _ticker?.cancel();
    _reveal.dispose();
    _beat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final shown = _shown.clamp(0.0, 1.0);
    final pct = (shown * 100).round();
    final first =
        _name.isEmpty ? '' : _name.trim().split(RegExp(r'\s+')).first;

    return Scaffold(
      // Black to match the native splash exactly — the hand-off is invisible.
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Drifting glyphs behind everything (music notes, hearts, chat
          // bubbles, flowers, sparkles) — subtle, fading in with the reveal.
          Positioned.fill(child: _SplashDecor(reveal: _reveal, accent: accent)),
          SafeArea(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The mark is present from frame 0 (identical to the native
                  // splash); it just picks up a soft heartbeat as we wake.
                  ScaleTransition(
                    scale: Tween<double>(begin: 1.0, end: 1.05).animate(
                        CurvedAnimation(
                            parent: _beat, curve: Curves.easeInOut)),
                    child: Container(
                      width: 128,
                      height: 128,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: accent.withValues(alpha: 0.38),
                            blurRadius: 50,
                            spreadRadius: 6,
                          ),
                        ],
                      ),
                      child: ClipOval(
                        child: Image.asset(
                          'assets/images/logo.png',
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            color: const Color(0xFF1A1A1A),
                            child: Icon(Icons.favorite_rounded,
                                color: accent, size: 48),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 30),
                  // Greeting + stage + progress rise and fade in after the mark.
                  AnimatedBuilder(
                    animation: _reveal,
                    builder: (context, child) {
                      final t =
                          Curves.easeOutCubic.transform(_reveal.value);
                      return Opacity(
                        opacity: t.clamp(0.0, 1.0),
                        child: Transform.translate(
                          offset: Offset(0, (1 - t) * 14),
                          child: child,
                        ),
                      );
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: Text(
                            first.isEmpty ? 'Aluta' : 'Welcome back, $first',
                            key: ValueKey(first),
                            style: const TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.2,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          child: Text(
                            _stage,
                            key: ValueKey(_stage),
                            style: TextStyle(
                                fontSize: 13,
                                color: Colors.white.withValues(alpha: 0.6)),
                          ),
                        ),
                        const SizedBox(height: 26),
                        SizedBox(
                          width: 220,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: LinearProgressIndicator(
                              value: shown,
                              minHeight: 7,
                              backgroundColor:
                                  Colors.white.withValues(alpha: 0.12),
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(accent),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '$pct%',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: accent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A subtle field of drifting Aluta glyphs — music notes, hearts, chat bubbles,
/// flowers and sparkles — that float upward, sway, twinkle and slowly rotate
/// behind the splash. Kept at low opacity so it reads as atmosphere, not noise.
class _SplashDecor extends StatefulWidget {
  const _SplashDecor({required this.reveal, required this.accent});
  final Animation<double> reveal;
  final Color accent;

  @override
  State<_SplashDecor> createState() => _SplashDecorState();
}

class _SplashDecorState extends State<_SplashDecor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(seconds: 16))
    ..repeat();
  late final List<_Glyph> _glyphs;

  static const _icons = <IconData>[
    Icons.music_note_rounded,
    Icons.favorite_rounded,
    Icons.chat_bubble_rounded,
    Icons.local_florist_rounded,
    Icons.auto_awesome_rounded,
    Icons.queue_music_rounded,
    Icons.favorite_border_rounded,
    Icons.chat_bubble_outline_rounded,
    Icons.spa_rounded,
    Icons.music_note,
  ];

  @override
  void initState() {
    super.initState();
    final rnd = math.Random(7);
    final palette = <Color>[
      widget.accent,
      const Color(0xFFFF8FB1), // soft pink
      const Color(0xFFB39DDB), // lavender
      const Color(0xFF80CBC4), // teal
      const Color(0xFFFFD08A), // warm amber
    ];
    _glyphs = List.generate(24, (i) {
      return _Glyph(
        icon: _icons[rnd.nextInt(_icons.length)],
        color: palette[rnd.nextInt(palette.length)],
        x: rnd.nextDouble(),
        size: 12 + rnd.nextDouble() * 16,
        speed: 0.45 + rnd.nextDouble() * 0.9,
        phase: rnd.nextDouble(),
        sway: 0.015 + rnd.nextDouble() * 0.05,
        swayPhase: rnd.nextDouble() * math.pi * 2,
        rot: (rnd.nextDouble() - 0.5) * 1.0,
        baseAlpha: 0.09 + rnd.nextDouble() * 0.13,
      );
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_c, widget.reveal]),
      builder: (context, _) {
        final rev = widget.reveal.value;
        return LayoutBuilder(
          builder: (ctx, cons) {
            final w = cons.maxWidth;
            final h = cons.maxHeight;
            return Stack(
              children: [for (final g in _glyphs) _tile(g, w, h, rev)],
            );
          },
        );
      },
    );
  }

  Widget _tile(_Glyph g, double w, double h, double rev) {
    final t = (_c.value * g.speed + g.phase) % 1.0;
    final y = (1.0 - t) * (h + 80) - 40; // float upward, loop
    final x = (g.x + math.sin(_c.value * math.pi * 2 + g.swayPhase) * g.sway) * w;
    final edge = (t < 0.12
            ? t / 0.12
            : (t > 0.88 ? (1 - t) / 0.12 : 1.0))
        .clamp(0.0, 1.0);
    final twinkle =
        0.6 + 0.4 * math.sin(_c.value * math.pi * 3 + g.phase * math.pi * 2);
    final alpha = (g.baseAlpha * edge * twinkle * rev).clamp(0.0, 1.0);
    return Positioned(
      left: x,
      top: y,
      child: Opacity(
        opacity: alpha,
        child: Transform.rotate(
          angle: (_c.value * g.rot + g.phase) * math.pi * 2,
          child: Icon(g.icon, size: g.size, color: g.color),
        ),
      ),
    );
  }
}

class _Glyph {
  const _Glyph({
    required this.icon,
    required this.color,
    required this.x,
    required this.size,
    required this.speed,
    required this.phase,
    required this.sway,
    required this.swayPhase,
    required this.rot,
    required this.baseAlpha,
  });
  final IconData icon;
  final Color color;
  final double x;
  final double size;
  final double speed;
  final double phase;
  final double sway;
  final double swayPhase;
  final double rot;
  final double baseAlpha;
}
