import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Bridges Aluta's WebRTC voice/group calls to Android's self-managed Telecom
/// stack, so a car head-unit or Bluetooth device sees each call as a real call
/// — its answer/end button works and call audio routes over the hands-free
/// profile.
///
/// Fully ADDITIVE and guarded: a no-op on non-Android platforms, and if the
/// device rejects self-managed calls (some MIUI ROMs) every method quietly does
/// nothing, leaving the existing in-app call flow untouched. The system-driven
/// answer/end events are surfaced through [onAnswer] / [onDisconnect]; the app
/// wires those to the real WebRTC accept/hangup.
class TelecomService {
  TelecomService._();
  static final TelecomService instance = TelecomService._();

  static const MethodChannel _ch = MethodChannel('aluta/telecom');

  bool _registered = false;

  /// The system asked to answer / end the active call (car or BT button).
  void Function(String callId)? onAnswer;
  void Function(String callId)? onDisconnect;

  bool get _android => !kIsWeb && Platform.isAndroid;
  bool get isReady => _registered;

  /// Register the self-managed phone account. Call once at startup.
  Future<void> init() async {
    if (!_android) return;
    _ch.setMethodCallHandler(_onNativeCall);
    try {
      final ok = await _ch.invokeMethod<bool>('register');
      _registered = ok == true;
    } catch (_) {
      _registered = false;
    }
  }

  Future<void> _onNativeCall(MethodCall call) async {
    final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? const {};
    final id = (args['callId'] ?? '').toString();
    switch (call.method) {
      case 'answer':
        onAnswer?.call(id);
        break;
      case 'disconnect':
      case 'reject':
        onDisconnect?.call(id);
        break;
      // 'mute' / 'unmute' arrive too, but the app manages mute itself.
    }
  }

  Future<void> reportIncoming(String callId, String name) async {
    if (!_android || !_registered) return;
    try {
      await _ch.invokeMethod('reportIncoming', {'callId': callId, 'name': name});
    } catch (_) {/* device rejected self-managed call — in-app flow still works */}
  }

  Future<void> startOutgoing(String callId, String name) async {
    if (!_android || !_registered) return;
    try {
      await _ch.invokeMethod('startOutgoing', {'callId': callId, 'name': name});
    } catch (_) {}
  }

  Future<void> setActive(String callId) async {
    if (!_android || !_registered) return;
    try {
      await _ch.invokeMethod('setActive', {'callId': callId});
    } catch (_) {}
  }

  Future<void> endCall(String callId) async {
    if (!_android || !_registered) return;
    try {
      await _ch.invokeMethod('endCall', {'callId': callId});
    } catch (_) {}
  }
}
