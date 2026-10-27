import 'dart:convert';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tzdata;

import '../screens/api_service.dart';

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
/// A tap that lands before home has wired this up is kept and handed over the
/// moment it is set, so a tap is never silently lost.
void Function(Map<String, dynamic> payload)? _onMessageTap;
Map<String, dynamic>? _pendingMessageTap;
void Function(Map<String, dynamic> payload)? get onMessageTap => _onMessageTap;
set onMessageTap(void Function(Map<String, dynamic> payload)? fn) {
  _onMessageTap = fn;
  final p = _pendingMessageTap;
  if (fn != null && p != null) {
    _pendingMessageTap = null;
    fn(p);
  }
}

/// Inline "Reply" action on message notifications (type a reply in the shade).
const String kMsgReply = 'msg_reply';

// ── Aluta notifications (everything that isn't a chat message or a call) ────
// Listen Together invites, tune-in requests, Our Space moments, reactions and
// Aluta-team replies. Each lives on its own channel (so it can be muted on
// its own in Android settings), can carry action buttons, and taps route to
// the home screen through [onAlutaTap] (or [consumeAlutaLaunchAction] on a
// cold start). Payload: {'type': 'aluta', 'kind': ..., ...}.
const String kLiveJoin = 'live_join';
const String kLiveLater = 'live_later';
const String kTuneLet = 'tune_let';
const String kTuneNo = 'tune_no';
const String kOpen = 'open';

const String alutaListenChannel = 'aluta_listen';
const String alutaSpaceChannel = 'aluta_space';
const String alutaReactionChannel = 'aluta_reactions';
const String alutaTeamChannel = 'aluta_team';

void Function(String? actionId, Map<String, dynamic> payload)? _onAlutaTap;
({String? a, Map<String, dynamic> p})? _pendingAlutaTap;
set onAlutaTap(void Function(String? actionId, Map<String, dynamic> p)? fn) {
  _onAlutaTap = fn;
  final pend = _pendingAlutaTap;
  if (fn != null && pend != null) {
    _pendingAlutaTap = null;
    fn(pend.a, pend.p);
  }
}

/// The per-person bundle key: everything from one friend (messages, invites,
/// reactions, Our Space) stacks under their name in the shade.
String personGroupKey(String personKey) => 'aluta_p_$personKey';

Future<void> _showPersonSummary(
    String personKey, String personName, String channel) async {
  try {
    await _fln.show(
      id: 950000 + (personKey.hashCode.abs() % 40000),
      title: personName,
      body: 'New from $personName',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channel,
          _channelNames[channel] ?? 'Aluta',
          icon: '@mipmap/launcher_icon',
          groupKey: personGroupKey(personKey),
          setAsGroupSummary: true,
          onlyAlertOnce: true,
        ),
      ),
    );
  } catch (_) {}
}

const Map<String, String> _channelNames = {
  'aluta_messages': 'Messages',
  alutaListenChannel: 'Listen Together',
  alutaSpaceChannel: 'Our Space',
  alutaReactionChannel: 'Reactions',
  alutaTeamChannel: 'Aluta team',
};

