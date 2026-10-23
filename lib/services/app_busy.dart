import 'package:flutter/foundation.dart';

/// Tiny app-wide "is something loading in the background?" signal.
///
/// It ref-counts in-flight background tasks (friend/group refreshes, user-data
/// loads, reconnects, …). The header status dot watches [count] and shows a
/// small spinner while it's > 0, so the user gets a glimpse of *why* the app
/// might feel briefly stuck. Increment with [begin] when a task starts and
/// [end] when it finishes (or just wrap it with [run], which is exception-safe).
class AppBusy {
  AppBusy._();
  static final AppBusy instance = AppBusy._();

  /// Number of background tasks currently running (0 = idle).
  final ValueNotifier<int> count = ValueNotifier<int>(0);

  bool get isBusy => count.value > 0;

  void begin() => count.value = count.value + 1;

  void end() {
    final n = count.value - 1;
    count.value = n < 0 ? 0 : n; // never underflow
  }

  /// Run [task] while marked busy — always decrements, even if it throws.
  Future<T> run<T>(Future<T> Function() task) async {
    begin();
    try {
      return await task();
    } finally {
      end();
    }
  }

  /// MAJOR background work only (startup sync, reconnect re-sync). Drives the
  /// centred busy overlay, scoped to the big moments so the spinner is not
  /// noisy on every small op.
  final ValueNotifier<int> major = ValueNotifier<int>(0);

  /// What the newest labelled major task is doing ("Reconnecting…"), shown
  /// under the loader when a wait runs long. Null = let the mood speak.
  final ValueNotifier<String?> majorLabel = ValueNotifier<String?>(null);
  final List<String> _labels = [];

  void beginMajor({String? label}) {
    if (label != null) {
      _labels.add(label);
      majorLabel.value = label;
    }
    major.value = major.value + 1;
  }

  void endMajor({String? label}) {
    if (label != null) {
      _labels.remove(label);
      majorLabel.value = _labels.isEmpty ? null : _labels.last;
    }
    final n = major.value - 1;
    major.value = n < 0 ? 0 : n;
  }

  Future<T> runMajor<T>(Future<T> Function() task, {String? label}) async {
    beginMajor(label: label);
    try {
      return await task();
    } finally {
      endMajor(label: label);
    }
  }
}

/// How many full-screen loading splashes (the launch splash, the preload
/// screen) are on screen. The centred busy loader stays hidden while any is
/// up — they already show the Aluta mark, so a second logo spinner on top
/// would just clutter the moment.
final ValueNotifier<int> splashOnScreen = ValueNotifier<int>(0);

/// How many genie menus are open. The busy loader waits while one is up so
/// the logo spinner never draws over a menu the user is reading.
final ValueNotifier<int> menusOnScreen = ValueNotifier<int>(0);

/// How many on-screen players show app-busy themselves (the music hero
/// record's ring). The centred loader stays away while one is visible, so it
/// never sits on top of the song title.
final ValueNotifier<int> discHostsBusy = ValueNotifier<int>(0);

/// App-wide singleton.
final appBusy = AppBusy.instance;
