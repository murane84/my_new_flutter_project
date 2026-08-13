import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Native bridge (see android MainActivity) for OS state the notification
/// plugin can't report — currently the full-screen-intent grant.
const MethodChannel _reliabilityChannel = MethodChannel('aluta/reliability');

/// Whether the app may currently show full-screen incoming-call intents (ring
/// over the lock screen). True on non-Android and pre-Android-14 (not gated);
/// on Android 14+ it reflects the real user-controlled grant. This is a genuine
/// OS query, unlike the notification plugin which can only *request* it.
Future<bool> fullScreenIntentAllowed() async {
  if (kIsWeb) return true;
  try {
    final ok =
        await _reliabilityChannel.invokeMethod<bool>('canUseFullScreenIntent');
    return ok ?? true;
  } catch (_) {
    // iOS / channel not registered / older OS → treat as allowed.
    return true;
  }
}

/// The device manufacturer (Build.MANUFACTURER), lowercased. Used to show the
/// OEM-specific "Autostart" steps on phones that need them (Xiaomi, Oppo…).
Future<String> deviceManufacturer() async {
  if (kIsWeb) return '';
  try {
    final m = await _reliabilityChannel.invokeMethod<String>('manufacturer');
    return (m ?? '').toLowerCase();
  } catch (_) {
    return '';
  }
}

/// Open the OEM "Autostart / Auto-launch" settings screen (falls back to the
/// app details page if the manufacturer screen can't be found).
Future<void> openAutostartSettings() async {
  if (kIsWeb) return;
  try {
    await _reliabilityChannel.invokeMethod('openAutostartSettings');
  } catch (_) {}
}

/// Open the "Display pop-up / show over lock screen" permission screen (MIUI
/// "Other permissions"; falls back to app details elsewhere).
Future<void> openPopupPermissionSettings() async {
  if (kIsWeb) return;
  try {
    await _reliabilityChannel.invokeMethod('openPopupPermissionSettings');
  } catch (_) {}
}

/// Thin wrapper around flutter_local_notifications for showing new-message
/// alerts + incoming-call rings while the app is backgrounded / killed. All
/// calls are best-effort / guarded.
final FlutterLocalNotificationsPlugin _fln = FlutterLocalNotificationsPlugin();
bool _ready = false;

// Action-button ids on the ringing call notification.
const String kCallAccept = 'call_accept';
const String kCallDecline = 'call_decline';

/// Wired by the app (home) so tapping Accept / Decline on the ringing
/// notification routes into the live call engine — this is what gives the
/// receiver working call controls even when the app is only in the background
/// (not actively on screen). `payload` is the JSON we attached to the
/// notification (caller id, group flag). Null while the app process isn't
/// running (killed) — that path is handled via [consumeCallLaunchAction].
void Function(String actionId, Map<String, dynamic> payload)? onCallAction;

/// Set by the home screen: tapping a MESSAGE notification (app alive/backgrounded)
/// routes here so we can open the sender's thread directly instead of just
/// landing on the chat list. `payload` carries `friend_id` + `sender_name`. The
/// killed-app (cold start) equivalent is [consumeMessageLaunchAction].
void Function(Map<String, dynamic> payload)? onMessageTap;

Map<String, dynamic> _decodePayload(String? raw) {
  if (raw == null || raw.isEmpty) return const {};
  try {
    final v = jsonDecode(raw);
    return v is Map<String, dynamic> ? v : const {};
  } catch (_) {
    return const {};
  }
}

/// Foreground / app-alive tap handler. A tapped Accept/Decline action (or the
/// notification body) lands here; we hand call actions to [onCallAction].
void _onNotifResponse(NotificationResponse r) {
  final a = r.actionId;
  if (a == kCallAccept || a == kCallDecline) {
    onCallAction?.call(a!, _decodePayload(r.payload));
    return;
  }
  // Tapping a message notification's body → open that thread.
  final p = _decodePayload(r.payload);
  if (p['type'] == 'message') {
    onMessageTap?.call(p);
  }
}

/// Background isolate tap handler (app killed). Must be a top-level, AOT entry.
/// We can't touch app state here; declining just lets the notification cancel
/// itself (cancelNotification: true) and the caller times out. Accept is picked
/// up on next launch via [consumeCallLaunchAction].
@pragma('vm:entry-point')
void _onNotifBgResponse(NotificationResponse r) {
  // Intentionally minimal — see doc comment above.
}

