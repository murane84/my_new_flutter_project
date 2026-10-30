import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the singing is in a song: when the voice comes in, when it stops,
/// and the instrumental breaks in between. Lyrics without hand timing use it
/// so the first line lands when the singer actually starts.
class VocalMap {
  const VocalMap(this.start, this.end, this.breaks);
  final Duration start;
  final Duration end;
  final List<(Duration, Duration)> breaks;

  Map<String, dynamic> toJson() => {
        's': start.inMilliseconds,
        'e': end.inMilliseconds,
        'b': [
          for (final b in breaks) [b.$1.inMilliseconds, b.$2.inMilliseconds]
        ],
      };

  static VocalMap? fromJson(Object? j) {
    if (j is! Map) return null;
    final s = (j['s'] as num?)?.toInt(), e = (j['e'] as num?)?.toInt();
    if (s == null || e == null || e <= s) return null;
    return VocalMap(
      Duration(milliseconds: s),
      Duration(milliseconds: e),
      [
        for (final b in (j['b'] as List? ?? const []))
          if (b is List && b.length == 2)
            (
              Duration(milliseconds: (b[0] as num).toInt()),
              Duration(milliseconds: (b[1] as num).toInt())
            ),
      ],
    );
  }

  /// From the device's per-100 ms loudness: [all0, voice0, all1, voice1, …].
  /// Singing = the voice band is a big share of the sound AND loud enough;
  /// it has to last 2 s to count (one stray note isn't the singer).
  static VocalMap? fromProfile(List<double> p) {
    final n = p.length ~/ 2;
    if (n < 200) return null; // < 20 s
    final all = List<double>.generate(n, (i) => p[2 * i]);
    final voice = List<double>.generate(n, (i) => p[2 * i + 1]);
    List<double> smooth(List<double> x, int w) {
      final out = List<double>.filled(x.length, 0);
      var acc = 0.0;
      for (var i = 0; i < x.length; i++) {
        acc += x[i];
        if (i >= w) acc -= x[i - w];
        out[i] = acc / (i + 1 < w ? i + 1 : w);
      }
      return out;
    }

    double median(List<double> xs) {
      if (xs.isEmpty) return 0;
      final s = [...xs]..sort();
      return s[s.length ~/ 2];
    }

    final ratio = [
      for (var i = 0; i < n; i++) voice[i] / (all[i] + 1e-6)
    ];
    final rs = smooth(ratio, 15);
    final vs = smooth(voice, 15);
    final vMed = median(vs);
    if (vMed <= 0) return null;
    final rMed = median([
      for (var i = 0; i < n; i++)
        if (vs[i] > 0.5 * vMed) rs[i]
    ]);
    if (rMed <= 0) return null;
    final singing = [
      for (var i = 0; i < n; i++) rs[i] >= 0.9 * rMed && vs[i] >= 0.6 * vMed
    ];
    // Smoothing lags ~0.75 s behind the sound; pull edges back by that.
    const lag = 7;
    int? start;
    var run = 0;
    for (var i = 0; i < n; i++) {
      run = singing[i] ? run + 1 : 0;
      if (run >= 20) {
        start = (i - run + 1 - lag).clamp(0, n - 1);
        break;
      }
    }
    if (start == null || start > n * 0.45) return null;
    int? end;
    run = 0;
    for (var i = n - 1; i >= 0; i--) {
      run = singing[i] ? run + 1 : 0;
      if (run >= 20) {
        end = (i + run - 1).clamp(0, n - 1);
        break;
      }
    }
    if (end == null || end <= start + 100) return null;
    final breaks = <(Duration, Duration)>[];
    var gap = 0;
    for (var i = start; i <= end; i++) {
      if (!singing[i]) {
        gap++;
      } else {
        if (gap >= 60) {
          breaks.add((
            Duration(milliseconds: (i - gap) * 100),
            Duration(milliseconds: (i - lag).clamp(i - gap, i) * 100)
          ));
        }
        gap = 0;
      }
    }
    return VocalMap(Duration(milliseconds: start * 100),
        Duration(milliseconds: end * 100 + 1500), breaks);
  }
}

/// Finds and remembers each song's VocalMap (Android; elsewhere it simply
/// isn't available and lyrics use the plain estimate).
class VocalMaps {
  VocalMaps._();
  static final VocalMaps instance = VocalMaps._();
  static const _ch = MethodChannel('aluta/downloads');
  static const _prefsKey = 'vocal_maps_v1';

  final Map<String, VocalMap?> _maps = {};
  final Map<String, Future<VocalMap?>> _running = {};
  bool _loaded = false;

  VocalMap? cached(String path) => _maps[path];
  bool known(String path) => _maps.containsKey(path);

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_prefsKey);
      if (raw == null) return;
      final m = jsonDecode(raw);
      if (m is Map) {
        m.forEach((k, v) => _maps[k.toString()] = VocalMap.fromJson(v));
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      // Keep it small: the most recent ~400 songs.
      final entries = _maps.entries.toList();
      final keep = entries.length > 400
          ? entries.sublist(entries.length - 400)
          : entries;
      await p.setString(_prefsKey,
          jsonEncode({for (final e in keep) e.key: e.value?.toJson()}));
    } catch (_) {}
  }

  /// The song's map, analysing it once if needed (a couple of seconds, in
  /// the background). Null when it can't be found (no voice detected, not
  /// Android, unreadable file).
  Future<VocalMap?> request(String path) async {
    await _load();
    if (_maps.containsKey(path)) return _maps[path];
    if (kIsWeb || !Platform.isAndroid) return null;
    return _running[path] ??= () async {
      VocalMap? map;
      try {
        final r = await _ch.invokeMethod<Object?>('vocalProfile', {'path': path});
        if (r is List) {
          map = VocalMap.fromProfile([for (final x in r) (x as num).toDouble()]);
        }
      } catch (_) {}
      _maps[path] = map;
      _running.remove(path);
      unawaited(_save());
      return map;
    }();
  }
}
