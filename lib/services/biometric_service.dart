import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// Fingerprint / Face unlock (Android & iOS) and Windows Hello (Windows).
///
/// Design note — privacy first: enabling this does NOT store your password
/// anywhere. Your account already keeps a long-lived *refresh token* in the OS's
/// encrypted store; the biometric prompt simply authorises the app to use that
/// token, so a fingerprint (or Face / Windows Hello) unlocks the session without
/// the raw password ever being written to disk.
///
/// Enrollment state itself lives in encrypted secure storage (not
/// SharedPreferences) so that a `prefs.clear()` on sign-out can't silently leave
/// it behind — sign-out wipes it explicitly via [disable].
class BiometricService {
  BiometricService._();
  static final BiometricService instance = BiometricService._();

  final LocalAuthentication _auth = LocalAuthentication();
  final FlutterSecureStorage _store = FlutterSecureStorage();

  static const String _enabledKey = 'biometric_enabled';
  static const String _accountKey = 'biometric_account';

  /// True when the device can perform a biometric OR device-credential
  /// (PIN / pattern / Windows Hello PIN) check. Web is never supported; on
  /// Windows this is only true once Windows Hello has been set up.
  Future<bool> isAvailable() async {
    if (kIsWeb) return false;
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  /// True when a real biometric (fingerprint / face / iris) is enrolled — used
  /// only to tailor the on-screen copy. Falls back gracefully to false.
  Future<bool> hasBiometrics() async {
    if (kIsWeb) return false;
    try {
      return await _auth.canCheckBiometrics &&
          (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Presents the OS biometric / Windows Hello sheet. Returns true on success.
  ///
  /// [biometricOnly] is false on purpose: allowing the device PIN/pattern (or
  /// Windows Hello PIN) as a fallback is what makes this reliable — a smudged
  /// sensor or a failed face match never locks the owner out of their own app.
  Future<bool> authenticate(String reason) async {
    if (kIsWeb) return false;
    try {
      // local_auth 3.x takes flat parameters (there is no AuthenticationOptions
      // object). biometricOnly:false keeps the device PIN / Windows Hello PIN as
      // a fallback so a smudged sensor never locks the owner out;
      // persistAcrossBackgrounding is the old stickyAuth.
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }

  Future<bool> isEnabled() async {
    try {
      return (await _store.read(key: _enabledKey)) == '1';
    } catch (_) {
      return false;
    }
  }

  /// The account (email) the quick-unlock was enrolled for, if any.
  Future<String?> enrolledAccount() async {
    try {
      return await _store.read(key: _accountKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> enable(String account) async {
    try {
      await _store.write(key: _enabledKey, value: '1');
      await _store.write(key: _accountKey, value: account);
    } catch (_) {/* best-effort */}
  }

  Future<void> disable() async {
    try {
      await _store.delete(key: _enabledKey);
      await _store.delete(key: _accountKey);
    } catch (_) {/* best-effort */}
  }
}
