// Riverpod state for the single active Aluta voice call — slice 2 of the
// migration (see aluta_riverpod_pattern guide). Same three-piece shape as
// playback_state.dart.
//
// CallService (lib/services/call_service.dart) is the WebRTC ENGINE and keeps
// all its logic; it used to be a ChangeNotifier that screens listened to. Now
// it publishes an immutable CallSnapshot into `callProvider` on every state
// change (via the app-wide providerContainer, since it's non-widget code), and
// the call screen watches that provider instead of add/removeListener.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/call_service.dart' show CallState, CallEndReason;

/// The parts of the call that CHANGE while it's live and must trigger UI
/// rebuilds. Stable descriptors (peer name/avatar, isCaller, fallback phone)
/// are set once at call setup and read straight off CallService, so they're not
/// duplicated here. Value equality means redundant publishes don't rebuild.
class CallSnapshot {
  final CallState state;
  final CallEndReason endReason;
  final bool muted;
  final bool speakerOn;

  const CallSnapshot({
    this.state = CallState.idle,
    this.endReason = CallEndReason.none,
    this.muted = false,
    this.speakerOn = false,
  });

  @override
  bool operator ==(Object other) =>
      other is CallSnapshot &&
      other.state == state &&
      other.endReason == endReason &&
      other.muted == muted &&
      other.speakerOn == speakerOn;

  @override
  int get hashCode => Object.hash(state, endReason, muted, speakerOn);
}

class CallNotifier extends Notifier<CallSnapshot> {
  @override
  CallSnapshot build() => const CallSnapshot();

  /// Called by CallService whenever its call state changes.
  void set(CallSnapshot snapshot) => state = snapshot;
}

/// Watch with `ref.watch(callProvider)` to rebuild on call-state changes;
/// react to transitions (e.g. auto-close on end) with `ref.listen(callProvider, ...)`.
final callProvider =
    NotifierProvider<CallNotifier, CallSnapshot>(CallNotifier.new);
