import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../screens/token_helper.dart';
import '../utils/app_config.dart';

/// How good this device's internet is for Listen Together right now.
enum NetGrade { good, fair, weak, offline }

class NetVerdict {
  const NetVerdict(this.grade, {this.rttMs, this.kbps, this.why});
  final NetGrade grade;
  final int? rttMs;
  final int? kbps;

  /// Plain words for a weak / offline result ("slow upload", "unstable").
  final String? why;

  bool get ok => grade == NetGrade.good || grade == NetGrade.fair;
}

/// A ~2 s check of the real path to Aluta's server before hosting or joining
/// a Listen Together session: three tiny round-trips, then one timed transfer
/// in the direction that matters — UP for a host (they stream the song), DOWN
/// for a guest. Below the bar we don't connect at all, so nobody lands in a
/// stuttering session. A passing result is reused for a minute.
class NetCheck {
  NetCheck._();

  static const int maxRttMs = 600;
  static const int hostMinKbps = 500; // song 128–256 kbit/s + headroom
  static const int guestMinKbps = 400;
  static const int _transferBytes = 128 * 1024;

  static final Map<bool, (DateTime, NetVerdict)> _cache = {};
  static Future<NetVerdict>? _running;
  static Uint8List? _upBody;

  /// The latest grade from any check (shown to friends as a signal dot).
  static final ValueNotifier<NetGrade?> lastGrade = ValueNotifier(null);

  /// The last fresh verdict, if one was taken in the past minute.
  static NetVerdict? cached({required bool host}) {
    final c = _cache[host];
    if (c == null) return null;
    if (DateTime.now().difference(c.$1) > const Duration(seconds: 60)) {
      return null;
    }
    return c.$2;
  }

  static Future<NetVerdict> listenTogether(
      {required bool host, bool force = false}) {
    if (!force) {
      final c = cached(host: host);
      if (c != null && c.ok) return Future.value(c);
    }
    return _running ??= _measure(host).whenComplete(() => _running = null);
  }

  static Future<NetVerdict> _measure(bool host) async {
    NetVerdict v;
    try {
      v = await _run(host);
    } catch (_) {
      v = const NetVerdict(NetGrade.offline, why: 'no internet connection');
    }
    _cache[host] = (DateTime.now(), v);
    lastGrade.value = v.grade;
    _lastAny = DateTime.now();
    unawaited(_report(v.grade));
    return v;
  }

  static DateTime? _lastAny;

  /// Tell the server our grade so friends see the signal dot. Fire-and-forget.
  static Future<void> _report(NetGrade g) async {
    if (g == NetGrade.offline) return; // can't reach it anyway
    try {
      final token = await getToken();
      if (token == null) return;
      final base = await AppConfig.baseUrl;
      await http
          .post(Uri.parse('$base/webrtc/net-grade'),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: '{"grade":"${g.name}"}')
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  /// On app start / resume: keep the signal dot fresh with a quiet guest
  /// check at most every 30 min (128 KB down).
  static void refreshInBackground() {
    final last = _lastAny;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 30)) {
      return;
    }
    _lastAny = DateTime.now();
    unawaited(listenTogether(host: false, force: true));
  }

  static Future<NetVerdict> _run(bool host) async {
    final token = await getToken();
    final base = await AppConfig.baseUrl;
    final headers = {
      if (token != null) 'Authorization': 'Bearer $token',
      'Cache-Control': 'no-store',
    };
    final client = http.Client();
    try {
      // 1) Round-trips.
      final rtts = <int>[];
      var failed = 0;
      for (var i = 0; i < 3; i++) {
        final sw = Stopwatch()..start();
        try {
          final r = await client
              .get(Uri.parse('$base/webrtc/probe?n=0&i=$i'), headers: headers)
              .timeout(const Duration(seconds: 3));
          if (r.statusCode >= 400) throw Exception('http ${r.statusCode}');
          rtts.add(sw.elapsedMilliseconds);
        } on TimeoutException {
          failed++;
        }
      }
      if (rtts.isEmpty) {
        return const NetVerdict(NetGrade.weak,
            why: 'the connection keeps timing out');
      }
      rtts.sort();
      final rtt = rtts[rtts.length ~/ 2];
      if (failed > 1) {
        return NetVerdict(NetGrade.weak,
            rttMs: rtt, why: 'the connection is unstable');
      }
      if (rtt > maxRttMs) {
        return NetVerdict(NetGrade.weak,
            rttMs: rtt, why: 'the connection is very slow to respond');
      }

      // 2) Timed transfer. Give up once it's clearly below half the bar.
      final need = host ? hostMinKbps : guestMinKbps;
      final cap = Duration(
          milliseconds: (_transferBytes * 8 / (need / 2)).round() + rtt);
      final sw = Stopwatch()..start();
      try {
        if (host) {
          final body = _upBody ??= _randomBytes(_transferBytes);
          final r = await client
              .post(Uri.parse('$base/webrtc/probe'),
                  headers: {
                    ...headers,
                    'Content-Type': 'application/octet-stream',
                  },
                  body: body)
              .timeout(cap);
          if (r.statusCode >= 400) throw Exception('http ${r.statusCode}');
        } else {
          final r = await client
              .get(Uri.parse('$base/webrtc/probe?n=$_transferBytes'),
                  headers: headers)
              .timeout(cap);
          if (r.statusCode >= 400) throw Exception('http ${r.statusCode}');
        }
      } on TimeoutException {
        return NetVerdict(NetGrade.weak,
            rttMs: rtt,
            why: host ? 'your upload is too slow' : 'your download is too slow');
      }
      final ms = max(1, sw.elapsedMilliseconds);
      final kbps = (_transferBytes * 8 / ms).round(); // bits per ms = kbit/s
      if (kbps < need) {
        return NetVerdict(NetGrade.weak,
            rttMs: rtt,
            kbps: kbps,
            why: host ? 'your upload is too slow' : 'your download is too slow');
      }
      final good = rtt <= maxRttMs ~/ 2 && kbps >= need * 2;
      return NetVerdict(good ? NetGrade.good : NetGrade.fair,
          rttMs: rtt, kbps: kbps);
    } finally {
      client.close();
    }
  }

  static Uint8List _randomBytes(int n) {
    final r = Random();
    final b = Uint8List(n);
    for (var i = 0; i < n; i++) {
      b[i] = r.nextInt(256);
    }
    return b;
  }
}
