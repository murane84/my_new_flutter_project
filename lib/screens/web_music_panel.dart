import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/live_session_service.dart' show BytesAudioSource;
import '../services/now_playing_presence.dart';
import 'home_page.dart' show playbackBus;
import 'web_fs/music_folder.dart';
import 'web_fs/blob_url.dart';
import '../utils/app_config.dart';
import '../utils/app_reload.dart';
import '../utils/toast_helper.dart';

/// Web-only replacement for the native [MusicControls] panel.
///
/// Browsers can't scan the device music library (that's what `on_audio_query`
/// does on mobile), and the native player uses `dart:io` APIs that throw on web.
/// So on web we show a compact but real mini-player: pick one or more local
/// audio files and play them in-memory as a queue — with next/previous,
/// shuffle, repeat, seek, time labels and volume — plus a button to download
/// the full app. Playback also broadcasts to friends' "Listening now".
class WebMusicPanel extends StatefulWidget {
  const WebMusicPanel({super.key, required this.textColor});
  final Color textColor;

  @override
  State<WebMusicPanel> createState() => _WebMusicPanelState();
}

class _WebTrack {
  _WebTrack(this.name, this.load);
  final String name;
  // Lazy byte loader: picked files return their in-memory bytes; folder entries
  // read from disk on demand, so a big library never all sits in memory.
  final Future<Uint8List> Function() load;
}

// 0 = off, 1 = repeat all (wrap at the end), 2 = repeat one.
const int _repeatOff = 0;
const int _repeatAll = 1;
const int _repeatOne = 2;

class _WebMusicPanelState extends State<WebMusicPanel> {
  final AudioPlayer _player = AudioPlayer();
  final List<_WebTrack> _queue = [];
  final math.Random _rand = math.Random();
  int _index = -1;
  bool _loading = false;
  int _repeat = _repeatOff;
  bool _shuffle = false;
  double _volume = 1.0;
  double _lastVolume = 1.0; // restored when un-muting
  double _speed = 1.0;
  static const List<double> _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
  Timer? _sleepTimer;
  int _sleepMinutes = 0; // 0 = off
  StreamSubscription<PlayerState>? _psSub;
  // The bytes + title of the track currently loaded, exposed on playbackBus so
  // "Start a room" / Listen Together can host it (web has no file paths).
  Uint8List? _currentBytes;
  String? _currentTitle;
  String? _blobUrl; // object URL of the track currently loaded (web)

  @override
  void initState() {
    super.initState();
    _psSub = _player.playerStateStream.listen(_onPlayerState);
    // Let the room/listen-together flow read what the web player is playing.
    playbackBus.currentBytes = () => _currentBytes ?? Uint8List(0);
    playbackBus.currentTitle = () => _currentTitle ?? '';
    playbackBus.currentPositionMs = () => _player.position.inMilliseconds;
    playbackBus.isPlaying = () => _player.playing;
    playbackBus.onPause = () => _player.pause();
    // Expose the loaded queue so a live session's "Add song" can offer these.
    playbackBus.webQueue = () => _queue
        .map((t) => (title: _cleanTitle(t.name), load: t.load))
        .toList();
  }

  void _onPlayerState(PlayerState st) {
    // Broadcast this web listener's now-playing to friends' "Listening now"
    // (web has no audio_service handler, so we report directly).
    final name = (_index >= 0 && _index < _queue.length)
        ? _queue[_index].name
        : null;
    if (name != null) {
      final playing =
          st.playing && st.processingState != ProcessingState.completed;
      NowPlayingPresence.instance
          .reportManual(title: _cleanTitle(name), playing: playing);
    }
    // Auto-advance when a track finishes.
    if (st.processingState == ProcessingState.completed) _onComplete();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _psSub?.cancel();
    _sleepTimer?.cancel();
    if (_blobUrl != null) revokeBlobUrl(_blobUrl!);
    NowPlayingPresence.instance.reportManual(title: '', playing: false);
    // Release the bus handlers we registered (web has no other player).
    playbackBus.currentBytes = null;
    playbackBus.currentTitle = null;
    playbackBus.currentPositionMs = null;
    playbackBus.isPlaying = null;
    playbackBus.onPause = null;
    playbackBus.webQueue = null;
    _player.dispose();
    super.dispose();
  }

  // A tidy display title: drop the file extension (e.g. ".mp3").
  String _cleanTitle(String name) =>
      name.replaceAll(RegExp(r'\.[^.]+$'), '').trim();

