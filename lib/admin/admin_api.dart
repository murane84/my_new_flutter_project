import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'admin_key.dart';

class AdminApiException implements Exception {
  AdminApiException(this.status, this.message);
  final int status;
  final String message;

  @override
  String toString() => message;
}

/// Talks to /admin/api. Every call after sign-in carries the admin session
/// token AND a signature from this device's key over
/// METHOD\nPATH\nTS\nNONCE\nSHA256(BODY) — the server refuses anything else.
/// The session token lives in memory only (a reload means signing in again).
class AdminApi {
  AdminApi._();
  static final AdminApi instance = AdminApi._();

  /// Same origin as the page by default; `--dart-define=ADMIN_API=https://…`
  /// for local development against the live server.
  static const String _override = String.fromEnvironment('ADMIN_API');

  String get origin => _override.isNotEmpty ? _override : Uri.base.origin;

  String? _token;
  bool get signedIn => _token != null;

  /// Fires when the server ends the session (idle, revoked, locked).
  final ValueNotifier<String?> sessionEnded = ValueNotifier<String?>(null);

  DateTime lastInteraction = DateTime.now();
  void touch() => lastInteraction = DateTime.now();
  bool get userIdle =>
      DateTime.now().difference(lastInteraction) > const Duration(minutes: 12);

  final _rnd = Random.secure();
  String _nonce() =>
      List.generate(16, (_) => _rnd.nextInt(256).toRadixString(16).padLeft(2, '0'))
          .join();

  Map<String, dynamic> _decode(http.Response r) {
    Map<String, dynamic> body = {};
    try {
      final d = jsonDecode(utf8.decode(r.bodyBytes));
      if (d is Map<String, dynamic>) body = d;
    } catch (_) {}
    if (r.statusCode >= 400) {
      final detail = body['detail'];
      String msg;
      if (detail is String) {
        msg = detail;
      } else if (detail is List && detail.isNotEmpty) {
        msg = 'Please check the form (${detail.length} problem(s)).';
      } else {
        msg = 'Request failed (${r.statusCode})';
      }
      throw AdminApiException(r.statusCode, msg);
    }
    return body;
  }

  Future<Map<String, dynamic>> _postPlain(
      String path, Map<String, dynamic> body) async {
    final r = await http
        .post(Uri.parse('$origin$path'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body))
        .timeout(const Duration(seconds: 25));
    return _decode(r);
  }

  // ── Sign-in ───────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
    String? deviceName,
    String? bootstrapCode,
    String? recoveryCode,
  }) async {
    final pub = await AdminKey.publicKey();
    return _postPlain('/admin/api/login', {
      'email': email,
      'password': password,
      'public_key': pub,
      if (deviceName != null && deviceName.isNotEmpty) 'device_name': deviceName,
      if (bootstrapCode != null && bootstrapCode.isNotEmpty)
        'bootstrap_code': bootstrapCode,
      if (recoveryCode != null && recoveryCode.isNotEmpty)
        'recovery_code': recoveryCode,
    });
  }

  /// Answers a login challenge with this device's signature → session.
  Future<Map<String, dynamic>> verify(String challengeId, String nonce) async {
    final sig = await AdminKey.sign('login\n$nonce');
    final out = await _postPlain('/admin/api/login/verify',
        {'challenge_id': challengeId, 'signature': sig});
    _token = out['token'] as String?;
    sessionEnded.value = null;
    touch();
    return out;
  }

  Future<String> poll(int deviceId) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final sig = await AdminKey.sign('poll\n$deviceId\n$ts');
    final out = await _postPlain('/admin/api/device/poll',
        {'device_id': deviceId, 'ts': ts, 'signature': sig});
    return (out['status'] ?? 'pending').toString();
  }

  // ── Signed requests ───────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _signed(String method, String path,
      [Map<String, dynamic>? body]) async {
    final token = _token;
    if (token == null) throw AdminApiException(401, 'Please sign in');
    final raw = body == null ? '' : jsonEncode(body);
    final ts = DateTime.now().millisecondsSinceEpoch.toString();
    final nonce = _nonce();
    final hash = await AdminKey.sha256Hex(raw);
    final sig = await AdminKey.sign([method, path, ts, nonce, hash].join('\n'));
    final headers = {
      'Authorization': 'Admin $token',
      'X-Admin-Ts': ts,
      'X-Admin-Nonce': nonce,
      'X-Admin-Sig': sig,
      if (body != null) 'Content-Type': 'application/json',
    };
    final uri = Uri.parse('$origin$path');
    final http.Response r;
    if (method == 'GET') {
      r = await http.get(uri, headers: headers).timeout(const Duration(seconds: 25));
    } else {
      r = await http
          .post(uri, headers: headers, body: raw)
          .timeout(const Duration(seconds: 25));
    }
    try {
      return _decode(r);
    } on AdminApiException catch (e) {
      if (e.status == 401 || e.status == 423) {
        _token = null;
        sessionEnded.value = e.message;
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> get(String path) => _signed('GET', path);

  Future<Map<String, dynamic>> post(String path,
          [Map<String, dynamic>? body]) =>
      _signed('POST', path, body ?? const <String, dynamic>{});

  Future<void> logout() async {
    try {
      await post('/admin/api/logout');
    } catch (_) {}
    _token = null;
  }

  void forget() => _token = null;
}
