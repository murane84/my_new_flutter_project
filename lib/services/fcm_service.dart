import 'package:flutter/foundation.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'contact_names.dart';
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

/// The sender the way *I* know them: my phone-book name for their number
/// (`sender_phone`, which the server adds to every push), else [registered] —
/// their Aluta profile name. Works in the background isolate too: the saved
/// names are read from the snapshot ContactNames keeps on the device.
Future<String> _knownAs(Map<String, dynamic> data, String registered) async {
  final phone = (data['sender_phone'] ?? '').toString().trim();
  if (phone.isEmpty) return registered;
  try {
    await ContactNames.instance
        .ensureLoaded()
        .timeout(const Duration(seconds: 2));
  } catch (_) {}
  if (!ContactNames.instance.hasRealName(phone)) return registered;
  final saved = ContactNames.instance.nameFor(phone)?.trim();
  return (saved == null || saved.isEmpty) ? registered : saved;
}

/// A line the server wrote with the registered name in it ("Belina shared a
/// moment") → the same line with my saved name ("My wife shared a moment").
String _swapName(String text, String registered, String knownAs) =>
    (registered.isEmpty || knownAs == registered)
        ? text
        : text.replaceAll(registered, knownAs);

/// Turn an FCM data payload into a local notification. Shared by the foreground
/// listener (below) and the background isolate handler (in main.dart), so a
/// message/call is shown the same way whether the app is open, backgrounded, or
/// terminated. The server sends DATA-only pushes, so the client always controls
/// how they're displayed.
Future<void> handleFcmData(Map<String, dynamic> data,
    {bool foreground = false}) async {
  try {
    final type = (data['type'] ?? '').toString();
    // Their registered name as the server wrote it (and may have put inside
    // the title/body), and how *I* know them — used by every branch below.
    final registered = (data['actor_name'] ??
            data['sender_name'] ??
            data['caller_name'] ??
            data['host_username'] ??
            data['from_name'] ??
            '')
        .toString();
    final known = await _knownAs(data, registered);
    String mine(String text) => _swapName(text, registered, known);
    if (type == 'call_offer') {
      final caller = mine((data['caller_name'] ?? 'Someone').toString());
      final callerId = (data['caller_id'] ?? '').toString();
      await showCallNotification(
        caller: caller,
        callerId: callerId.isEmpty ? null : callerId,
      );
    } else if (type == 'group_call') {
      final caller = mine((data['caller_name'] ?? 'Someone').toString());
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
      final host = mine((data['host_username'] ?? 'Someone').toString());
      final song = (data['track_title'] ?? '').toString().trim();
      final hostId = int.tryParse((data['host_id'] ?? '').toString()) ?? 0;
      await showMessageNotification(
        title: '🎧 $host wants to listen with you',
        body: song.isEmpty
            ? 'Tap to join — you\'ll hear the same song, in sync'
            : '$song · tap to join, in sync',
        // One slot per host: a newer invite replaces the old one.
        id: 7500 + hostId % 1000,
        senderId: hostId == 0 ? null : '$hostId',
        senderName: host,
      );
    } else if (type == 'heartbeat_tap') {
      // Partner's wordless "thinking of you" (server spaces.py). In the
      // foreground the live socket already pulses the app — no banner.
      if (foreground) return;
      final from = (data['from_id'] ?? '').toString();
      await showMessageNotification(
        title: mine((data['title'] ?? '💓').toString()),
        body: mine((data['body'] ?? 'is thinking of you').toString()),
        // Its own slot (never replaces another alert); tap opens their chat.
        id: 7300 + (int.tryParse(from) ?? 0) % 1000,
        senderId: from.isEmpty ? null : from,
        senderName: mine((data['from_name'] ?? '').toString()),
      );
    } else if (type == 'friend_online') {
      // "Tell me when they're online" fired (server online_watch.py). In the
      // foreground the socket shows the in-app card instead.
      if (foreground) return;
      final fid = (data['friend_id'] ?? '').toString();
      final who = mine((data['friend_name'] ?? 'Your friend').toString());
      final listen = (data['purpose'] ?? '') == 'listen';
      await showMessageNotification(
        title: '$who is online now 🟢',
        body: listen
            ? 'Ready to listen together? 🎧'
            : "Say hi while they're here 👋",
        id: 7400 + (int.tryParse(fid) ?? 0) % 1000,
        senderId: fid.isEmpty ? null : fid,
        senderName: who,
      );
    } else if (type == 'reaction') {
      // Someone reacted to MY message (server messages.py). Open chat → the
      // bubble already shows it live, so no banner for that thread.
      final who = mine((data['sender_name'] ?? 'Someone').toString());
      final senderId = (data['sender_id'] ?? '').toString();
      final convId = (data['conversation_id'] ?? '').toString();
      final groupTitle = (data['group_title'] ?? '').toString();
      final messageId = (data['message_id'] ?? '').toString();
      if (foreground &&
          ActiveChat.instance.suppresses(senderId: senderId, convId: convId)) {
        return;
      }
      final emoji = (data['emoji'] ?? '❤️').toString();
      final preview = (data['body'] ?? '').toString().trim();
      final quoted = preview.isEmpty
          ? 'your message'
          : '“${preview.length > 60 ? '${preview.substring(0, 60)}…' : preview}”';
      final isGroup = convId.isNotEmpty;
      await showMessageNotification(
        title: isGroup && groupTitle.isNotEmpty ? groupTitle : who,
        body: isGroup
            ? '$who reacted $emoji to $quoted'
            : 'Reacted $emoji to $quoted',
        // Its own slot per message, so it never replaces a real message.
        id: 7600 + (int.tryParse(messageId) ?? 0) % 1000,
        senderId: senderId.isEmpty ? null : senderId,
        senderName: who,
        conversationId: convId.isEmpty ? null : convId,
        groupTitle: groupTitle.isEmpty ? null : groupTitle,
        messageId: messageId.isEmpty ? null : messageId,
      );
    } else if (type == 'heart_opened' && foreground) {
      // App open: the in-app heart pill already shows it — no second banner.
      return;
    } else if (type == 'heart_opened' || type == 'heart_ready') {
      // Secret hearts (server hearts.py): the tender receipt to the sender, or
      // a timed heart that just became openable. Never carries the note.
      final who = mine((data['sender_name'] ?? 'Someone').toString());
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
    } else if (data['sender_name'] == null && data['title'] != null) {
      // Our Space / capsule / dedication pushes: the server writes the whole
      // title + line (with the registered name inside) — show THOSE, in my
      // names, instead of a generic "New message".
      await showMessageNotification(
        title: mine(data['title'].toString()),
        body: mine((data['body'] ?? '').toString()),
      );
    } else {
      final sender = mine((data['sender_name'] ?? 'New message').toString());
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
