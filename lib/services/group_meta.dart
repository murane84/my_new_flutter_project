import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_prefs.dart';

/// Small per-GROUP facts the Circle list shows on a group's row:
///  • muted groups (no notifications; a calm row) — follows the account;
///  • this week's jam DJ (worked out in the open group chat, remembered here
///    so the list can show "👑 Lorraine" without loading the messages).
class GroupMeta extends ChangeNotifier {
  GroupMeta._() {
    _load();
    AccountPrefs.onRestore(_load);
  }
  static final GroupMeta instance = GroupMeta._();

  static const kMuted = 'muted_groups_v1';
  static const kDj = 'group_dj_v1';
  // Who (by id) holds the crowns: {cid: {"w": weekDjId, "d": todayDjId,
  // "day": "yyyy-mm-dd", "at": msWorkedOut}} — so Group info can badge the
  // member, and stale crowns expire on their own.
  static const kDjIds = 'group_dj_ids_v1';

  final Set<int> _muted = <int>{};
  final Map<int, String> _dj = <int, String>{};
  final Map<int, Map<String, dynamic>> _djIds = <int, Map<String, dynamic>>{};

  bool isMuted(int cid) => _muted.contains(cid);
  String? djOf(int cid) => _dj[cid];

  static String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month}-${n.day}';
  }

  /// This week's jam DJ (most winners played in 7 days), by user id — null
  /// when nobody, or when it was last worked out over a week ago.
  int? djWeekIdOf(int cid) {
    final m = _djIds[cid];
    final at = (m?['at'] as num?)?.toInt() ?? 0;
    if (DateTime.now().millisecondsSinceEpoch - at >
        const Duration(days: 7).inMilliseconds) {
      return null;
    }
    return (m?['w'] as num?)?.toInt();
  }

  /// Today's jam DJ (most winners played since midnight) — only today.
  int? djDayIdOf(int cid) {
    final m = _djIds[cid];
    if (m == null || m['day'] != _today()) return null;
    return (m['d'] as num?)?.toInt();
  }

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _muted
        ..clear()
        ..addAll((p.getStringList(kMuted) ?? const [])
            .map(int.tryParse)
            .whereType<int>());
      final rawIds = p.getString(kDjIds);
      _djIds.clear();
      if (rawIds != null && rawIds.isNotEmpty) {
        final m = jsonDecode(rawIds);
        if (m is Map) {
          m.forEach((k, v) {
            final id = int.tryParse(k.toString());
            if (id != null && v is Map) {
              _djIds[id] = v.cast<String, dynamic>();
            }
          });
        }
      }
      final raw = p.getString(kDj);
      _dj.clear();
      if (raw != null && raw.isNotEmpty) {
        final m = jsonDecode(raw);
        if (m is Map) {
          m.forEach((k, v) {
            final id = int.tryParse(k.toString());
            if (id != null && v is String && v.isNotEmpty) _dj[id] = v;
          });
        }
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> toggleMute(int cid) async {
    if (!_muted.remove(cid)) _muted.add(cid);
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(kMuted, _muted.map((e) => '$e').toList());
      AccountPrefs.touch();
    } catch (_) {}
  }

  /// The open group chat found its DJ of the week (null = nobody yet).
  Future<void> setDj(int cid, String? name) async {
    final n = (name ?? '').trim();
    if ((_dj[cid] ?? '') == n) return;
    if (n.isEmpty) {
      _dj.remove(cid);
    } else {
      _dj[cid] = n;
    }
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          kDj, jsonEncode({for (final e in _dj.entries) '${e.key}': e.value}));
    } catch (_) {}
  }

  /// The open group chat worked out who holds the week's and today's crowns.
  Future<void> setDjIds(int cid, {int? week, int? day}) async {
    final next = <String, dynamic>{
      'w': ?week,
      'd': ?day,
      'day': _today(),
      'at': DateTime.now().millisecondsSinceEpoch,
    };
    final cur = _djIds[cid];
    if (cur != null &&
        cur['w'] == next['w'] &&
        cur['d'] == next['d'] &&
        cur['day'] == next['day'] &&
        // …and refreshed within the hour (keeps a long-reigning DJ's
        // week crown from expiring).
        (next['at'] as int) - ((cur['at'] as num?)?.toInt() ?? 0) <
            const Duration(hours: 1).inMilliseconds) {
      return;
    }
    _djIds[cid] = next;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(kDjIds,
          jsonEncode({for (final e in _djIds.entries) '${e.key}': e.value}));
    } catch (_) {}
  }

  /// For notification code (may run in a background isolate): read fresh.
  static Future<bool> isMutedStored(int cid) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.reload();
      return (p.getStringList(kMuted) ?? const []).contains('$cid');
    } catch (_) {
      return false;
    }
  }
}
