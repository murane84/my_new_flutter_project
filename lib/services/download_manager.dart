import 'dart:async';
import 'dart:io';

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/token_helper.dart' show mediaAuthHeaders;
import 'notif_service.dart' show showDownloadProgress, finishDownloadNotif;

/// One file being fetched to disk.
class DownloadJob {
  DownloadJob(this.url, this.dest, this.name);
  final String url;
  final File dest;
  final String name; // shown in the progress notification
  int _lastNotifPct = -1;
  bool notify = true;
  double? progress; // 0..1, null while the size is unknown
  late final Future<DownloadResult> future;
}

/// How a download ended.
enum DownloadOutcome { ok, gone, failed }

class DownloadResult {
  const DownloadResult(this.outcome, [this.file]);
  final DownloadOutcome outcome;
  final File? file;
  bool get ok => outcome == DownloadOutcome.ok;
}

/// Keeps attachment downloads alive across navigation — the download twin of
/// UploadManager.
///
/// A big file (e.g. a 140 MB APK) used to be fetched from inside the ChatPage:
/// leaving the chat lost its progress, and coming back + tapping again started
/// a SECOND download from zero into the same `.part` file. This app-lifetime
/// singleton owns each transfer instead:
///  • one job per URL — tapping again (or reopening the chat) re-attaches to
///    the running job and its live progress;
///  • it RESUMES: bytes already in `<dest>.part` are kept and the rest is asked
///    for with an HTTP Range request (the attachments route supports 206), so a
///    dropped line, an app restart, or a failed attempt doesn't start over;
///  • retries with backoff on network errors;
///  • the phone sleeping doesn't stall it: while any job runs, Android holds
///    a partial CPU wake lock + a high-perf Wi-Fi lock (MainActivity
///    `holdAwake`), and an ongoing progress notification shows it continuing;
///  • unfinished jobs are remembered on disk and RESUME by themselves when the
///    app comes back to the foreground (or starts again after being killed).
class DownloadManager with WidgetsBindingObserver {
  DownloadManager._();
  static final DownloadManager instance = DownloadManager._();

  static const MethodChannel _ch = MethodChannel('aluta/downloads');
  static const String _pendingKey = 'pending_downloads_v1';
  bool _inited = false;

  /// Call once at startup (idempotent): resumes jobs left unfinished and
  /// re-checks whenever the app returns to the foreground.
  void init() {
    if (_inited || kIsWeb) return;
    _inited = true;
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {}
    unawaited(resumePending());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(resumePending());
  }

  /// Restart every remembered, not-yet-finished download (from its .part).
  Future<void> resumePending() async {
    final pending = await _readPending();
    for (final p in pending) {
      final url = (p['url'] ?? '').toString();
      final dest = (p['dest'] ?? '').toString();
      if (url.isEmpty || dest.isEmpty || _jobs.containsKey(url)) continue;
      final f = File(dest);
      if (await f.exists()) {
        await _forget(url);
        continue;
      }
      unawaited(fetch(url, f,
          headers: mediaAuthHeaders(url),
          expectedTotal: (p['size'] as num?)?.toInt() ?? 0,
          name: (p['name'] ?? 'File').toString()));
    }
  }

  final Map<String, DownloadJob> _jobs = {};

  /// Bumps on progress (≈1% steps) / start / finish so bubbles can re-render.
  final ValueNotifier<int> rev = ValueNotifier<int>(0);

  DownloadJob? job(String url) => _jobs[url];
  bool isBusy(String url) => _jobs.containsKey(url);

  /// Fetch [url] into [dest]. If a download for [url] is already running, the
  /// caller simply joins it. [onRetry] fires before each retry (for a toast).
  Future<DownloadResult> fetch(
    String url,
    File dest, {
    Map<String, String> headers = const {},
    int expectedTotal = 0,
    String name = 'File',
    bool notify = true, // shade progress notification (off for tiny media)
    void Function(int attempt)? onRetry,
  }) {
    final running = _jobs[url];
    if (running != null) return running.future;
    final job = DownloadJob(url, dest, name)..notify = notify;
    _jobs[url] = job;
    _holdAwake(true);
    if (notify) {
      unawaited(_remember(url, dest.path, expectedTotal, name));
      unawaited(showDownloadProgress(url, name, null));
    }
    job.future =
        _run(job, headers, expectedTotal, onRetry).then((r) async {
      if (notify) {
        if (r.outcome != DownloadOutcome.failed) await _forget(url);
        await finishDownloadNotif(url, name, r.ok);
      }
      return r;
    }).whenComplete(() {
      _jobs.remove(url);
      if (_jobs.isEmpty) _holdAwake(false);
      _bump();
    });
    _bump();
    return job.future;
  }

