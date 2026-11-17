import 'dart:async';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

/// 🔒 A reply typed into a notification while Aluta is running in the
/// background is handed to the app's own isolate to send. Two isolates
/// sealing for the same friend at once could both use the same message key
/// (and overwrite each other's session state); the app's isolate sends one
/// message at a time. With Aluta closed there's no app isolate — the
/// notification's isolate sends it itself.
const String _name = 'aluta_inline_reply';
ReceivePort? _port;

/// How old a hand-over may be when the app picks it up; past this the
/// notification's isolate has already given up and sends it itself.
const int _freshMs = 2000;

/// APP isolate: take inline replies from the notification's isolate.
void listenForInlineReplies(
    Future<void> Function(Map<String, dynamic> payload, String? input) send) {
  if (_port != null) return;
  final port = ReceivePort();
  IsolateNameServer.removePortNameMapping(_name);
  if (!IsolateNameServer.registerPortWithName(port.sendPort, _name)) {
    port.close();
    return;
  }
  _port = port;
  port.listen((m) async {
    if (m is! List || m.length != 4 || m[3] is! SendPort) return;
    final back = m[3] as SendPort;
    final at = m[2];
    if (at is! int || DateTime.now().millisecondsSinceEpoch - at > _freshMs) {
      return; // too late: the other side sends it (never twice)
    }
    back.send('got');
    try {
      await send(Map<String, dynamic>.from(m[0] as Map), m[1] as String?);
    } catch (_) {}
    back.send('done');
  });
}

/// NOTIFICATION isolate: give the reply to the running app. True when the
/// app took it (it sends and clears the banner); false → send it here.
Future<bool> handInlineReplyToApp(
    Map<String, dynamic> payload, String? input) async {
  final app = IsolateNameServer.lookupPortByName(_name);
  if (app == null) return false;
  final back = ReceivePort();
  final events = StreamIterator<dynamic>(back);
  try {
    app.send(
        [payload, input, DateTime.now().millisecondsSinceEpoch, back.sendPort]);
    final got = await events
        .moveNext()
        .timeout(const Duration(seconds: 3), onTimeout: () => false);
    if (!got) {
      // Nobody answered: a name left behind by an app that's gone.
      IsolateNameServer.removePortNameMapping(_name);
      return false;
    }
    // Stay alive while the app sends (Android keeps this work running).
    await events
        .moveNext()
        .timeout(const Duration(seconds: 60), onTimeout: () => false);
    return true;
  } catch (_) {
    return false;
  } finally {
    await events.cancel();
    back.close();
  }
}
