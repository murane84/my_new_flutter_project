import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'token_helper.dart';
import '../utils/app_config.dart';

class WebSocketManager {
  final String userId;
  WebSocketChannel? _channel;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 10;
  final void Function(Map<String, dynamic>) onEventReceived;
  final VoidCallback onDisconnected;
  bool _isClosed = false;
  Timer? _heartbeatTimer;

  final Logger _logger = Logger();

  WebSocketManager({
    required this.userId,
    required this.onEventReceived,
    required this.onDisconnected,
  });

  void connect() async {
    if (_isClosed || userId.isEmpty) return;

    try {
      final token = await getToken();
      if (token == null) {
        _logger.e('Cannot connect WebSocket: no token');
        return;
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
      _startHeartbeat();
      _logger.i('WebSocket connected for userId: $userId');
    } catch (e) {
      _logger.e('Failed to connect WebSocket: $e');
      _onDisconnected();
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      try {
        _channel?.sink.add(jsonEncode({'type': 'ping'}));
      } catch (_) {}
    });
  }

  void _onDisconnected() {
    _heartbeatTimer?.cancel();
    if (_isClosed) return;

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
    _heartbeatTimer?.cancel();
    _channel?.sink.close();
    _logger.i('WebSocket closed');
  }
}
