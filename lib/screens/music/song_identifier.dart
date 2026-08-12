import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api_service.dart';
import '../../services/audio_capture.dart';
import '../../utils/toast_helper.dart';

/// Shazam-style "what's this song?" flow. The user first picks a SOURCE:
///  - "From this phone" — captures the device's own audio output (what another
///    app is playing) via Android's MediaProjection playback capture. Android
///    10+; apps that block capture (some DRM players) can't be grabbed.
///  - "Around me" — records a short clip from the microphone (ambient / a song
///    playing on a speaker nearby).
/// The clip is sent to the backend (AudD / AcoustID) and the title/artist is
/// shown with links to open it elsewhere. Available anywhere via
/// [showSongIdentifier].
Future<void> showSongIdentifier(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => const _SongIdentifierSheet(),
  );
}

enum _Phase {
  choose,
  listening, // mic
  capturing, // device audio
  identifying,
  result,
  noMatch,
  error,
  notConfigured,
  denied,
  captureFailed, // device capture cancelled / blocked / empty
}

class _SongIdentifierSheet extends StatefulWidget {
  const _SongIdentifierSheet();

  @override
  State<_SongIdentifierSheet> createState() => _SongIdentifierSheetState();
}

class _SongIdentifierSheetState extends State<_SongIdentifierSheet>
    with SingleTickerProviderStateMixin {
  // How long we listen before auto-identifying, and the earliest a user can
  // cut it short (a couple of seconds is too little for a reliable match).
  static const int _maxMs = 10000;
  static const int _minMs = 4000;

  final AudioRecorder _recorder = AudioRecorder();
  late final AnimationController _pulse;
  Timer? _tick;
  int _elapsedMs = 0;
  String? _clipPath;
  bool _stopping = false;

  bool _deviceSupported = false;

  _Phase _phase = _Phase.choose;
  Map<String, dynamic>? _result;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    // Show the source chooser first; check whether internal capture is possible
    // so we can enable/disable that option.
    AudioCapture.isSupported().then((ok) {
      if (mounted) setState(() => _deviceSupported = ok);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _pulse.dispose();
    _recorder.dispose();
    super.dispose();
  }

  // ── Mic ("around me") ───────────────────────────────────────────────────
  Future<void> _startMic() async {
    setState(() {
      _phase = _Phase.listening;
      _elapsedMs = 0;
      _result = null;
    });
    try {
      if (!await _recorder.hasPermission()) {
        if (mounted) setState(() => _phase = _Phase.denied);
        return;
      }
      final dir = await getTemporaryDirectory();
      _clipPath =
          '${dir.path}/aluta_id_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: _clipPath!,
      );
      _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (!mounted) return;
        setState(() => _elapsedMs += 100);
        if (_elapsedMs >= _maxMs) _stopAndIdentify();
      });
    } catch (_) {
      if (mounted) setState(() => _phase = _Phase.error);
    }
  }

  Future<void> _stopAndIdentify() async {
    if (_stopping) return;
    _stopping = true;
    _tick?.cancel();
    if (!mounted) return;
    setState(() => _phase = _Phase.identifying);
    try {
      final path = await _recorder.stop();
      final clip = path ?? _clipPath;
      if (clip == null) {
        if (mounted) setState(() => _phase = _Phase.error);
        return;
      }
      final file = File(clip);
      final bytes = await file.readAsBytes();
      try {
        await file.delete();
      } catch (_) {}
      if (bytes.isEmpty) {
        if (mounted) setState(() => _phase = _Phase.error);
        return;
      }
      await _identifyBytes(bytes, 'clip.m4a', 'audio/mp4');
    } catch (_) {
      if (mounted) setState(() => _phase = _Phase.error);
    } finally {
      _stopping = false;
    }
  }

  // ── Device ("from this phone") ──────────────────────────────────────────
  Future<void> _startDevice() async {
    setState(() {
      _phase = _Phase.capturing;
      _result = null;
    });
    try {
      final path = await AudioCapture.captureInternal(durationMs: _maxMs);
      if (!mounted) return;
      if (path == null) {
        // User cancelled the capture consent, the source app blocks capture, or
        // nothing was playing.
        setState(() => _phase = _Phase.captureFailed);
        return;
      }
      final file = File(path);
      final bytes = await file.readAsBytes();
      try {
        await file.delete();
      } catch (_) {}
      if (bytes.isEmpty) {
        if (mounted) setState(() => _phase = _Phase.captureFailed);
        return;
      }
      setState(() => _phase = _Phase.identifying);
      await _identifyBytes(bytes, 'clip.wav', 'audio/wav');
    } catch (_) {
      if (mounted) setState(() => _phase = _Phase.captureFailed);
    }
  }

  // ── Shared identify ─────────────────────────────────────────────────────
  Future<void> _identifyBytes(
      List<int> bytes, String filename, String mime) async {
    try {
      final res = await ApiService()
          .recognizeSong(bytes: bytes, filename: filename, mime: mime);
      if (!mounted) return;
      if (res == null) {
        setState(() => _phase = _Phase.error);
      } else if (res['error'] == 'not_configured') {
        setState(() => _phase = _Phase.notConfigured);
      } else if (res['matched'] == true) {
        setState(() {
          _result = res;
          _phase = _Phase.result;
        });
      } else {
        setState(() => _phase = _Phase.noMatch);
      }
    } catch (_) {
      if (mounted) setState(() => _phase = _Phase.error);
    }
  }

  // Return to the source chooser (used by every "Try again" / "Close" retry).
  void _backToChooser() {
    _tick?.cancel();
    if (mounted) {
      setState(() {
        _phase = _Phase.choose;
        _elapsedMs = 0;
        _result = null;
      });
    }
  }

  Future<void> _open(String? url) async {
    if (url == null || url.isEmpty) return;
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) showToast(context, 'Could not open the link');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.all(10),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: scheme.primary.withAlpha(120)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 3,
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            _body(scheme),
          ],
        ),
      ),
    );
  }

  Widget _body(ColorScheme scheme) {
    switch (_phase) {
      case _Phase.choose:
        return _chooser(scheme);
      case _Phase.listening:
        return _listening(scheme);
      case _Phase.capturing:
        return _capturing(scheme);
      case _Phase.identifying:
        return _identifying(scheme);
      case _Phase.result:
        return _resultView(scheme);
      case _Phase.noMatch:
        return _message(
          scheme,
          Icons.search_off_rounded,
          'No match found',
          'Couldn\'t recognise that one. Try again with the music a little louder or closer.',
          retry: true,
        );
      case _Phase.notConfigured:
        return _message(
          scheme,
          Icons.info_outline_rounded,
          'Not set up yet',
          'Song recognition needs an AudD API key on the server. Add AUDD_API_TOKEN in Railway to enable it.',
        );
      case _Phase.denied:
        return _message(
          scheme,
          Icons.mic_off_rounded,
          'Microphone needed',
          'Allow microphone access so Aluta can listen to the song.',
          retry: true,
        );
      case _Phase.captureFailed:
        return _message(
          scheme,
          Icons.music_off_rounded,
          'Couldn\'t capture this phone',
          'Make sure something is actually playing, then allow "Start capturing" when asked. Some apps (Spotify, Netflix and other protected players) block capture — for those, use "Around me" instead.',
          retry: true,
        );
      case _Phase.error:
        return _message(
          scheme,
          Icons.error_outline_rounded,
          'Something went wrong',
          'Couldn\'t identify the song right now. Please try again.',
          retry: true,
        );
    }
  }

  // ── Source chooser ──────────────────────────────────────────────────────
  Widget _chooser(ColorScheme scheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.graphic_eq_rounded, size: 40, color: scheme.primary),
        const SizedBox(height: 10),
        Text('Identify a song',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface)),
        const SizedBox(height: 4),
        Text('Where is the music playing?',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 18),
        _sourceTile(
          scheme,
          icon: Icons.smartphone_rounded,
          title: 'From this phone',
          subtitle: _deviceSupported
              ? 'Recognise audio playing on this device (another app, or Aluta).'
              : 'Needs Android 10 or newer.',
          enabled: _deviceSupported,
          onTap: _deviceSupported ? _startDevice : null,
        ),
        const SizedBox(height: 10),
        _sourceTile(
          scheme,
          icon: Icons.mic_rounded,
          title: 'Around me',
          subtitle: 'Listen with the microphone to music playing nearby.',
          enabled: true,
          onTap: _startMic,
        ),
        const SizedBox(height: 14),
        TextButton(
          onPressed: () => Navigator.maybePop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _sourceTile(
    ColorScheme scheme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool enabled,
    required VoidCallback? onTap,
  }) {
    final fg = enabled ? scheme.onSurface : scheme.onSurfaceVariant;
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: scheme.outlineVariant.withAlpha(120)),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: scheme.primary.withAlpha(30),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: fg)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: scheme.onSurfaceVariant.withAlpha(150)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pulsingIcon(ColorScheme scheme, IconData icon) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, _) {
        final t = _pulse.value;
        return SizedBox(
          width: 120,
          height: 120,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 92 + 28 * t,
                height: 92 + 28 * t,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary.withAlpha((40 * (1 - t)).round()),
                ),
              ),
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary,
                  boxShadow: [
                    BoxShadow(
                      color: scheme.primary.withAlpha(90),
                      blurRadius: 20,
                      spreadRadius: 2 * t,
                    ),
                  ],
                ),
                child: Icon(icon, size: 38, color: scheme.onPrimary),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _listening(ColorScheme scheme) {
    final remaining = ((_maxMs - _elapsedMs) / 1000).ceil().clamp(0, 99);
    final canStop = _elapsedMs >= _minMs;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Listening…',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface)),
        const SizedBox(height: 4),
        Text('Point the phone toward the music',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 18),
        _pulsingIcon(scheme, Icons.mic_rounded),
        const SizedBox(height: 16),
        Text('$remaining s',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant)),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: canStop ? _stopAndIdentify : null,
            icon: const Icon(Icons.hearing_rounded),
            label: Text(canStop ? 'Identify now' : 'Keep listening…'),
          ),
        ),
        TextButton(
          onPressed: _backToChooser,
          child: const Text('Back'),
        ),
      ],
    );
  }

  Widget _capturing(ColorScheme scheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Listening to this phone…',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface)),
        const SizedBox(height: 4),
        Text('Keep the audio playing',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 18),
        _pulsingIcon(scheme, Icons.smartphone_rounded),
        const SizedBox(height: 18),
        Text('Capturing the sound…',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant)),
        const SizedBox(height: 10),
      ],
    );
  }

  Widget _identifying(ColorScheme scheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Identifying…',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface)),
        const SizedBox(height: 22),
        SizedBox(
          width: 46,
          height: 46,
          child: CircularProgressIndicator(strokeWidth: 3, color: scheme.primary),
        ),
        const SizedBox(height: 22),
        Text('Matching the clip against millions of songs',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 10),
      ],
    );
  }

  Widget _resultView(ColorScheme scheme) {
    final r = _result ?? const {};
    final title = (r['title'] ?? 'Unknown title').toString();
    final artist = (r['artist'] ?? '').toString();
    final album = (r['album'] ?? '').toString();
    final artwork = (r['artwork'] ?? '').toString();
    final spotify = (r['spotify_url'] ?? '').toString();
    final apple = (r['apple_url'] ?? '').toString();
    final songLink = (r['song_link'] ?? '').toString();
    final source = (r['source'] ?? '').toString();
    final sourceLabel = source == 'acoustid'
        ? 'via AcoustID'
        : source == 'audd'
            ? 'via AudD'
            : '';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: artwork.isNotEmpty
              ? Image.network(
                  artwork,
                  width: 132,
                  height: 132,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _artFallback(scheme),
                )
              : _artFallback(scheme),
        ),
        const SizedBox(height: 14),
        Text(title,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: scheme.onSurface)),
        if (artist.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(artist,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant)),
        ],
        if (album.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(album,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: scheme.onSurfaceVariant.withAlpha(180))),
        ],
        if (sourceLabel.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(sourceLabel,
              style: TextStyle(
                  fontSize: 10.5,
                  letterSpacing: 0.3,
                  color: scheme.onSurfaceVariant.withAlpha(150))),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            if (spotify.isNotEmpty)
              _linkChip(scheme, Icons.music_note_rounded, 'Spotify',
                  () => _open(spotify)),
            if (apple.isNotEmpty)
              _linkChip(scheme, Icons.apple_rounded, 'Apple Music',
                  () => _open(apple)),
            if (songLink.isNotEmpty)
              _linkChip(scheme, Icons.open_in_new_rounded, 'Open',
                  () => _open(songLink)),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _backToChooser,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Again'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: () => Navigator.maybePop(context),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _artFallback(ColorScheme scheme) => Container(
        width: 132,
        height: 132,
        color: scheme.primaryContainer,
        child: Icon(Icons.music_note_rounded,
            size: 54, color: scheme.onPrimaryContainer),
      );

  Widget _linkChip(
      ColorScheme scheme, IconData icon, String label, VoidCallback onTap) {
    return ActionChip(
      onPressed: onTap,
      avatar: Icon(icon, size: 18, color: scheme.primary),
      label: Text(label),
      side: BorderSide(color: scheme.outlineVariant.withAlpha(120)),
    );
  }

  Widget _message(ColorScheme scheme, IconData icon, String title, String body,
      {bool retry = false}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 6),
        Icon(icon, size: 46, color: scheme.primary),
        const SizedBox(height: 12),
        Text(title,
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface)),
        const SizedBox(height: 6),
        Text(body,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.maybePop(context),
                child: const Text('Close'),
              ),
            ),
            if (retry) ...[
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _backToChooser,
                  icon: const Icon(Icons.tune_rounded, size: 18),
                  label: const Text('Try again'),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
