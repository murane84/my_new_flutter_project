import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/song_library.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'home_page.dart';
import 'api_service.dart';
import '../services/connected_contacts_service.dart';

/// The post-unlock warm-up gate.
///
/// After the fingerprint unlock (or a straight logged-in launch) the old flow
/// dropped the user onto Home *instantly*, while friends, conversations,
/// statuses, the device music library and the contact match were all still
/// loading in the background. On aggressive OEMs (MIUI and friends) that reads
/// as the app misbehaving — half-empty lists, a frozen first tap, sometimes a
/// kill. This screen holds a calm, branded "Loading Data" moment with a real
/// percentage and blocks until the important pieces are warm, so Home paints
/// complete on first frame.
///
/// It can never trap the user: a hard ceiling (longer on a fresh install where
/// there is genuinely more to fetch, short on a warm relaunch) reveals Home no
/// matter what, and every task is individually time-boxed and failure-soft.
class PreloadScreen extends StatefulWidget {
  static const String routeName = '/preload';
  const PreloadScreen({super.key});

  @override
  State<PreloadScreen> createState() => _PreloadScreenState();
}

class _PreloadScreenState extends State<PreloadScreen> {
  // Task weights (sum = 1.0). Progress advances as each milestone completes.
  static const double _wInit = 0.05;
  static const double _wProfile = 0.15;
  static const double _wCircle = 0.30; // friends + conversations + spaces
  static const double _wStories = 0.15;
  static const double _wContacts = 0.15;
  static const double _wMusic = 0.15;
  static const double _wFinal = 0.05;

  double _target = 0; // where the bar should be as tasks complete
  double _shown = 0; // eased, displayed value
  String _stage = 'Waking up…';
  Timer? _ticker;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 40), (_) {
      if (!mounted) return;
      final diff = _target - _shown;
      if (diff.abs() < 0.0015) return;
      setState(() => _shown += diff * 0.18);
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
    _bump(_wInit, 'Waking up…');

    // Skip the network tasks entirely when offline so an offline launch stays
    // snappy (the device reads below still run). Online, each network task is
    // individually time-boxed and failure-soft.
    final online = await _isOnline();

    // Absolute LAST-RESORT ceiling — deliberately far beyond the heavy on-device
    // reads below, so in normal use Home is revealed on TRUE completion, never
    // mid-load. It only trips if something genuinely hangs, so the user is never
    // trapped. (This is what stops the old early open at ~80%.)
    final ceiling = Duration(seconds: firstRun ? 120 : 75);
    final ceilingTimer = Timer(ceiling, _finish);

    final api = ApiService();

    // Profile — also persists my_user_id, which the chat caches key on.
    final tProfile = () async {
      if (online) {
        try {
          await api.getUserData().timeout(const Duration(seconds: 15));
        } catch (_) {}
      }
      _bump(_wProfile, 'Loading your space…');
    }();

    // Your circle: friends, conversations and Our Spaces, warmed together.
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

    // Statuses feed.
    final tStories = () async {
      if (online) {
        try {
          await api.fetchStoriesFeed().timeout(const Duration(seconds: 15));
        } catch (_) {}
      }
      _bump(_wStories, 'Catching up on status…');
    }();

    // Contacts match (heavy device scan; asks permission once). Skipped on web.
    // Given a generous window so it TRULY finishes before Home opens rather than
    // being cut off to churn in the background (which stuttered MIUI devices).
    final tContacts = () async {
      if (!kIsWeb) {
        try {
          await ConnectedContactsService.instance
              .refresh()
              .timeout(const Duration(seconds: 60));
        } catch (_) {}
      }
      _bump(_wContacts, 'Finding your people…');
    }();

    // Device music library — the big "read the files" step. Let it fully
    // complete (huge libraries on slow phones take real time) so Home opens
    // with everything warm, instead of the scan grinding on after launch.
    final tMusic = () async {
      if (!kIsWeb) {
        try {
          await SongLibrary.songs().timeout(const Duration(seconds: 90));
        } catch (_) {}
      }
      _bump(_wMusic, 'Tuning your music…');
    }();

    // Home opens only when EVERY task has truly completed (or hit its own
    // generous timeout) — not on a short wall-clock ceiling.
    await Future.wait([tProfile, tCircle, tStories, tContacts, tMusic]);
    ceilingTimer.cancel();
    _bump(_wFinal, 'Almost there…');
    // Actually wait for the bar to fill to 100% before opening Home. On fast
    // platforms (Windows / web) every task finishes almost instantly, so the
    // eased bar hadn't caught up to the target — a fixed short delay used to
    // jump to Home at ~90%. Hold until the displayed value reaches full (with a
    // safety cap so a stalled tick can't trap us), then snap to an exact 100%
    // and let it show briefly.
    final capAt = DateTime.now().add(const Duration(milliseconds: 1600));
    while (mounted && _shown < 0.995 && DateTime.now().isBefore(capAt)) {
      await Future.delayed(const Duration(milliseconds: 40));
    }
    if (mounted) setState(() => _shown = 1.0);
    await Future.delayed(const Duration(milliseconds: 300));
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
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = _shown.clamp(0.0, 1.0);
    final pct = (shown * 100).round();
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.35),
                      blurRadius: 44,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: ClipOval(
                  child: Image.asset(
                    'assets/images/logo.png',
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      color: scheme.surfaceContainerHighest,
                      child: Icon(Icons.favorite_rounded,
                          color: scheme.primary, size: 40),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 30),
              Text(
                'Loading Data',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(
                  _stage,
                  key: ValueKey(_stage),
                  style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: 26),
              SizedBox(
                width: 220,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: shown,
                    minHeight: 8,
                    backgroundColor: scheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '$pct%',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
