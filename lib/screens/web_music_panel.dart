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
import '../utils/bounce_tap.dart' show Tactile;
import '../services/track_title.dart'
    show cleanDisplayName, splitTitleArtist;
import 'listening_audience_sheet.dart' show PresenceShareButton;

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
  // Volume is tap-to-reveal (mirrors the native player): the slider only
  // appears when the user taps the volume icon, then auto-hides after a short
  // idle — so it never looks like a second seek bar.
  bool _showVolume = false;
  Timer? _volumeHideTimer;
  // Ticks whenever the queue or current track changes, so the in-chat queue
  // sheet can mirror this player and stay live.
  final ValueNotifier<int> _queueRev = ValueNotifier<int>(0);
  // Playlist tile collapses/expands the inline queue (native has the list
  // behind its Playlist button).
  bool _queueCollapsed = false;

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
    // Let the in-chat queue sheet mirror + control this player.
    playbackBus.webCurrentIndex = () => _index;
    playbackBus.webPlayAt = (i) => _playAt(i);
    playbackBus.webQueueRev = _queueRev;
    playbackBus.onToggle =
        () => _player.playing ? _player.pause() : _player.play();
    playbackBus.onPlay = () => _player.play();
    playbackBus.onNext = _next;
    playbackBus.onPrev = _prev;
    playbackBus.onSeekFraction = (fr) {
      final d = _player.duration;
      if (d != null && d.inMilliseconds > 0) {
        _player.seek(d * fr.clamp(0.0, 1.0));
      }
    };
    playbackBus.webDurationMs = () => _player.duration?.inMilliseconds ?? 0;
    playbackBus.webShuffle = () => _shuffle;
    playbackBus.webRepeat = () => _repeat;
    playbackBus.onToggleShuffle = _toggleShuffle;
    playbackBus.onToggleRepeat = _toggleRepeat;
    playbackBus.webAddSongs = () => _openFiles();
    playbackBus.webRemoveAt = _removeAt;
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
    _queueRev.value++;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _psSub?.cancel();
    _sleepTimer?.cancel();
    _volumeHideTimer?.cancel();
    _bannerTimer?.cancel();
    if (_blobUrl != null) revokeBlobUrl(_blobUrl!);
    NowPlayingPresence.instance.reportManual(title: '', playing: false);
    // Release the bus handlers we registered (web has no other player).
    playbackBus.currentBytes = null;
    playbackBus.currentTitle = null;
    playbackBus.currentPositionMs = null;
    playbackBus.isPlaying = null;
    playbackBus.onPause = null;
    playbackBus.webQueue = null;
    playbackBus.webCurrentIndex = null;
    playbackBus.webPlayAt = null;
    playbackBus.webQueueRev = null;
    playbackBus.onToggle = null;
    playbackBus.onPlay = null;
    playbackBus.onNext = null;
    playbackBus.onPrev = null;
    playbackBus.onSeekFraction = null;
    playbackBus.webDurationMs = null;
    playbackBus.webShuffle = null;
    playbackBus.webRepeat = null;
    playbackBus.onToggleShuffle = null;
    playbackBus.onToggleRepeat = null;
    playbackBus.webAddSongs = null;
    playbackBus.webRemoveAt = null;
    _queueRev.dispose();
    _player.dispose();
    super.dispose();
  }

  // A tidy display title: drop the file extension AND the downloader junk
  // ("Downloaded from clipzag.com", skiza spam, "(Official Video)", bare
  // domains …) so it matches how the native app shows the same song.
  String _cleanTitle(String name) => cleanDisplayName(name);

  String _mimeFor(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.wav')) return 'audio/wav';
    if (n.endsWith('.m4a') || n.endsWith('.aac')) return 'audio/aac';
    if (n.endsWith('.ogg')) return 'audio/ogg';
    if (n.endsWith('.flac')) return 'audio/flac';
    return 'audio/mpeg';
  }

  Future<void> _openFiles() async {
    // Multi-select (allowMultiple) so a phone/web user can grab many songs at
    // once, like the desktop picker — without it the browser input is single.
    final result = await FilePicker.pickFiles(
      allowMultiple: true, // ignore: deprecated_member_use
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
        _queueRev.value++;
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
        _queueRev.value++;
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
    _queueRev.value++;
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

  void _toggleRepeat() {
    setState(() => _repeat = (_repeat + 1) % 3);
    _queueRev.value++;
  }

  void _toggleShuffle() {
    setState(() => _shuffle = !_shuffle);
    _queueRev.value++;
  }

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
    _queueRev.value++;
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
              _nowPlayingCard(theme),
              const SizedBox(height: 8),
              _seekBar(theme),
              _transport(theme),
              const SizedBox(height: 8),
              _featureRow(theme),
              const SizedBox(height: 12),
              _bottomRow(theme),
              const SizedBox(height: 8),
              if (!_queueCollapsed) _queueHeader(theme),
            ],
          ),
        ),
        if (!_queueCollapsed) ...[
          Divider(height: 1, color: theme.dividerColor.withValues(alpha: 0.4)),
          Expanded(child: _queueBody(theme)),
        ] else
          const Spacer(),
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

  // A vinyl disc, like the native player's now-playing art.
  Widget _vinyl(Color accent) {
    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [Color.lerp(accent, Colors.black, 0.5)!, Colors.black],
          stops: const [0.18, 1.0],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Center(
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: accent,
            boxShadow: [
              BoxShadow(color: accent.withValues(alpha: 0.6), blurRadius: 8),
            ],
          ),
          child: Center(
            child: Container(
              width: 5,
              height: 5,
              decoration: const BoxDecoration(
                  shape: BoxShape.circle, color: Colors.black),
            ),
          ),
        ),
      ),
    );
  }

  // Now-playing card: disc + title + track counter + live indicator + heart,
  // mirroring the native player's header card.
  Widget _nowPlayingCard(ThemeData theme) {
    final scheme = theme.colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final accent = scheme.primary;
    final name = (_index >= 0 && _index < _queue.length)
        ? _cleanTitle(_queue[_index].name)
        : 'Nothing playing';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
                accent.withValues(alpha: isDark ? 0.13 : 0.07), scheme.surface),
            scheme.surface,
          ],
        ),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          _vinyl(accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 14.5),
                ),
                const SizedBox(height: 2),
                Text(
                  _queue.isEmpty
                      ? ''
                      : 'Track ${_index + 1} of ${_queue.length}',
                  style: TextStyle(fontSize: 11.5, color: theme.hintColor),
                ),
              ],
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.podcasts_rounded, size: 18, color: accent),
              const SizedBox(height: 6),
              // Favourites need the account-backed library → not on web.
              GestureDetector(
                onTap: () => _featureUnavailable('Favourites'),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.favorite_border_rounded,
                      size: 20, color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _seekBar(ThemeData theme) {
    final accent = theme.colorScheme.primary;
    // Stable bar pattern per track (survives shuffle/reorder) — keyed on the
    // track name so the same song always draws the same waveform.
    final seed = (_index >= 0 && _index < _queue.length)
        ? _queue[_index].name.hashCode
        : 0;
    return StreamBuilder<Duration>(
      stream: _player.positionStream,
      builder: (context, ps) {
        final pos = ps.data ?? Duration.zero;
        final dur = _player.duration ?? Duration.zero;
        final durMs = dur.inMilliseconds;
        final frac =
            durMs <= 0 ? 0.0 : (pos.inMilliseconds / durMs).clamp(0.0, 1.0);
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              // A SoundCloud-style waveform that IS the seek control — the same
              // look and feel as the native (Windows/Android) player.
              child: _WebWaveformSeekBar(
                fraction: frac,
                accent: accent,
                inactive: accent.withValues(alpha: 0.20),
                enabled: durMs > 0,
                seed: seed,
                onSeek: (f) =>
                    _player.seek(Duration(milliseconds: (f * durMs).round())),
                labelFor: (f) =>
                    _fmt(Duration(milliseconds: (f * durMs).round())),
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
        final buffering =
            snap.data?.processingState == ProcessingState.loading ||
                snap.data?.processingState == ProcessingState.buffering;
        return FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _discBtn(
                theme,
                icon: Icons.shuffle_rounded,
                size: 18,
                tooltip: 'Shuffle',
                onTap: _queue.length > 1 ? _toggleShuffle : null,
                active: _shuffle,
              ),
              const SizedBox(width: 8),
              _discBtn(
                theme,
                icon: Icons.skip_previous_rounded,
                size: 24,
                tooltip: 'Previous',
                onTap: _queue.length > 1 ? _prev : null,
              ),
              const SizedBox(width: 6),
              _discBtn(
                theme,
                icon: Icons.replay_10_rounded,
                size: 22,
                tooltip: 'Back 10s',
                onTap: () => _seekBy(-10),
              ),
              const SizedBox(width: 12),
              _playDisc(theme, playing: playing, buffering: buffering),
              const SizedBox(width: 12),
              _discBtn(
                theme,
                icon: Icons.forward_10_rounded,
                size: 22,
                tooltip: 'Forward 10s',
                onTap: () => _seekBy(10),
              ),
              const SizedBox(width: 6),
              _discBtn(
                theme,
                icon: Icons.skip_next_rounded,
                size: 24,
                tooltip: 'Next',
                onTap: _queue.length > 1 ? _next : null,
              ),
              const SizedBox(width: 8),
              _discBtn(
                theme,
                icon: _repeat == _repeatOne
                    ? Icons.repeat_one_rounded
                    : Icons.repeat_rounded,
                size: 18,
                tooltip: _repeat == _repeatOne
                    ? 'Repeat one'
                    : _repeat == _repeatAll
                        ? 'Repeat all'
                        : 'Repeat off',
                onTap: _toggleRepeat,
                active: _repeat != _repeatOff,
              ),
            ],
          ),
        );
      },
    );
  }

  // A raised, top-lit accent-tinted disc so bare transport icons read as 3D
  // chips — the same treatment as the native (Windows/Android) player.
  Widget _discBtn(
    ThemeData theme, {
    required IconData icon,
    required double size,
    required String tooltip,
    VoidCallback? onTap,
    bool active = false,
    Color? activeColor,
  }) {
    final scheme = theme.colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final enabled = onTap != null;
    final tint = active ? (activeColor ?? scheme.primary) : scheme.primary;
    final iconColor = !enabled
        ? scheme.onSurface.withValues(alpha: 0.30)
        : active
            ? tint
            : scheme.onSurface;
    return Tactile(
      enabled: enabled,
      child: Tooltip(
        message: tooltip,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: enabled
                  ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color.alphaBlend(
                          tint.withValues(alpha: isDark ? 0.14 : 0.09),
                          scheme.surface,
                        ),
                        Color.alphaBlend(
                          tint.withValues(alpha: isDark ? 0.24 : 0.16),
                          scheme.surfaceContainerHighest,
                        ),
                      ],
                    )
                  : null,
              color: enabled
                  ? null
                  : scheme.surfaceContainerHighest.withValues(alpha: 0.30),
              border: Border.all(
                color: enabled
                    ? tint.withValues(alpha: isDark ? 0.32 : 0.22)
                    : scheme.outlineVariant.withValues(alpha: 0.30),
                width: 1,
              ),
              boxShadow: enabled
                  ? [
                      BoxShadow(
                        color: tint.withValues(alpha: isDark ? 0.22 : 0.14),
                        blurRadius: 7,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : null,
            ),
            child: Icon(icon, size: size, color: iconColor),
          ),
        ),
      ),
    );
  }

  // A small raised pill matching the disc buttons, showing playback speed.
  Widget _speedPill(ThemeData theme, String label) {
    final scheme = theme.colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final active = _speed != 1.0;
    final tint = scheme.primary;
    return Tactile(
      child: Tooltip(
        message: 'Playback speed',
        child: GestureDetector(
          onTap: _cycleSpeed,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.alphaBlend(
                    tint.withValues(alpha: isDark ? 0.14 : 0.09),
                    scheme.surface,
                  ),
                  Color.alphaBlend(
                    tint.withValues(alpha: isDark ? 0.24 : 0.16),
                    scheme.surfaceContainerHighest,
                  ),
                ],
              ),
              border: Border.all(
                color: tint.withValues(alpha: isDark ? 0.32 : 0.22),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: tint.withValues(alpha: isDark ? 0.22 : 0.14),
                  blurRadius: 7,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: active ? tint : scheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // The glossy primary play/pause disc — white-lit top-left → accent → a darker
  // accent at the bottom-right, with an accent glow (brighter while playing).
  Widget _playDisc(ThemeData theme,
      {required bool playing, required bool buffering}) {
    final accent = theme.colorScheme.primary;
    return Tactile(
      enabled: !buffering,
      child: GestureDetector(
        onTap: buffering
            ? null
            : () => playing ? _player.pause() : _player.play(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(accent, Colors.white, 0.22)!,
                accent,
                Color.lerp(accent, Colors.black, 0.14)!,
              ],
              stops: const [0.0, 0.55, 1.0],
            ),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: playing ? 0.58 : 0.28),
                blurRadius: playing ? 22 : 12,
                spreadRadius: 2,
              ),
            ],
          ),
          child: buffering
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2.5),
                )
              : Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 34,
                  color: Colors.white,
                ),
        ),
      ),
    );
  }

  // ── Native-style feature row + bottom row ────────────────────────────────

  // Playlist · Sleep · Equalizer · Lyrics — mirrors the native player. The two
  // that need the device/account (Equalizer DSP, synced Lyrics) aren't possible
  // on web, so tapping them shows a banner pointing to the Windows/Android app.
  Widget _featureRow(ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _featureTile(
          theme,
          icon: Icons.queue_music_rounded,
          label: 'Playlist',
          active: !_queueCollapsed,
          badge: _queue.isNotEmpty ? '${_queue.length}' : null,
          onTap: () => setState(() => _queueCollapsed = !_queueCollapsed),
        ),
        _featureTile(
          theme,
          icon: Icons.snooze_rounded,
          label: 'Sleep',
          active: _sleepMinutes > 0,
          badge: _sleepMinutes > 0 ? '${_sleepMinutes}m' : null,
          onTap: _showSleepMenu,
        ),
        _featureTile(
          theme,
          icon: Icons.graphic_eq_rounded,
          label: 'Equalizer',
          available: false,
          onTap: () => _featureUnavailable('Equalizer'),
        ),
        _featureTile(
          theme,
          icon: Icons.lyrics_rounded,
          label: 'Lyrics',
          available: false,
          onTap: () => _featureUnavailable('Lyrics'),
        ),
      ],
    );
  }

  Widget _featureTile(
    ThemeData theme, {
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    bool active = false,
    bool available = true,
    String? badge,
  }) {
    final scheme = theme.colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final accent = scheme.primary;
    final tint = active ? accent : accent.withValues(alpha: isDark ? 0.5 : 0.4);
    final iconColor = !available
        ? scheme.onSurfaceVariant.withValues(alpha: 0.55)
        : active
            ? accent
            : scheme.onSurface;
    return Tactile(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color.alphaBlend(
                            tint.withValues(alpha: isDark ? 0.14 : 0.09),
                            scheme.surface),
                        Color.alphaBlend(
                            tint.withValues(alpha: isDark ? 0.24 : 0.16),
                            scheme.surfaceContainerHighest),
                      ],
                    ),
                    border: Border.all(
                      color: active
                          ? accent.withValues(alpha: 0.5)
                          : accent.withValues(alpha: 0.18),
                      width: 1,
                    ),
                    boxShadow: active
                        ? [
                            BoxShadow(
                              color: accent.withValues(alpha: 0.28),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ]
                        : null,
                  ),
                  child: Icon(icon, size: 20, color: iconColor),
                ),
                if (badge != null)
                  Positioned(
                    right: -4,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: accent,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Text(
                        badge,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                if (!available)
                  Positioned(
                    right: -3,
                    bottom: -3,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: scheme.outlineVariant
                                .withValues(alpha: 0.6)),
                      ),
                      child: Icon(Icons.lock_rounded,
                          size: 9, color: scheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: !available
                    ? scheme.onSurfaceVariant.withValues(alpha: 0.7)
                    : active
                        ? accent
                        : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Bottom row — volume (floating slider) · share · speed, like native.
  Widget _bottomRow(ThemeData theme) {
    final scheme = theme.colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final accent = scheme.primary;
    final speedLabel =
        '${_speed.toStringAsFixed(_speed.truncateToDouble() == _speed ? 0 : 2)}x';
    final volIcon = _volume <= 0
        ? Icons.volume_off_rounded
        : _volume < 0.5
            ? Icons.volume_down_rounded
            : Icons.volume_up_rounded;
    return SizedBox(
      height: 54,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              GestureDetector(
                onLongPress: () {
                  _toggleMute();
                  _armVolumeHide();
                },
                child: _discBtn(
                  theme,
                  icon: volIcon,
                  size: 18,
                  tooltip: 'Volume  (hold to mute)',
                  onTap: _toggleVolume,
                  active: _showVolume || _volume <= 0,
                ),
              ),
              // Share "listening now": tap = on/off, long-press = who sees it.
              PresenceShareButton(color: accent, size: 20),
              _speedPill(theme, speedLabel),
            ],
          ),
          // Floating volume slider — glows over the row, fades back to the icon.
          IgnorePointer(
            ignoring: !_showVolume,
            child: AnimatedOpacity(
              opacity: _showVolume ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              child: AnimatedScale(
                scale: _showVolume ? 1 : 0.86,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutBack,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 300),
                  padding: const EdgeInsets.only(left: 4, right: 12),
                  decoration: BoxDecoration(
                    color: Color.alphaBlend(
                      accent.withValues(alpha: isDark ? 0.16 : 0.10),
                      scheme.surface,
                    ),
                    borderRadius: BorderRadius.circular(24),
                    border:
                        Border.all(color: accent.withValues(alpha: 0.38)),
                    boxShadow: [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.50),
                        blurRadius: 22,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        iconSize: 18,
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Close',
                        color: accent,
                        onPressed: _closeVolume,
                        icon: Icon(volIcon),
                      ),
                      SizedBox(
                        width: 180,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            activeTrackColor: accent,
                            inactiveTrackColor:
                                accent.withValues(alpha: 0.22),
                            thumbColor: accent,
                            overlayColor: accent.withValues(alpha: 0.14),
                            thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6),
                            overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 11),
                          ),
                          child: Slider(
                            value: _volume,
                            onChanged: (v) {
                              setState(() => _volume = v);
                              _player.setVolume(v);
                              _armVolumeHide();
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // A sleep-timer chooser (web supports this one).
  void _showSleepMenu() {
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        Widget row(String label, int minutes) => ListTile(
              leading: Icon(
                  minutes == 0
                      ? Icons.alarm_off_rounded
                      : Icons.snooze_rounded,
                  color: _sleepMinutes == minutes ? scheme.primary : null),
              title: Text(label),
              trailing: _sleepMinutes == minutes
                  ? Icon(Icons.check_rounded, color: scheme.primary)
                  : null,
              onTap: () {
                _setSleep(minutes);
                Navigator.pop(ctx);
              },
            );
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              row('Off', 0),
              row('15 minutes', 15),
              row('30 minutes', 30),
              row('45 minutes', 45),
              row('1 hour', 60),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  // Banner shown when a feature only the full app can do is tapped on web.
  Timer? _bannerTimer;
  void _featureUnavailable(String feature) {
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;
    messenger.clearMaterialBanners();
    messenger.showMaterialBanner(
      MaterialBanner(
        backgroundColor: scheme.surfaceContainerHighest,
        leading: Icon(Icons.phonelink_rounded, color: scheme.primary),
        content: Text(
          '$feature is only available in the Windows or Android app — '
          'open Aluta there to use it.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: messenger.clearMaterialBanners,
            child: const Text('GOT IT'),
          ),
        ],
      ),
    );
    _bannerTimer?.cancel();
    _bannerTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) messenger.clearMaterialBanners();
    });
  }


  // ── Volume popup (tap-to-reveal, auto-hide) ──────────────────────────────
  void _toggleVolume() {
    if (_showVolume) {
      _closeVolume();
    } else {
      setState(() => _showVolume = true);
      _armVolumeHide();
    }
  }

  void _armVolumeHide() {
    _volumeHideTimer?.cancel();
    _volumeHideTimer =
        Timer(const Duration(milliseconds: 1800), _closeVolume);
  }

  void _closeVolume() {
    _volumeHideTimer?.cancel();
    if (!mounted || !_showVolume) return;
    setState(() => _showVolume = false);
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
        // Add songs / folder folded in here (like the native playlist), plus
        // the "about this player" popover.
        IconButton(
          tooltip: 'Add songs',
          iconSize: 18,
          color: theme.colorScheme.primary,
          onPressed: _loading ? null : _openFiles,
          icon: const Icon(Icons.library_add_rounded),
        ),
        if (folderPickSupported)
          IconButton(
            tooltip: 'Load a folder',
            iconSize: 18,
            color: theme.colorScheme.primary,
            onPressed: _loading ? null : _openFolder,
            icon: const Icon(Icons.folder_copy_outlined),
          ),
        _infoAnchor(theme),
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
      itemBuilder: (_, i) => _queueRow(theme, i),
    );
  }

  // One queue row, styled like the native playlist: a raised circular avatar
  // (an animated equalizer while this row is the one playing, else a music
  // note), a two-line clean title / artist, and remove + drag affordances.
  Widget _queueRow(ThemeData theme, int i) {
    final scheme = theme.colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final accent = scheme.primary;
    final current = i == _index;
    final ta = splitTitleArtist(_cleanTitle(_queue[i].name));
    final title = ta.$1;
    final artist = ta.$2;
    return Padding(
      key: ValueKey(_queue[i]),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: Material(
        color: current
            ? accent.withValues(alpha: isDark ? 0.10 : 0.07)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: current ? null : () => _playAt(i),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                _queueAvatar(theme, current),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight:
                              current ? FontWeight.w700 : FontWeight.w600,
                          color: current ? accent : widget.textColor,
                        ),
                      ),
                      if (artist != null && artist.isNotEmpty) ...[
                        const SizedBox(height: 1),
                        Text(
                          artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: current
                                ? accent.withValues(alpha: 0.75)
                                : theme.hintColor,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  iconSize: 17,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Remove',
                  onPressed: () => _removeAt(i),
                  color: theme.hintColor,
                  icon: const Icon(Icons.close_rounded),
                ),
                ReorderableDragStartListener(
                  index: i,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 2, right: 2),
                    child: Icon(Icons.drag_handle_rounded,
                        size: 18, color: theme.hintColor),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // The circular track avatar. Current row → a glossy accent disc (white-lit
  // top-left → accent → darker) with a glow and a live mini-equalizer; other
  // rows → a soft raised accent-tinted disc with a music note. Both read as 3D.
  Widget _queueAvatar(ThemeData theme, bool current) {
    final scheme = theme.colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final accent = scheme.primary;
    const d = 42.0;
    if (current) {
      return Container(
        width: d,
        height: d,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.lerp(accent, Colors.white, 0.22)!,
              accent,
              Color.lerp(accent, Colors.black, 0.14)!,
            ],
            stops: const [0.0, 0.55, 1.0],
          ),
          boxShadow: [
            BoxShadow(
              color: accent.withValues(alpha: 0.45),
              blurRadius: 12,
              spreadRadius: 1,
            ),
          ],
        ),
        child: const Center(child: _WebMiniEq(color: Colors.white)),
      );
    }
    return Container(
      width: d,
      height: d,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
              accent.withValues(alpha: isDark ? 0.16 : 0.10),
              scheme.surface,
            ),
            Color.alphaBlend(
              accent.withValues(alpha: isDark ? 0.26 : 0.18),
              scheme.surfaceContainerHighest,
            ),
          ],
        ),
        border: Border.all(
          color: accent.withValues(alpha: isDark ? 0.30 : 0.20),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: isDark ? 0.18 : 0.12),
            blurRadius: 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Icon(Icons.music_note_rounded,
          size: 19, color: accent.withValues(alpha: 0.95)),
    );
  }
}

