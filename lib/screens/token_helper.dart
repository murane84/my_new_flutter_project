import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logger/logger.dart';
import '../utils/app_config.dart';

final _storage = FlutterSecureStorage();
final _logger = Logger();

Future<void> saveToken(String token) async {
  try {
    await _storage.write(key: AppConfig.tokenKey, value: token);
  } catch (e) {
    _logger.e('Error saving token: $e');
  }
}

Future<String?> getToken() async {
  try {
    return await _storage.read(key: AppConfig.tokenKey);
  } catch (e) {
    _logger.e('Error retrieving token: $e');
    return null;
  }
}

Future<void> removeToken() async {
  try {
    await _storage.delete(key: AppConfig.tokenKey);
  } catch (e) {
    _logger.e('Error removing token: $e');
  }
}
