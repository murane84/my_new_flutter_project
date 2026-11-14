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

  /// Bumped when the server refuses a keepsake because this couple's Our Space
  /// storage is full (HTTP 413). The app shows one friendly toast for it.
  final ValueNotifier<int> spaceFull = ValueNotifier<int>(0);

  void markSpaceFull() => spaceFull.value++;

  /// Bumped when the server refuses a keepsake because this extra Our Space
  /// is read-only (Together ran out — HTTP 402). Nothing is lost.
  final ValueNotifier<int> spaceReadOnly = ValueNotifier<int>(0);

  void markSpaceReadOnly() => spaceReadOnly.value++;

  /// Bumped when my plan changed (a payment confirmed, a gift, an end) —
  /// pushed by the server; open screens reload the plan.
  final ValueNotifier<int> planChanged = ValueNotifier<int>(0);

  void markPlanChanged() => planChanged.value++;

  /// Opens the plans page (set by the signed-in home) — for toasts.
  void Function()? openPlans;
}
