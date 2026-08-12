import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

/// Captures the phone's OWN audio output — what other apps (or Aluta) are
/// playing — for the "identify song" feature, via Android's MediaProjection
/// playback-capture. Everything runs natively (see AudioCaptureService.kt +
/// MainActivity); this just bridges to it.
///
/// Limitations (platform, not ours):
///  - Android 10 (API 29) and up only.
///  - Shows a one-time "start capturing" system consent per session.
///  - Apps that opt OUT of capture (many DRM/streaming players — Spotify,
///    Netflix, sometimes YouTube) can't be captured; Aluta's own music and most
///    casual players can.
class AudioCapture {
  AudioCapture._();

  static const MethodChannel _ch = MethodChannel('aluta/audiocapture');

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// True on Android 10+ where playback capture exists. False everywhere else.
  static Future<bool> isSupported() async {
    if (!_isAndroid) return false;
    try {
      return (await _ch.invokeMethod<bool>('isSupported')) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Capture ~[durationMs] of internal audio to a WAV file and return its path,
  /// or null if the user denied the capture consent, nothing was captured (the
  /// source app blocks capture), or it failed.
  static Future<String?> captureInternal({int durationMs = 9000}) async {
    if (!_isAndroid) return null;
    try {
      final path = await _ch.invokeMethod<String>(
        'capture',
        <String, dynamic>{'durationMs': durationMs},
      );
      return (path == null || path.isEmpty) ? null : path;
    } catch (_) {
      return null;
    }
  }
}