// ─── Waveform seek bar (web) ──────────────────────────────────────────────────
// A SoundCloud-style waveform that doubles as the seek control: a stable per-
// track bar pattern fills with the accent up to the play head and is faint
// beyond it; drag or tap anywhere to scrub, with a small time bubble following
// the finger. Mirrors the native player's _WaveformSeekBar.
class _WebWaveformSeekBar extends StatefulWidget {
  final double fraction; // 0..1 played
  final Color accent;
  final Color inactive;
  final bool enabled;
  final int seed; // stable bar pattern per track
  final ValueChanged<double> onSeek;
  final String Function(double fraction) labelFor;

  const _WebWaveformSeekBar({
    required this.fraction,
    required this.accent,
    required this.inactive,
    required this.enabled,
    required this.seed,
    required this.onSeek,
    required this.labelFor,
  });

  @override
  State<_WebWaveformSeekBar> createState() => _WebWaveformSeekBarState();
}

class _WebWaveformSeekBarState extends State<_WebWaveformSeekBar> {
  static const int _bars = 48;
  double? _dragFrac; // non-null while scrubbing
  late List<double> _heights;

  @override
  void initState() {
    super.initState();
    _heights = _gen(widget.seed);
  }

  @override
  void didUpdateWidget(covariant _WebWaveformSeekBar old) {
    super.didUpdateWidget(old);
    if (old.seed != widget.seed) _heights = _gen(widget.seed);
  }

