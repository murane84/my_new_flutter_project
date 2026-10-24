import 'dart:async';

import 'package:flutter/foundation.dart';

import '../screens/api_service.dart';
import '../utils/time_utils.dart';

/// "Free to talk" · Busy · Driving · Sleeping — a one-tap status that ends
/// on its own (1 h; sleeping 8 h). Mine + my circle's, kept live by
/// `friend_status` socket events.
class QuickStatus extends ChangeNotifier {
  QuickStatus._();
  static final QuickStatus instance = QuickStatus._();

  static const List<String> kinds = ['free', 'busy', 'driving', 'sleeping'];

  static String emoji(String s) => switch (s) {
        'free' => '📞',
        'busy' => '⛔',
        'driving' => '🚗',
        'sleeping' => '😴',
        _ => '',
      };

  static String label(String s) => switch (s) {
        'free' => 'Free to talk',
        'busy' => 'Busy',
        'driving' => 'Driving',
        'sleeping' => 'Sleeping',
        _ => '',
      };

  final Map<int, ({String status, DateTime until})> _friends = {};
  ({String status, DateTime until})? _mine;
  Timer? _tick;

  ({String status, DateTime until})? get mine =>
      (_mine != null && _mine!.until.isAfter(DateTime.now())) ? _mine : null;

  /// A friend's live status kind, or null (none / expired).
  String? statusOf(int id) {
    final s = _friends[id];
    if (s == null || !s.until.isAfter(DateTime.now())) return null;
    return s.status;
  }

  /// "📞 Free to talk" or '' — ready to drop into a subtitle.
  String lineFor(int id) {
    final s = statusOf(id);
    return s == null ? '' : '${emoji(s)} ${label(s)}';
  }

  ({String status, DateTime until})? _parse(Map m) {
    final st = (m['status'] ?? '').toString();
    final exp = (m['expires_at'] ?? '').toString();
    if (st.isEmpty || exp.isEmpty) return null;
    return (status: st, until: parseServerTime(exp));
  }

  Future<void> load() async {
    final friends = await ApiService().quickStatuses();
    final mine = await ApiService().quickStatuses(mine: true);
    _friends.clear();
    for (final m in friends) {
      final id = (m['user_id'] as num?)?.toInt();
      final p = _parse(m);
      if (id != null && p != null) _friends[id] = p;
    }
    _mine = mine.isEmpty ? null : _parse(mine.first);
    _armTick();
    notifyListeners();
  }

  void applyEvent(Map<String, dynamic> d) {
    final id = (d['user_id'] as num?)?.toInt();
    if (id == null) return;
    final p = _parse(d);
    if (p == null) {
      _friends.remove(id);
    } else {
      _friends[id] = p;
    }
    _armTick();
    notifyListeners();
  }

  /// Set (or clear with null). Returns false if it didn't save.
  Future<bool> setMine(String? status) async {
    final res = await ApiService().setQuickStatus(status);
    if (res == null) return false;
    _mine = res.isEmpty ? null : _parse(res);
    _armTick();
    notifyListeners();
    return true;
  }

  // Repaint once a minute while any status is up, so expired ones vanish.
  void _armTick() {
    final any = _mine != null || _friends.isNotEmpty;
    if (!any) {
      _tick?.cancel();
      _tick = null;
      return;
    }
    _tick ??= Timer.periodic(const Duration(minutes: 1), (_) {
      final now = DateTime.now();
      _friends.removeWhere((_, v) => !v.until.isAfter(now));
      if (_mine != null && !_mine!.until.isAfter(now)) _mine = null;
      if (_mine == null && _friends.isEmpty) {
        _tick?.cancel();
        _tick = null;
      }
      notifyListeners();
    });
  }
}
