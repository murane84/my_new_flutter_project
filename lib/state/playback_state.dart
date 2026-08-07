// Riverpod state for the "ambient" playback surface: what's playing now, and
// the active "Listen Together" live session. This replaces the two hand-rolled
// global ChangeNotifiers (nowPlayingNotifier / liveSessionNotifier) that used
// to live in home_page.dart.
//
// The pattern, so it can be repeated for presence + unread counts:
//   1. An IMMUTABLE state class (NowPlaying / LiveSession) — a plain value.
//   2. A Notifier<State> that owns the only mutation methods and swaps `state`.
//   3. A NotifierProvider the UI watches.
// Widgets read reactively with `ref.watch(provider)` (rebuild on change) and
// mutate with `ref.read(provider.notifier).method()`. Non-widget code (services,
// top-level callbacks, the WebSocket handler) has no `ref`, so it goes through
// the app-wide `providerContainer` defined at the bottom.

import 'package:flutter_riverpod/flutter_riverpod.dart';

// ─── Now playing ─────────────────────────────────────────────────────────────

/// Immutable snapshot of what the ambient now-playing UI (footer bar + media
/// notification) should show. Being immutable is what makes stale-UI bugs hard
/// to write: every change produces a brand-new value that Riverpod diffs.
class NowPlaying {
  final String track;
  final String artist;
  final bool playing;

  const NowPlaying({
    this.track = '',
    this.artist = '',
    this.playing = false,
  });

  NowPlaying copyWith({String? track, String? artist, bool? playing}) =>
      NowPlaying(
        track: track ?? this.track,
        artist: artist ?? this.artist,
        playing: playing ?? this.playing,
      );
}

class NowPlayingNotifier extends Notifier<NowPlaying> {
  @override
  NowPlaying build() => const NowPlaying();

  /// Mirrors the former `nowPlayingNotifier.update(...)`. No-ops when nothing
  /// changed so listeners don't rebuild for identical values.
  void update({
    required String track,
    required String artist,
    required bool playing,
  }) {
    if (state.track == track &&
        state.artist == artist &&
        state.playing == playing) {
      return;
    }
    state = NowPlaying(track: track, artist: artist, playing: playing);
  }
}

/// Watch with `ref.watch(nowPlayingProvider)`; mutate with
/// `ref.read(nowPlayingProvider.notifier).update(...)`.
final nowPlayingProvider =
    NotifierProvider<NowPlayingNotifier, NowPlaying>(NowPlayingNotifier.new);

// ─── Live "Listen Together" session ──────────────────────────────────────────

/// Immutable snapshot of the active live session, if any. `active == false` is
/// the "no session" state (peer/asHost are then meaningless).
class LiveSession {
  final bool active;
  final String peer;
  final bool asHost;

  const LiveSession({
    this.active = false,
    this.peer = '',
    this.asHost = false,
  });
}

class LiveSessionNotifier extends Notifier<LiveSession> {
  @override
  LiveSession build() => const LiveSession();

  /// Mirrors the former `liveSessionNotifier.start(...)`.
  void start({required String peer, required bool asHost}) {
    state = LiveSession(active: true, peer: peer, asHost: asHost);
  }

  /// Mirrors the former `liveSessionNotifier.stop()`.
  void stop() {
    if (!state.active) return;
    state = const LiveSession();
  }
}

/// Watch with `ref.watch(liveSessionProvider)`; mutate with
/// `ref.read(liveSessionProvider.notifier).start(...)` / `.stop()`.
final liveSessionProvider =
    NotifierProvider<LiveSessionNotifier, LiveSession>(LiveSessionNotifier.new);

// ─── App-wide container (bridge for non-widget code) ─────────────────────────

/// The ONE container that owns provider state for the whole app.
///
/// `main()` wires this exact instance into the widget tree via
/// `UncontrolledProviderScope`, so a widget's `ref` and this container read and
/// write the SAME state. Use this only where there is no `ref` — services,
/// top-level callbacks, the WebSocket handler:
///
///   providerContainer.read(liveSessionProvider.notifier).stop();
///
/// In widgets, always prefer `ref` (ConsumerWidget / ConsumerState).
final providerContainer = ProviderContainer();
