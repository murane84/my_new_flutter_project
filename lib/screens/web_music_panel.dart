import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/live_session_service.dart' show BytesAudioSource;
import '../utils/app_config.dart';
import '../utils/toast_helper.dart';

/// Web-only replacement for the native [MusicControls] panel.
///
/// Browsers can't scan the device music library (that's what `on_audio_query`
/// does on mobile), and the native player uses `dart:io` APIs that throw on web.
/// So on web we show a simple, working panel: pick a local audio file and play
/// it in-memory, plus a button to download the full Android app.
class WebMusicPanel extends StatefulWidget {
  const WebMusicPanel({super.key, required this.textColor});
  final Color textColor;

  @override
  State<WebMusicPanel> createState() => _WebMusicPanelState();
}

class _WebMusicPanelState extends State<WebMusicPanel> {
  final AudioPlayer _player = AudioPlayer();
  String? _title;
  bool _loading = false;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _openFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'wav', 'm4a', 'aac', 'ogg', 'flac'],
    );
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.single;
    setState(() => _loading = true);
    try {
      final bytes = await picked.readAsBytes();
      await _player.setAudioSource(BytesAudioSource(bytes));
      if (!mounted) return;
      setState(() => _title = picked.name);
      await _player.play();
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not play that file', type: ToastType.error);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _download(String fileName) async {
    final base = await AppConfig.baseUrl;
    final uri = Uri.parse('$base/downloads/$fileName');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      showToast(context, 'Could not start the download', type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.library_music_outlined, size: 56, color: theme.hintColor),
            const SizedBox(height: 12),
            Text(
              'The browser version is the lite one — your device music library '
              'and background playback need the full app.\n'
              'Play a local file here, or get the full app for your device:',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: widget.textColor),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _loading ? null : _openFile,
              icon: const Icon(Icons.folder_open),
              label: Text(_loading ? 'Loading…' : 'Open a file to play'),
            ),
            const SizedBox(height: 14),
            Text('Get the full app',
                style: theme.textTheme.labelLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _download('aluta.apk'),
                  icon: const Icon(Icons.android),
                  label: const Text('Android'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _download('aluta-windows.zip'),
                  icon: const Icon(Icons.desktop_windows),
                  label: const Text('Windows'),
                ),
              ],
            ),
            if (_title != null) ...[
              const SizedBox(height: 24),
              Text(
                _title!,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              _controls(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _controls() {
    return StreamBuilder<PlayerState>(
      stream: _player.playerStateStream,
      builder: (context, snap) {
        final playing = snap.data?.playing ?? false;
        return Column(
          children: [
            IconButton.filled(
              iconSize: 34,
              onPressed: () => playing ? _player.pause() : _player.play(),
              icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
            ),
            StreamBuilder<Duration>(
              stream: _player.positionStream,
              builder: (context, ps) {
                final pos = ps.data ?? Duration.zero;
                final dur = _player.duration ?? Duration.zero;
                final maxMs = dur.inMilliseconds.toDouble();
                return Slider(
                  value: maxMs <= 0
                      ? 0
                      : pos.inMilliseconds
                          .clamp(0, dur.inMilliseconds)
                          .toDouble(),
                  max: maxMs <= 0 ? 1 : maxMs,
                  onChanged: maxMs <= 0
                      ? null
                      : (v) => _player.seek(Duration(milliseconds: v.round())),
                );
              },
            ),
          ],
        );
      },
    );
  }
}
