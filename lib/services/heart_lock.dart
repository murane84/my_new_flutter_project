import 'package:shared_preferences/shared_preferences.dart';

/// Viewer-side privacy toggle for secret-heart messages (message_type 'heart').
///
/// When ON, revealing a secret heart first requires the device unlock —
/// fingerprint / face / Windows Hello, or the device PIN / pattern / password
/// as a fallback — via [BiometricService]. This is shoulder-surf / phone-grab
/// privacy (the note text itself is not encrypted), so someone glancing at or
/// grabbing the phone can't read a covered heart, and a revealed one re-seals
/// itself after a short idle (handled in the heart widget).
///
/// Off by default; the preference lives per device in SharedPreferences.
class HeartLock {
  HeartLock._();
  static final HeartLock instance = HeartLock._();

  static const String _prefKey = 'lock_secret_hearts';

  /// How long a revealed heart stays open with no interaction before it
  /// re-seals itself (also used by the genie card).
  static const Duration idleRelock = Duration(seconds: 30);

  bool enabled = false;
  bool _loaded = false;

  Future<void> init() async {
    if (_loaded) return;
    try {
      final p = await SharedPreferences.getInstance();
      enabled = p.getBool(_prefKey) ?? false;
    } catch (_) {}
    _loaded = true;
  }

  Future<void> setEnabled(bool value) async {
    enabled = value;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_prefKey, value);
    } catch (_) {}
  }
}
