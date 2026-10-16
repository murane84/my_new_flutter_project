import 'dart:async';
import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// What a camera capture produced: the file plus whether it is a video (so the
/// caller can route a recorded clip through the video pipeline and a still
/// through the image pipeline).
class CaptureResult {
  final XFile file;
  final bool isVideo;
  const CaptureResult(this.file, {required this.isVideo});
}

/// Open the in-app camera and let the user take a PHOTO or record a VIDEO.
///
/// A single camera screen is used on every platform now (mobile included), so
/// the Photo/Video toggle and the press-and-hold-to-record shortcut behave the
/// same everywhere. (The old build used the OS camera via image_picker on
/// mobile, which can only ever return a still — it has no record control.)
///
/// Returns null if the user backs out or the camera can't be opened; in the
/// latter case a cause-specific toast is shown first:
///   • web over http → asks for a secure (https) connection,
///   • permission blocked → asks to allow camera/microphone access,
///   • camera busy / genuinely absent → says exactly that.
Future<CaptureResult?> captureMedia(
  BuildContext context, {
  bool allowVideo = true,
  Duration? maxVideoDuration,
}) async {
  // The browser camera API only exists in a secure context (https/localhost).
  if (kIsWeb && !_webSecureContext()) {
    _camToast(context,
        'The camera needs a secure (https) connection to work in the browser.');
    return null;
  }
  List<CameraDescription> cameras = const [];
  try {
    cameras = await availableCameras();
  } catch (e) {
    if (context.mounted) _camToast(context, cameraErrorMessage(e));
    return null;
  }
  if (cameras.isEmpty) {
    if (context.mounted) {
      _camToast(context, 'No camera was found on this device.');
    }
    return null;
  }
  if (!context.mounted) return null;
  return Navigator.push<CaptureResult?>(
    context,
    MaterialPageRoute(
      builder: (_) => CameraCaptureScreen(
        cameras: cameras,
        allowVideo: allowVideo,
        maxVideoDuration: maxVideoDuration,
      ),
    ),
  );
}

/// Backwards-compatible photo-only entry point (returns just the still).
Future<XFile?> capturePhoto(
  BuildContext context, {
  int imageQuality = 90,
  double? maxWidth,
}) async {
  final r = await captureMedia(context, allowVideo: false);
  return r?.file;
}

/// True when the current web page is a secure context (https, or localhost),
/// which the browser requires before it exposes any camera. `Uri.base` is the
/// page URL on web.
bool _webSecureContext() {
  final u = Uri.base;
  return u.scheme == 'https' || u.host == 'localhost' || u.host == '127.0.0.1';
}

void _camToast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

/// A friendly, cause-specific message for a camera failure — so the UI never
/// says "no camera" when the real problem is a blocked permission, an insecure
/// (http) page, or the camera being in use elsewhere.
String cameraErrorMessage(Object? e) {
  final s = e.toString().toLowerCase();
  if (s.contains('notallowed') ||
      s.contains('denied') ||
      s.contains('permission')) {
    return 'Camera/microphone access is blocked. Allow access in your '
        'browser/system settings, then try again.';
  }
  if (s.contains('notreadable') ||
      s.contains('in use') ||
      s.contains('trackstart')) {
    return 'The camera is in use by another app. Close it and try again.';
  }
  if (s.contains('securi') ||
      s.contains('mediadevices') ||
      s.contains('notsupported') ||
      s.contains('not supported')) {
    return 'The camera needs a secure (https) connection to work in the browser.';
  }
  if (s.contains('notfound') ||
      s.contains('no camera') ||
      s.contains('not found')) {
    return 'No camera was found on this device.';
  }
  return 'Couldn’t open the camera. Please try again.';
}

