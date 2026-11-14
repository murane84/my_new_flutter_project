import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../utils/prefs_now.dart';

/// My plan's amounts, as the server sent them on /plan (every section is
/// open; these are how much). Kept on the device so a call started offline
/// still knows its length. -1 = unlimited.
class PlanLimits {
  PlanLimits._();
  static final PlanLimits instance = PlanLimits._();

  static const _key = 'plan_limits_v1';
  static const unlimited = -1;

  Map<String, int> _limits = const {};
  String level = 'free';

  /// Bumped whenever the amounts change (perks like the Harmony font
  /// follow it).
  final ValueNotifier<int> changed = ValueNotifier<int>(0);

  /// A short line the call screens show ("1 minute left …"), or null.
  final ValueNotifier<String?> callNote = ValueNotifier<String?>(null);

  int of(String meter, int fallback) {
    restore();
    return _limits[meter] ?? fallback;
  }

  /// Minutes a call may run (≤0 = unlimited). Free is 10 until we know.
  int get callMinutes => of('call_minutes', 10);

  /// Largest file / video I can send (server max 200 MB).
  int get fileMb {
    final v = of('file_mb', 50);
    return (v <= 0 || v > 200) ? 200 : v;
  }

  int get fileBytes => fileMb * 1024 * 1024;

  /// "max 50 MB · Aluta Together sends bigger files" for too-large toasts.
  String get fileNote => nextLevelName.isEmpty
      ? 'max $fileMb MB'
      : 'max $fileMb MB · $nextLevelName sends bigger files';

  String get nextLevelName => switch (level) {
        'free' => 'Aluta Together',
        'together' => 'Together Plus',
        _ => '',
      };

  void restore() {
    if (_limits.isNotEmpty) return;
    try {
      final raw = prefsNow?.getString(_key);
      if (raw == null) return;
      final d = jsonDecode(raw);
      if (d is Map) _apply(d.cast<String, dynamic>());
    } catch (_) {}
  }

  /// From GET /plan.
  void update(Map<String, dynamic> plan) {
    final l = plan['limits'];
    if (l is! Map) return;
    _apply({'level': plan['level'], 'limits': l});
    try {
      prefsNow?.setString(_key, jsonEncode({'level': level, 'limits': _limits}));
    } catch (_) {}
  }

  void _apply(Map<String, dynamic> d) {
    level = (d['level'] ?? 'free').toString();
    final l = d['limits'];
    if (l is Map) {
      _limits = {
        for (final e in l.entries)
          if (e.value is num) e.key.toString(): (e.value as num).toInt()
      };
    }
    changed.value++;
  }

  // ── Call length ──────────────────────────────────────────────────────────
  // One timer per call: a heads-up a minute before, then [end] runs. For a
  // 1:1 call the caller's plan sets the length (the caller starts it); in a
  // group call each person's own plan sets how long they stay.
  Timer? _warn, _stop;

  void startCallClock(DateTime since, VoidCallback end) {
    stopCallClock();
    callNote.value = null;
    final mins = callMinutes;
    if (mins <= 0) return;
    final total = Duration(minutes: mins);
    final gone = DateTime.now().difference(since);
    final left = total - gone;
    if (left <= Duration.zero) {
      end();
      return;
    }
    final next = nextLevelName;
    final warnIn = left - const Duration(minutes: 1);
    if (warnIn > Duration.zero) {
      _warn = Timer(warnIn, () {
        callNote.value = '1 minute left — your plan’s calls last '
            '$mins min${next.isEmpty ? '' : '. $next gives longer calls'}';
      });
    }
    _stop = Timer(left, () {
      callNote.value = 'Call ended — your plan’s calls last $mins min'
          '${next.isEmpty ? '' : '. $next gives longer calls'}';
      end();
    });
  }

  void stopCallClock() {
    _warn?.cancel();
    _stop?.cancel();
    _warn = _stop = null;
    if (callNote.value != null && callNote.value!.startsWith('1 minute')) {
      callNote.value = null;
    }
  }
}