  String _mimeFor(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.wav')) return 'audio/wav';
    if (n.endsWith('.m4a') || n.endsWith('.aac')) return 'audio/aac';
    if (n.endsWith('.ogg')) return 'audio/ogg';
    if (n.endsWith('.flac')) return 'audio/flac';
    return 'audio/mpeg';
  }

  Future<void> _openFiles() async {
    // file_picker 12: pickFiles is multi-select by default (pickFile is single),
    // so no allowMultiple flag is needed.
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'wav', 'm4a', 'aac', 'ogg', 'flac'],
    );
    if (result == null || result.files.isEmpty) return;
    setState(() => _loading = true);
    try {
      final startEmpty = _queue.isEmpty;
      for (final f in result.files) {
        final bytes = await f.readAsBytes();
        _queue.add(_WebTrack(f.name, () async => bytes));
      }
      if (!mounted) return;
      setState(() {});
      if (startEmpty) await _playAt(0);
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not load those files', type: ToastType.error);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Load every audio file in a chosen folder (web folder picker). Entries load
  /// their bytes lazily, so a large library is cheap to list.
  Future<void> _openFolder() async {
    setState(() => _loading = true);
    try {
      final startEmpty = _queue.isEmpty;
      final entries = await pickMusicFolder();
      if (entries.isEmpty) return;
      for (final e in entries) {
        _queue.add(_WebTrack(e.name, e.load));
      }
      if (!mounted) return;
      setState(() {});
      if (startEmpty) await _playAt(0);
      if (mounted) {
        showToast(
            context,
            'Loaded ${entries.length} song${entries.length == 1 ? '' : 's'}',
            type: ToastType.info);
      }
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not load that folder',
            type: ToastType.error);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _playAt(int i) async {
    if (i < 0 || i >= _queue.length) return;
    _index = i;
    if (mounted) setState(() {});
    final t = _queue[i];
    try {
      final bytes = await t.load();
      _currentBytes = bytes;
      _currentTitle = _cleanTitle(t.name);
      // Play from a fresh object URL. Switching a StreamAudioSource on
      // just_audio_web doesn't reliably swap the audio element (you keep
      // hearing the previous track), so each track gets its own blob URL and
      // we revoke the previous one. Stop first to tear down the old element.
      final prev = _blobUrl;
      final url = makeBlobUrl(bytes, _mimeFor(t.name));
      await _player.stop();
      if (url.isNotEmpty) {
        _blobUrl = url;
        await _player.setUrl(url);
      } else {
        // Non-web fallback (the panel is web-only, but keep it safe).
        _blobUrl = null;
        await _player.setAudioSource(
            BytesAudioSource(bytes, contentType: _mimeFor(t.name)));
      }
      if (prev != null) revokeBlobUrl(prev);
      await _player.setVolume(_volume);
      await _player.setSpeed(_speed);
      await _player.play();
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not play ${t.name}', type: ToastType.error);
      }
    }
  }

  int _randomOther() {
    if (_queue.length <= 1) return _index;
    int j;
    do {
      j = _rand.nextInt(_queue.length);
    } while (j == _index);
    return j;
  }

  void _onComplete() {
    if (_queue.isEmpty) return;
    if (_repeat == _repeatOne) {
      _playAt(_index);
      return;
    }
    if (_shuffle && _queue.length > 1) {
      _playAt(_randomOther());
      return;
    }
    if (_index < _queue.length - 1) {
      _playAt(_index + 1);
      return;
    }
    if (_repeat == _repeatAll) _playAt(0);
    // else: reached the end, stop.
  }

  void _next() {
    if (_queue.isEmpty) return;
    if (_shuffle && _queue.length > 1) {
      _playAt(_randomOther());
      return;
    }
    _playAt(_index < _queue.length - 1 ? _index + 1 : 0);
  }

  void _prev() {
    if (_queue.isEmpty) return;
    // Past 3s → restart the current track; otherwise go to the previous one.
    if (_player.position.inSeconds > 3) {
      _player.seek(Duration.zero);
      return;
    }
    _playAt(_index > 0 ? _index - 1 : _queue.length - 1);
  }

  void _removeAt(int i) {
    final wasCurrent = i == _index;
    setState(() => _queue.removeAt(i));
    if (_queue.isEmpty) {
      _player.stop();
      _index = -1;
      NowPlayingPresence.instance.reportManual(title: '', playing: false);
      setState(() {});
      return;
    }
    if (i < _index) {
      setState(() => _index--);
    } else if (wasCurrent) {
      if (_index >= _queue.length) _index = _queue.length - 1;
      _playAt(_index);
    }
  }

  void _toggleRepeat() => setState(() => _repeat = (_repeat + 1) % 3);
  void _toggleShuffle() => setState(() => _shuffle = !_shuffle);

  void _cycleSpeed() {
    final i = _speeds.indexOf(_speed);
    final next = _speeds[(i + 1) % _speeds.length];
    setState(() => _speed = next);
    _player.setSpeed(next);
  }

  void _toggleMute() {
    setState(() {
      if (_volume > 0) {
        _lastVolume = _volume;
        _volume = 0;
      } else {
        _volume = _lastVolume > 0 ? _lastVolume : 1.0;
      }
    });
    _player.setVolume(_volume);
  }

  void _seekBy(int seconds) {
    final target = _player.position + Duration(seconds: seconds);
    final dur = _player.duration ?? Duration.zero;
    var ms = target.inMilliseconds;
    if (ms < 0) ms = 0;
    if (dur > Duration.zero && ms > dur.inMilliseconds) {
      ms = dur.inMilliseconds;
    }
    _player.seek(Duration(milliseconds: ms));
  }

  void _clearQueue() {
    _player.stop();
    setState(() {
      _queue.clear();
      _index = -1;
    });
    if (_blobUrl != null) revokeBlobUrl(_blobUrl!);
    _blobUrl = null;
    _currentBytes = null;
    _currentTitle = null;
    NowPlayingPresence.instance.reportManual(title: '', playing: false);
  }

  void _setSleep(int minutes) {
    _sleepTimer?.cancel();
    setState(() => _sleepMinutes = minutes);
    if (minutes <= 0) return;
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      _player.pause();
      if (mounted) setState(() => _sleepMinutes = 0);
    });
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final item = _queue.removeAt(oldIndex);
      _queue.insert(newIndex, item);
      // Keep the pointer on the currently-playing track after the move.
      if (_index == oldIndex) {
        _index = newIndex;
      } else if (oldIndex < _index && newIndex >= _index) {
        _index -= 1;
      } else if (oldIndex > _index && newIndex <= _index) {
        _index += 1;
      }
    });
  }

  Future<void> _download(String fileName) async {
    final base = await AppConfig.baseUrl;
    final uri = Uri.parse('$base/downloads/$fileName');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      showToast(context, 'Could not start the download', type: ToastType.error);
    }
  }

  /// Pull-to-refresh → full page reload to fetch the newest deployed build.
  Future<void> _reloadPage() async {
    if (mounted) showToast(context, 'Refreshing…', type: ToastType.info);
    await Future.delayed(const Duration(milliseconds: 350));
    hardReloadApp();
    await Future.delayed(const Duration(seconds: 2));
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_queue.isEmpty) return _emptyState(theme);
    // Active: controls pinned at the top, queue fills the rest (scrolls inside),
    // so everything is reachable without scrolling the whole panel.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
          child: Column(
            children: [
              _sourceRow(theme),
              const SizedBox(height: 10),
              _nowPlaying(theme),
              const SizedBox(height: 2),
              _seekBar(theme),
              _transport(theme),
              _secondaryRow(theme),
              const SizedBox(height: 8),
              _queueHeader(theme),
            ],
          ),
        ),
        Divider(height: 1, color: theme.dividerColor.withValues(alpha: 0.4)),
        Expanded(child: _queueBody(theme)),
      ],
    );
  }

  // First-run / empty state: a short prompt + the load buttons, and the lite
  // note tucked into the info popover. Scrollable so pull-to-refresh still works.
  Widget _emptyState(ThemeData theme) {
    return RefreshIndicator(
      onRefresh: _reloadPage,
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight - 40),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.library_music_outlined,
                      size: 52, color: theme.hintColor),
                  const SizedBox(height: 12),
                  Text('Play music here',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(
                    'Load songs to build a queue — pick several at once, or a '
                    'whole folder.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: widget.textColor),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _loading ? null : _openFiles,
                    icon: const Icon(Icons.library_add_rounded),
                    label:
                        Text(_loading ? 'Loading…' : 'Choose songs to play'),
                  ),
                  if (folderPickSupported) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _loading ? null : _openFolder,
                      icon: const Icon(Icons.folder_copy_outlined),
                      label: const Text('Load a music folder'),
                    ),
                  ],
                  const SizedBox(height: 14),
                  _infoAnchor(theme, inline: true),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Compact source controls for the active player: add songs, load a folder,
  // and the info popover.
  Widget _sourceRow(ThemeData theme) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: _loading ? null : _openFiles,
            icon: const Icon(Icons.library_add_rounded, size: 18),
            label: Text(_loading ? 'Loading…' : 'Add songs',
                overflow: TextOverflow.ellipsis),
            style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                visualDensity: VisualDensity.compact),
          ),
        ),
        if (folderPickSupported) ...[
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _loading ? null : _openFolder,
              icon: const Icon(Icons.folder_copy_outlined, size: 18),
              label: const Text('Folder', overflow: TextOverflow.ellipsis),
              style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  visualDensity: VisualDensity.compact),
            ),
          ),
        ],
        const SizedBox(width: 2),
        _infoAnchor(theme),
      ],
    );
  }

  // The lite-player note + "get the full app" buttons, hidden behind an info
  // button and shown as a popover card over the player.
  Widget _infoAnchor(ThemeData theme, {bool inline = false}) {
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor:
            WidgetStatePropertyAll(theme.colorScheme.surfaceContainerHigh),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16))),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      ),
      builder: (context, controller, _) {
        void toggle() =>
            controller.isOpen ? controller.close() : controller.open();
        if (inline) {
          return TextButton.icon(
            onPressed: toggle,
            icon: const Icon(Icons.info_outline_rounded, size: 16),
            label: const Text('About this player · Get the app'),
          );
        }
        return IconButton(
          tooltip: 'About · Get the app',
          iconSize: 20,
          color: theme.hintColor,
          onPressed: toggle,
          icon: const Icon(Icons.info_outline_rounded),
        );
      },
      menuChildren: [_infoCard(theme)],
    );
  }

  Widget _infoCard(ThemeData theme) {
    return Container(
      width: 280,
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.library_music_outlined,
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Text('Lite web player',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            "Browsers can't scan your music library, so load songs to play "
            'here — pick several at once, or a whole folder. The full app adds '
            'your library + background playback.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: widget.textColor),
          ),
          const SizedBox(height: 12),
          Text('Get the full app',
              style: theme.textTheme.labelMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _download('aluta.apk'),
              icon: const Icon(Icons.android, size: 18),
              label: const Text('Android'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _download('aluta-windows.zip'),
              icon: const Icon(Icons.desktop_windows, size: 18),
              label: const Text('Windows'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _nowPlaying(ThemeData theme) {
    final name = (_index >= 0 && _index < _queue.length)
        ? _cleanTitle(_queue[_index].name)
        : '';
    return Column(
      children: [
        Text(name,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        Text('Track ${_index + 1} of ${_queue.length}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.hintColor)),
      ],
    );
  }

  Widget _seekBar(ThemeData theme) {
    return StreamBuilder<Duration>(
      stream: _player.positionStream,
      builder: (context, ps) {
        final pos = ps.data ?? Duration.zero;
        final dur = _player.duration ?? Duration.zero;
        final maxMs = dur.inMilliseconds.toDouble();
        return Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                value: maxMs <= 0
                    ? 0
                    : pos.inMilliseconds
                        .clamp(0, dur.inMilliseconds)
                        .toDouble(),
                max: maxMs <= 0 ? 1 : maxMs,
                onChanged: maxMs <= 0
                    ? null
                    : (v) => _player.seek(Duration(milliseconds: v.round())),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(pos),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.hintColor)),
                  Text(_fmt(dur),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.hintColor)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _transport(ThemeData theme) {
    return StreamBuilder<PlayerState>(
      stream: _player.playerStateStream,
      builder: (context, snap) {
        final playing = snap.data?.playing ?? false;
        final buffering = snap.data?.processingState == ProcessingState.loading ||
            snap.data?.processingState == ProcessingState.buffering;
        return FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              iconSize: 28,
              onPressed: _queue.length > 1 ? _prev : null,
              icon: const Icon(Icons.skip_previous_rounded),
            ),
            IconButton(
              tooltip: 'Back 10s',
              iconSize: 24,
              onPressed: () => _seekBy(-10),
              icon: const Icon(Icons.replay_10_rounded),
            ),
            const SizedBox(width: 2),
            IconButton.filled(
              iconSize: 34,
              onPressed: buffering
                  ? null
                  : () => playing ? _player.pause() : _player.play(),
              icon: buffering
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    )
                  : Icon(playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded),
            ),
            const SizedBox(width: 2),
            IconButton(
              tooltip: 'Forward 10s',
              iconSize: 24,
              onPressed: () => _seekBy(10),
              icon: const Icon(Icons.forward_10_rounded),
            ),
            IconButton(
              iconSize: 28,
              onPressed: _queue.length > 1 ? _next : null,
              icon: const Icon(Icons.skip_next_rounded),
            ),
          ],
          ),
        );
      },
    );
  }

  Widget _secondaryRow(ThemeData theme) {
    final accent = theme.colorScheme.primary;
    IconData repeatIcon;
    switch (_repeat) {
      case _repeatOne:
        repeatIcon = Icons.repeat_one_rounded;
        break;
      default:
        repeatIcon = Icons.repeat_rounded;
    }
    return Row(
      children: [
        IconButton(
          tooltip: 'Shuffle',
          iconSize: 20,
          onPressed: _queue.length > 1 ? _toggleShuffle : null,
          color: _shuffle ? accent : theme.hintColor,
          icon: const Icon(Icons.shuffle_rounded),
        ),
        IconButton(
          tooltip: _repeat == _repeatOne
              ? 'Repeat one'
              : _repeat == _repeatAll
                  ? 'Repeat all'
                  : 'Repeat off',
          iconSize: 20,
          onPressed: _toggleRepeat,
          color: _repeat == _repeatOff ? theme.hintColor : accent,
          icon: Icon(repeatIcon),
        ),
        // Playback speed — cycles 0.5x … 2x.
        InkWell(
          onTap: _cycleSpeed,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Text(
              '${_speed.toStringAsFixed(_speed.truncateToDouble() == _speed ? 0 : 2)}x',
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: _speed == 1.0 ? theme.hintColor : accent),
            ),
          ),
        ),
        const SizedBox(width: 2),
        IconButton(
          tooltip: _volume <= 0 ? 'Unmute' : 'Mute',
          iconSize: 18,
          onPressed: _toggleMute,
          color: theme.hintColor,
          icon: Icon(
            _volume <= 0
                ? Icons.volume_off_rounded
                : _volume < 0.5
                    ? Icons.volume_down_rounded
                    : Icons.volume_up_rounded,
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              value: _volume,
              onChanged: (v) {
                setState(() => _volume = v);
                _player.setVolume(v);
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _queueHeader(ThemeData theme) {
    return Row(
      children: [
        Icon(Icons.queue_music_rounded,
            size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 6),
        Text('Queue (${_queue.length})',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        const Spacer(),
        // Sleep timer — pause playback after a while.
        PopupMenuButton<int>(
          tooltip: 'Sleep timer',
          onSelected: _setSleep,
          itemBuilder: (_) => const [
            PopupMenuItem(value: 0, child: Text('Sleep: Off')),
            PopupMenuItem(value: 15, child: Text('Sleep in 15 min')),
            PopupMenuItem(value: 30, child: Text('Sleep in 30 min')),
            PopupMenuItem(value: 60, child: Text('Sleep in 60 min')),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bedtime_outlined,
                    size: 18,
                    color: _sleepMinutes > 0
                        ? theme.colorScheme.primary
                        : theme.hintColor),
                if (_sleepMinutes > 0) ...[
                  const SizedBox(width: 3),
                  Text('${_sleepMinutes}m',
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.primary)),
                ],
              ],
            ),
          ),
        ),
        IconButton(
          tooltip: 'Clear queue',
          iconSize: 18,
          color: theme.hintColor,
          onPressed: _clearQueue,
          icon: const Icon(Icons.playlist_remove_rounded),
        ),
      ],
    );
  }

  // The queue fills the Expanded area below the controls and scrolls inside it.
  Widget _queueBody(ThemeData theme) {
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      itemCount: _queue.length,
      // onReorder is the stable, widely-supported callback; onReorderItem
      // only exists on very recent channels.
      // ignore: deprecated_member_use
      onReorder: _reorder,
      itemBuilder: (_, i) {
            final current = i == _index;
            return ListTile(
              key: ValueKey(_queue[i]),
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: Icon(
                current
                    ? Icons.graphic_eq_rounded
                    : Icons.music_note_rounded,
                size: 18,
                color: current ? theme.colorScheme.primary : theme.hintColor,
              ),
              title: Text(
                _cleanTitle(_queue[i].name),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: current ? FontWeight.bold : FontWeight.normal,
                  color: current
                      ? theme.colorScheme.primary
                      : widget.textColor,
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    iconSize: 18,
                    tooltip: 'Remove',
                    onPressed: () => _removeAt(i),
                    icon: const Icon(Icons.close_rounded),
                  ),
                  ReorderableDragStartListener(
                    index: i,
                    child: Icon(Icons.drag_handle_rounded,
                        size: 18, color: theme.hintColor),
                  ),
                ],
              ),
              onTap: current ? null : () => _playAt(i),
            );
          },
    );
  }
}
