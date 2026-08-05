import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;
import 'package:logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'token_helper.dart';
import 'user.dart';
import '../utils/app_config.dart';
import '../utils/session_events.dart';

final _logger = Logger();

class ApiService {
  Future<String> get _baseUrl => AppConfig.baseUrl;

  Map<String, String> _authHeaders(String token) => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };

  // Delegates to the platform-aware token store (web-safe).
  Future<String?> _getToken() async => getToken();

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
          await saveToken(token);
        }
        final String refresh = data['refresh_token'] ?? '';
        if (refresh.isNotEmpty) {
          await saveRefreshToken(refresh);
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

      await removeToken();
      await removeRefreshToken();
    } catch (e) {
      _logger.e('Logout exception: $e');
      await removeToken();
      await removeRefreshToken();
    }
  }

  // ── Silent token refresh ────────────────────────────────────────────────
  // Exchanges the long-lived refresh token for a fresh access token so an
  // expired access token is invisible to the user. Returns true on success.
  Future<bool> refreshAccessToken() async {
    try {
      final refresh = await getRefreshToken();
      if (refresh == null || refresh.isEmpty) return false;
      final res = await http.post(
        Uri.parse('${await _baseUrl}/auth/refresh'),
        headers: _authHeaders(refresh),
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = jsonDecode(res.body);
        final newToken = data is Map ? data['access_token'] as String? : null;
        if (newToken != null && newToken.isNotEmpty) {
          await saveToken(newToken);
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // SET ONLINE STATUS (keepalive / reconnect / logout)
  Future<bool> setOnlineStatus(bool isOnline) async {
    try {
      Future<http.Response?> post(String? tok) async {
        if (tok == null) return null;
        return http.post(
          Uri.parse('${await _baseUrl}/users/me/online?is_online=$isOnline'),
          headers: _authHeaders(tok),
        );
      }

      var res = await post(await _getToken());
      if (res == null) return false;

      // Access token expired? Silently refresh and retry once. Only if the
      // refresh itself fails do we treat the session as truly expired.
      if (res.statusCode == 401 || res.statusCode == 403) {
        if (await refreshAccessToken()) {
          res = await post(await _getToken());
        }
        if (res == null || res.statusCode == 401 || res.statusCode == 403) {
          SessionEvents.instance.markExpired();
          return false;
        }
      }
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

      var activeToken = token;
      var response = await http.get(
        Uri.parse('${await _baseUrl}/users/me'),
        headers: _authHeaders(activeToken),
      );

      // Access token expired? Silently refresh and retry once.
      if (response.statusCode == 401 || response.statusCode == 403) {
        if (await refreshAccessToken()) {
          final fresh = await _getToken();
          if (fresh != null) {
            activeToken = fresh;
            response = await http.get(
              Uri.parse('${await _baseUrl}/users/me'),
              headers: _authHeaders(activeToken),
            );
          }
        }
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final data = jsonDecode(response.body);
        if (data is Map<String, dynamic>) return data;
        throw Exception('Invalid user data format');
      } else if (response.statusCode == 401 || response.statusCode == 403) {
        SessionEvents.instance.markExpired();
        throw Exception('Session expired. Please log in again.');
      }
      throw Exception('Failed to fetch user data');
    } catch (e) {
      _logger.e('Get user data exception: $e');
      return {};
    }
  }

  Future<Map<String, dynamic>> getCurrentUser(String token) => getUserData();

  // UPDATE PROFILE — username / phone / password. Email is immutable.
  Future<Map<String, dynamic>> updateProfile({
    String? username,
    String? phone,
    String? avatarUrl,
    String? currentPassword,
    String? newPassword,
  }) async {
    final token = await _getToken();
    if (token == null) return {'success': false, 'message': 'Not signed in'};
    try {
      final response = await http.patch(
        Uri.parse('${await _baseUrl}/users/me/update'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          if (username != null) 'username': username,
          if (phone != null) 'phone': phone,
          if (avatarUrl != null) 'avatar_url': avatarUrl,
          if (currentPassword != null && currentPassword.isNotEmpty)
            'current_password': currentPassword,
          if (newPassword != null && newPassword.isNotEmpty)
            'new_password': newPassword,
        }),
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return {
          'success': true,
          'user': jsonDecode(response.body) as Map<String, dynamic>,
        };
      }
      final body = _tryDecode(response.body);
      return {
        'success': false,
        'message': body?['detail'] ?? 'Could not update profile',
      };
    } catch (e) {
      _logger.e('Update profile exception: $e');
      return {
        'success': false,
        'message': 'Network error. Check your connection.',
      };
    }
  }

  // DELETE ACCOUNT — wipes the account + data on the server, clears local creds.
  Future<Map<String, dynamic>> deleteAccount() async {
    final token = await _getToken();
    if (token == null) return {'success': false, 'message': 'Not signed in'};
    try {
      final response = await http.delete(
        Uri.parse('${await _baseUrl}/users/me'),
        headers: _authHeaders(token),
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          await removeToken();
          await removeRefreshToken();
        } catch (_) {}
        return {'success': true};
      }
      final body = _tryDecode(response.body);
      return {
        'success': false,
        'message': body?['detail'] ?? 'Could not delete account',
      };
    } catch (e) {
      _logger.e('Delete account exception: $e');
      return {
        'success': false,
        'message': 'Network error. Check your connection.',
      };
    }
  }

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
    String content, {
    String? messageType, // text | image | file | audio
    String? mediaUrl, // relative, e.g. /attachments/<id>
    String? mediaName,
    String? mediaMime,
    int? mediaSize,
    int? mediaDuration, // audio length in ms
  }) async {
    try {
      final token = await _getToken();
      if (token == null) throw Exception('No access token');

      final response = await http.post(
        Uri.parse('${await _baseUrl}/messages/'),
        headers: _authHeaders(token),
        body: jsonEncode({
          'receiver_id': receiverId,
          'content': content,
          if (messageType != null) 'message_type': messageType,
          if (mediaUrl != null) 'media_url': mediaUrl,
          if (mediaName != null) 'media_name': mediaName,
          if (mediaMime != null) 'media_mime': mediaMime,
          if (mediaSize != null) 'media_size': mediaSize,
          if (mediaDuration != null) 'media_duration': mediaDuration,
        }),
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

  /// Upload a chat attachment (image / file / voice note). Returns the server's
  /// response: {url: /attachments/<id>, name, mime, size}, or null on failure.
  Future<Map<String, dynamic>?> uploadMedia({
    required List<int> bytes,
    required String filename,
    required String mime,
  }) async {
    try {
      final token = await _getToken();
      if (token == null) throw Exception('No access token');

      final uri = Uri.parse('${await _baseUrl}/upload/media');
      final req = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer $token'
        ..files.add(http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: filename,
          contentType: MediaType.parse(
              mime.isNotEmpty ? mime : 'application/octet-stream'),
        ));

      final streamed = await req.send();
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final data = jsonDecode(resp.body);
        if (data is Map<String, dynamic>) return data;
      }
      _logger.w('Upload media failed: ${resp.statusCode} ${resp.body}');
      return null;
    } catch (e) {
      _logger.e('Upload media exception: $e');
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
        // Return the RAW server timestamp untouched. The UI formats it with
        // parseServerTime()/formatLastSeen(), which correctly treats a naive
        // string as UTC and converts to the device's local zone. Formatting
        // here with DateTime.parse().toLocal() was the 3-hour-off bug: a
        // tz-less string parses as *local*, so toLocal() did nothing and the
        // raw UTC value was shown as if local (−3h in EAT). It also caused a
        // double-format when formatLastSeen re-parsed the pretty string.
        final String? lastSeen = data['last_seen'];

        return {
          'is_online': isOnline,
          'last_seen': lastSeen,
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