/// Show an Aluta notification (see the block comment above).
Future<void> showAlutaNotification({
  required String channel,
  required String title,
  required String body,
  required int id,
  required Map<String, dynamic> payload,
  List<(String id, String label)> actions = const [],
  Uint8List? picture,
  List<String>? lines,
  String? personKey,
  String? personName,
  bool silent = false,
}) async {
  if (kIsWeb) return;
  try {
    if (!_ready) await initNotifications();
    final p = {'type': 'aluta', ...payload};
    final group =
        personKey == null ? _msgGroupKey : personGroupKey(personKey);
    await _fln.show(
      id: id,
      title: title,
      body: body,
      payload: jsonEncode(p),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channel,
          _channelNames[channel] ?? 'Aluta',
          importance: silent ? Importance.low : Importance.high,
          priority: silent ? Priority.low : Priority.high,
          icon: '@mipmap/launcher_icon',
          groupKey: group,
          styleInformation: picture != null
              ? BigPictureStyleInformation(
                  ByteArrayAndroidBitmap(picture),
                  contentTitle: title,
                  summaryText: body,
                  hideExpandedLargeIcon: true,
                )
              : (lines != null && lines.length > 1
                  ? InboxStyleInformation(lines,
                      contentTitle: title,
                      summaryText: '${lines.length} reactions')
                  : BigTextStyleInformation(body)),
          largeIcon: picture != null ? ByteArrayAndroidBitmap(picture) : null,
          actions: [
            for (final a in actions)
              AndroidNotificationAction(
                a.$1,
                a.$2,
                // "Not now" style answers don't need the app open.
                showsUserInterface: a.$1 != kLiveLater && a.$1 != kTuneNo,
                cancelNotification: true,
              ),
          ],
        ),
      ),
    );
    if (personKey != null && personName != null) {
      await _showPersonSummary(personKey, personName, channel);
    }
  } catch (_) {/* best-effort */}
}

Future<void> cancelAlutaNotification(int id) async {
  if (kIsWeb) return;
  try {
    if (!_ready) await initNotifications();
    await _fln.cancel(id: id);
  } catch (_) {}
}

/// Stable slots: one per (kind, person) so a newer one replaces the older.
int alutaNotifId(String kind, String key) =>
    4000000 + ('$kind:$key'.hashCode.abs() % 900000);

/// Cold start from an Aluta notification (or one of its buttons).
Future<({String? actionId, Map<String, dynamic> payload})?>
    consumeAlutaLaunchAction() async {
  if (kIsWeb) return null;
  try {
    final details = await _fln.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    final r = details.notificationResponse;
    final p = _decodePayload(r?.payload);
    if (p['type'] != 'aluta') return null;
    return (actionId: r?.actionId, payload: p);
  } catch (_) {
    return null;
  }
}

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
  final p = _decodePayload(r.payload);
  // Inline reply typed in the notification → send it, no app needed.
  if (a == kMsgReply) {
    _sendInlineReply(p, r.input);
    return;
  }
  // Listen Together / tune-in / Our Space / team → home routes it.
  if (p['type'] == 'aluta') {
    if (a == kLiveLater) {
      _declineLiveFromShade(p);
      return;
    }
    if (a == kTuneNo) return; // the asker's wait simply times out
    final fn = _onAlutaTap;
    if (fn != null) {
      fn(a, p);
    } else {
      _pendingAlutaTap = (a: a, p: p);
    }
    return;
  }
  // Tapping a message notification's body → open that thread.
  if (p['type'] == 'message') {
    final fn = _onMessageTap;
    if (fn != null) {
      fn(p);
    } else {
      _pendingMessageTap = p; // home not wired yet → hand over when it is
    }
  }
}

/// Send what was typed into a notification's Reply box to that DM / group,
/// mark the thread read, and clear the banner. Works from the background
/// isolate too (app closed). On failure the banner says so — tap opens chat.
Future<void> _sendInlineReply(Map<String, dynamic> p, String? input) async {
  final text = (input ?? '').trim();
  if (text.isEmpty) return;
  final fid = int.tryParse((p['friend_id'] ?? '').toString());
  final cid = int.tryParse((p['conversation_id'] ?? '').toString());
  if (fid == null && cid == null) return;
  final notifId = messageNotifId(
      senderId: p['friend_id']?.toString(),
      conversationId: p['conversation_id']?.toString());
  final api = ApiService();
  Future<Map<String, dynamic>?> send() =>
      api.sendMessage(fid ?? 0, text, conversationId: cid);
  var sent = await send();
  // A closed app's access token may have expired — refresh once, retry.
  if (sent == null && await api.refreshAccessToken()) sent = await send();
  try {
    if (!_ready) await initNotifications();
    if (sent != null) {
      if (cid != null) {
        await api.markConversationRead(cid);
      } else if (fid != null) {
        await api.markMessagesAsReadPatch(fid);
      }
      await _fln.cancel(id: notifId);
    } else {
      await _fln.show(
        id: notifId,
        title: (p['group_title'] ?? p['sender_name'] ?? 'Aluta').toString(),
        body: "Couldn't send your reply — tap to open the chat",
        payload: jsonEncode(p),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            importance: Importance.high,
            priority: Priority.high,
            icon: '@mipmap/launcher_icon',
            groupKey: _msgGroupKey,
          ),
        ),
      );
    }
  } catch (_) {/* best-effort */}
}