  // Deterministic pseudo-random bar heights (0.26..1.0) for a stable look.
  List<double> _gen(int seed) {
    var x = (seed & 0x7fffffff) | 1;
    final out = <double>[];
    for (var i = 0; i < _bars; i++) {
      x = (x * 1103515245 + 12345) & 0x7fffffff;
      out.add(0.26 + (x % 1000) / 1000.0 * 0.74);
    }
    return out;
  }

  void _setFromDx(double dx, double w) {
    if (w <= 0) return;
    setState(() => _dragFrac = (dx / w).clamp(0.0, 1.0));
  }

  void _commit() {
    final f = _dragFrac;
    if (f != null) widget.onSeek(f);
    setState(() => _dragFrac = null);
  }

  @override
  Widget build(BuildContext context) {
    final frac = (_dragFrac ?? widget.fraction).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (ctx, c) {
        final w = c.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown:
              widget.enabled ? (d) => _setFromDx(d.localPosition.dx, w) : null,
          onTapUp: widget.enabled ? (_) => _commit() : null,
          onTapCancel:
              widget.enabled ? () => setState(() => _dragFrac = null) : null,
          onHorizontalDragStart:
              widget.enabled ? (d) => _setFromDx(d.localPosition.dx, w) : null,
          onHorizontalDragUpdate:
              widget.enabled ? (d) => _setFromDx(d.localPosition.dx, w) : null,
          onHorizontalDragEnd: widget.enabled ? (_) => _commit() : null,
          child: SizedBox(
            height: 36,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _WebWavePainter(
                      heights: _heights,
                      fraction: frac,
                      accent: widget.accent,
                      inactive: widget.inactive,
                    ),
                  ),
                ),
                if (_dragFrac != null)
                  Positioned(
                    left: (frac * w - 24).clamp(0.0, (w - 48).clamp(0.0, w)),
                    top: -24,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: widget.accent,
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.25),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Text(
                        widget.labelFor(frac),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _WebWavePainter extends CustomPainter {
  final List<double> heights;
  final double fraction;
  final Color accent;
  final Color inactive;

  _WebWavePainter({
    required this.heights,
    required this.fraction,
    required this.accent,
    required this.inactive,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = heights.length;
    if (n == 0) return;
    const gap = 2.0;
    final barW = (size.width - gap * (n - 1)) / n;
    if (barW <= 0) return;
    final playedX = fraction * size.width;
    final mid = size.height / 2;
    final aPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = accent;
    final iPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = inactive;
    for (var i = 0; i < n; i++) {
      final x = i * (barW + gap);
      final h = (heights[i] * size.height).clamp(3.0, size.height);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, mid - h / 2, barW, h),
        Radius.circular(barW / 2),
      );
      canvas.drawRRect(rect, (x + barW) <= playedX ? aPaint : iPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _WebWavePainter old) =>
      old.fraction != fraction ||
      old.accent != accent ||
      old.inactive != inactive ||
      old.heights != heights;
}

// ─── Mini equalizer (web) ─────────────────────────────────────────────────────
// A compact 4-bar equalizer that gently dances — used inside the now-playing
// queue avatar, mirroring the native playlist's "this is playing" indicator.
class _WebMiniEq extends StatefulWidget {
  final Color color;
  const _WebMiniEq({required this.color});

  @override
  State<_WebMiniEq> createState() => _WebMiniEqState();
}

class _WebMiniEqState extends State<_WebMiniEq>
    with SingleTickerProviderStateMixin {
  static const int _n = 4;
  static const List<double> _phase = [0.0, 0.55, 0.25, 0.8];
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  // Triangle wave 0..1 (no dart:math needed).
  double _wave(double x) {
    x = x - x.floorToDouble();
    return x < 0.5 ? x * 2 : (1 - x) * 2;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (int i = 0; i < _n; i++) ...[
              Container(
                width: 3,
                height: 6.0 + _wave(_c.value + _phase[i]) * 13.0,
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              if (i < _n - 1) const SizedBox(width: 2.5),
            ],
          ],
        );
      },
    );
  }
}
