import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// When each partner last sent me a heartbeat ("thinking of you") — so their
/// chat header can say "💓 thought of you 5 min ago". On this device only;
/// written by the live socket and by the background push handler.
class HeartbeatLog extends ChangeNotifier {
  HeartbeatLog._();
  static final HeartbeatLog instance = HeartbeatLog._();

  static const _key = 'last_heartbeat_v1';
  final Map<int, DateTime> _at = {};

  /// The last heartbeat from [friendId] within [within], else null.
  DateTime? recent(int friendId,
      {Duration within = const Duration(hours: 24)}) {
    final t = _at[friendId];
    if (t == null || DateTime.now().difference(t) > within) return null;
    return t;
  }

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.reload();
      final m = jsonDecode(p.getString(_key) ?? '{}');
      if (m is Map) {
        _at.clear();
        m.forEach((k, v) {
          final id = int.tryParse('$k');
          final t = DateTime.tryParse('$v');
          if (id != null && t != null) _at[id] = t.toLocal();
        });
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Note a heartbeat from [friendId] (now, or the server's [atIso]).
  static Future<void> record(int friendId, [String? atIso]) async {
    final t = (atIso == null ? null : DateTime.tryParse(atIso))?.toLocal() ??
        DateTime.now();
    instance._at[friendId] = t;
    instance.notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.reload();
      final m = jsonDecode(p.getString(_key) ?? '{}');
      final map = m is Map ? Map<String, dynamic>.from(m) : <String, dynamic>{};
      map['$friendId'] = t.toUtc().toIso8601String();
      // Keep it small: drop anything older than a week.
      final cut = DateTime.now().subtract(const Duration(days: 7));
      map.removeWhere((_, v) {
        final d = DateTime.tryParse('$v');
        return d == null || d.isBefore(cut);
      });
      await p.setString(_key, jsonEncode(map));
    } catch (_) {}
  }
}
