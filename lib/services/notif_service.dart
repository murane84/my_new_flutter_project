import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Thin wrapper around flutter_local_notifications for showing new-message
/// alerts while the app is backgrounded (kept alive by the audio foreground
/// service while music plays). All calls are best-effort / guarded.
final FlutterLocalNotificationsPlugin _fln = FlutterLocalNotificationsPlugin();
bool _ready = false;

const _channelId = 'aluta_messages';
const _channelName = 'Messages';

// Separate, max-importance channel for incoming calls so they ring loudly and
// (Android 14+) can use a full-screen intent even over the lock screen.
const _callChannelId = 'aluta_calls';
const _callChannelName = 'Incoming calls';

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
    // Android 14+ (API 34) gates full-screen intents behind a dedicated
    // permission that isn't granted by default — without it a `call_offer`
    // push can't wake/turn on the screen, it just lands quietly in the shade.
    // Best-effort: on older Androids this is a no-op.
    try {
      await android_?.requestFullScreenIntentPermission();
    } catch (_) {/* not available on this OS/plugin path */}
    await android_?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: 'New chat messages',
        importance: Importance.high,
      ),
    );
    await android_?.createNotificationChannel(
      const AndroidNotificationChannel(
        _callChannelId,
        _callChannelName,
        description: 'Incoming voice calls',
        importance: Importance.max,
        playSound: true,
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

/// Show an incoming-call notification (from an FCM `call_offer` push). Uses the
/// max-importance call channel + a full-screen intent so it can surface over the
/// lock screen; tapping it opens the app, which reconnects the socket and shows
/// the in-app ringing UI.
Future<void> showCallNotification({
  required String caller,
  int id = 2001,
}) async {
  if (kIsWeb) return;
  try {
    if (!_ready) await initNotifications();
    await _fln.show(
      id: id,
      title: 'Incoming call',
      body: '$caller is calling…',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _callChannelId,
          _callChannelName,
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          fullScreenIntent: true,
          ongoing: true,
          autoCancel: false,
          // Show full content on the lock screen so the call surfaces even
          // when the device is locked.
          visibility: NotificationVisibility.public,
          ticker: 'Incoming call',
          icon: '@mipmap/launcher_icon',
        ),
      ),
    );
  } catch (_) {/* best-effort */}
}