/// "Not now" on a Listen Together invite: tell the host, without opening Aluta.
Future<void> _declineLiveFromShade(Map<String, dynamic> p) async {
  final sid = (p['session_id'] ?? '').toString();
  if (sid.isEmpty) return;
  try {
    await ApiService().declineLiveSession(sid);
  } catch (_) {}
}

/// Background isolate tap handler (app killed). Must be a top-level, AOT entry.
/// We can't touch app state here; declining just lets the notification cancel
/// itself (cancelNotification: true) and the caller times out. Accept is picked
/// up on next launch via [consumeCallLaunchAction].
@pragma('vm:entry-point')
Future<void> _onNotifBgResponse(NotificationResponse r) async {
  // Calls: intentionally nothing (see above). An inline message reply typed
  // while the app is closed is sent from here, and so is "Not now" on a
  // Listen Together invite.
  if (r.actionId == kLiveLater) {
    try {
      DartPluginRegistrant.ensureInitialized();
    } catch (_) {}
    await _declineLiveFromShade(_decodePayload(r.payload));
    return;
  }
  if (r.actionId != kMsgReply) return;
  try {
    DartPluginRegistrant.ensureInitialized(); // secure storage + prefs here
  } catch (_) {}
  await _sendInlineReply(_decodePayload(r.payload), r.input);
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

const _diaryChannelId = 'aluta_diary_plans';
const _diaryChannelName = 'Diary plan reminders';
// Notification-id namespace for scheduled diary-plan reminders, so they can be
// reconciled (cancelled/rescheduled) without touching message/call ids. A plan
// with entry id E schedules at (_diaryNotifBase + E).
const int _diaryNotifBase = 3000000;
const int _diaryNotifMax = 3999999;

bool _tzReady = false;
void _ensureTimeZones() {
  if (_tzReady) return;
  try {
    tzdata.initializeTimeZones();
    _tzReady = true;
  } catch (_) {/* best-effort — scheduling just no-ops if this fails */}
}

Future<void> initNotifications() async {
  if (_ready || kIsWeb) return;
  try {
    _ensureTimeZones();
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
    // One channel per kind of Aluta alert, so each can be muted on its own.
    for (final ch in const [
      (alutaListenChannel, 'Listen Together',
          'Invites to listen together and tune-in requests', Importance.high),
      (alutaSpaceChannel, 'Our Space',
          'Moments, dedications and notes from your partner', Importance.high),
      (alutaReactionChannel, 'Reactions',
          'Emoji reactions to your messages', Importance.defaultImportance),
      (alutaTeamChannel, 'Aluta team',
          'Replies to your feedback and help requests',
          Importance.defaultImportance),
    ]) {
      await android_?.createNotificationChannel(AndroidNotificationChannel(
          ch.$1, ch.$2,
          description: ch.$3, importance: ch.$4));
    }
    // Gentle, low-key channel for Our Diary plan reminders (a warm nudge, not a
    // ring). Default importance so it lands quietly in the shade.
    await android_?.createNotificationChannel(
      const AndroidNotificationChannel(
        _diaryChannelId,
        _diaryChannelName,
        description: 'Reminders for plans you pinned in Our Diary',
        importance: Importance.defaultImportance,
      ),
    );
    _ready = true;
  } catch (_) {/* best-effort */}
}

// ── Our Diary: pinned-plan reminders ─────────────────────────────────────────

/// A plan the couple pinned for a reminder. [id] is the diary entry id (used to
/// derive a stable notification id so a reschedule replaces the old one).
class PlanReminder {
  final int id;
  final String title; // what to show (plan title, else a snippet of the body)
  final DateTime date; // the plan's day (local); reminder fires that morning
  const PlanReminder({required this.id, required this.title, required this.date});
}

int _diaryNotifId(int entryId) {
  final v = _diaryNotifBase + entryId;
  return v > _diaryNotifMax ? _diaryNotifBase + (entryId % 1000000) : v;
}

/// The exact instant a reminder should fire for [day]: 9:00am on that calendar
/// day in the DEVICE's local wall-clock, expressed as a UTC-anchored TZDateTime
/// (so it fires at 9am local regardless of the tz database's default location —
/// we don't need to know the device's IANA zone name). Null if that instant is
/// already in the past.
tz.TZDateTime? _reminderInstant(DateTime day) {
  // 9am on the plan's day, in local wall-clock; toUtc() applies the device's
  // real offset to get the correct absolute instant.
  final localNine = DateTime(day.year, day.month, day.day, 9, 0);
  final utc = localNine.toUtc();
  final when = tz.TZDateTime.from(utc, tz.UTC);
  final now = tz.TZDateTime.now(tz.UTC);
  if (!when.isAfter(now)) {
    // Same-day-but-past (e.g. pinned in the afternoon for today): nudge shortly
    // so a plan for "today" still reminds. A truly past day → skip.
    if (day.year == now.toLocal().year &&
        day.month == now.toLocal().month &&
        day.day == now.toLocal().day) {
      return now.add(const Duration(minutes: 1));
    }
    return null;
  }
  return when;
}

Future<void> _scheduleDiaryReminder(PlanReminder p) async {
  final when = _reminderInstant(p.date);
  if (when == null) return;
  final title = p.title.trim().isEmpty ? 'A plan for today 💛' : p.title.trim();
  try {
    await _fln.zonedSchedule(
      id: _diaryNotifId(p.id),
      title: 'Upcoming plan 💛',
      body: title,
      scheduledDate: when,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _diaryChannelId,
          _diaryChannelName,
          channelDescription: 'Reminders for plans you pinned in Our Diary',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          icon: '@mipmap/launcher_icon',
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: '{"type":"diary_plan"}',
    );
  } catch (_) {/* best-effort — exact-alarm perms etc. */}
}

/// Reconcile the OS's scheduled diary reminders to exactly [plans]: schedule the
/// ones that should exist, and cancel any previously-scheduled diary reminder
/// (in our id namespace) that's no longer pinned — so unpinning on either
/// partner's device clears the reminder here on the next space open. Idempotent
/// and best-effort; a no-op on web.
Future<void> syncDiaryReminders(List<PlanReminder> plans) async {
  if (kIsWeb) return;
  try {
    if (!_ready) await initNotifications();
    _ensureTimeZones();
    final wantIds = <int>{for (final p in plans) _diaryNotifId(p.id)};
    // Cancel stale ones still pending in our namespace.
    try {
      final pending = await _fln.pendingNotificationRequests();
      for (final req in pending) {
        if (req.id >= _diaryNotifBase &&
            req.id <= _diaryNotifMax &&
            !wantIds.contains(req.id)) {
          await _fln.cancel(id: req.id);
        }
      }
    } catch (_) {/* listing not supported → skip the prune */}
    // (Re)schedule the desired set (same id replaces any existing one).
    for (final p in plans) {
      await _scheduleDiaryReminder(p);
    }
  } catch (_) {/* best-effort */}
}

/// Cancel a single diary reminder immediately (e.g. the user just unpinned or
/// deleted the plan) without waiting for the next reconcile.
Future<void> cancelDiaryReminder(int entryId) async {
  if (kIsWeb) return;
  try {
    await _fln.cancel(id: _diaryNotifId(entryId));
  } catch (_) {/* best-effort */}
}

const _msgGroupKey = 'aluta_messages_group';

/// A stable per-conversation notification id. Keeps ONE banner per chat (a new
/// message from the same sender replaces the old instead of piling up),
/// prevents different chats from clobbering each other (they used to share a
/// fixed id), and lets a chat's banner be cancelled when you open it.
int messageNotifId({String? senderId, String? conversationId}) {
  final key = (conversationId != null && conversationId.isNotEmpty)
      ? 'c:$conversationId'
      : 's:${senderId ?? ''}';
  return 100000 + (key.hashCode.abs() % 800000);
}

/// Cancel the banner for one conversation — called when the user opens it, so a
/// message they're now reading stops showing in the shade.
Future<void> cancelConversationNotifications(
    {String? senderId, String? conversationId}) async {
  if (kIsWeb) return;
  try {
    if (!_ready) await initNotifications();
    await _fln.cancel(
        id: messageNotifId(senderId: senderId, conversationId: conversationId));
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
  // When set, tapping scrolls to + highlights this exact message in the thread.
  String? messageId,
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
        if (messageId != null && messageId.isNotEmpty) 'message_id': messageId,
      });
    }
    final notifId = (hasGroup || hasSender)
        ? messageNotifId(senderId: senderId, conversationId: conversationId)
        : id;
    // One bundle per person / group: their messages, invites, reactions and
    // Our Space alerts stack under one name instead of a pile of "Aluta".
    final personKey = hasGroup
        ? 'c$conversationId'
        : (hasSender ? 's$senderId' : null);
    await _fln.show(
      id: notifId,
      title: title,
      body: body,
      payload: payload,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/launcher_icon',
          // Bundled per person (see personKey); the per-conversation id keeps
          // one banner per sender.
          groupKey:
              personKey == null ? _msgGroupKey : personGroupKey(personKey),
          // A chat banner gets an inline Reply box (answer without opening).
          actions: payload == null
              ? null
              : const [
                  AndroidNotificationAction(
                    kMsgReply,
                    'Reply',
                    inputs: [
                      AndroidNotificationActionInput(label: 'Write a reply…'),
                    ],
                    showsUserInterface: false,
                    cancelNotification: false,
                  ),
                ],
        ),
      ),
    );
    if (personKey != null) {
      await _showPersonSummary(personKey,
          (hasGroup ? groupTitle : senderName) ?? title, _channelId);
    }
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

