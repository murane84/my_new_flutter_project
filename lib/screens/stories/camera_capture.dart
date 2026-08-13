import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

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
            return const Center(
              child: Text('Camera unavailable',
                  style: TextStyle(color: Colors.white70)),
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
