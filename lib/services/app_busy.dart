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
}

/// App-wide singleton.
final appBusy = AppBusy.instance;
