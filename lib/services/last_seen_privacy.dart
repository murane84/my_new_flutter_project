import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_prefs.dart';

/// Who can see my "last seen": 'circle' (every friend — default), 'bonds'
/// (only my Our Space partners) or 'nobody'. Synced with the account; the
/// server applies it both ways (privacy.py): hide yours and you stop seeing
/// theirs. A hidden last seen simply isn't shown — nothing says "hidden".
class LastSeenPrivacy {
  LastSeenPrivacy._();
  static final LastSeenPrivacy instance = LastSeenPrivacy._();

  static const key = 'last_seen_mode';
  static const modes = ['circle', 'bonds', 'nobody'];

  final ValueNotifier<String> mode = ValueNotifier<String>('circle');

  Future<void>? _loading;
  Future<void> load() {
    if (_loading == null) AccountPrefs.onRestore(_doLoad);
    return _loading ??= _doLoad();
  }

  Future<void> _doLoad() async {
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getString(key);
      mode.value = modes.contains(v) ? v! : 'circle';
    } catch (_) {}
  }

  Future<void> set(String m) async {
    if (!modes.contains(m)) return;
    mode.value = m;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(key, m);
    } catch (_) {}
    AccountPrefs.touch();
  }
}