  void _holdAwake(bool on) {
    if (kIsWeb || !Platform.isAndroid) return;
    _ch.invokeMethod('holdAwake', {'on': on}).catchError((_) => null);
  }

  // ── Pending-job memory (survives the app being killed) ───────────────────
  Future<List<Map<String, dynamic>>> _readPending() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_pendingKey);
      if (raw == null || raw.isEmpty) return [];
      final l = jsonDecode(raw);
      if (l is! List) return [];
      return l.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writePending(List<Map<String, dynamic>> l) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_pendingKey, jsonEncode(l));
    } catch (_) {}
  }

  Future<void> _remember(String url, String dest, int size, String name) async {
    final l = await _readPending();
    l.removeWhere((m) => m['url'] == url);
    l.add({'url': url, 'dest': dest, 'size': size, 'name': name});
    await _writePending(l);
  }

  Future<void> _forget(String url) async {
    final l = await _readPending();
    final before = l.length;
    l.removeWhere((m) => m['url'] == url);
    if (l.length != before) await _writePending(l);
  }

  Future<DownloadResult> _run(DownloadJob job, Map<String, String> headers,
      int expectedTotal, void Function(int attempt)? onRetry) async {
    final part = File('${job.dest.path}.part');
    try {
      await part.parent.create(recursive: true);
    } catch (_) {}
    for (var attempt = 0; attempt < 6; attempt++) {
      if (attempt > 0) {
        onRetry?.call(attempt);
        await Future.delayed(Duration(seconds: (2 * attempt).clamp(2, 10)));
      }
      try {
        final status = await _streamOnce(job, part, headers, expectedTotal);
        if (status == 200) {
          try {
            if (await job.dest.exists()) await job.dest.delete();
          } catch (_) {}
          await part.rename(job.dest.path);
          return DownloadResult(DownloadOutcome.ok, job.dest);
        }
        if (status == 404 || status == 410) {
          try {
            if (await part.exists()) await part.delete();
          } catch (_) {}
          return const DownloadResult(DownloadOutcome.gone);
        }
        // Other HTTP errors: retry.
      } catch (_) {
        // Network drop: keep the .part and resume on the next attempt.
      }
    }
    return const DownloadResult(DownloadOutcome.failed);
  }

  /// One pass: resume from what's already in [part]. Returns 200 when the file
  /// is complete, else the HTTP status that stopped it.
  Future<int> _streamOnce(DownloadJob job, File part,
      Map<String, String> headers, int expectedTotal) async {
    var have = 0;
    try {
      if (await part.exists()) have = await part.length();
    } catch (_) {}
    if (expectedTotal > 0 && have >= expectedTotal) return 200;

    final client = http.Client();
    IOSink? sink;
    try {
      final req = http.Request('GET', Uri.parse(job.url))
        ..headers.addAll(headers);
      if (have > 0) req.headers['Range'] = 'bytes=$have-';
      final resp = await client.send(req);

      var total = 0;
      FileMode mode = FileMode.write;
      if (resp.statusCode == 206) {
        mode = FileMode.append;
        // Content-Range: bytes start-end/total
        final cr = resp.headers['content-range'] ?? '';
        final slash = cr.lastIndexOf('/');
        total = slash >= 0 ? int.tryParse(cr.substring(slash + 1)) ?? 0 : 0;
      } else if (resp.statusCode == 200) {
        have = 0; // server ignored the Range → start clean
        total = resp.contentLength ?? 0;
      } else if (resp.statusCode == 416 && have > 0) {
        // Range past the end → what we have is the whole file.
        return 200;
      } else {
        return resp.statusCode;
      }
      if (total <= 0) total = expectedTotal;

      sink = part.openWrite(mode: mode);
      var received = have;
      _setProgress(job, received, total);
      final stream = resp.stream.timeout(const Duration(seconds: 45));
      await for (final chunk in stream) {
        sink.add(chunk);
        received += chunk.length;
        _setProgress(job, received, total);
        if (total > 0 && received >= total) break;
      }
      await sink.flush();
      if (total > 0 && received < total) {
        throw const SocketException('incomplete');
      }
      return 200;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client.close();
    }
  }

  void _setProgress(DownloadJob job, int received, int total) {
    final q = total > 0 ? (received / total).clamp(0.0, 1.0).toDouble() : null;
    final prev = job.progress;
    job.progress = q;
    if (q == null || prev == null || (q - prev).abs() >= 0.01 || q >= 1.0) {
      _bump();
    }
    // The shade notification moves in 5% steps (cheap on the system).
    final pct = q == null ? -1 : (q * 100).floor();
    if (job.notify && pct >= 0 && pct - job._lastNotifPct >= 5) {
      job._lastNotifPct = pct;
      unawaited(showDownloadProgress(job.url, job.name, pct));
    }
  }

  void _bump() => rev.value++;
}
