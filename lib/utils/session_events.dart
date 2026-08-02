import 'package:flutter/foundation.dart';

/// Fired when the server rejects our token with 401/403 — i.e. the session has
/// genuinely expired (not just a transient network blip). The app listens and
/// forces a clean sign-out → login, instead of leaving a returning user stuck
/// "offline" and hoping a manual refresh reconnects them.
class SessionEvents {
  SessionEvents._();
  static final SessionEvents instance = SessionEvents._();

  final ValueNotifier<bool> expired = ValueNotifier<bool>(false);

  void markExpired() {
    if (!expired.value) expired.value = true;
  }

  void reset() => expired.value = false;
}
