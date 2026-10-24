import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'biometric_service.dart';
import 'account_prefs.dart';

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
  static const String _receiptsKey = 'send_heart_receipts';
  static const String _coachKey = 'heart_hold_coach_seen';
  static const MethodChannel _ch = MethodChannel('aluta/downloads');

  /// Tell the sender when I open their heart ("Opened 2:14 PM"). On by
  /// default; turning it off keeps my opening private (like hiding ticks).
  bool sendReceipts = true;

  /// Whether the one-time "Hold to open" coach has been shown on this device.
  bool coachSeen = false;

  // How many hearts / letter cards are open right now. While > 0 the app's
  // window is FLAG_SECURE on Android: no screenshots, no screen recording,
  // and the recent-apps thumbnail is blanked — so an open note can't leak
  // through the app switcher.
  int _openCount = 0;

  void noteOpened() {
    _openCount++;
    if (_openCount == 1) _setSecure(true);
  }

  void noteClosed() {
    if (_openCount == 0) return;
    _openCount--;
    if (_openCount == 0) _setSecure(false);
  }

  void _setSecure(bool on) {
    if (kIsWeb || !Platform.isAndroid) return;
    _ch.invokeMethod('setSecure', {'on': on}).catchError((_) => null);
  }

  Future<void> setSendReceipts(bool v) async {
    sendReceipts = v;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_receiptsKey, v);
    } catch (_) {}
    AccountPrefs.touch();
  }

  Future<void> markCoachSeen() async {
    coachSeen = true;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_coachKey, true);
    } catch (_) {}
  }

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
    AccountPrefs.onRestore(_reloadFromPrefs); // privacy back from account
    try {
      final p = await SharedPreferences.getInstance();
      enabled = p.getBool(_prefKey) ?? false;
      sendReceipts = p.getBool(_receiptsKey) ?? true;
      coachSeen = p.getBool(_coachKey) ?? false;
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
    AccountPrefs.touch();
  }

  /// Re-read the synced choices after the account copy came back. The lock
  /// only switches ON if this device can actually verify you (biometrics /
  /// device PIN) — otherwise it stays off rather than locking you out.
  Future<void> _reloadFromPrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      sendReceipts = p.getBool(_receiptsKey) ?? true;
      final want = p.getBool(_prefKey) ?? false;
      if (want && !await BiometricService.instance.isAvailable()) {
        enabled = false;
        await p.setBool(_prefKey, false);
      } else {
        enabled = want;
      }
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
