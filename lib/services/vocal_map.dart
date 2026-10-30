import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'vocal_decode.dart';

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

  /// The same per-100 ms profile as the Android / Windows code, from raw mono
  /// samples (used on the web, where the browser decodes the song). Down-
  /// samples to ~11 kHz first — the voice band (300–3400 Hz) fits well below.
  static List<double> profileFromPcm(Float32List x, int sampleRate) {
    final f = (sampleRate ~/ 11025).clamp(1, 8);
    final sr = sampleRate / f;
    final hp = _Biquad.highPass(300, sr), lp = _Biquad.lowPass(3400, sr);
    final frame = (sr / 10).round();
    final out = <double>[];
    var sumAll = 0.0, sumVoice = 0.0, n = 0;
    final limit = x.length - f;
    for (var i = 0; i <= limit; i += f) {
      var m = 0.0;
      for (var k = 0; k < f; k++) {
        m += x[i + k];
      }
      m /= f;
      final v = lp.run(hp.run(m));
      sumAll += m * m;
      sumVoice += v * v;
      if (++n >= frame) {
        out
          ..add(math.sqrt(sumAll / n))
          ..add(math.sqrt(sumVoice / n));
        sumAll = 0;
        sumVoice = 0;
        n = 0;
      }
    }
    return out;
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
      // Below the median on purpose: half of the sung frames sit under it, and
      // counting those as "no voice" would invent breaks mid-verse.
      for (var i = 0; i < n; i++) rs[i] >= 0.75 * rMed && vs[i] >= 0.5 * vMed
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

class _Biquad {
  _Biquad(this.b0, this.b1, this.b2, this.a1, this.a2);
  final double b0, b1, b2, a1, a2;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  double run(double x) {
    final y = b0 * x + b1 * _x1 + b2 * _x2 - a1 * _y1 - a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }

  // RBJ cookbook, Q = 0.707 — same filters as VocalProfile.kt.
  static _Biquad highPass(double fc, double sr) {
    final w = 2 * math.pi * fc / sr, a = math.sin(w) / (2 * 0.707);
    final c = math.cos(w), a0 = 1 + a;
    return _Biquad((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0,
        -2 * c / a0, (1 - a) / a0);
  }

  static _Biquad lowPass(double fc, double sr) {
    final w = 2 * math.pi * fc / sr, a = math.sin(w) / (2 * 0.707);
    final c = math.cos(w), a0 = 1 + a;
    return _Biquad((1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0,
        -2 * c / a0, (1 - a) / a0);
  }
}

/// Finds and remembers each song's VocalMap: Android and Windows decode the
/// file natively; the web decodes the loaded song's bytes in the browser.
class VocalMaps {
  VocalMaps._();
  static final VocalMaps instance = VocalMaps._();
  static const _ch = MethodChannel('aluta/downloads');
  static const _winCh = MethodChannel('aluta/vocal');
  static const _prefsKey = 'vocal_maps_v1';
  // Written just before a native analysis and cleared after: if the app dies
  // in the middle, that song is marked "no map" on the next start and never
  // analysed again — one bad file can't crash Aluta on every launch.
  static const _inflightKey = 'vocal_inflight_v1';
  static const _maxBytes = 40 * 1024 * 1024;

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
      if (raw != null) {
        final m = jsonDecode(raw);
        if (m is Map) {
          m.forEach((k, v) => _maps[k.toString()] = VocalMap.fromJson(v));
        }
      }
      final crashed = p.getString(_inflightKey);
      if (crashed != null && crashed.isNotEmpty) {
        _maps[crashed] = null;
        await p.remove(_inflightKey);
        unawaited(_save());
      }
    } catch (_) {}
  }

  Future<void> _mark(String? path) async {
    try {
      final p = await SharedPreferences.getInstance();
      if (path == null) {
        await p.remove(_inflightKey);
      } else {
        await p.setString(_inflightKey, path);
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
    if (kIsWeb || !(Platform.isAndroid || Platform.isWindows)) return null;
    return _running[path] ??= () async {
      VocalMap? map;
      try {
        // Huge files (long mixes, videos) aren't worth decoding.
        try {
          final f = File(path);
          if (await f.exists() && await f.length() > _maxBytes) {
            _maps[path] = null;
            _running.remove(path);
            unawaited(_save());
            return null;
          }
        } catch (_) {}
        await _mark(path);
        final r = await (Platform.isWindows ? _winCh : _ch)
            .invokeMethod<Object?>('vocalProfile', {'path': path})
            .timeout(const Duration(seconds: 25));
        if (r is List) {
          map = VocalMap.fromProfile([for (final x in r) (x as num).toDouble()]);
        }
      } catch (_) {}
      await _mark(null);
      _maps[path] = map;
      _running.remove(path);
      unawaited(_save());
      return map;
    }();
  }

  /// Web: the song is only in memory — decode [bytes] in the browser.
  /// [key] identifies the song (e.g. 'web:<title>').
  Future<VocalMap?> requestBytes(String key, Uint8List bytes) async {
    await _load();
    if (_maps.containsKey(key)) return _maps[key];
    if (bytes.isEmpty || bytes.length > _maxBytes) return null;
    return _running[key] ??= () async {
      VocalMap? map;
      try {
        final pcm = await decodePcm(bytes);
        if (pcm != null) {
          map = VocalMap.fromProfile(profileFromPcm(pcm.$1, pcm.$2));
        }
      } catch (_) {}
      _maps[key] = map;
      _running.remove(key);
      unawaited(_save());
      return map;
    }();
  }
}
