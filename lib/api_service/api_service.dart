import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:intl/intl.dart'; // For formatting datetime
import 'token_helper.dart';

final logger = Logger();
final FlutterSecureStorage secureStorage = FlutterSecureStorage();

class ApiService {
  final String baseUrl = 'http://192.168.2.54:8000';

  // REGISTER
  Future<bool> register(String email, String password, String username) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/auth/register/'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'password': password,
          'username': username,
        }),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return true;
      } else {
        logger.w('Register failed: ${response.statusCode} - ${response.body}');
        return false;
      }
    } catch (e) {
      logger.e('Register exception: $e');
      return false;
    }
  }

  // LOGIN
  Future<Map<String, dynamic>> login(String email, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'password': password}),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final Map<String, dynamic> responseData = jsonDecode(response.body);
        final String username = responseData['username'] ?? '';
        final String token = responseData['access_token'] ?? '';

        if (token.isNotEmpty) {
          await secureStorage.write(key: 'access_token', value: token);
        }

        return {'success': true, 'username': username, 'access_token': token};
      } else {
        logger.w('Login failed: ${response.statusCode} - ${response.body}');
        return {'success': false};
      }
    } catch (e) {
      logger.e('Login exception: $e');
      return {'success': false};
    }
  }

  // LOGOUT
  Future<void> logoutUser() async {
    try {
      final String? token = await secureStorage.read(key: 'access_token');
      if (token == null) {
        logger.w('No access token found. Skipping logout.');
        return;
      }

      // Call API to set the user's status to offline using existing endpoint
      final statusResponse = await http.post(
        Uri.parse('$baseUrl/users/me/online?is_online=false'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

      if (statusResponse.statusCode == 200) {
        logger.i('User status set to offline.');
      } else {
        logger.w(
          'Failed to update user online status: ${statusResponse.statusCode} - ${statusResponse.body}',
        );
      }

      // Now proceed with the logout
      final response = await http.post(
        Uri.parse('$baseUrl/logout'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        logger.i('User logged out successfully from backend.');
      } else {
        logger.w('Logout failed: ${response.statusCode} - ${response.body}');
      }

      // Always delete token locally
      await secureStorage.delete(key: 'access_token');
      logger.i('Access token deleted locally.');
    } catch (e) {
      logger.e('Logout exception: $e');
    }
  }

  // GET CURRENT USER
  Future<Map<String, dynamic>> getUserData() async {
    try {
      final String? token = await secureStorage.read(key: 'access_token');
      if (token == null) throw Exception('No access token found');

      final response = await http.get(
        Uri.parse('$baseUrl/users/me'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final dynamic data = jsonDecode(response.body);
        if (data is Map<String, dynamic>) {
          return data;
        } else {
          throw Exception('Invalid user data format');
        }
      } else if (response.statusCode == 401) {
        throw Exception('Token expired, please log in again.');
      } else {
        logger.w(
          'Fetch user data failed: ${response.statusCode} - ${response.body}',
        );
        throw Exception('Failed to fetch user data');
      }
    } catch (e) {
      logger.e('Get user data exception: $e');
      return {};
    }
  }

  Future<Map<String, dynamic>> getCurrentUser(String token) async {
    return await getUserData();
  }

  // FETCH USERS
  Future<List<Map<String, dynamic>>> fetchUsers() async {
    try {
      final String? token = await secureStorage.read(key: 'access_token');
      if (token == null) throw Exception('No access token found');

      final response = await http.get(
        Uri.parse('$baseUrl/users/'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final dynamic body = jsonDecode(response.body);
        if (body is List) {
          return body.whereType<Map<String, dynamic>>().toList();
        } else {
          throw Exception('Invalid users list format');
        }
      } else {
        logger.w(
          'Fetch users failed: ${response.statusCode} - ${response.body}',
        );
        throw Exception('Failed to fetch users');
      }
    } catch (e) {
      logger.e('Fetch users exception: $e');
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getFriends() async {
    return await fetchUsers();
  }

  // FETCH MESSAGES BETWEEN TWO USERS
  Future<List<Map<String, dynamic>>> fetchMessagesBetween(
    int userId,
    int friendId, {
    int skip = 0,
    int limit = 20,
    String? lastTimestamp, // 👈 Add this optional param
  }) async {
    try {
      final String? token = await secureStorage.read(key: 'access_token');
      if (token == null) throw Exception('No access token found');

      final queryParams = <String, String>{};
      if (lastTimestamp != null) {
        queryParams['after'] = lastTimestamp;
      }

      final uri = Uri.parse(
        '$baseUrl/messages/$userId/$friendId',
      ).replace(queryParameters: queryParams.isNotEmpty ? queryParams : null);

      final response = await http.get(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final dynamic body = jsonDecode(response.body);
        if (body is List) {
          return body.whereType<Map<String, dynamic>>().toList();
        } else {
          throw Exception('Invalid messages format');
        }
      } else {
        logger.w(
          'Fetch messages failed: ${response.statusCode} - ${response.body}',
        );
        return [];
      }
    } catch (e) {
      logger.e('Fetch messages exception: $e');
      return [];
    }
  }

  // SEND MESSAGE
  Future<bool> sendMessage(
    int receiverId,
    String content, {
    required String type,
  }) async {
    try {
      final String? token = await secureStorage.read(key: 'access_token');
      if (token == null) throw Exception('No access token found');

      final response = await http.post(
        Uri.parse('$baseUrl/messages/'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'receiver_id': receiverId, 'content': content}),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return true;
      } else {
        logger.w(
          'Send message failed: ${response.statusCode} - ${response.body}',
        );
        return false;
      }
    } catch (e) {
      logger.e('Send message exception: $e');
      return false;
    }
  }

  // MARK MESSAGE AS DELIVERED
  Future<void> markMessageAsDelivered(int messageId) async {
    final token = await getToken();
    if (token == null) return;

    await http.put(
      Uri.parse('$baseUrl/messages/$messageId/delivered'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
    );
  }

  // MARK MESSAGES AS READ
  Future<void> markMessagesAsRead(int userId, int friendId) async {
    try {
      final String? token = await secureStorage.read(key: 'access_token');
      if (token == null) throw Exception('No access token found');

      final response = await http.post(
        Uri.parse('$baseUrl/messages/$userId/$friendId/read'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        logger.i(
          'Messages marked as read for userId: $userId and friendId: $friendId',
        );
      } else {
        logger.w(
          'Mark messages as read failed: ${response.statusCode} - ${response.body}',
        );
      }
    } catch (e) {
      logger.e('Mark messages as read exception: $e');
    }
  }

  // FETCH FRIEND ONLINE STATUS
  Future<Map<String, dynamic>> fetchFriendStatus(int friendId) async {
    try {
      Future<String> token() async {
        final token = await secureStorage.read(key: 'access_token');
        if (token == null) throw Exception('No access token found');
        return token;
      }

      final response = await http.get(
        Uri.parse('$baseUrl/users/$friendId/status'),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(response.body);
        final bool isOnline = data['is_online'] ?? false;
        final String? lastSeen = data['last_seen'];

        String formattedLastSeen = 'Unknown';
        if (lastSeen != null && lastSeen.isNotEmpty) {
          try {
            final DateTime parsed = DateTime.parse(lastSeen).toLocal();
            formattedLastSeen = DateFormat('yyyy-MM-dd HH:mm').format(parsed);
          } catch (_) {
            logger.w('Invalid date format from backend: $lastSeen');
          }
        }

        return {
          'is_online': isOnline,
          'last_seen': formattedLastSeen != 'Unknown'
              ? formattedLastSeen
              : null,
        };
      } else {
        logger.w(
          'Fetch friend status failed: ${response.statusCode} - ${response.body}',
        );
        return {};
      }
    } catch (e) {
      logger.e('Fetch friend status exception: $e');
      return {};
    }
  }

  // CHECK IF FRIEND IS ONLINE
  Future<bool> isUserOnline(int friendId) async {
    try {
      final status = await fetchFriendStatus(friendId);
      return status['is_online'] ?? false;
    } catch (e) {
      logger.e('Check isUserOnline exception: $e');
      return false;
    }
  }
}
