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

  final Set<int> _muted = <int>{};
  final Map<int, String> _dj = <int, String>{};

  bool isMuted(int cid) => _muted.contains(cid);
  String? djOf(int cid) => _dj[cid];

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _muted
        ..clear()
        ..addAll((p.getStringList(kMuted) ?? const [])
            .map(int.tryParse)
            .whereType<int>());
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
