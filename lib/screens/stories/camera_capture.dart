import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// Take a photo with the device camera, with accurate, cause-specific feedback.
/// Mobile uses image_picker's camera (proven). Web/desktop use the `camera`
/// package (image_picker has no camera there). Shared by the story composer and
/// the chat composer so both behave identically.
///
/// The toasts name the ACTUAL reason instead of a blanket "no camera":
///   • web over http → asks for a secure (https) connection,
///   • permission blocked → asks to allow camera access,
///   • camera busy / genuinely absent → says exactly that.
Future<XFile?> capturePhoto(
  BuildContext context, {
  int imageQuality = 90,
  double? maxWidth,
}) async {
  final mobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  if (mobile) {
    return ImagePicker().pickImage(
      source: ImageSource.camera,
      imageQuality: imageQuality,
      maxWidth: maxWidth,
    );
  }
  // The browser camera API only exists in a secure context (https/localhost).
  // Detect it up-front so we can tell the user precisely (rather than "no
  // camera") when they're on a plain-http/LAN build.
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
  return Navigator.push<XFile?>(
    context,
    MaterialPageRoute(builder: (_) => CameraCaptureScreen(camera: cameras.first)),
  );
}

/// True when the current web page is a secure context (https, or localhost),
/// which the browser requires before it exposes any camera. `Uri.base` is the
/// page URL on web.
bool _webSecureContext() {
  final u = Uri.base;
  return u.scheme == 'https' ||
      u.host == 'localhost' ||
      u.host == '127.0.0.1';
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
    return 'Camera access is blocked. Allow camera access in your browser/'
        'system settings, then try again.';
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

/// A minimal in-app camera screen used where image_picker has no camera
/// (web + desktop). Shows a live preview and returns the captured photo as an
/// [XFile] via Navigator.pop (same XFile type image_picker uses, so the story
/// composer consumes it unchanged). Mobile keeps using image_picker's camera.
class CameraCaptureScreen extends StatefulWidget {
  final CameraDescription camera;

  const CameraCaptureScreen({super.key, required this.camera});

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen> {
  CameraController? _controller;
  Future<void>? _init;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final c = CameraController(
      widget.camera,
      ResolutionPreset.medium,
      enableAudio: false,
    );
    _controller = c;
    _init = c.initialize();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    final c = _controller;
    if (c == null || _busy) return;
    setState(() => _busy = true);
    try {
      await _init;
      final file = await c.takePicture();
      if (!mounted) return;
      Navigator.pop(context, file);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn’t capture — please try again')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Take a photo'),
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
            // e.g. permission denied on web → "Allow camera access…".
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
              Padding(
                padding: const EdgeInsets.only(bottom: 28),
                child: FloatingActionButton(
                  onPressed: _busy ? null : _capture,
                  child: _busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.camera_alt_rounded),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
