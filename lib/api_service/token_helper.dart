import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logger/logger.dart';

final storage = FlutterSecureStorage();
final logger = Logger(); // Use this instead of print

Future<void> saveToken(String token) async {
  try {
    logger.i('Saving token...');
    await storage.write(key: 'auth_token', value: token);
  } catch (e) {
    logger.e('Error saving token: $e');
  }
}

Future<String?> getToken() async {
  try {
    final token = await storage.read(key: 'auth_token');
    logger.i('Retrieved token: $token');
    return token;
  } catch (e) {
    logger.e('Error retrieving token: $e');
    return null;
  }
}

Future<void> removeToken() async {
  try {
    logger.i('Token removed from secure storage');
    await storage.delete(key: 'auth_token');
  } catch (e) {
    logger.e('Error removing token: $e');
  }
}
