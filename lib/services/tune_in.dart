import 'dart:async';

import 'package:flutter/foundation.dart';

/// "Tune in" = ASK to join what a friend is already playing — never start
/// your own music at them. The request rides the app socket:
///
///   me      → friend : tune_in_request   (with the song I saw)
///   friend  → me     : tune_in_accept    (they host THEIR song, at their
///                                         position, and invite me — I join
///                                         automatically)
///                    | tune_in_decline   (reason: busy / not_playing / no)
///   me      → friend : tune_in_cancel    (I gave up waiting)
///   server  → me     : tune_in_unreachable
///
/// Starting a session yourself (when nobody is playing) is the other path:
/// the regular Listen Together host flow with your own song.
class TuneInService {
  TuneInService._();
  static final TuneInService instance = TuneInService._();

  /// Sends one event over the app socket (wired by the home page).
  void Function(Map<String, dynamic> msg)? sendSignal;

  /// Called when my request got no answer in time (home shows a toast).
  void Function(int friendId)? onTimeout;

  static const Duration _wait = Duration(seconds: 60);

  /// The friend I'm waiting on (null when not waiting).
  final ValueNotifier<int?> pending = ValueNotifier<int?>(null);
  DateTime? _pendingAt;
  Timer? _timer;

  /// The last friend who cancelled their request to me (an open "let them
  /// in?" prompt for them closes itself).
  final ValueNotifier<int?> cancelledBy = ValueNotifier<int?>(null);

  /// The friend whose phone got the ask by push (Aluta was closed there).
  final ValueNotifier<int?> pushedTo = ValueNotifier<int?>(null);

  /// The ask went out as a push: give them longer to pick up their phone.
  void markPushed(int friendId) {
    if (pending.value != friendId) return;
    pushedTo.value = friendId;
    _timer?.cancel();
    _timer = Timer(const Duration(minutes: 2), () {
      if (pending.value != friendId) return;
      cancel();
      onTimeout?.call(friendId);
    });
  }

  /// The friend who just said yes (their invite is on its way).
  final ValueNotifier<int?> accepted = ValueNotifier<int?>(null);

  bool get canSend => sendSignal != null;

  /// Ask [friendId] to let me listen along to [title]. false = no socket.
  bool request(int friendId, {String? title}) {
    final send = sendSignal;
    if (send == null) return false;
    // A new ask replaces an older one.
    final old = pending.value;
    if (old != null && old != friendId) cancel();
    send({
      'type': 'tune_in_request',
      'to': friendId,
      if (title != null && title.isNotEmpty) 'title': title,
    });
    pending.value = friendId;
    _pendingAt = DateTime.now();
    _timer?.cancel();
    _timer = Timer(_wait, () {
      if (pending.value != friendId) return;
      cancel();
      onTimeout?.call(friendId);
    });
    return true;
  }

  /// Stop waiting (tells the friend so their prompt disappears).
  void cancel() {
    final id = pending.value;
    _clear();
    if (id != null) sendSignal?.call({'type': 'tune_in_cancel', 'to': id});
  }

  /// The invite from [hostId] is the one I asked for → join without a prompt.
  bool consumeIfPending(int? hostId) {
    if (hostId == null || pending.value != hostId) return false;
    final at = _pendingAt;
    final fresh =
        at != null && DateTime.now().difference(at) < const Duration(minutes: 3);
    _clear();
    return fresh;
  }

  /// The friend answered (accept/decline) — stop the wait timer. An accept
  /// keeps [pending] set until the invite arrives (see [consumeIfPending]).
  void answered(int from, {required bool accepted}) {
    if (pending.value != from) return;
    _timer?.cancel();
    if (accepted) {
      this.accepted.value = from;
    } else {
      _clear();
    }
  }

  /// Host side: answer a request.
  void reply(int to, {required bool accept, String? reason}) {
    sendSignal?.call({
      'type': accept ? 'tune_in_accept' : 'tune_in_decline',
      'to': to,
      'reason': ?reason,
    });
  }

  void _clear() {
    accepted.value = null;
    pushedTo.value = null;
    _timer?.cancel();
    _timer = null;
    _pendingAt = null;
    pending.value = null;
  }
}
