import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'web_reloader_stub.dart'
    if (dart.library.html) 'web_reloader_web.dart';

/// Web-only: notices when a NEWER build of the app has been deployed (the
/// browser keeps running the assets it loaded until a full reload) and shows a
/// persistent "Reload" banner so the user can pick up the new version without
/// guessing. No-op on Android / iOS / desktop, where a new version arrives as a
/// fresh app install rather than a page reload.
class WebUpdateChecker {
  WebUpdateChecker._();
  static final WebUpdateChecker instance = WebUpdateChecker._();

  GlobalKey<ScaffoldMessengerState>? _messenger;
  String? _boot; // fingerprint of the build this tab is running
  Timer? _timer;
  bool _shown = false;

  /// Begin polling (web only). Records the build we booted with, then checks for
  /// a newer one every couple of minutes.
  void start(GlobalKey<ScaffoldMessengerState> messenger) {
    if (!kIsWeb) return;
    _messenger = messenger;
    _fetchStamp().then((s) => _boot ??= s);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 2), (_) => _check());
  }

  /// Check once on demand (e.g. when the tab regains focus).
  Future<void> checkNow() => _check();

  Future<void> _check() async {
    if (!kIsWeb || _shown) return;
    final latest = await _fetchStamp();
    if (latest == null) return;
    _boot ??= latest; // in case the very first fetch hadn't landed yet
    if (latest == _boot) return;
    _shown = true;
    _prompt();
  }

  Future<String?> _fetchStamp() async {
    try {
      // The Flutter service worker lists every asset by content hash, so its
      // body changes on every build — a reliable per-deploy fingerprint.
      // Cache-bust so neither the browser nor the active SW serve a stale copy.
      final uri = Uri.base.resolve('flutter_service_worker.js').replace(
        queryParameters: {
          '_': DateTime.now().millisecondsSinceEpoch.toString(),
        },
      );
      final r = await http
          .get(uri, headers: const {'cache-control': 'no-cache'})
          .timeout(const Duration(seconds: 8));
      if (r.statusCode != 200 || r.body.isEmpty) return null;
      return '${r.body.length}:${r.body.hashCode}';
    } catch (_) {
      return null;
    }
  }

  void _prompt() {
    final m = _messenger?.currentState;
    if (m == null) {
      _shown = false; // messenger not mounted yet — retry on the next tick
      return;
    }
    m.clearSnackBars();
    m.showSnackBar(
      SnackBar(
        content: const Text('A new version of Aluta is available.'),
        duration: const Duration(days: 365), // persistent until acted on
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(label: 'Reload', onPressed: reloadApp),
      ),
    );
  }
}
