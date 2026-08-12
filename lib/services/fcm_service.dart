import 'package:flutter/foundation.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'notif_service.dart';
import '../screens/api_service.dart';

/// Whether Firebase Cloud Messaging is supported on this platform. FCM only has
/// an Android/iOS implementation in this app — on web / Windows / Linux every
/// call is a no-op (and touching FirebaseMessaging there would throw).
bool get fcmSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Turn an FCM data payload into a local notification. Shared by the foreground
/// listener (below) and the background isolate handler (in main.dart), so a
/// message/call is shown the same way whether the app is open, backgrounded, or
/// terminated. The server sends DATA-only pushes, so the client always controls
/// how they're displayed.
Future<void> handleFcmData(Map<String, dynamic> data) async {
  try {
    final type = (data['type'] ?? '').toString();
    if (type == 'call_offer') {
      final caller = (data['caller_name'] ?? 'Someone').toString();
      final callerId = (data['caller_id'] ?? '').toString();
      await showCallNotification(
        caller: caller,
        callerId: callerId.isEmpty ? null : callerId,
      );
    } else if (type == 'group_call') {
      final caller = (data['caller_name'] ?? 'Someone').toString();
      final title = (data['title'] ?? 'Group').toString();
      final room = int.tryParse((data['room'] ?? '').toString());
      await showCallNotification(
        caller: '$caller · $title',
        isGroup: true,
        room: room,
      );
    } else if (type == 'live_invite') {
      // "Listen together" invite while the app was closed/backgrounded. Show a
      // heads-up so the user opens the app; on open, the notification socket
      // reconnects and the server re-delivers the invite → the prompt appears.
      final host = (data['host_username'] ?? 'Someone').toString();
      await showMessageNotification(
        title: '$host · Listen together',
        body: 'wants to listen to music with you',
      );
    } else if (type == 'call_end' ||
        type == 'call_cancel' ||
        type == 'call_decline' ||
        type == 'call_busy') {
      // The caller hung up / the call ended: stop the ringing notification on a
      // killed callee's phone so it doesn't keep ringing.
      await cancelCallNotification();
    } else {
      final title = (data['sender_name'] ?? 'New message').toString();
      final body = (data['body'] ?? '').toString();
      final senderId = (data['sender_id'] ?? '').toString();
      await showMessageNotification(
        title: title,
        body: body.isEmpty ? 'Sent you a message' : body,
        // Lets a tap open the sender's thread directly (not just the chat list).
        senderId: senderId.isEmpty ? null : senderId,
        senderName: title,
      );
    }
  } catch (_) {/* best-effort */}
}

class FcmService {
  FcmService._();
  static final FcmService instance = FcmService._();

  bool _inited = false;

  /// Request permission + wire the foreground / tap / token-refresh handlers.
  /// Safe to call more than once. Firebase must already be initialised (main).
  Future<void> init() async {
    if (_inited || !fcmSupported) return;
    _inited = true;
    try {
      final fm = FirebaseMessaging.instance;
      await fm.requestPermission(alert: true, badge: true, sound: true);
      // Foreground: Android doesn't auto-display data messages while the app is
      // open, so show our own local notification. The service is an app-lifetime
      // singleton, so these listeners live for the whole run — no need to keep /
      // cancel the subscriptions.
      FirebaseMessaging.onMessage.listen((m) {
        handleFcmData(m.data);
      });
      // Rotated token → re-register with the backend.
      fm.onTokenRefresh.listen((t) {
        if (t.isNotEmpty) ApiService().saveDeviceToken(t);
      });
    } catch (_) {/* best-effort */}
  }

  /// Fetch the current token and register it server-side. Call after login /
  /// whenever the authenticated home mounts. Best-effort.
  Future<void> registerToken() async {
    if (!fcmSupported) return;
    try {
      await init();
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null && token.isNotEmpty) {
        await ApiService().saveDeviceToken(token);
      }
    } catch (_) {/* best-effort */}
  }

  /// Unregister this device's token (on logout) so it stops receiving the
  /// account's pushes. Best-effort.
  Future<void> unregisterToken() async {
    if (!fcmSupported) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null && token.isNotEmpty) {
        await ApiService().deleteDeviceToken(token);
      }
    } catch (_) {/* best-effort */}
  }
}
