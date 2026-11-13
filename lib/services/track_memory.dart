import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Small per-file memories for the playlist:
/// * where a LONG track (DJ mix, set, a long recording someone keeps) was
///   stopped, so it picks up there next time;
/// * files that can't be played, so they're marked and skipped instead of
///   stalling the queue (retried after the next library scan).
class TrackMemory {
  TrackMemory._();
  static final TrackMemory instance = TrackMemory._();

  static const _kPos = 'track_resume_pos_v1';
  static const _kBroken = 'track_broken_v1';

  /// Long enough to be worth resuming.
  static const longTrack = Duration(minutes: 15);

  final Map<String, int> _pos = {};
  final Set<String> _broken = {};
  bool _loaded = false;
  SharedPreferences? _p;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      _p = await SharedPreferences.getInstance();
      final raw = _p!.getString(_kPos);
      if (raw != null) {
        (jsonDecode(raw) as Map).forEach((k, v) {
          if (k is String && v is int) _pos[k] = v;
        });
      }
      _broken.addAll(_p!.getStringList(_kBroken) ?? const []);
    } catch (_) {}
  }

  // ── resume ────────────────────────────────────────────────────────────────
  /// Where to pick [path] up, or null (short song / nothing saved / at the
  /// very start or end).
  Duration? resumeAt(String path, Duration? length) {
    final ms = _pos[path];
    if (ms == null || length == null || length < longTrack) return null;
    if (ms < 30000 || ms > length.inMilliseconds - 60000) return null;
    return Duration(milliseconds: ms);
  }

  void savePosition(String path, Duration pos, Duration? length) {
    if (length == null || length < longTrack) return;
    _pos.remove(path);
    _pos[path] = pos.inMilliseconds; // newest last
    while (_pos.length > 60) {
      _pos.remove(_pos.keys.first);
    }
    _p?.setString(_kPos, jsonEncode(_pos));
  }

  void clearPosition(String path) {
    if (_pos.remove(path) != null) _p?.setString(_kPos, jsonEncode(_pos));
  }

  // ── broken files ──────────────────────────────────────────────────────────
  bool isBroken(String path) => _broken.contains(path);

  void markBroken(String path) {
    if (_broken.add(path)) _p?.setStringList(_kBroken, _broken.toList());
  }

  void markPlayable(String path) {
    if (_broken.remove(path)) _p?.setStringList(_kBroken, _broken.toList());
  }

  /// After a library scan: give every marked file another chance.
  void forgiveAll() {
    if (_broken.isEmpty) return;
    _broken.clear();
    _p?.setStringList(_kBroken, const []);
  }
}
