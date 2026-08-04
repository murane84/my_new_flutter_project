import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Thin wrapper around flutter_local_notifications for showing new-message
/// alerts while the app is backgrounded (kept alive by the audio foreground
/// service while music plays). All calls are best-effort / guarded.
final FlutterLocalNotificationsPlugin _fln = FlutterLocalNotificationsPlugin();
bool _ready = false;

const _channelId = 'aluta_messages';
const _channelName = 'Messages';

Future<void> initNotifications() async {
  if (_ready || kIsWeb) return;
  try {
    const android =
        AndroidInitializationSettings('@mipmap/launcher_icon');
    await _fln.initialize(
        settings: const InitializationSettings(android: android));
    final android_ = _fln.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android_?.requestNotificationsPermission();
    await android_?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: 'New chat messages',
        importance: Importance.high,
      ),
    );
    _ready = true;
  } catch (_) {/* best-effort */}
}

Future<void> showMessageNotification({
  required String title,
  required String body,
  int id = 1001,
}) async {
  if (kIsWeb) return;
  try {
    if (!_ready) await initNotifications();
    await _fln.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/launcher_icon',
        ),
      ),
    );
  } catch (_) {/* best-effort */}
}
