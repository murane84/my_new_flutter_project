part of '../home_page.dart';

// Playback plumbing shared across the app: the lightweight command bus the
// ambient controls use to drive the single mounted player, and the
// value-notifiers the now-playing bar listens to.
//
// NOTE: now-playing + live-session STATE moved to Riverpod —
// see lib/state/playback_state.dart (nowPlayingProvider / liveSessionProvider).
// The PlaybackBus below is a command channel (imperative callbacks), not state,
// so it deliberately stays a plain object.

// A tiny command bus so lightweight ambient controls (e.g. the collapsed
// now-playing bar) can drive the ONE mounted player without owning the
// AudioPlayer. MusicControls registers its handlers on init and clears them
// on dispose.
class PlaybackBus {
  VoidCallback? onToggle;
  VoidCallback? onNext;
  VoidCallback? onPrev;
  // Seek to a fraction (0..1) of the current track's duration.
  void Function(double fraction)? onSeekFraction;
  // Pause the local player (used when a live session takes over playback so
  // the same song isn't heard twice).
  VoidCallback? onPause;
  // Resume playback (media-button "play"); seek to an absolute position
  // (media-button / notification scrub).
  VoidCallback? onPlay;
  void Function(Duration position)? onSeekTo;
  // Read-backs so the live-share flow can sync to what's playing now.
  String? Function()? currentPath; // file path of the current track, if any
  int Function()? currentPositionMs; // current playback position
  bool Function()? isPlaying;
  // Toggle "favourite" on the currently-playing track (driven by the bar heart).
  VoidCallback? onToggleFavorite;
}

final playbackBus = PlaybackBus();

// Command channel for the app-wide PLAYLIST DRAWER. The playlist UI lives in
// MusicControls (which is always mounted, so the drawer can render over the
// chat via the root Overlay). MusicControls registers [open]/[close]/[toggle]
// on init and clears them on dispose; any screen — e.g. a chat thread's header
// button — can drive the drawer through this bus without owning the player.
// [isOpen] lets those shortcut buttons show the right icon.
class PlaylistDrawerBus {
  VoidCallback? open;
  VoidCallback? close;
  VoidCallback? toggle;
  final ValueNotifier<bool> isOpen = ValueNotifier<bool>(false);
  // The playlist body itself, built by MusicControls (which owns the data). The
  // HOST (home_page) renders this below the active header so the header — and
  // the chat's playlist toggle — stay visible above the drawer.
  WidgetBuilder? contentBuilder;
  // Bumped by MusicControls whenever the playlist/current track/favourites
  // change while the drawer is open, so the host rebuilds the (externally
  // hosted) content with fresh data.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  bool get available => toggle != null;
}

final playlistDrawerBus = PlaylistDrawerBus();

// Elapsed / total for the current track, so the now-playing bar can show tiny
// time labels flanking the seek bar. Updated per position tick alongside
// [playProgressNotifier]; kept separate so only the times rebuild.
class PlayClock {
  const PlayClock(this.position, this.duration);
  final Duration position;
  final Duration duration;
}

final ValueNotifier<PlayClock> playClockNotifier =
    ValueNotifier<PlayClock>(const PlayClock(Duration.zero, Duration.zero));

// Whether the currently-playing track is a favourite — drives the bar's heart.
final ValueNotifier<bool> favoriteNotifier = ValueNotifier<bool>(false);

// Current playback progress (0..1), updated by the player's position stream.
// Kept separate from nowPlayingNotifier so the frequent per-tick updates only
// rebuild the tiny progress bar — not the whole chat surface.
final ValueNotifier<double> playProgressNotifier = ValueNotifier<double>(0.0);

// The music player's currently-loaded playlist (file paths), mirrored here so
// other features — like starting a live "Listen Together" from already-loaded
// songs instead of the file browser — can read it without owning the player.
final ValueNotifier<List<String>> playlistNotifier =
    ValueNotifier<List<String>>(<String>[]);