/// In-app camera with a Photo/Video toggle. Tap the shutter for a photo; switch
/// to Video and tap to start/stop recording. On mobile you can also press and
/// hold the shutter to record for as long as you hold it (release to stop) —
/// a quick shortcut that doesn't need the toggle. Returns a [CaptureResult].
class CameraCaptureScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  final bool allowVideo;
  final Duration? maxVideoDuration;

  const CameraCaptureScreen({
    super.key,
    required this.cameras,
    this.allowVideo = true,
    this.maxVideoDuration,
  });

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen> {
  CameraController? _controller;
  Future<void>? _init;
  int _camIndex = 0;

  bool _busy = false; // taking a photo / switching camera
  bool _videoMode = false; // Photo (false) vs Video (true)
  bool _recording = false;
  bool _holdRecording = false; // started via press-and-hold on the shutter

  Timer? _ticker;
  Duration _elapsed = Duration.zero;

  bool get _isMobile =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    _setController(0);
  }

  void _setController(int index) {
    final old = _controller;
    final c = CameraController(
      widget.cameras[index],
      ResolutionPreset.high,
      // Audio is only needed for video; requesting it when we can record keeps
      // clips with sound. Photo-only launches skip the mic entirely.
      enableAudio: widget.allowVideo,
    );
    _controller = c;
    _camIndex = index;
    _init = c.initialize();
    old?.dispose();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  void _startTicker() {
    _elapsed = Duration.zero;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsed += const Duration(seconds: 1));
      final max = widget.maxVideoDuration;
      if (max != null && _elapsed >= max) _stopRecording();
    });
  }

  Future<void> _takePhoto() async {
    final c = _controller;
    if (c == null || _busy || _recording) return;
    setState(() => _busy = true);
    try {
      await _init;
      final file = await c.takePicture();
      if (!mounted) return;
      Navigator.pop(context, CaptureResult(file, isVideo: false));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _camToast(context, cameraErrorMessage(e));
    }
  }

  Future<void> _startRecording() async {
    final c = _controller;
    if (c == null || _recording || _busy) return;
    try {
      await _init;
      await c.startVideoRecording();
      if (!mounted) return;
      setState(() => _recording = true);
      _startTicker();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _recording = false;
        _holdRecording = false;
      });
      _camToast(context, cameraErrorMessage(e));
    }
  }

  Future<void> _stopRecording() async {
    final c = _controller;
    if (c == null || !_recording) return;
    _ticker?.cancel();
    try {
      final file = await c.stopVideoRecording();
      if (!mounted) return;
      Navigator.pop(context, CaptureResult(file, isVideo: true));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _recording = false;
        _holdRecording = false;
      });
      _camToast(context, cameraErrorMessage(e));
    }
  }

  // Shutter tap: photo in Photo mode, start/stop in Video mode.
  void _onShutterTap() {
    if (_holdRecording) return; // a hold just ended; ignore the trailing tap
    if (_videoMode) {
      if (_recording) {
        _stopRecording();
      } else {
        _startRecording();
      }
    } else {
      _takePhoto();
    }
  }

  // Press-and-hold shortcut (mobile): record while held, stop on release.
  void _onShutterHoldStart() {
    if (!_isMobile || !widget.allowVideo || _recording) return;
    _holdRecording = true;
    _startRecording();
  }

  void _onShutterHoldEnd() {
    if (!_holdRecording) return;
    _stopRecording();
    // Clear the flag after this frame so the trailing onTap is ignored.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _holdRecording = false;
    });
  }

  Future<void> _flipCamera() async {
    if (widget.cameras.length < 2 || _busy || _recording) return;
    setState(() => _busy = true);
    try {
      _setController((_camIndex + 1) % widget.cameras.length);
      await _init;
    } catch (_) {/* ignore and keep current */} finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(_videoMode ? 'Record a video' : 'Take a photo'),
        actions: [
          if (widget.cameras.length > 1)
            IconButton(
              tooltip: 'Flip camera',
              onPressed: (_busy || _recording) ? null : _flipCamera,
              icon: const Icon(Icons.flip_camera_ios_rounded),
            ),
        ],
      ),
      body: FutureBuilder<void>(
        future: _init,
        builder: (ctx, snap) {
          if (_controller == null ||
              snap.connectionState != ConnectionState.done) {
            return const Center(
                child: CircularProgressIndicator(color: Colors.white));
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Text(
                  cameraErrorMessage(snap.error),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            );
          }
          return Stack(
            alignment: Alignment.bottomCenter,
            children: [
              Center(child: CameraPreview(_controller!)),

              // Recording indicator (red dot + elapsed time).
              if (_recording)
                Positioned(
                  top: 16,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: const BoxDecoration(
                            color: Colors.redAccent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(_fmt(_elapsed),
                            style: const TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                ),

              // Controls: mode toggle + shutter.
              Padding(
                padding: const EdgeInsets.only(bottom: 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.allowVideo && !_recording) _modeToggle(),
                    if (widget.allowVideo && !_recording)
                      const SizedBox(height: 16),
                    if (_isMobile && widget.allowVideo && !_recording)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 10),
                        child: Text('Hold to record',
                            style: TextStyle(
                                color: Colors.white54, fontSize: 12)),
                      ),
                    _shutter(),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _modeToggle() {
    Widget chip(String label, bool selected, VoidCallback onTap) => InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Text(
              label,
              style: TextStyle(
                color: selected ? Colors.amber : Colors.white70,
                fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                letterSpacing: 0.5,
              ),
            ),
          ),
        );
    return Container(
      decoration: BoxDecoration(
        color: Colors.black38,
        borderRadius: BorderRadius.circular(22),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          chip('PHOTO', !_videoMode, () {
            if (_busy) return;
            setState(() => _videoMode = false);
          }),
          chip('VIDEO', _videoMode, () {
            if (_busy) return;
            setState(() => _videoMode = true);
          }),
        ],
      ),
    );
  }

  Widget _shutter() {
    final recording = _recording;
    return GestureDetector(
      onTap: _busy ? null : _onShutterTap,
      onLongPressStart: (_) => _onShutterHoldStart(),
      onLongPressEnd: (_) => _onShutterHoldEnd(),
      child: Container(
        width: 78,
        height: 78,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
              color: recording ? Colors.redAccent : Colors.white, width: 4),
        ),
        child: Center(
          child: _busy
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: recording ? 30 : 60,
                  height: recording ? 30 : 60,
                  decoration: BoxDecoration(
                    color: (_videoMode || recording)
                        ? Colors.redAccent
                        : Colors.white,
                    borderRadius: BorderRadius.circular(recording ? 6 : 40),
                  ),
                ),
        ),
      ),
    );
  }
}
