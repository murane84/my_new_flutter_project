import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Thin wrapper around flutter_local_notifications for showing new-message
/// alerts + incoming-call rings while the app is backgrounded / killed. All
/// calls are best-effort / guarded.
final FlutterLocalNotificationsPlugin _fln = FlutterLocalNotificationsPlugin();
bool _ready = false;

const _channelId = 'aluta_messages';
const _channelName = 'Messages';

// Incoming-call channel. NB the id is versioned (_v2): a channel's sound,
// vibration and importance are LOCKED at creation and Android ignores later
// changes to the same id. Bumping the id is the only way to ship the new
// ringtone-style config to devices that already created the old 'aluta_calls'
// channel (with a plain notification ding). The old one is deleted below.
const _callChannelId = 'aluta_calls_v2';
const _callChannelName = 'Incoming calls';
const _callNotifId = 2001;

// The phone's own ringtone (whatever the user set for incoming calls). Using
// this URI + the RINGTONE audio usage makes an Aluta call ring on the ring
// stream, at ring volume, with the same tone as a normal/WhatsApp call —
// instead of the short message notification sound.
const _systemRingtoneUri = 'content://settings/system/ringtone';

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
    // Retire the old call channel (plain ding) so only the ringtone one remains.
    try {
      await android_?.deleteNotificationChannel('aluta_calls');
    } catch (_) {/* fine if it never existed */}
    await android_?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: 'New chat messages',
        importance: Importance.high,
      ),
    );
    await android_?.createNotificationChannel(
      AndroidNotificationChannel(
        _callChannelId,
        _callChannelName,
        description: 'Incoming voice calls',
        importance: Importance.max,
        playSound: true,
        // Ring with the phone's set ringtone, on the ringtone stream.
        sound: const UriAndroidNotificationSound(_systemRingtoneUri),
        audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
        enableVibration: true,
        vibrationPattern:
            Int64List.fromList(<int>[0, 1000, 800, 1000, 800, 1000]),
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

/// Show a ringing incoming-call notification (from an FCM `call_offer` push).
/// Rings with the phone's ringtone on the max-importance call channel, loops
/// until answered/dismissed (FLAG_INSISTENT), and uses a full-screen intent so
/// it surfaces the call over the lock screen. Auto-clears after 45s so a lost
/// dismiss can never ring forever. Tapping it opens the app.
Future<void> showCallNotification({
  required String caller,
  int id = _callNotifId,
}) async {
  if (kIsWeb) return;
  try {
    if (!_ready) await initNotifications();
    await _fln.show(
      id: id,
      title: 'Incoming call',
      body: '$caller is calling…',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _callChannelId,
          _callChannelName,
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          fullScreenIntent: true,
          ongoing: true,
          autoCancel: false,
          playSound: true,
          sound: const UriAndroidNotificationSound(_systemRingtoneUri),
          audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
          enableVibration: true,
          vibrationPattern:
              Int64List.fromList(<int>[0, 1000, 800, 1000, 800, 1000]),
          // FLAG_INSISTENT (0x4): keep ringing/vibrating until the notification
          // is answered or dismissed — that's what makes it behave like a call
          // rather than a one-shot ding.
          additionalFlags: Int32List.fromList(<int>[4]),
          // Safety net: if the "call ended" dismiss never arrives (e.g. the
          // callee's app was killed and the dismiss push was lost), stop after
          // the 45s ring window instead of ringing forever.
          timeoutAfter: 45000,
          visibility: NotificationVisibility.public,
          ticker: 'Incoming call',
          icon: '@mipmap/launcher_icon',
        ),
      ),
    );
  } catch (_) {/* best-effort */}
}

/// Stop/clear the ringing call notification (call answered, declined, or the
/// caller cancelled). Safe to call even if nothing is showing.
Future<void> cancelCallNotification() async {
  if (kIsWeb) return;
  try {
    await _fln.cancel(_callNotifId);
  } catch (_) {/* best-effort */}
}

// ── Permission helpers (used by the Call reliability screen) ─────────────────

AndroidFlutterLocalNotificationsPlugin? get _android =>
    _fln.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

/// Are notifications enabled for the app? (null-safe → true on non-Android.)
Future<bool> notificationsEnabled() async {
  if (kIsWeb) return true;
  try {
    return await _android?.areNotificationsEnabled() ?? true;
  } catch (_) {
    return true;
  }
}

/// Ask for the POST_NOTIFICATIONS runtime permission (Android 13+).
Future<void> askNotificationsPermission() async {
  if (kIsWeb) return;
  try {
    await initNotifications();
    await _android?.requestNotificationsPermission();
  } catch (_) {/* best-effort */}
}

/// Ask for the Android-14 full-screen-intent permission (opens its settings
/// screen). Returns whether it's granted where the plugin can tell.
Future<bool?> askFullScreenIntentPermission() async {
  if (kIsWeb) return true;
  try {
    await initNotifications();
    return await _android?.requestFullScreenIntentPermission();
  } catch (_) {
    return null;
  }
}
