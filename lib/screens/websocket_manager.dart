import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'token_helper.dart';
import 'api_service.dart';
import '../utils/app_config.dart';
import '../utils/session_events.dart';

class WebSocketManager {
  final String userId;
  WebSocketChannel? _channel;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 10;

  // Close code the server sends (see /ws/{user_id} and /live/ws) when it rejects
  // the JWT — missing, invalid, expired, or not matching this user. Handled
  // specially below: refresh the access token and retry, instead of looping
  // with the same stale token.
  static const int _authFailedCloseCode = 4401;

  final void Function(Map<String, dynamic>) onEventReceived;
  final VoidCallback onDisconnected;
  // Fired after each successful (re)connect. The chat uses it to run ONE
  // reconciliation fetch and catch up on anything missed while the socket was
  // down. Optional, so existing callers (e.g. HomePage) are unaffected.
  final VoidCallback? onConnected;
  bool _isClosed = false;

  // Live-connection tracking so ensureConnected() can revive a dead socket
  // without ever opening a second one alongside a healthy connection.
  bool _connected = false;
  bool _connecting = false;
  bool get isConnected => _connected;

  Timer? _heartbeatTimer;

  final ApiService _api = ApiService();
  final Logger _logger = Logger();

  WebSocketManager({
    required this.userId,
    required this.onEventReceived,
    required this.onDisconnected,
    this.onConnected,
  });

  void connect() async {
    // Already up or mid-handshake? Don't stack a second socket on top.
    if (_isClosed || userId.isEmpty || _connecting || _connected) return;
    _connecting = true;

    try {
      var token = await getToken();
      if (token == null || token.isEmpty) {
        // No cached access token (cleared, or a cold start where only the
        // long-lived refresh token survives). Try a silent refresh before
        // giving up — standard chat-app behaviour so the user isn't bounced.
        if (await _api.refreshAccessToken()) {
          token = await getToken();
        }
        if (token == null || token.isEmpty) {
          _logger.e('Cannot connect WebSocket: no token');
          // Only a definitive refresh rejection means the session is truly
          // over; a transient failure is left to normal reconnect attempts.
          if (_api.refreshWasRejected) {
            _isClosed = true;
            SessionEvents.instance.markExpired();
            onDisconnected();
          }
          return;
        }
      }

      final wsBase = await AppConfig.wsBaseUrl;
      final uri = Uri.parse(
        '$wsBase/ws/$userId',
      ).replace(queryParameters: {'token': token});

      _logger.i('Connecting to WebSocket: $uri');
      _channel = WebSocketChannel.connect(uri);

      _channel!.stream.listen(
        (rawMessage) {
          try {
            final event = jsonDecode(rawMessage as String);
            if (event is Map<String, dynamic>) {
              onEventReceived(event);
            }
          } catch (e) {
            _logger.e('Error parsing WS event: $e');
          }
        },
        onDone: _onDisconnected,
        onError: (error) {
          _logger.e('WebSocket error: $error');
          _onDisconnected();
        },
        cancelOnError: true,
      );

      _reconnectAttempts = 0;
      _connected = true;
      _startHeartbeat();
      _logger.i('WebSocket connected for userId: $userId');
      // A fresh realtime link — let the listener reconcile anything missed
      // while the socket was down.
      onConnected?.call();
    } catch (e) {
      _logger.e('Failed to connect WebSocket: $e');
      _onDisconnected();
    } finally {
      // Whatever happened (connected, early no-token return, or error), we're
      // no longer mid-handshake — clear the guard so a later revive can retry.
      _connecting = false;
    }
  }

  /// Revive the socket if it isn't currently up. Safe to call repeatedly and
  /// while already connected — it no-ops unless the connection is actually
  /// down, so it never spawns a second socket alongside a healthy one.
  void ensureConnected() {
    if (!_isClosed && !_connected && !_connecting) connect();
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      try {
        _channel?.sink.add(jsonEncode({'type': 'ping'}));
      } catch (_) {}
    });
  }

  void _onDisconnected() async {
    _heartbeatTimer?.cancel();
    _connected = false;
    if (_isClosed) return;

    // Did the server reject our JWT? The access token is short-lived, so after
    // an idle spell the reconnect handshake comes back 4401. Silently mint a
    // fresh access token from the refresh token and retry immediately — the
    // user never sees it. Only if the refresh token itself is rejected do we
    // treat the session as genuinely expired and hand off to login.
    if (_channel?.closeCode == _authFailedCloseCode) {
      final refreshed = await _api.refreshAccessToken();
      if (_isClosed) return;
      if (refreshed) {
        _reconnectAttempts = 0; // clean slate — new token
        connect();
        return;
      }
      if (_api.refreshWasRejected) {
        _isClosed = true;
        _logger.w('WebSocket auth rejected and refresh failed — session expired');
        SessionEvents.instance.markExpired();
        onDisconnected();
        return;
      }
      // Transient refresh failure (network) — fall through to backoff retry.
    }

    if (_reconnectAttempts < _maxReconnectAttempts) {
      final delay = Duration(
        seconds: min(30, pow(2, _reconnectAttempts).toInt()),
      );
      _reconnectAttempts++;
      _logger.w(
        'Reconnecting ($_reconnectAttempts/$_maxReconnectAttempts) in ${delay.inSeconds}s...',
      );
      Future.delayed(delay, connect);
    } else {
      _logger.e('Max reconnection attempts reached');
      onDisconnected();
    }
  }

  void sendEvent(Map<String, dynamic> event) {
    try {
      _channel?.sink.add(jsonEncode(event));
    } catch (e) {
      _logger.w('Failed to send WS event: $e');
    }
  }

  void close() {
    _isClosed = true;
    _connected = false;
    _heartbeatTimer?.cancel();
    _channel?.sink.close();
    _logger.i('WebSocket closed');
  }
}
