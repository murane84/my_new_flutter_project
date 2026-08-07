// Riverpod state for friend online presence — the final slice of the migration
// (see aluta_riverpod_pattern guide). Single source of truth for the friend-list
// online dots and the "N online" count.
//
// Presence is API-derived (each friend's `is_online` comes from _fetchFriends);
// there's no dedicated presence WebSocket event. But the open chat already
// reports its peer's online changes back via onFriendOnlineStatusChanged, so we
// route THAT into setOnline here — the friend-list dot + count then update live,
// the presence equivalent of the unread bump, instead of waiting for a refetch.

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Immutable set of friendIds currently online.
class Presence {
  final Set<int> onlineIds;

  const Presence({this.onlineIds = const {}});

  bool isOnline(int friendId) => onlineIds.contains(friendId);

  int get onlineCount => onlineIds.length;
}

class PresenceNotifier extends Notifier<Presence> {
  @override
  Presence build() => const Presence();

  /// Replace the online set from a fresh friends fetch (authoritative).
  void syncFromFriends(Set<int> online) {
    state = Presence(onlineIds: Set<int>.unmodifiable(online));
  }

  /// A single friend's status changed live (from the chat's presence signal) —
  /// flip just that id so the list dot + count react immediately.
  void setOnline(int friendId, bool online) {
    if (state.onlineIds.contains(friendId) == online) return;
    final next = Set<int>.from(state.onlineIds);
    online ? next.add(friendId) : next.remove(friendId);
    state = Presence(onlineIds: next);
  }
}

/// Rows watch `ref.watch(presenceProvider).isOnline(id)`; the count chip watches
/// `.onlineCount`; the fetch/callbacks mutate via `ref.read(presenceProvider.notifier)`.
final presenceProvider =
    NotifierProvider<PresenceNotifier, Presence>(PresenceNotifier.new);
