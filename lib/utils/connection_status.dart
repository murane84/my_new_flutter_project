import 'package:flutter/foundation.dart';

/// App-wide connection status — the SINGLE source of truth for "am I online?".
///
/// Every indicator in the app (the home footer dot, the Messages header badge,
/// and the chat "you are offline" banner) reads from this one value, so they
/// can never disagree. It reflects the server side: it flips to `false` only
/// when a real server call fails, and back to `true` when one succeeds.
class ConnectionStatus {
  ConnectionStatus._();
  static final ConnectionStatus instance = ConnectionStatus._();

  /// true = connected to the server (online); false = offline.
  final ValueNotifier<bool> online = ValueNotifier<bool>(true);

  bool get isOnline => online.value;

  /// Update the shared status. No-op if unchanged (avoids needless rebuilds).
  void set(bool value) {
    if (online.value != value) online.value = value;
  }
}
