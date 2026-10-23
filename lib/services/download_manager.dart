import 'dart:async';
import 'dart:io';

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/token_helper.dart' show mediaAuthHeaders;
import 'notif_service.dart'
    show showDownloadProgress, finishDownloadNotif, cancelDownloadNotif;

/// One file being fetched to disk.
class DownloadJob {
  DownloadJob(this.url, this.dest, this.name);
  final String url;
  final File dest;
  final String name; // shown in the progress notification
  int _lastNotifPct = -1;
  bool notify = true;

  // Cancellation: the flag is checked between chunks, the client is closed to
  // abort a read in flight, and [_cancelled] wakes any retry wait at once.
  bool cancelled = false;
  http.Client? _client;
  final Completer<void> _cancelled = Completer<void>();
  double? progress; // 0..1, null while the size is unknown
  late final Future<DownloadResult> future;
}

/// How a download ended.
enum DownloadOutcome { ok, gone, failed, cancelled }

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
    // The network came back (Wi-Fi rejoined, data on, out of a dead zone) →
    // continue anything that had paused, from its last byte.
    try {
      Connectivity().onConnectivityChanged.listen((r) {
        if (r.any((c) => c != ConnectivityResult.none)) {
          unawaited(resumePending());
        }
      });
    } catch (_) {}
    unawaited(resumePending());
  }

  /// Wait until some network is up again (or [max] passes).
  Future<void> _waitForNetwork(Duration max) async {
    try {
      final now = await Connectivity().checkConnectivity();
      if (now.any((c) => c != ConnectivityResult.none)) return;
      await Connectivity()
          .onConnectivityChanged
          .firstWhere((r) => r.any((c) => c != ConnectivityResult.none))
          .timeout(max);
    } catch (_) {/* timeout / plugin missing → just carry on */}
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

  /// Stop a download for good (tapped by mistake): aborts the transfer,
  /// deletes the partial file, forgets it (no auto-resume) and clears the
  /// progress notification. Whoever awaited it gets [DownloadOutcome.cancelled].
  Future<void> cancel(String url) async {
    final j = _jobs[url];
    if (j == null || j.cancelled) return;
    j.cancelled = true;
    try {
      j._client?.close();
    } catch (_) {}
    if (!j._cancelled.isCompleted) j._cancelled.complete();
    _bump();
  }
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
      if (r.outcome == DownloadOutcome.cancelled) {
        await _forget(url);
        await cancelDownloadNotif(url);
        return r;
      }
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
    final part = await _partFor(job.url, job.dest);
    try {
      await part.parent.create(recursive: true);
      await job.dest.parent.create(recursive: true);
    } catch (_) {}
    // Show where we already are straight away (a resumed job doesn't flash
    // back to 0%).
    try {
      if (expectedTotal > 0 && await part.exists()) {
        _setProgress(job, await part.length(), expectedTotal);
      }
    } catch (_) {}
    // Patient retries: a flaky line / dead zone / Doze nap shouldn't end the
    // download. Keep resuming (from the last byte) while it still makes
    // progress; only give up after 30 min with NO new bytes — and even then
    // the job stays remembered and continues on the next network change or
    // app resume.
    var lastBytes = -1;
    var stalledSince = DateTime.now();
    Future<DownloadResult> cancelledResult() async {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      return const DownloadResult(DownloadOutcome.cancelled);
    }

    Future<void> waitOrCancel(Future<void> f) =>
        Future.any([f, job._cancelled.future]);

    for (var attempt = 0;; attempt++) {
      if (job.cancelled) return cancelledResult();
      if (attempt > 0) {
        var nowBytes = 0;
        try {
          if (await part.exists()) nowBytes = await part.length();
        } catch (_) {}
        if (nowBytes > lastBytes) {
          lastBytes = nowBytes;
          stalledSince = DateTime.now();
        } else if (DateTime.now().difference(stalledSince) >
            const Duration(minutes: 30)) {
          break;
        }
        onRetry?.call(attempt);
        await waitOrCancel(_waitForNetwork(const Duration(minutes: 5)));
        if (job.cancelled) return cancelledResult();
        await waitOrCancel(
            Future.delayed(Duration(seconds: (2 * attempt).clamp(2, 15))));
        if (job.cancelled) return cancelledResult();
      }
      try {
        final status = await _streamOnce(job, part, headers, expectedTotal);
        if (job.cancelled) return await cancelledResult();
        if (status == 200) {
          try {
            if (await job.dest.exists()) await job.dest.delete();
          } catch (_) {}
          try {
            await part.rename(job.dest.path);
          } catch (_) {
            // Different volume → copy, then drop the partial.
            await part.copy(job.dest.path);
            try {
              await part.delete();
            } catch (_) {}
          }
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
        if (job.cancelled) return await cancelledResult();
      }
    }
    return const DownloadResult(DownloadOutcome.failed);
  }

  /// Where a job's partial bytes live. NOT next to [dest] (that's usually the
  /// OS cache dir, which Android may wipe while the phone sleeps under storage
  /// pressure): app-support storage, keyed by the url, so a download that
  /// Doze / a low-memory kill interrupted always continues from its last byte.
  Future<File> _partFor(String url, File dest) async {
    try {
      if (!kIsWeb) {
        final base = await getApplicationSupportDirectory();
        return File('${base.path}/aluta_parts/${_fnv(url)}.part');
      }
    } catch (_) {}
    return File('${dest.path}.part');
  }

  static String _fnv(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
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
    job._client = client;
    IOSink? sink;
    try {
      final req = http.Request('GET', Uri.parse(job.url))
        // Fresh auth every attempt: a resumed-at-startup job may have been
        // created before the token was cached, or the token may roll over
        // during a long download.
        ..headers.addAll({...headers, ...mediaAuthHeaders(job.url)});
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
        if (job.cancelled) throw const SocketException('cancelled');
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
