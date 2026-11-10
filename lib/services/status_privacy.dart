import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_prefs.dart';

/// Who can see my status: 'circle' (every friend — default) or 'bonds'
/// (only my accepted Our Space partners), plus friends hidden from it either
/// way. Synced with the account; the server applies it to the feed, the
/// status media and the live "posted" nudge (privacy.py).
class StatusPrivacy {
  StatusPrivacy._();
  static final StatusPrivacy instance = StatusPrivacy._();

  static const kMode = 'status_audience_mode';
  static const kHidden = 'status_hidden_ids';

  final ValueNotifier<String> mode = ValueNotifier<String>('circle');
  final ValueNotifier<Set<int>> hidden = ValueNotifier<Set<int>>({});

  Future<void>? _loading;
  Future<void> load() {
    if (_loading == null) AccountPrefs.onRestore(_doLoad);
    return _loading ??= _doLoad();
  }

  Future<void> _doLoad() async {
    try {
      final p = await SharedPreferences.getInstance();
      final m = p.getString(kMode);
      mode.value = (m == 'bonds') ? 'bonds' : 'circle';
      hidden.value = (p.getStringList(kHidden) ?? const [])
          .map(int.tryParse)
          .whereType<int>()
          .toSet();
    } catch (_) {}
  }

  Future<void> setMode(String m) async {
    if (m != 'circle' && m != 'bonds') return;
    mode.value = m;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(kMode, m);
    } catch (_) {}
    AccountPrefs.touch();
  }

  Future<void> setHidden(Set<int> ids) async {
    hidden.value = Set<int>.unmodifiable(ids);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(kHidden, ids.map((e) => '$e').toList());
    } catch (_) {}
    AccountPrefs.touch();
  }

  /// A one-line summary ("My circle", "Bonds only", "My circle · 2 hidden").
  String get summary {
    final base = mode.value == 'bonds' ? 'Bonds only' : 'My circle';
    final n = hidden.value.length;
    return n == 0 ? base : '$base · $n hidden';
  }
}
