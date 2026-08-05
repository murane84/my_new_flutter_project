import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:intl/intl.dart';
import 'package:flutter/foundation.dart';
import 'token_helper.dart';
import 'user.dart';
import '../utils/app_config.dart';

final _logger = Logger();
final FlutterSecureStorage _secureStorage = FlutterSecureStorage();

class ApiService {
  Future<String> get _baseUrl => AppConfig.baseUrl;

  Map<String, String> _authHeaders(String token) => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };

  Future<String?> _getToken() async {
    return await _secureStorage.read(key: AppConfig.tokenKey);
  }

  // REGISTER
  Future<Map<String, dynamic>> register(
    String email,
    String password,
    String username, {
    String? phone,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('${await _baseUrl}/auth/register/'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'password': password,
          'username': username,
          if (phone != null && phone.isNotEmpty) 'phone': phone,
        }),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return {'success': true};
      }

      final body = _tryDecode(response.body);
      final message = body?['detail'] ?? 'Registration failed. Please try again.';
      _logger.w('Register failed: ${response.statusCode} - ${response.body}');
      return {'success': false, 'message': message};
    } catch (e) {
      _logger.e('Register exception: $e');
      return {'success': false, 'message': 'Network error. Check your connection.'};
    }
  }

  // LOGIN
  Future<Map<String, dynamic>> login(String email, String password) async {
    try {
      final response = await http.post(
        Uri.parse('${await _baseUrl}/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'password': password}),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final String token = data['access_token'] ?? '';
        if (token.isNotEmpty) {
          await _secureStorage.write(key: AppConfig.tokenKey, value: token);
        }
        return {
          'success': true,
          'username': data['username'] ?? '',
          'access_token': token,
          'user_id': data['user_id'],
        };
      }

      final body = _tryDecode(response.body);
      String message;
      if (response.statusCode == 401) {
        message = 'Invalid email or password.';
      } else {
        message = body?['detail'] ?? 'Login failed. Please try again.';
      }
      _logger.w('Login failed: ${response.statusCode} - ${response.body}');
      return {'success': false, 'message': message};
    } catch (e) {
      _logger.e('Login exception: $e');
      return {'success': false, 'message': 'Network error. Check your connection.'};
    }
  }

  // LOGOUT
  Future<void> logoutUser() async {
    try {
      final token = await _getToken();
      if (token == null) return;

      await http.post(
        Uri.parse('${await _baseUrl}/users/me/online?is_online=false'),
        headers: _authHeaders(token),
      );

      await http.post(
        Uri.parse('${await _baseUrl}/logout'),
        headers: _authHeaders(token),
      );

      await _secureStorage.delete(key: AppConfig.tokenKey);
    } catch (e) {
      _logger.e('Logout exception: $e');
      await _secureStorage.delete(key: AppConfig.tokenKey);
    }
  }

  // SET ONLINE STATUS (keepalive / reconnect / logout)
  Future<bool> setOnlineStatus(bool isOnline) async {
    try {
      final token = await _getToken();
      if (token == null) return false;
      final res = await http.post(
        Uri.parse(
            '${await _baseUrl}/users/me/online?is_online=$isOnline'),
        headers: _authHeaders(token),
      );
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  // GET CURRENT USER
  Future<Map<String, dynamic>> getUserData() async {
    try {
      final token = await _getToken();
      if (token == null) throw Exception('No access token found');

      final response = await http.get(
        Uri.parse('${await _baseUrl}/users/me'),
        headers: _authHeaders(token),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(response.body);
        if (data is Map<String, dynamic>) return data;
        throw Exception('Invalid user data format');
      } else if (response.statusCode == 401) {
        throw Exception('Session expired. Please log in again.');
      }
      throw Exception('Failed to fetch user data');
    } catch (e) {
      _logger.e('Get user data exception: $e');
      return {};
    }
  }

  Future<Map<String, dynamic>> getCurrentUser(String token) => getUserData();

  // FETCH USERS / FRIENDS WITH UNREAD COUNTS
  // NOTE: throws on any error so callers can distinguish "API error"
  // from a genuinely empty friends list and preserve cached data.
  Future<List<Map<String, dynamic>>> fetchUsers() async {
    final token = await _getToken();
    if (token == null) throw Exception('No access token');

    final response = await http.get(
      Uri.parse('${await _baseUrl}/users/friends/unread_counts'),
      headers: _authHeaders(token),
    );

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final body = jsonDecode(response.body);
      if (body is List) return body.whereType<Map<String, dynamic>>().toList();
      throw Exception('Invalid users list format');
    }
    // 401 = session expired, 4xx/5xx = server error — both throw so UI
    // can catch and keep showing cached friends instead of clearing list.
    _logger.w('fetchUsers failed: ${response.statusCode}');
    throw Exception('HTTP ${response.statusCode}');
  }

  Future<List<Map<String, dynamic>>> getFriends() => fetchUsers();

  Future<List<User>> getFriendsWithUnreadCounts() async {
    final token = await getToken();
    final response = await http.get(
      Uri.parse('${await _baseUrl}/users/friends/unread_counts'),
      headers: _authHeaders(token ?? ''),
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = jsonDecode(response.body);
      return data.map((u) => User.fromMap(u as Map<String, dynamic>)).toList();
    }
    throw Exception('Failed to fetch friends');
  }

  // FETCH MESSAGES
  Future<List<Map<String, dynamic>>> fetchMessagesBetween(
    int userId,
    int friendId, {
    int skip = 0,
    int limit = 50,
    String? lastTimestamp,
  }) async {
    try {
      final token = await _getToken();
      if (token == null) throw Exception('No access token found');

      final params = <String, String>{
        'skip': skip.toString(),
        'limit': limit.toString(),
      };
      if (lastTimestamp != null) params['after'] = lastTimestamp;

      final uri = Uri.parse(
        '${await _baseUrl}/messages/$userId/$friendId',
      ).replace(queryParameters: params);

      final response = await http.get(uri, headers: _authHeaders(token));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final body = jsonDecode(response.body);
        if (body is List) return body.whereType<Map<String, dynamic>>().toList();
        throw Exception('Invalid messages format');
      }
      // Throw so callers can catch and preserve cached messages
      _logger.w('fetchMessagesBetween failed: ${response.statusCode}');
      throw Exception('HTTP ${response.statusCode}');
    } catch (e) {
      _logger.e('Fetch messages exception: $e');
      rethrow; // propagate — caller decides whether to show cached data
    }
  }

  Future<List<Map<String, dynamic>>> fetchVisibleMessagesWithFriend(
    int friendId, {
    int skip = 0,
    int limit = 50,
  }) async {
    try {
      final token = await _getToken();
      if (token == null) return [];

      final uri = Uri.parse(
        '${await _baseUrl}/messages/$friendId/all_messages',
      ).replace(
        queryParameters: {'skip': skip.toString(), 'limit': limit.toString()},
      );

      final response = await http.get(uri, headers: _authHeaders(token));
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        if (body is List) return body.whereType<Map<String, dynamic>>().toList();
      }
      return [];
    } catch (e) {
      _logger.e('Error fetching visible messages: $e');
      return [];
    }
  }

  // SEND MESSAGE
  Future<Map<String, dynamic>?> sendMessage(
    int receiverId,
    String content,
  ) async {
    try {
      final token = await _getToken();
      if (token == null) throw Exception('No access token');

      final response = await http.post(
        Uri.parse('${await _baseUrl}/messages/'),
        headers: _authHeaders(token),
        body: jsonEncode({'receiver_id': receiverId, 'content': content}),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(response.body);
        if (data is Map<String, dynamic>) return data;
      }
      _logger.w('Send message failed: ${response.statusCode}');
      return null;
    } catch (e) {
      _logger.e('Send message exception: $e');
      return null;
    }
  }

  // MARK AS DELIVERED
  Future<void> markMessageAsDelivered(int messageId) async {
    final token = await getToken();
    if (token == null || token.isEmpty) return;

    try {
      await http.put(
        Uri.parse('${await _baseUrl}/messages/$messageId/delivered'),
        headers: _authHeaders(token),
      );
    } catch (e) {
      _logger.e('markMessageAsDelivered exception: $e');
    }
  }

  // MARK AS READ
  Future<void> markMessagesAsReadPatch(int senderId) async {
    final token = await _getToken();
    if (token == null) return;

    try {
      await http.patch(
        Uri.parse('${await _baseUrl}/messages/$senderId/read'),
        headers: _authHeaders(token),
      );
    } catch (e) {
      _logger.e('Mark messages as read exception: $e');
    }
  }

  // FRIEND STATUS
  Future<Map<String, dynamic>> fetchFriendStatus(int friendId) async {
    try {
      final token = await _getToken();
      if (token == null) return {};

      final response = await http.get(
        Uri.parse('${await _baseUrl}/users/$friendId/status'),
        headers: _authHeaders(token),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(response.body);
        final bool isOnline = data['is_online'] ?? false;
        final String? lastSeen = data['last_seen'];

        String? formatted;
        if (lastSeen != null && lastSeen.isNotEmpty) {
          try {
            formatted = DateFormat('MMM d, HH:mm').format(
              DateTime.parse(lastSeen).toLocal(),
            );
          } catch (_) {}
        }

        return {
          'is_online': isOnline,
          'last_seen': formatted,
          'phone': data['phone'],
        };
      }
      return {};
    } catch (e) {
      _logger.e('Fetch friend status exception: $e');
      return {};
    }
  }

  Future<bool> isUserOnline(int friendId) async {
    final status = await fetchFriendStatus(friendId);
    return status['is_online'] ?? false;
  }

  // UNREAD COUNT
  Future<int> getUnreadMessagesCount(int friendId) async {
    try {
      final token = await _getToken();
      if (token == null) return 0;

      final response = await http.get(
        Uri.parse('${await _baseUrl}/messages/$friendId/unread_count'),
        headers: _authHeaders(token),
      );

      if (response.statusCode == 200) {
        return int.tryParse(response.body) ?? 0;
      }
      return 0;
    } catch (_) {
      return 0;
    }
  }

  // DELETE
  Future<void> deleteChatWith(int friendId) async {
    final token = await getToken();
    final response = await http.delete(
      Uri.parse('${await _baseUrl}/messages/$friendId'),
      headers: _authHeaders(token ?? ''),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to delete chat');
    }
  }

  Future<void> deleteMessagesWithFriend(
    int userId,
    int friendId, {
    required bool deleteForAll,
  }) async {
    final token = await getToken();
    final response = await http.delete(
      Uri.parse('${await _baseUrl}/messages/$friendId?delete_for_all=$deleteForAll'),
      headers: _authHeaders(token ?? ''),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to delete messages');
    }
  }

  Future<void> deleteSingleMessage(
    int messageId, {
    required bool deleteForAll,
  }) async {
    final token = await getToken();
    final response = await http.delete(
      Uri.parse(
        '${await _baseUrl}/messages/$messageId/delete?delete_for_all=$deleteForAll',
      ),
      headers: _authHeaders(token ?? ''),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to delete message');
    }
  }

  // REACT TO MESSAGE — toggle the current user's emoji on a message.
  // Returns the new reactions JSON string ({"<uid>":"<emoji>"}) or null.
  Future<String?> reactToMessage(int messageId, String emoji) async {
    final token = await getToken();
    final response = await http.post(
      Uri.parse(
        '${await _baseUrl}/messages/$messageId/react'
        '?emoji=${Uri.encodeQueryComponent(emoji)}',
      ),
      headers: _authHeaders(token ?? ''),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Failed to react');
    }
    try {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['reactions'] as String?;
    } catch (_) {
      return null;
    }
  }

  // EDIT MESSAGE — sender-only, text messages. Returns the updated message map.
  Future<Map<String, dynamic>?> editMessage(int messageId, String content) async {
    final token = await getToken();
    final response = await http.patch(
      Uri.parse('${await _baseUrl}/messages/$messageId/edit'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${token ?? ''}',
      },
      body: jsonEncode({'content': content}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Failed to edit message');
    }
    try {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // MUTE / BLOCK
  Future<bool> toggleMute(int friendId) async {
    final token = await getToken();
    final response = await http.post(
      Uri.parse('${await _baseUrl}/users/$friendId/mute'),
      headers: _authHeaders(token ?? ''),
    );
    if (response.statusCode == 200) {
      return (jsonDecode(response.body) as Map)['muted'] as bool;
    }
    throw Exception('Failed to toggle mute');
  }

  Future<bool> toggleBlock(int userId) async {
    final token = await getToken();
    final response = await http.post(
      Uri.parse('${await _baseUrl}/block/$userId'),
      headers: _authHeaders(token ?? ''),
    );
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as bool;
    }
    throw Exception('Failed to toggle block');
  }

  Future<bool> isUserMuted(int userId) async {
    final token = await getToken();
    final response = await http.get(
      Uri.parse('${await _baseUrl}/users/$userId/muted'),
      headers: _authHeaders(token ?? ''),
    );
    if (response.statusCode == 200) {
      return (jsonDecode(response.body) as Map)['muted'] ?? false;
    }
    throw Exception('Failed to check mute status');
  }

  Future<bool> isUserBlocked(int userId) async {
    final token = await getToken();
    final response = await http.get(
      Uri.parse('${await _baseUrl}/block/$userId'),
      headers: _authHeaders(token ?? ''),
    );
    if (response.statusCode == 200) return jsonDecode(response.body) as bool;
    throw Exception('Failed to check block status');
  }

  Future<List<Map<String, dynamic>>> getFriendsList(String token) async {
    final response = await http.get(
      Uri.parse('${await _baseUrl}/users/friends'),
      headers: _authHeaders(token),
    );
    if (response.statusCode == 200) {
      return List<Map<String, dynamic>>.from(jsonDecode(response.body));
    }
    return [];
  }

  Map<String, dynamic>? _tryDecode(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  // ignore: unused_field
  static final _unused = debugPrint; // suppress unused import warning
}
