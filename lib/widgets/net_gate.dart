import 'dart:async';

import 'package:flutter/material.dart';

import '../services/net_check.dart';
import '../utils/toast_helper.dart';

/// Checks the internet before a Listen Together session starts (host) or is
/// joined (guest). Returns true when it's good enough. Otherwise it explains
/// why in a toast and returns false, so the session is never started on a
/// connection that would only stutter.
///
/// [retry] — offered as "Tell me when it's good": Aluta keeps re-testing in
/// the background for a few minutes and, once the signal is strong, offers to
/// carry on ([retry] runs the original action again).
/// [sendInstead] — offered as "Send the song": a file goes through even on a
/// weak network.
Future<bool> ensureListenTogetherNet(
  BuildContext context, {
  required bool host,
  String? peerName,
  VoidCallback? retry,
  VoidCallback? sendInstead,
}) async {
  if (NetCheck.cached(host: host)?.ok == true) return true;
  // Only mention the check if it takes long enough to notice.
  var told = false;
  final hint = Timer(const Duration(milliseconds: 450), () {
    if (!context.mounted) return;
    told = true;
    showToast(context, 'Checking your connection…',
        duration: const Duration(milliseconds: 1600));
  });
  final v = await NetCheck.listenTogether(host: host);
  hint.cancel();
  if (!context.mounted) return false;
  if (v.ok) return true;
  final overlay = Overlay.of(context, rootOverlay: true);
  final why = v.why ?? 'the connection is too weak';
  showToast(
    overlay.context,
    v.grade == NetGrade.offline
        ? "You're offline — Listen Together needs internet"
        : 'Your internet is too weak for Listen Together right now',
    type: ToastType.error,
    overlay: overlay,
    detail: '${why[0].toUpperCase()}${why.substring(1)}. '
        'Move to a stronger Wi-Fi or mobile signal to enjoy it.',
    duration: Duration(milliseconds: told ? 6500 : 6000),
    actions: [
      if (retry != null)
        ToastAction('Tell me', () {
          NetRetryWatch.start(
              host: host, overlay: overlay, peerName: peerName, onGood: retry);
        }),
      if (sendInstead != null) ToastAction('Send song', sendInstead),
    ],
  );
  return false;
}

/// "Ready when you are": after a failed check, re-test every 30 s for up to
/// 5 minutes; on a pass, offer to carry on with what they wanted to do.
class NetRetryWatch {
  NetRetryWatch._();

  static Timer? _timer;
  static DateTime? _until;

  static void stop() {
    _timer?.cancel();
    _timer = null;
    _until = null;
  }

  static void start({
    required bool host,
    required OverlayState overlay,
    required VoidCallback onGood,
    String? peerName,
  }) {
    stop();
    _until = DateTime.now().add(const Duration(minutes: 5));
    showToast(overlay.context,
        "Okay — I'll tell you when your signal is strong enough",
        overlay: overlay, duration: const Duration(milliseconds: 2600));
    _timer = Timer.periodic(const Duration(seconds: 30), (_) async {
      final until = _until;
      if (until == null || DateTime.now().isAfter(until) || !overlay.mounted) {
        stop();
        return;
      }
      final v = await NetCheck.listenTogether(host: host, force: true);
      if (!v.ok || _timer == null || !overlay.mounted) return;
      stop();
      final who = (peerName ?? '').trim().split(RegExp(r'\s+')).first;
      showToast(
        overlay.context,
        who.isEmpty
            ? 'Your signal is strong now — ready for Listen Together 🎧'
            : 'Your signal is strong now — listen together with $who? 🎧',
        type: ToastType.success,
        overlay: overlay,
        duration: const Duration(seconds: 8),
        onTap: onGood,
        actions: [ToastAction('Start', onGood)],
      );
    });
  }
}
