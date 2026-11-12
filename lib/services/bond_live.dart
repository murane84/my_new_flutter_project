import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Live bits of a bond that the chat knows and the chat HEADER shows (the
/// header lives in Home, the chat below it):
///  • "Here together" — both of you are in your chat right now;
///  • the day you planned to meet ("3 days till you meet 💞").
/// The planned day is remembered per friend, so the header can count down
/// before the chat has been opened this run.
class BondLive extends ChangeNotifier {
  BondLive._();
  static final BondLive instance = BondLive._();

  final Set<int> _together = {};
  final Map<int, DateTime> _dates = {};
  bool _loaded = false;

  bool togetherWith(int id) => _together.contains(id);

  DateTime? dateWith(int id) {
    _load();
    final d = _dates[id];
    if (d == null) return null;
    final today = DateTime.now();
    final t0 = DateTime(today.year, today.month, today.day);
    return d.isBefore(t0) ? null : d;
  }

  void setTogether(int id, bool on) {
    final changed = on ? _together.add(id) : _together.remove(id);
    if (changed) notifyListeners();
  }

  void setDate(int id, DateTime? d) {
    final day = d == null ? null : DateTime(d.year, d.month, d.day);
    if (_dates[id] == day) return;
    if (day == null) {
      _dates.remove(id);
    } else {
      _dates[id] = day;
    }
    notifyListeners();
    SharedPreferences.getInstance().then((p) => day == null
        ? p.remove('bond_date_$id')
        : p.setString('bond_date_$id', day.toIso8601String()));
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      var any = false;
      for (final k in p.getKeys()) {
        if (!k.startsWith('bond_date_')) continue;
        final id = int.tryParse(k.substring(10));
        final d = DateTime.tryParse(p.getString(k) ?? '');
        if (id != null && d != null && !_dates.containsKey(id)) {
          _dates[id] = d;
          any = true;
        }
      }
      if (any) notifyListeners();
    } catch (_) {}
  }

  /// "💞 3 days till you meet" / "💞 Tomorrow you meet" / "💞 Today you meet!"
  static String? countdownLine(DateTime? day) {
    if (day == null) return null;
    final now = DateTime.now();
    final n = day.difference(DateTime(now.year, now.month, now.day)).inDays;
    if (n < 0) return null;
    if (n == 0) return '💞 Today you meet!';
    if (n == 1) return '💞 Tomorrow you meet';
    return '💞 $n days till you meet';
  }
}