/// On cold start, returns the call action the user tapped in the notification
/// that launched the app (e.g. Accept from a killed state), or null. The app
/// uses this to reconnect and auto-answer. Safe to call once at startup.
/// [actionId] is the tapped action (kCallAccept / kCallDecline) or null when the
/// user tapped the notification BODY (they expect the full-screen call UI).
Future<({String? actionId, Map<String, dynamic> payload})?>
    consumeCallLaunchAction() async {
  if (kIsWeb) return null;
  try {
    final details = await _fln.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    final resp = details.notificationResponse;
    final a = resp?.actionId;
    final payload = _decodePayload(resp?.payload);
    // A call notification carries caller_id (1:1) or group=true. Return it
    // whether the user tapped Accept/Decline OR just the notification body —
    // a body tap dismisses the notification, so the app must show the call UI.
    final isCall = payload.containsKey('caller_id') || payload['group'] == true;
    if (a == kCallAccept || a == kCallDecline || isCall) {
      return (actionId: a, payload: payload);
    }
    return null;
  } catch (_) {
    return null;
  }
}

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
      settings: const InitializationSettings(android: android),
      onDidReceiveNotificationResponse: _onNotifResponse,
      onDidReceiveBackgroundNotificationResponse: _onNotifBgResponse,
    );
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
      await android_?.deleteNotificationChannel(channelId: 'aluta_calls');
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
  // When set, tapping the notification opens this sender's DM thread (both
  // while the app is alive and on cold start) instead of just the chat list.
  String? senderId,
  String? senderName,
  // When set, this is a GROUP message: tapping opens the group thread
  // (conversation) rather than a DM with the sender.
  String? conversationId,
  String? groupTitle,
}) async {
  if (kIsWeb) return;
  try {
    if (!_ready) await initNotifications();
    String? payload;
    final hasGroup = conversationId != null && conversationId.isNotEmpty;
    final hasSender = senderId != null && senderId.isNotEmpty;
    if (hasGroup || hasSender) {
      payload = jsonEncode({
        'type': 'message',
        if (hasSender) 'friend_id': senderId,
        'sender_name': senderName ?? title,
        if (hasGroup) 'conversation_id': conversationId,
        if (hasGroup && groupTitle != null && groupTitle.isNotEmpty)
          'group_title': groupTitle,
      });
    }
    await _fln.show(
      id: id,
      title: title,
      body: body,
      payload: payload,
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

/// On cold start, returns the message-notification payload the user tapped to
/// launch the app (so home can open that thread), or null. Mirrors
/// [consumeCallLaunchAction] but for `type: 'message'` payloads.
Future<Map<String, dynamic>?> consumeMessageLaunchAction() async {
  if (kIsWeb) return null;
  try {
    final details = await _fln.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    final p = _decodePayload(details.notificationResponse?.payload);
    return p['type'] == 'message' ? p : null;
  } catch (_) {
    return null;
  }
}

/// Show a ringing incoming-call notification (from an FCM `call_offer` push).
/// Rings with the phone's ringtone on the max-importance call channel, loops
/// until answered/dismissed (FLAG_INSISTENT), and uses a full-screen intent so
/// it surfaces the call over the lock screen. Auto-clears after 45s so a lost
/// dismiss can never ring forever. Tapping it opens the app.
Future<void> showCallNotification({
  required String caller,
  String? callerId,
  bool isGroup = false,
  int? room,
  int id = _callNotifId,
}) async {
  if (kIsWeb) return;
  try {
    if (!_ready) await initNotifications();
    // Attach who's calling so the Accept/Decline actions (and a cold-start
    // launch) can route back to the right caller / group room.
    final payloadMap = <String, dynamic>{'group': isGroup, 'caller_name': caller};
    if (callerId != null) payloadMap['caller_id'] = callerId;
    if (room != null) payloadMap['room'] = room;
    final payload = jsonEncode(payloadMap);
    await _fln.show(
      id: id,
      title: 'Incoming call',
      body: '$caller is calling…',
      payload: payload,
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
          // The whole point of this change: give the receiver working call
          // controls right on the notification, even when the app isn't on
          // screen. Decline cancels the ring locally; Accept brings the app
          // up to answer.
          actions: <AndroidNotificationAction>[
            const AndroidNotificationAction(
              kCallDecline,
              'Decline',
              cancelNotification: true,
            ),
            const AndroidNotificationAction(
              kCallAccept,
              'Accept',
              showsUserInterface: true,
              cancelNotification: true,
            ),
          ],
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
    await _fln.cancel(id: _callNotifId);
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
