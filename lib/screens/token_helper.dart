import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/app_config.dart';

/// Token storage.
///
/// flutter_secure_storage is unreliable in browsers (the web build stores the
/// token but reads can silently return null), which made every authenticated
/// request fail on the web PWA. So on web we use shared_preferences (backed by
/// localStorage — rock solid), and keep the encrypted secure storage on native.
final FlutterSecureStorage _storage = FlutterSecureStorage();

Future<void> saveToken(String token) async {
  try {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConfig.tokenKey, token);
    } else {
      await _storage.write(key: AppConfig.tokenKey, value: token);
    }
  } catch (_) {/* best-effort */}
}

Future<String?> getToken() async {
  try {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(AppConfig.tokenKey);
    }
    return await _storage.read(key: AppConfig.tokenKey);
  } catch (_) {
    return null;
  }
}

Future<void> removeToken() async {
  try {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(AppConfig.tokenKey);
    } else {
      await _storage.delete(key: AppConfig.tokenKey);
    }
  } catch (_) {/* best-effort */}
}
