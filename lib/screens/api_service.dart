import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;
import 'package:logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'token_helper.dart';
import 'user.dart';
import '../utils/app_config.dart';
import '../utils/session_events.dart';
import '../services/biometric_service.dart';

final _logger = Logger();

class ApiService {
  Future<String> get _baseUrl => AppConfig.baseUrl;

  Map<String, String> _authHeaders(String token) => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };

  // Delegates to the platform-aware token store (web-safe).
  Future<String?> _getToken() async => getToken();

  String _platformName() {
    if (kIsWeb) return 'web';
    return defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
  }

  /// Register this device's FCM token so the backend can push
  /// message/call notifications when the app is backgrounded or closed.
  Future<bool> saveDeviceToken(String token) async {
    try {
      final t = await _getToken();
      if (t == null) return false;
      final resp = await http.post(
        Uri.parse('${await _baseUrl}/devices/token'),
        headers: _authHeaders(t),
        body: jsonEncode({'token': token, 'platform': _platformName()}),
      );
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      _logger.e('saveDeviceToken exception: $e');
      return false;
    }
  }

  /// Unregister this device's FCM token (on logout) so it stops receiving the
  /// account's pushes. Best-effort.
  Future<void> deleteDeviceToken(String token) async {
    try {
      final t = await _getToken();
      if (t == null) return;
      await http.delete(
        Uri.parse('${await _baseUrl}/devices/token'),
        headers: _authHeaders(t),
        body: jsonEncode({'token': token}),
      );
    } catch (e) {
      _logger.e('deleteDeviceToken exception: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Two-factor authentication + password recovery (TOTP / Google Authenticator)
  // ---------------------------------------------------------------------------

  /// Whether authenticator 2FA is currently enabled for the signed-in user.
  Future<bool> twoFactorStatus() async {
    try {
      final t = await _getToken();
      if (t == null) return false;
      final resp = await http.get(
        Uri.parse('${await _baseUrl}/auth/2fa/status'),
        headers: _authHeaders(t),
      );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return (_tryDecode(resp.body)?['enabled'] ?? false) == true;
      }
    } catch (e) {
      _logger.e('twoFactorStatus exception: $e');
    }
    return false;
  }

  /// Begin authenticator enrollment. Returns {secret, otpauth_uri} to render as
  /// a QR. Not active until [twoFactorVerify] confirms a code.
  Future<Map<String, dynamic>> twoFactorSetup() async {
    try {
      final t = await _getToken();
      if (t == null) {
        return {'success': false, 'message': 'Please sign in again.'};
      }
      final resp = await http.post(
        Uri.parse('${await _baseUrl}/auth/2fa/setup'),
        headers: _authHeaders(t),
      );
      final body = _tryDecode(resp.body);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return {
          'success': true,
          'secret': body?['secret'] ?? '',
          'otpauth_uri': body?['otpauth_uri'] ?? '',
        };
      }
      return {
        'success': false,
        'message': body?['detail'] ?? 'Could not start setup.',
      };
    } catch (e) {
      _logger.e('twoFactorSetup exception: $e');
      return {'success': false, 'message': 'Network error. Check your connection.'};
    }
  }

  /// Confirm the first authenticator code, turning 2FA on.
  Future<Map<String, dynamic>> twoFactorVerify(String code) async {
    try {
      final t = await _getToken();
      if (t == null) {
        return {'success': false, 'message': 'Please sign in again.'};
      }
      final resp = await http.post(
        Uri.parse('${await _baseUrl}/auth/2fa/verify'),
        headers: _authHeaders(t),
        body: jsonEncode({'code': code}),
      );
      final body = _tryDecode(resp.body);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return {'success': true};
      }
      return {
        'success': false,
        'message': body?['detail'] ?? 'Invalid or expired code.',
      };
    } catch (e) {
      _logger.e('twoFactorVerify exception: $e');
      return {'success': false, 'message': 'Network error. Check your connection.'};
    }
  }

  /// Turn 2FA off — prove ownership with a current [code] OR the account
  /// [password].
  Future<Map<String, dynamic>> twoFactorDisable({
    String? code,
    String? password,
  }) async {
    try {
      final t = await _getToken();
      if (t == null) {
        return {'success': false, 'message': 'Please sign in again.'};
      }
      final resp = await http.post(
        Uri.parse('${await _baseUrl}/auth/2fa/disable'),
        headers: _authHeaders(t),
        body: jsonEncode({
          if (code != null && code.isNotEmpty) 'code': code,
          if (password != null && password.isNotEmpty) 'password': password,
        }),
      );
      final body = _tryDecode(resp.body);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return {'success': true};
      }
      return {
        'success': false,
        'message': body?['detail'] ?? 'Could not turn off 2FA.',
      };
    } catch (e) {
      _logger.e('twoFactorDisable exception: $e');
      return {'success': false, 'message': 'Network error. Check your connection.'};
    }
  }

  /// Ask the backend to email a password-reset code. Always resolves to a
  /// generic success (the server never reveals whether the email exists).
  Future<Map<String, dynamic>> requestEmailResetCode(String email) async {
    try {
      final resp = await http.post(
        Uri.parse('${await _baseUrl}/auth/password-reset/request'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email}),
      );
      final body = _tryDecode(resp.body);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return {
          'success': true,
          'message': body?['message'] ?? 'If that email is registered, a code was sent.',
        };
      }
      return {
        'success': false,
        'message': body?['detail'] ?? 'Could not send a code right now.',
      };
    } catch (e) {
      _logger.e('requestEmailResetCode exception: $e');
      return {'success': false, 'message': 'Network error. Check your connection.'};
    }
  }

  /// Reset a FORGOTTEN password using the emailed code.
  Future<Map<String, dynamic>> resetPasswordWithEmailCode({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    try {
      final resp = await http.post(
        Uri.parse('${await _baseUrl}/auth/password-reset/confirm'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'code': code,
          'new_password': newPassword,
        }),
      );
      final body = _tryDecode(resp.body);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return {
          'success': true,
          'message': body?['message'] ?? 'Password updated.',
        };
      }
      return {
        'success': false,
        'message': body?['detail'] ?? 'Invalid or expired code.',
      };
    } catch (e) {
      _logger.e('resetPasswordWithEmailCode exception: $e');
      return {'success': false, 'message': 'Network error. Check your connection.'};
    }
  }

  /// Reset a FORGOTTEN password using the authenticator code (no auth token
  /// needed — the code is the proof of ownership).
  Future<Map<String, dynamic>> resetPasswordWithTotp({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    try {
      final resp = await http.post(
        Uri.parse('${await _baseUrl}/auth/password-reset'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'code': code,
          'new_password': newPassword,
        }),
      );
      final body = _tryDecode(resp.body);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return {
          'success': true,
          'message': body?['message'] ?? 'Password updated.',
        };
      }
      return {
        'success': false,
        'message': body?['detail'] ?? 'Could not reset password.',
      };
    } catch (e) {
      _logger.e('resetPasswordWithTotp exception: $e');
      return {'success': false, 'message': 'Network error. Check your connection.'};
    }
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

  // ── QR device linking (log the desktop app in from the phone) ──────────────

  /// Desktop: start a QR-login handshake. Returns {code, pair_code, expires_in}.
  Future<Map<String, dynamic>?> createLoginLink(
      {String? label, String? platform}) async {
    try {
      final resp = await http.post(
        Uri.parse('${await _baseUrl}/auth/link/new'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'label': ?label,
          'platform': ?platform,
        }),
      );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final data = jsonDecode(resp.body);
        if (data is Map<String, dynamic>) return data;
      }
      return null;
    } catch (e) {
      _logger.e('createLoginLink exception: $e');
      return null;
    }
  }

  /// Desktop: poll a handshake. Returns {status: pending|approved|expired, ...}.
  /// On "approved" it also saves the returned tokens locally (like a login).
  Future<Map<String, dynamic>?> pollLoginLink(String code) async {
    try {
      final resp = await http.get(
        Uri.parse('${await _baseUrl}/auth/link/poll')
            .replace(queryParameters: {'code': code}),
        headers: {'Content-Type': 'application/json'},
      );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final data = jsonDecode(resp.body);
        if (data is Map<String, dynamic>) {
          if (data['status'] == 'approved') {
            final t = (data['access_token'] ?? '').toString();
            final r = (data['refresh_token'] ?? '').toString();
            if (t.isNotEmpty) await saveToken(t);
            if (r.isNotEmpty) await saveRefreshToken(r);
          }
          return data;
        }
      }
      return {'status': 'error'};
    } catch (e) {
      _logger.e('pollLoginLink exception: $e');
      return {'status': 'error'};
    }
  }

  /// Phone (signed in): authorise a desktop link by scanned code or typed pair.
  Future<bool> approveLoginLink({String? code, String? pairCode}) async {
    try {
      final token = await _getToken();
      if (token == null) return false;
      final resp = await http.post(
        Uri.parse('${await _baseUrl}/auth/link/approve'),
        headers: _authHeaders(token),
        body: jsonEncode({
          'code': ?code,
          'pair_code': ?pairCode,
        }),
      );
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      _logger.e('approveLoginLink exception: $e');
      return false;
    }
  }

  /// Phone: upload the saved-name map so the desktop can personalise names.
  Future<bool> uploadContactNames(Map<String, String> names) async {
    try {
      final token = await _getToken();
      if (token == null) return false;
      final resp = await http.post(
        Uri.parse('${await _baseUrl}/users/contacts/names'),
        headers: _authHeaders(token),
        body: jsonEncode({'names': names}),
      );
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      _logger.e('uploadContactNames exception: $e');
      return false;
    }
  }

  /// List the account's linked-device sessions (for the Linked-devices screen).
  Future<List<Map<String, dynamic>>> listDevices() async {
    try {
      final token = await _getToken();
      if (token == null) return [];
      final resp = await http.get(
        Uri.parse('${await _baseUrl}/auth/devices'),
        headers: _authHeaders(token),
      );
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body);
        if (body is List) return body.whereType<Map<String, dynamic>>().toList();
      }
      return [];
    } catch (e) {
      _logger.e('listDevices exception: $e');
      return [];
    }
  }

  /// Sign a linked device out remotely.
  Future<bool> revokeDevice(int deviceId) async {
    try {
      final token = await _getToken();
      if (token == null) return false;
      final resp = await http.post(
        Uri.parse('${await _baseUrl}/auth/devices/$deviceId/revoke'),
        headers: _authHeaders(token),
      );
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      _logger.e('revokeDevice exception: $e');
      return false;
    }
  }

  /// Desktop: download the user's saved-name map after QR login.
  Future<Map<String, String>> fetchContactNames() async {
    try {
      final token = await _getToken();
      if (token == null) return {};
      final resp = await http.get(
        Uri.parse('${await _baseUrl}/users/contacts/names'),
        headers: _authHeaders(token),
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final m = (data is Map) ? data['names'] : null;
        if (m is Map) {
          return m.map((k, v) => MapEntry(k.toString(), v.toString()));
        }
      }
      return {};
    } catch (e) {
      _logger.e('fetchContactNames exception: $e');
      return {};
    }
  }

  /// Back up the user's edited song details (path → {t,a,al,g,y}) to their
  /// account so they survive a reinstall/update or a new device. Full-map
  /// replace — the client only calls this after pulling+merging the server copy.
  Future<bool> uploadTrackOverrides(Map<String, dynamic> overrides) async {
    try {
      final token = await _getToken();
      if (token == null) return false;
      final resp = await http.post(
        Uri.parse('${await _baseUrl}/users/track-overrides'),
        headers: _authHeaders(token),
        body: jsonEncode({'overrides': overrides}),
      );
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      _logger.e('uploadTrackOverrides exception: $e');
      return false;
    }
  }

  /// Fetch the account's backed-up song-detail edits after login. Returns a
  /// map of track path → compact meta map ({t,a,al,g,y}).
  Future<Map<String, Map<String, dynamic>>> fetchTrackOverrides() async {
    try {
      final token = await _getToken();
      if (token == null) return {};
      final resp = await http.get(
        Uri.parse('${await _baseUrl}/users/track-overrides'),
        headers: _authHeaders(token),
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final m = (data is Map) ? data['overrides'] : null;
        if (m is Map) {
          final out = <String, Map<String, dynamic>>{};
          m.forEach((k, v) {
            if (v is Map) {
              out[k.toString()] = v.cast<String, dynamic>();
            }
          });
          return out;
        }
      }
      return {};
    } catch (e) {
      _logger.e('fetchTrackOverrides exception: $e');
      return {};
    }
  }

  // LOGOUT
  Future<void> logoutUser() async {
    // If biometric quick-unlock is enrolled, KEEP the enrollment + refresh token
    // so the user can fingerprint straight back in on their own device (the
    // login screen shows a fingerprint button). Without biometric, signing out
    // is a full wipe. The access token is always cleared either way.
    final keepForBiometric = await BiometricService.instance.isEnabled();
    try {
      final token = await _getToken();
      if (token != null) {
        // Always flag offline.
        await http.post(
          Uri.parse('${await _baseUrl}/users/me/online?is_online=false'),
          headers: _authHeaders(token),
        );
        // Full server logout can revoke the refresh token, so only call it when
        // we are NOT keeping that token for fingerprint re-login.
        if (!keepForBiometric) {
          await http.post(
            Uri.parse('${await _baseUrl}/logout'),
            headers: _authHeaders(token),
          );
        }
      }
      await removeToken();
      if (!keepForBiometric) await removeRefreshToken();
    } catch (e) {
      _logger.e('Logout exception: $e');
      await removeToken();
      if (!keepForBiometric) await removeRefreshToken();
    }
  }

  // ── Silent token refresh ────────────────────────────────────────────────
  // Exchanges the long-lived refresh token for a fresh access token so an
  // expired access token is invisible to the user. Returns true on success.
  // True only when /auth/refresh EXPLICITLY rejects the refresh token (401/403)
  // — i.e. the session is genuinely dead. Network errors / transient failures
  // leave it false, so a blip never signs the user out.
  bool _refreshRejected = false;
  bool get refreshWasRejected => _refreshRejected;

  Future<bool> refreshAccessToken() async {
    _refreshRejected = false;
    try {
      final refresh = await getRefreshToken();
      if (refresh == null || refresh.isEmpty) {
        _refreshRejected = true; // nothing to refresh with → truly need re-login
        return false;
      }
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
        return false; // odd 2xx without a token — treat as transient
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        _refreshRejected = true; // server definitively rejected the token
      }
      return false;
    } catch (_) {
      return false; // network/transient — NOT a reason to log out
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
          if (refreshWasRejected) SessionEvents.instance.markExpired();
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
        if (refreshWasRejected) SessionEvents.instance.markExpired();
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
          'username': ?username,
          'phone': ?phone,
          'avatar_url': ?avatarUrl,
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
  /// Pin a message for [hours] hours. Returns the updated message map (with
  /// its new `pinned_until`) on success, or null on failure.
  Future<Map<String, dynamic>?> pinMessage(int messageId, int hours) async {
    try {
      final token = await _getToken();
      if (token == null) return null;
      final uri = Uri.parse('${await _baseUrl}/messages/$messageId/pin')
          .replace(queryParameters: {'hours': hours.toString()});
      final res = await http.post(uri, headers: _authHeaders(token));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final body = jsonDecode(res.body);
        if (body is Map<String, dynamic>) return body;
      }
    } catch (_) {}
    return null;
  }

  /// Remove the pin from a message. Returns true on success.
  Future<bool> unpinMessage(int messageId) async {
    try {
      final token = await _getToken();
      if (token == null) return false;
      final uri = Uri.parse('${await _baseUrl}/messages/$messageId/unpin');
      final res = await http.post(uri, headers: _authHeaders(token));
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

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
    int? conversationId, // when set → send to a GROUP conversation instead of a DM
  }) async {
    try {
      final token = await _getToken();
      if (token == null) throw Exception('No access token');

      // Group send: POST to the conversation (no receiver_id — the members are
      // the recipients). DM send stays on the legacy /messages/ path unchanged.
      final Uri uri = conversationId != null
          ? Uri.parse('${await _baseUrl}/conversations/$conversationId/messages')
          : Uri.parse('${await _baseUrl}/messages/');
      final Map<String, dynamic> payload = {
        'content': content,
        'message_type': ?messageType,
        'media_url': ?mediaUrl,
        'media_name': ?mediaName,
        'media_mime': ?mediaMime,
        'media_size': ?mediaSize,
        'media_duration': ?mediaDuration,
      };
      if (conversationId == null) payload['receiver_id'] = receiverId;

      final response = await http.post(
        uri,
        headers: _authHeaders(token),
        body: jsonEncode(payload),
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

  /// Match device address-book phone numbers against registered Aluta users;
  /// the server auto-adds matches as friends. Returns {matched:[users], added:N}.
  Future<Map<String, dynamic>> syncContacts(List<String> phones) async {
    try {
      final token = await _getToken();
      if (token == null) return {'matched': [], 'added': 0};
      final resp = await http.post(
        Uri.parse('${await _baseUrl}/users/contacts/sync'),
        headers: _authHeaders(token),
        body: jsonEncode({'phones': phones}),
      );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final data = _tryDecode(resp.body);
        if (data != null) return data;
      }
      _logger.w('syncContacts failed: ${resp.statusCode}');
      return {'matched': [], 'added': 0};
    } catch (e) {
      _logger.e('syncContacts exception: $e');
      return {'matched': [], 'added': 0};
    }
  }

  // ---------------------------------------------------------------------------
  // Group conversations (DMs keep using the legacy /messages endpoints above)
  // ---------------------------------------------------------------------------

  /// All my conversations (groups + DMs) with last-message + unread, newest
  /// first. Returns raw maps (see ConversationOut on the server).
  Future<List<Map<String, dynamic>>> listConversations() async {
    try {
      final token = await _getToken();
      if (token == null) return [];
      final resp = await http.get(
        Uri.parse('${await _baseUrl}/conversations'),
        headers: _authHeaders(token),
      );
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body);
        if (body is List) return body.whereType<Map<String, dynamic>>().toList();
      }
      return [];
    } catch (e) {
      _logger.e('listConversations exception: $e');
      return [];
    }
  }

  /// Create a group. Returns the created conversation map, or null.
  Future<Map<String, dynamic>?> createGroup(
    String title,
    List<int> memberIds, {
    String? avatarUrl,
  }) async {
    try {
      final token = await _getToken();
      if (token == null) return null;
      final resp = await http.post(
        Uri.parse('${await _baseUrl}/conversations/group'),
        headers: _authHeaders(token),
        body: jsonEncode({
          'title': title,
          'member_ids': memberIds,
          'avatar_url': ?avatarUrl,
        }),
      );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final data = jsonDecode(resp.body);
        if (data is Map<String, dynamic>) return data;
      }
      _logger.w('createGroup failed: ${resp.statusCode} ${resp.body}');
      return null;
    } catch (e) {
      _logger.e('createGroup exception: $e');
      return null;
    }
  }

  /// One conversation's details (members, title, my role, …).
  Future<Map<String, dynamic>?> getConversation(int cid) async {
    try {
      final token = await _getToken();
      if (token == null) return null;
      final resp = await http.get(
        Uri.parse('${await _baseUrl}/conversations/$cid'),
        headers: _authHeaders(token),
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data is Map<String, dynamic>) return data;
      }
      return null;
    } catch (e) {
      _logger.e('getConversation exception: $e');
      return null;
    }
  }

  /// Whether a GROUP call is currently active in [cid] (a member is in the
  /// room). Used to show the "call in progress · Join" banner when a group is
  /// opened, so someone who missed/declined the ring can still reconnect.
  /// Returns {'active': bool, 'title': String, 'count': int} or null on error.
  Future<Map<String, dynamic>?> getGroupCallState(int cid) async {
    try {
      final token = await _getToken();
      if (token == null) return null;
      final resp = await http.get(
        Uri.parse('${await _baseUrl}/conversations/$cid/call'),
        headers: _authHeaders(token),
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data is Map<String, dynamic>) return data;
      }
      return null;
    } catch (e) {
      _logger.e('getGroupCallState exception: $e');
      return null;
    }
  }

  /// Decline a "listen together" invite: stops the server re-delivering it to us
  /// and notifies the host so they can end or keep waiting. Best-effort.
  Future<void> declineLiveSession(String sessionId) async {
    try {
      final token = await _getToken();
      if (token == null) return;
      await http.post(
        Uri.parse('${await _baseUrl}/live/sessions/$sessionId/decline'),
        headers: _authHeaders(token),
      );
    } catch (e) {
      _logger.w('declineLiveSession exception: $e');
    }
  }

  /// A page of a conversation's messages (same shape as DM messages).
  Future<List<Map<String, dynamic>>> fetchConversationMessages(
    int cid, {
    int skip = 0,
    int limit = 60,
  }) async {
    try {
      final token = await _getToken();
      if (token == null) return [];
      final uri = Uri.parse('${await _baseUrl}/conversations/$cid/messages')
          .replace(queryParameters: {
        'skip': skip.toString(),
        'limit': limit.toString(),
      });
      final resp = await http.get(uri, headers: _authHeaders(token));
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body);
        if (body is List) return body.whereType<Map<String, dynamic>>().toList();
      }
      return [];
    } catch (e) {
      _logger.e('fetchConversationMessages exception: $e');
      return [];
    }
  }

  /// Mark a conversation read (up to a message id, or all).
  Future<void> markConversationRead(int cid, {int? messageId}) async {
    try {
      final token = await _getToken();
      if (token == null) return;
      await http.patch(
        Uri.parse('${await _baseUrl}/conversations/$cid/read'),
        headers: _authHeaders(token),
        body: jsonEncode({'message_id': ?messageId}),
      );
    } catch (e) {
      _logger.e('markConversationRead exception: $e');
    }
  }

  /// Who has read a given group message (for a 'seen by' sheet).
  Future<List<Map<String, dynamic>>> conversationSeenBy(
      int cid, int messageId) async {
    try {
      final token = await _getToken();
      if (token == null) return [];
      final resp = await http.get(
        Uri.parse(
            '${await _baseUrl}/conversations/$cid/messages/$messageId/seen'),
        headers: _authHeaders(token),
      );
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body);
        if (body is List) return body.whereType<Map<String, dynamic>>().toList();
      }
      return [];
    } catch (e) {
      _logger.e('conversationSeenBy exception: $e');
      return [];
    }
  }

  /// Shazam-style recognition: upload a short mic clip; the backend asks AudD to
  /// identify it and returns {matched, title, artist, album, artwork, links…}.
  /// Returns {matched:false, error:'not_configured'} if the server has no key,
  /// or null on a transport failure.
  Future<Map<String, dynamic>?> recognizeSong({
    required List<int> bytes,
    String filename = 'clip.m4a',
    String mime = 'audio/mp4',
  }) async {
    try {
      final token = await _getToken();
      if (token == null) return null;
      final uri = Uri.parse('${await _baseUrl}/recognize');
      final req = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer $token'
        ..files.add(http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: filename,
          contentType: MediaType.parse(mime),
        ));
      final streamed = await req.send();
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final data = jsonDecode(resp.body);
        if (data is Map<String, dynamic>) return data;
        return {'matched': false};
      }
      if (resp.statusCode == 503) {
        return {'matched': false, 'error': 'not_configured'};
      }
      return null;
    } catch (e) {
      _logger.e('recognizeSong exception: $e');
      return null;
    }
  }

  /// WhatsApp-style message info: three buckets (read / delivered / sent) of the
  /// group's other members for one sent message. Returns null on failure.
  Future<Map<String, dynamic>?> messageInfo(int cid, int messageId) async {
    try {
      final token = await _getToken();
      if (token == null) return null;
      final resp = await http.get(
        Uri.parse(
            '${await _baseUrl}/conversations/$cid/messages/$messageId/info'),
        headers: _authHeaders(token),
      );
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body);
        if (body is Map<String, dynamic>) return body;
      }
      return null;
    } catch (e) {
      _logger.e('messageInfo exception: $e');
      return null;
    }
  }

  Future<bool> addGroupMembers(int cid, List<int> userIds) async {
    return _convAction('POST', '/conversations/$cid/members',
        body: {'user_ids': userIds});
  }

  Future<bool> removeGroupMember(int cid, int userId) async {
    return _convAction('DELETE', '/conversations/$cid/members/$userId');
  }

  Future<bool> leaveConversation(int cid) async {
    return _convAction('POST', '/conversations/$cid/leave');
  }

  Future<bool> renameGroup(int cid, String title) =>
      updateGroup(cid, title: title);

  /// Update group settings (name and/or avatar). Admin only (server-enforced).
  Future<bool> updateGroup(int cid, {String? title, String? avatarUrl}) async {
    return _convAction('PATCH', '/conversations/$cid', body: {
      'title': ?title,
      'avatar_url': ?avatarUrl,
    });
  }

  Future<bool> _convAction(String method, String path,
      {Map<String, dynamic>? body}) async {
    try {
      final token = await _getToken();
      if (token == null) return false;
      final uri = Uri.parse('${await _baseUrl}$path');
      final headers = _authHeaders(token);
      final encoded = body == null ? null : jsonEncode(body);
      late final http.Response resp;
      switch (method) {
        case 'POST':
          resp = await http.post(uri, headers: headers, body: encoded);
          break;
        case 'PATCH':
          resp = await http.patch(uri, headers: headers, body: encoded);
          break;
        case 'DELETE':
          resp = await http.delete(uri, headers: headers, body: encoded);
          break;
        default:
          resp = await http.get(uri, headers: headers);
      }
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      _logger.e('_convAction $method $path exception: $e');
      return false;
    }
  }

  /// Upload a chat attachment (image / file / voice note). Returns the server's
  /// response: `{url: /attachments/<id>, name, mime, size}`, or null on failure.
  ///
  /// Pass `ephemeral: true` for a shared song: the server marks the bytes for
  /// early purge (removed once the recipient caches the file locally and acks
  /// via [ackAttachmentCached], or after a 7-day TTL), keeping only a reference.
  Future<Map<String, dynamic>?> uploadMedia({
    required List<int> bytes,
    required String filename,
    required String mime,
    bool ephemeral = false,
  }) async {
    try {
      final token = await _getToken();
      if (token == null) throw Exception('No access token');

      var uri = Uri.parse('${await _baseUrl}/upload/media');
      if (ephemeral) {
        uri = uri.replace(queryParameters: {'ephemeral': 'true'});
      }
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

  /// Tell the server that an ephemeral shared song (`/attachments/<id>`) is now
  /// cached on this device. The server purges its copy of the bytes and keeps
  /// only the reference row. Idempotent + best-effort — returns true on success.
  Future<bool> ackAttachmentCached(String assetId) async {
    try {
      final token = await _getToken();
      if (token == null) return false;
      final resp = await http.post(
        Uri.parse('${await _baseUrl}/attachments/$assetId/cached'),
        headers: _authHeaders(token),
      );
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      _logger.e('ackAttachmentCached exception: $e');
      return false;
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
