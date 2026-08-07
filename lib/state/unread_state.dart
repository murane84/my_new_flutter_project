// Riverpod state for per-friend unread message counts — slice 3 of the
// migration (see aluta_riverpod_pattern guide). This is the single source of
// truth for the friend-list unread badges.
//
// Before: the count lived inside each friend map (`f['unread_count']`) and the
// badge only updated after a full `_fetchFriends()` round-trip. Now the friends
// fetch SYNCS authoritative counts here, opening a chat CLEARS optimistically,
// and — the win — the WebSocket `new_message` handler BUMPS the sender's count
// instantly (non-widget code, so via the app-wide providerContainer), so a
// badge appears the moment a message arrives instead of after the next refresh.

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Immutable map of friendId -> unread count.
class UnreadState {
  final Map<int, int> counts;

  const UnreadState({this.counts = const {}});

  int countFor(int friendId) => counts[friendId] ?? 0;

  int get total => counts.values.fold(0, (sum, c) => sum + c);
}

class UnreadNotifier extends Notifier<UnreadState> {
  @override
  UnreadState build() => const UnreadState();

  /// Replace all counts from a fresh friends fetch (authoritative). The caller
  /// has already zeroed the actively-open chat, so this won't resurrect a badge
  /// the user is currently reading.
  void syncFromFriends(Map<int, int> fresh) {
    state = UnreadState(counts: Map<int, int>.unmodifiable(fresh));
  }

  /// A message just arrived from [friendId] — badge it now, without waiting for
  /// the next fetch. A subsequent `syncFromFriends` reconciles to the server's
  /// authoritative number.
  void bump(int friendId) {
    final next = Map<int, int>.from(state.counts);
    next[friendId] = (next[friendId] ?? 0) + 1;
    state = UnreadState(counts: next);
  }

  /// Chat opened / messages marked read — clear the badge optimistically.
  void clear(int friendId) {
    if ((state.counts[friendId] ?? 0) == 0) return;
    final next = Map<int, int>.from(state.counts)..[friendId] = 0;
    state = UnreadState(counts: next);
  }
}

/// Badges watch `ref.watch(unreadProvider).countFor(id)`; the fetch/handlers
/// mutate via `ref.read(unreadProvider.notifier)` (widgets) or
/// `providerContainer.read(unreadProvider.notifier)` (non-widget code).
final unreadProvider =
    NotifierProvider<UnreadNotifier, UnreadState>(UnreadNotifier.new);