// ── Attachment downloads (DownloadManager) ──────────────────────────────────
// A quiet, ongoing progress notification while a file downloads in the
// background, so the user sees it keep going after leaving the chat or
// turning the screen off; it turns into "Downloaded" when done.

const String _dlChannelId = 'aluta_downloads';

/// Stable id per download (derived from the url).
int downloadNotifId(String key) => 70000 + (key.hashCode & 0x7fff);

Future<void> showDownloadProgress(String key, String name, int? percent) async {
  if (kIsWeb) return;
  try {
    await initNotifications();
    await _fln.show(
      id: downloadNotifId(key),
      title: name,
      body: percent == null ? 'Downloading…' : 'Downloading · $percent%',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _dlChannelId,
          'Downloads',
          channelDescription: 'Files downloading from your chats',
          importance: Importance.low,
          priority: Priority.low,
          onlyAlertOnce: true,
          ongoing: true,
          autoCancel: false,
          showProgress: true,
          indeterminate: percent == null,
          maxProgress: 100,
          progress: percent ?? 0,
          icon: '@mipmap/launcher_icon',
        ),
      ),
    );
  } catch (_) {}
}

Future<void> finishDownloadNotif(String key, String name, bool ok) async {
  if (kIsWeb) return;
  try {
    await _fln.show(
      id: downloadNotifId(key),
      title: name,
      body: ok ? 'Downloaded · open it from the chat' : 'Paused (no network) — continues from where it stopped',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _dlChannelId,
          'Downloads',
          channelDescription: 'Files downloading from your chats',
          importance: Importance.low,
          priority: Priority.low,
          onlyAlertOnce: true,
          autoCancel: true,
          icon: '@mipmap/launcher_icon',
        ),
      ),
    );
  } catch (_) {}
}

Future<void> cancelDownloadNotif(String key) async {
  if (kIsWeb) return;
  try {
    await _fln.cancel(id: downloadNotifId(key));
  } catch (_) {}
}
