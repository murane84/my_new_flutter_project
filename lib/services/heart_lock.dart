import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'biometric_service.dart';

/// Viewer-side privacy for secret-heart messages (message_type 'heart').
///
/// When ON, revealing a secret heart first requires the device unlock —
/// fingerprint / face / Windows Hello, or the device PIN / pattern / password
/// as a fallback — via [BiometricService]. This is shoulder-surf / phone-grab
/// privacy (the note text itself is not encrypted).
///
/// * One unlock opens a short [unlockWindow] in which further hearts open
///   without asking again (no re-auth for every heart in a conversation).
/// * Every open heart re-seals itself after [idleRelock] of no interaction,
///   and ALL of them re-seal the moment the app leaves the foreground (the
///   "phone grabbed / handed over" case) — listen to [relockEpoch].
///
/// Off by default; the preference lives per device in SharedPreferences.
class HeartLock with WidgetsBindingObserver {
  HeartLock._();
  static final HeartLock instance = HeartLock._();

  static const String _prefKey = 'lock_secret_hearts';

  /// How long a revealed heart stays open with no interaction before it
  /// re-seals itself (also used by the genie card).
  static const Duration idleRelock = Duration(seconds: 30);

  /// After a successful unlock, further hearts open without re-auth for this
  /// long (cleared early when the app is backgrounded).
  static const Duration unlockWindow = Duration(minutes: 2);

  bool enabled = false;
  bool _loaded = false;
  bool _observing = false;
  DateTime? _unlockedUntil;

  /// Bumped whenever every open heart must seal (app backgrounded). Open
  /// hearts and the genie card listen and close.
  final ValueNotifier<int> relockEpoch = ValueNotifier<int>(0);

  Future<void> init() async {
    if (!_observing) {
      _observing = true;
      try {
        WidgetsBinding.instance.addObserver(this);
      } catch (_) {}
    }
    if (_loaded) return;
    try {
      final p = await SharedPreferences.getInstance();
      enabled = p.getBool(_prefKey) ?? false;
    } catch (_) {}
    _loaded = true;
  }

  Future<void> setEnabled(bool value) async {
    enabled = value;
    _unlockedUntil = null;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_prefKey, value);
    } catch (_) {}
  }

  bool get _inWindow =>
      _unlockedUntil != null && DateTime.now().isBefore(_unlockedUntil!);

  /// Gate for opening a heart: true straight away when the lock is off or a
  /// recent unlock is still fresh; otherwise asks for the device unlock.
  Future<bool> ensureUnlocked([String reason = 'Open secret heart']) async {
    if (!enabled || _inWindow) return true;
    final ok = await BiometricService.instance.authenticate(reason);
    if (ok) _unlockedUntil = DateTime.now().add(unlockWindow);
    return ok;
  }

  /// Seal everything now (and forget the unlock window).
  void relockAll() {
    _unlockedUntil = null;
    relockEpoch.value++;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `inactive` also fires for the biometric prompt itself on Android, so only
    // seal on a real trip to the background.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      relockAll();
    }
  }
}
