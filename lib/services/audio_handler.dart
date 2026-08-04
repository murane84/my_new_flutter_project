import 'package:audio_service/audio_service.dart';

import '../screens/home_page.dart' show playbackBus;

/// A lightweight [BaseAudioHandler] that acts purely as the media-session layer:
/// it does NOT own the AudioPlayer (that stays in MusicControls). Instead it
///   • forwards hardware / notification media-button events (car Bluetooth,
///     steering wheel, headset, lock screen) to the app's [playbackBus], and
///   • mirrors the player's current state into a media notification, whose
///     foreground service keeps the app alive (and online) while music plays.
class AlutaAudioHandler extends BaseAudioHandler {
  String? _lastId;

  @override
  Future<void> play() async => playbackBus.onPlay?.call();

  @override
  Future<void> pause() async => playbackBus.onPause?.call();

  @override
  Future<void> skipToNext() async => playbackBus.onNext?.call();

  @override
  Future<void> skipToPrevious() async => playbackBus.onPrev?.call();

  @override
  Future<void> seek(Duration position) async =>
      playbackBus.onSeekTo?.call(position);

  @override
  Future<void> stop() async {
    playbackBus.onPause?.call();
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      processingState: AudioProcessingState.idle,
    ));
    await super.stop();
  }

  /// Push the player's current state so the media notification / car display
  /// stays accurate and its buttons keep working. Called by MusicControls.
  void updateFromPlayer({
    required String id,
    required String title,
    required String artist,
    required bool playing,
    required Duration position,
    Duration? duration,
    bool buffering = false,
  }) {
    if (id != _lastId) {
      _lastId = id;
      mediaItem.add(MediaItem(
        id: id,
        title: title.isEmpty ? 'Aluta' : title,
        artist: artist.isEmpty ? 'Aluta' : artist,
        duration: duration,
      ));
    } else if (duration != null && mediaItem.value?.duration != duration) {
      final mi = mediaItem.value;
      if (mi != null) mediaItem.add(mi.copyWith(duration: duration));
    }

    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: buffering
          ? AudioProcessingState.buffering
          : AudioProcessingState.ready,
      playing: playing,
      updatePosition: position,
    ));
  }
}

/// Non-null once [initAudioService] succeeds. Null on platforms/without a media
/// session (web/desktop, or if init fails) — callers must null-check.
AlutaAudioHandler? audioHandler;

/// Initialise the media session. Wrapped so a failure (e.g. on a platform that
/// doesn't support it) can never stop the app from launching.
Future<void> initAudioService() async {
  try {
    audioHandler = await AudioService.init(
      builder: () => AlutaAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.aluta.playback',
        androidNotificationChannelName: 'Aluta playback',
        // Clean monochrome glyph instead of the colored logo (which Android
        // was showing as a small duplicate copy on the notification).
        androidNotificationIcon: 'drawable/ic_notification',
        // NOTE: androidNotificationOngoing must be false here because
        // androidStopForegroundOnPause is false. audio_service asserts that an
        // "ongoing" (non-dismissable) notification is only valid when the
        // foreground service is stopped on pause; combining ongoing:true with
        // stopForegroundOnPause:false is disallowed. We prioritise keeping the
        // service alive when paused (below) over making the notification
        // non-dismissable.
        androidNotificationOngoing: false,
        // Keep the foreground service alive even when paused — so a live
        // session (or backgrounded playback) is never killed when the user
        // switches to another app. The notification stays until stopped.
        androidStopForegroundOnPause: false,
      ),
    );
  } catch (_) {
    audioHandler = null;
  }
}
