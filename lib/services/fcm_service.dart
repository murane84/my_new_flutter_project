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

/// Tracks the ONE conversation the user is actively viewing in the foreground,
/// so a foreground FCM for that same conversation doesn't also raise a banner —
/// the in-app delivery already showed the message and played its tone. Every
/// other conversation still notifies normally.
class ActiveChat {
  ActiveChat._();
  static final ActiveChat instance = ActiveChat._();

  String? _dmFriendId; // open DM's friend id (matches a DM push's sender_id)
  String? _convId; // open group's conversation id

  void enterDm(String friendId) {
    _dmFriendId = friendId;
    _convId = null;
  }

  void enterGroup(String conversationId) {
    _convId = conversationId;
    _dmFriendId = null;
  }

  // Clear only if still the active one, so returning from a nested chat/screen
  // doesn't wipe the chat beneath it.
  void leaveDm(String friendId) {
    if (_dmFriendId == friendId) _dmFriendId = null;
  }

  void leaveGroup(String conversationId) {
    if (_convId == conversationId) _convId = null;
  }

  /// True when an incoming message belongs to the conversation on screen.
  bool suppresses({String? senderId, String? convId}) {
    if (convId != null && convId.isNotEmpty) {
      return _convId != null && _convId == convId;
    }
    if (senderId != null && senderId.isNotEmpty) {
      return _dmFriendId != null && _dmFriendId == senderId;
    }
    return false;
  }
}

/// Turn an FCM data payload into a local notification. Shared by the foreground
/// listener (below) and the background isolate handler (in main.dart), so a
/// message/call is shown the same way whether the app is open, backgrounded, or
/// terminated. The server sends DATA-only pushes, so the client always controls
/// how they're displayed.
Future<void> handleFcmData(Map<String, dynamic> data,
    {bool foreground = false}) async {
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
    } else if (type == 'heartbeat_tap') {
      // Partner's wordless "thinking of you" (server spaces.py). In the
      // foreground the live socket already pulses the app — no banner.
      if (foreground) return;
      await showMessageNotification(
        title: (data['title'] ?? '💓').toString(),
        body: (data['body'] ?? 'is thinking of you').toString(),
      );
    } else if (type == 'heart_opened' || type == 'heart_ready') {
      // Secret hearts (server hearts.py): the tender receipt to the sender, or
      // a timed heart that just became openable. Never carries the note.
      final who = (data['sender_name'] ?? 'Someone').toString();
      final convId = (data['conversation_id'] ?? '').toString();
      final senderId = (data['sender_id'] ?? '').toString();
      final messageId = (data['message_id'] ?? '').toString();
      if (foreground &&
          ActiveChat.instance.suppresses(senderId: senderId, convId: convId)) {
        return; // that chat is open — the bubble shows it
      }
      await showMessageNotification(
        title: who,
        body: type == 'heart_opened'
            ? 'opened your secret heart 💗'
            : '💌 Your secret heart is ready to open',
        senderId: senderId.isEmpty ? null : senderId,
        senderName: who,
        messageId: messageId.isEmpty ? null : messageId,
        // Set only for GROUP hearts (server), so a tap opens the right thread.
        conversationId: convId.isEmpty ? null : convId,
      );
    } else if (type == 'call_end' ||
        type == 'call_cancel' ||
        type == 'call_decline' ||
        type == 'call_busy') {
      // The caller hung up / the call ended: stop the ringing notification on a
      // killed callee's phone so it doesn't keep ringing.
      await cancelCallNotification();
    } else {
      final sender = (data['sender_name'] ?? 'New message').toString();
      final body = (data['body'] ?? '').toString();
      final senderId = (data['sender_id'] ?? '').toString();
      final convId = (data['conversation_id'] ?? '').toString();
      final groupTitle = (data['group_title'] ?? '').toString();
      final messageId = (data['message_id'] ?? '').toString();
      final isGroup = convId.isNotEmpty;
      // If the app is in the foreground AND the user is already reading this
      // exact conversation, don't pop a redundant banner for it — they were
      // notified in-app the instant it arrived. All other chats still notify.
      if (foreground &&
          ActiveChat.instance.suppresses(senderId: senderId, convId: convId)) {
        return;
      }
      // For a group message show the group name as the title and "Sender: text"
      // as the body; a tap opens the GROUP thread (via conversation_id) instead
      // of a DM with the sender.
      // An @-mention reads "Juma mentioned you: <text>" so it stands out from
      // ordinary group chatter (server sends type "mention" + the preview).
      final mentioned = type == 'mention' || data['mentioned'] == '1';
      final everyone = data['mention_all'] == '1';
      await showMessageNotification(
        title: isGroup && groupTitle.isNotEmpty ? groupTitle : sender,
        body: mentioned
            ? '$sender ${everyone ? 'mentioned everyone' : 'mentioned you'}'
                '${body.isEmpty ? '' : ': $body'}'
            : isGroup
                ? '$sender: ${body.isEmpty ? 'Sent a message' : body}'
                : (body.isEmpty ? 'Sent you a message' : body),
        senderId: senderId.isEmpty ? null : senderId,
        senderName: sender,
        conversationId: convId.isEmpty ? null : convId,
        groupTitle: groupTitle.isEmpty ? null : groupTitle,
        messageId: messageId.isEmpty ? null : messageId,
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
        handleFcmData(m.data, foreground: true);
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
