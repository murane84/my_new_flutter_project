// Riverpod state for the single active Aluta GROUP voice call (mesh). Mirrors
// call_state.dart: GroupCallService is the engine and publishes an immutable
// snapshot here on every change; the group-call screen watches this provider.

import 'package:flutter_riverpod/flutter_riverpod.dart';

enum GroupCallPhase { idle, ringing, active }

class GroupCallSnapshot {
  final GroupCallPhase phase;
  final String title;
  final List<int> participantIds; // connected peers (excludes me)
  final bool muted;
  final bool speakerOn;

  const GroupCallSnapshot({
    this.phase = GroupCallPhase.idle,
    this.title = '',
    this.participantIds = const [],
    this.muted = false,
    this.speakerOn = false,
  });

  @override
  bool operator ==(Object other) =>
      other is GroupCallSnapshot &&
      other.phase == phase &&
      other.title == title &&
      other.muted == muted &&
      other.speakerOn == speakerOn &&
      _listEq(other.participantIds, participantIds);

  @override
  int get hashCode =>
      Object.hash(phase, title, muted, speakerOn, Object.hashAll(participantIds));

  static bool _listEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class GroupCallNotifier extends Notifier<GroupCallSnapshot> {
  @override
  GroupCallSnapshot build() => const GroupCallSnapshot();
  void set(GroupCallSnapshot snapshot) => state = snapshot;
}

final groupCallProvider =
    NotifierProvider<GroupCallNotifier, GroupCallSnapshot>(
        GroupCallNotifier.new);
