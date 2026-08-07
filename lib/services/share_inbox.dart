import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/share_target_screen.dart';

/// Holds images shared INTO Aluta from other apps (via the Android share sheet)
/// until the "Share to…" recipient picker can be presented.
///
/// Presentation is deliberately decoupled from the share plugin so it can be
/// triggered from several places — cold start (Splash), a warm share while the
/// app is open (stream listener in main), and the first Home build (covers the
/// case where the share arrived before the user had signed in). Every entry
/// point calls [maybePresent], which is idempotent and only fires once.
class ShareInbox {
  ShareInbox._();
  static final ShareInbox instance = ShareInbox._();

  final List<String> _pending = [];
  bool _presenting = false;

  void add(Iterable<String> paths) =>
      _pending.addAll(paths.where((p) => p.trim().isNotEmpty));

  bool get hasPending => _pending.isNotEmpty;

  /// If there are pending shared images AND the user is signed in, push the
  /// recipient picker. When signed out, the images stay pending so a later
  /// call (e.g. once Home builds after login) can present them. Safe to call
  /// repeatedly and from anywhere with a navigator.
  Future<void> maybePresent(NavigatorState? nav) async {
    if (_presenting || _pending.isEmpty || nav == null || !nav.mounted) return;
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool('isLoggedIn') ?? false)) return; // wait until signed in
    if (!nav.mounted) return;
    final paths = List<String>.from(_pending);
    _pending.clear();
    _presenting = true;
    try {
      await nav.push(MaterialPageRoute(
        builder: (_) => ShareTargetScreen(imagePaths: paths),
      ));
    } finally {
      _presenting = false;
    }
  }
}
