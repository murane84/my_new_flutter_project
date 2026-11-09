import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_prefs.dart';

/// Quiet hours: between [from] and [to] (local time), music and Our Space
/// notifications — Listen Together invites, tune-in asks, "they're playing
/// now", moments, dedications, heartbeats — arrive silently in the shade
/// instead of buzzing. Calls, messages and @-mentions still ring.
/// Off by default; synced with the account like the other toggles.
class QuietHours {
  QuietHours._();
  static final QuietHours instance = QuietHours._();

  static const kOn = 'quiet_hours_on';
  static const kFrom = 'quiet_from_min';
  static const kTo = 'quiet_to_min';

  final ValueNotifier<bool> on = ValueNotifier<bool>(false);

  /// Minutes after midnight.
  final ValueNotifier<int> from = ValueNotifier<int>(22 * 60);
  final ValueNotifier<int> to = ValueNotifier<int>(7 * 60);

  Future<void>? _loading;
  Future<void> load() {
    if (_loading == null) AccountPrefs.onRestore(_doLoad);
    return _loading ??= _doLoad();
  }

  Future<void> _doLoad() async {
    try {
      final p = await SharedPreferences.getInstance();
      on.value = p.getBool(kOn) ?? false;
      from.value = p.getInt(kFrom) ?? 22 * 60;
      to.value = p.getInt(kTo) ?? 7 * 60;
    } catch (_) {}
  }

  Future<void> setOn(bool v) async {
    on.value = v;
    await _save((p) => p.setBool(kOn, v));
  }

  Future<void> setFrom(int m) async {
    from.value = m;
    await _save((p) => p.setInt(kFrom, m));
  }

  Future<void> setTo(int m) async {
    to.value = m;
    await _save((p) => p.setInt(kTo, m));
  }

  Future<void> _save(Future<bool> Function(SharedPreferences p) w) async {
    try {
      await w(await SharedPreferences.getInstance());
    } catch (_) {}
    AccountPrefs.touch();
  }

  /// Is it quiet right now? Reads storage fresh, so the background push
  /// handler (its own isolate) sees the latest setting too.
  static Future<bool> isNow([DateTime? at]) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.reload();
      if (!(p.getBool(kOn) ?? false)) return false;
      final f = p.getInt(kFrom) ?? 22 * 60;
      final t = p.getInt(kTo) ?? 7 * 60;
      final now = at ?? DateTime.now();
      final m = now.hour * 60 + now.minute;
      if (f == t) return false;
      // 22:00 → 07:00 wraps past midnight.
      return f < t ? (m >= f && m < t) : (m >= f || m < t);
    } catch (_) {
      return false;
    }
  }
}
