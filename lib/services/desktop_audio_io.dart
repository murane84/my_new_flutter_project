import 'dart:io' show Platform;
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

/// On Windows, route just_audio through libmpv (media_kit) instead of the
/// WinRT/Media-Foundation `just_audio_windows` backend. This removes the
/// startup race over Media Foundation with camera_windows / video_player_win
/// that could leave the player stuck "loading".
///
/// No-op on every other platform (Android/iOS/macOS keep native just_audio,
/// Linux is left unchanged). Must run before any AudioPlayer is created.
Future<void> initDesktopAudio() async {
  if (!Platform.isWindows) return;
  // Allow the local loopback HTTP server just_audio uses to serve a
  // StreamAudioSource (Listen Together's in-memory audio) to libmpv.
  JustAudioMediaKit.protocolWhitelist = const [
    'file',
    'http',
    'https',
    'tcp',
    'tls',
    'crypto',
    'data',
  ];
  JustAudioMediaKit.ensureInitialized(
    windows: true,
    linux: false,
    android: false,
    iOS: false,
    macOS: false,
  );
}
