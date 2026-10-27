import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/live_session_service.dart' show BytesAudioSource;
import '../services/now_playing_presence.dart';
import '../services/song_insights.dart';
import '../widgets/song_feel_strip.dart';
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
import '../widgets/genie_menu.dart';
import '../utils/readable.dart';
import '../widgets/controls_glass.dart';
import '../widgets/playing_bars.dart';
import 'music_controls.dart' show showSongShareSheet, showSongDedicate;
import '../utils/typing_guard.dart';

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
  // A-B repeat (same as the native player): loop one stretch of the song.
  Duration? _abA;
  Duration? _abB;
  DateTime _abLoopAt = DateTime.fromMillisecondsSinceEpoch(0);
  StreamSubscription<Duration>? _abSub;
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
  // The full-height queue card that slides up over the player (Playlist
  // tile / the expand button on the inline queue): far more room to scroll
  // and reorder than the one or two rows left under the controls.
  bool _sheetOpen = false;
  String _sheetQuery = '';
  final ScrollController _sheetScroll = ScrollController();
  static const double _rowExtent = 60;

  @override
  void initState() {
    super.initState();
    _psSub = _player.playerStateStream.listen(_onPlayerState);
    _abSub = _player.positionStream.listen((pos) {
      final a = _abA, b = _abB;
      if (a != null &&
          b != null &&
          pos >= b &&
          DateTime.now().difference(_abLoopAt).inMilliseconds > 400) {
        _abLoopAt = DateTime.now();
        _player.seek(a);
      }
    });
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
    playbackBus.webPlayNextAt = _playNextAt;
    playbackBus.webShareAt = (i) => _shareAt(i);
    playbackBus.webDedicateAt = _dedicateAt;
    playbackBus.webSendToPartnerAt =
        (i) => _shareAt(i, sendTo: SongBridge.instance.partnerId?.call());
  }

  // ── Per-track actions (same as the native playlist's) ────────────────────

  // Keys the share sheet uses for queue songs: the last segment is the real
  // file name (extension → mime / name in the chat).
  String _keyOf(int i) => 'webq/$i/${_queue[i].name}';
  int? _indexOfKey(String k) {
    final parts = k.split('/');
    return parts.length >= 3 ? int.tryParse(parts[1]) : null;
  }

  /// Share one queue song with friends (multi-pick), or straight to [sendTo].
  void _shareAt(int i, {int? sendTo}) {
    if (i < 0 || i >= _queue.length) return;
    String title(String k) {
      final j = _indexOfKey(k);
      if (j == null || j >= _queue.length) return 'Song';
      return splitTitleArtist(_cleanTitle(_queue[j].name)).$1;
    }

    String artist(String k) {
      final j = _indexOfKey(k);
      if (j == null || j >= _queue.length) return '';
      return splitTitleArtist(_cleanTitle(_queue[j].name)).$2 ?? '';
    }

    showSongShareSheet(
      context,
      keys: [_keyOf(i)],
      library: [for (var j = 0; j < _queue.length; j++) _keyOf(j)],
      titleOf: title,
      artistOf: artist,
      bytesOf: (k) async {
        final j = _indexOfKey(k);
        if (j == null || j >= _queue.length) return const <int>[];
        return _queue[j].load();
      },
      sendTo: sendTo,
    );
  }

  /// "Dedicate to…" a friend: the song sealed in a heart, with a note.
  void _dedicateAt(int i) {
    if (i < 0 || i >= _queue.length) return;
    final t = _queue[i];
    final ta = splitTitleArtist(_cleanTitle(t.name));
    showSongDedicate(
      context,
      fileName: t.name,
      title: ta.$1,
      artist: ta.$2 ?? '',
      loadBytes: () => t.load(),
      durationMs: i == _index ? _player.duration?.inMilliseconds : null,
    );
  }

  /// Move a song to play right after the current one.
  void _playNextAt(int i) {
    if (i < 0 || i >= _queue.length || i == _index || i == _index + 1) return;
    // Reorder semantics (target before removal): right after the current.
    _reorder(i, _index + 1);
    showToast(context, 'Plays next', type: ToastType.info);
  }

  Widget _trackMenu(ThemeData theme, int i) {
    final partner = SongBridge.instance.partnerId?.call() != null;
    final current = i == _index;
    PopupMenuItem<String> item(String v, IconData icon, String label,
            {Color? color}) =>
        PopupMenuItem<String>(
          value: v,
          child: Row(children: [
            Icon(icon, size: 19, color: color ?? theme.hintColor),
            const SizedBox(width: 12),
            Text(label),
          ]),
        );
    return GeniePopupMenuButton<String>(
      tooltip: 'Track options',
      padding: EdgeInsets.zero,
      icon: Icon(Icons.more_vert_rounded, size: 19, color: theme.hintColor),
      onSelected: (v) {
        switch (v) {
          case 'play':
            _playAt(i);
          case 'next':
            _playNextAt(i);
          case 'share':
            _shareAt(i);
          case 'partner':
            _shareAt(i, sendTo: SongBridge.instance.partnerId?.call());
          case 'dedicate':
            _dedicateAt(i);
          case 'remove':
            _removeAt(i);
        }
      },
      itemBuilder: (_) => [
        if (!current) item('play', Icons.play_arrow_rounded, 'Play'),
        if (!current && i != _index + 1)
          item('next', Icons.playlist_play_rounded, 'Play next'),
        if (partner)
          item('partner', Icons.favorite_rounded, 'Send to my partner',
              color: theme.colorScheme.primary),
        item('share', Icons.send_rounded, 'Share with friends'),
        item('dedicate', Icons.volunteer_activism_rounded, 'Dedicate to…'),
        item('remove', Icons.close_rounded, 'Remove from queue'),
      ],
    );
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
    _sheetScroll.dispose();
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
    playbackBus.webPlayNextAt = null;
    playbackBus.webShareAt = null;
    playbackBus.webDedicateAt = null;
    playbackBus.webSendToPartnerAt = null;
    _queueRev.dispose();
    _abSub?.cancel();
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
    // Use a raw web <input multiple accept="audio/*"> (via the web_fs helper)
    // rather than file_picker — on mobile browsers file_picker's allowMultiple
    // is unreliable and limits you to one song, while the native input reliably
    // multi-selects. Bytes load lazily per track.
    final picked = await pickMusicFiles();
    if (picked.isEmpty) return;
    setState(() => _loading = true);
    try {
      final startEmpty = _queue.isEmpty;
      for (final e in picked) {
        _queue.add(_WebTrack(e.name, e.load));
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
    // Don't flip _loading until AFTER the (possibly long) picker resolves —
    // otherwise an open/slow chooser would leave the panel "loading", which
    // disables the Queue add/folder buttons.
    final startEmpty = _queue.isEmpty;
    final entries = await pickMusicFolder();
    if (entries.isEmpty) return;
    setState(() => _loading = true);
    try {
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
    _abA = null; // A-B points belong to the previous song
    _abB = null;
    if (mounted) setState(() {});
    final t = _queue[i];
    try {
      final bytes = await t.load();
      _currentBytes = bytes;
      _currentTitle = _cleanTitle(t.name);
      SongInsights.instance.recordPlay(_currentTitle ?? '');
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
    if (_queue.isEmpty) {
      _sheetOpen = false; // nothing to show — don't reopen on the next load
      return _emptyState(theme);
    }
    // Active: controls pinned at the top, queue fills the rest (scrolls inside),
    // so everything is reachable without scrolling the whole panel.
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
          child: Column(
            children: [
              _nowPlayingCard(theme),
              // How this song feels → who it's for (same as the native player).
              if (_index >= 0 && _index < _queue.length)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SongFeelStrip(
                    title: _cleanTitle(_queue[_index].name),
                    accent: theme.colorScheme.primary,
                  ),
                ),
              const SizedBox(height: 10),
              // Waveform, transport and tools share one glassy card (same as
              // the phone / desktop player) instead of floating.
              ControlsGlass(
                accent: theme.colorScheme.primary,
                padding: const EdgeInsets.fromLTRB(8, 16, 8, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _seekBar(theme),
                    _transport(theme),
                    const SizedBox(height: 8),
                    _fitNarrow(_featureRow(theme), 340),
                    const SizedBox(height: 12),
                    _fitNarrow(_bottomRow(theme), 300),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              _fitNarrow(_queueHeader(theme), 370),
            ],
          ),
        ),
        Divider(height: 1, color: theme.dividerColor.withValues(alpha: 0.4)),
        Expanded(child: _queueBody(theme)),
      ],
    );
    return TypingSafeShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _closeSheet,
      },
      child: Stack(
        children: [
          body,
          // Scrim — tap outside the card to put it away.
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_sheetOpen,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 220),
                opacity: _sheetOpen ? 1 : 0,
                child: GestureDetector(
                  onTap: _closeSheet,
                  child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.18)),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_sheetOpen,
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 320),
                curve: _sheetOpen ? Curves.easeOutCubic : Curves.easeInCubic,
                offset: _sheetOpen ? Offset.zero : const Offset(0, 1.05),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: _sheetOpen ? 1 : 0,
                  child: _queueSheet(theme),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openSheet() {
    if (_queue.isEmpty) return;
    setState(() {
      _sheetOpen = true;
      _sheetQuery = '';
    });
    // Open already looking at the playing song.
    WidgetsBinding.instance.addPostFrameCallback((_) => _sheetToCurrent());
  }

  void _closeSheet() {
    if (!_sheetOpen) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _sheetOpen = false);
  }

  void _sheetToCurrent({bool animate = false}) {
    if (!_sheetScroll.hasClients || _index < 0) return;
    final pos = _sheetScroll.position;
    final target = (_index * _rowExtent - pos.viewportDimension / 2 + _rowExtent)
        .clamp(0.0, pos.maxScrollExtent);
    animate
        ? _sheetScroll.animateTo(target,
            duration: const Duration(milliseconds: 380),
            curve: Curves.easeOutCubic)
        : _sheetScroll.jumpTo(target);
  }

  /// The full-height queue card: header with the queue tools, the song
  /// playing now, a search box, and the whole list (drag to reorder).
  Widget _queueSheet(ThemeData theme) {
    final scheme = theme.colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final accent = scheme.primary;
    final q = _sheetQuery;
    final hits = <int>[
      for (var i = 0; i < _queue.length; i++)
        if (q.isEmpty || _cleanTitle(_queue[i].name).toLowerCase().contains(q))
          i,
    ];
    final now = (_index >= 0 && _index < _queue.length)
        ? splitTitleArtist(_cleanTitle(_queue[_index].name))
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Container(
        decoration: BoxDecoration(
          color: isDark
              ? Color.alphaBlend(
                  Colors.white.withValues(alpha: 0.05), scheme.surface)
              : scheme.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
              color: accent.withValues(alpha: isDark ? 0.30 : 0.18)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.16),
              blurRadius: 24,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Grabber — drag down (or tap) to put the card away.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closeSheet,
              onVerticalDragEnd: (d) {
                if ((d.primaryVelocity ?? 0) > 200) _closeSheet();
              },
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 2),
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 6, 6, 4),
                    child: Row(
                      children: [
                        Icon(Icons.queue_music_rounded,
                            size: 20, color: accent),
                        const SizedBox(width: 8),
                        Text('Queue',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: widget.textColor)),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                              _index >= 0
                                  ? '${_index + 1} / ${_queue.length}'
                                  : '${_queue.length}',
                              style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  color: accent)),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: 'Find the playing song',
                          iconSize: 19,
                          color: accent,
                          onPressed: q.isEmpty
                              ? () => _sheetToCurrent(animate: true)
                              : null,
                          icon: const Icon(Icons.my_location_rounded),
                        ),
                        IconButton(
                          tooltip: 'Add songs',
                          iconSize: 19,
                          color: accent,
                          onPressed: _loading ? null : _openFiles,
                          icon: const Icon(Icons.library_add_rounded),
                        ),
                        if (folderPickSupported)
                          IconButton(
                            tooltip: 'Load a folder',
                            iconSize: 19,
                            color: accent,
                            onPressed: _loading ? null : _openFolder,
                            icon: const Icon(Icons.folder_copy_outlined),
                          ),
                        IconButton(
                          tooltip: 'Hide queue',
                          iconSize: 22,
                          color: theme.hintColor,
                          onPressed: _closeSheet,
                          icon: const Icon(Icons.keyboard_arrow_down_rounded),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Now playing strip.
            if (now != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [
                      accent.withValues(alpha: isDark ? 0.22 : 0.14),
                      accent.withValues(alpha: isDark ? 0.08 : 0.04),
                    ]),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      _queueAvatar(theme, true),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('NOW PLAYING',
                                style: TextStyle(
                                    fontSize: 9.5,
                                    letterSpacing: 1,
                                    fontWeight: FontWeight.w800,
                                    color: accent)),
                            Text(now.$1,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: widget.textColor)),
                            if ((now.$2 ?? '').isNotEmpty)
                              Text(now.$2!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 11.5,
                                      color: theme.hintColor)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            // Search.
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: SizedBox(
                height: 38,
                child: TextField(
                  onChanged: (v) =>
                      setState(() => _sheetQuery = v.trim().toLowerCase()),
                  style: const TextStyle(fontSize: 13.5),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Search the queue',
                    prefixIcon: const Icon(Icons.search_rounded, size: 18),
                    filled: true,
                    fillColor: scheme.surfaceContainerHighest
                        .withValues(alpha: isDark ? 0.5 : 0.7),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ),
            Divider(height: 1, color: theme.dividerColor.withValues(alpha: 0.4)),
            Expanded(
              child: hits.isEmpty
                  ? Center(
                      child: Text('No song matches “$q”',
                          style: TextStyle(color: theme.hintColor)),
                    )
                  : q.isEmpty
                      // Whole queue: drag ≡ to reorder.
                      ? ReorderableListView.builder(
                          scrollController: _sheetScroll,
                          buildDefaultDragHandles: false,
                          padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
                          itemCount: _queue.length,
                          // ignore: deprecated_member_use
                          onReorder: _reorder,
                          itemBuilder: (_, i) => _queueRow(theme, i),
                        )
                      // Searching: matches only (no reordering a filtered list).
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
                          itemCount: hits.length,
                          itemBuilder: (_, k) =>
                              _queueRow(theme, hits[k], reorderable: false),
                        ),
            ),
          ],
        ),
      ),
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
    // Same genie motion as every other menu (widgets/genie_menu.dart).
    return Builder(builder: (ctx) {
      void open() {
        final box = ctx.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) return;
        showGenieMenu(
          ctx,
          anchor: box.localToGlobal(Offset.zero) & box.size,
          width: 308,
          color: theme.colorScheme.surfaceContainerHigh,
          entries: [
            GenieMenuEntry(label: '', enabled: false, custom: _infoCard(theme)),
          ],
        );
      }

      if (inline) {
        return TextButton.icon(
          onPressed: open,
          icon: const Icon(Icons.info_outline_rounded, size: 16),
          label: const Text('About this player · Get the app'),
        );
      }
      return IconButton(
        tooltip: 'About · Get the app',
        iconSize: 20,
        color: theme.hintColor,
        onPressed: open,
        icon: const Icon(Icons.info_outline_rounded),
      );
    });
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
          const SizedBox(height: 10),
          // Load right from here — so "load songs to play here" is one tap.
          Builder(builder: (ctx) {
            void pick(Future<void> Function() action) {
              Navigator.of(ctx).maybePop();
              action();
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  onPressed: _loading ? null : () => pick(_openFiles),
                  icon: const Icon(Icons.library_add_rounded, size: 18),
                  label: const Text('Choose songs'),
                ),
                if (folderPickSupported) ...[
                  const SizedBox(height: 6),
                  OutlinedButton.icon(
                    onPressed: _loading ? null : () => pick(_openFolder),
                    icon: const Icon(Icons.folder_copy_outlined, size: 18),
                    label: const Text('Load a music folder'),
                  ),
                ],
              ],
            );
          }),
          const SizedBox(height: 14),
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
              // Share "listening now" with friends: tap = on/off, hold = who
              // sees it. (Was a decorative icon that looked tappable.)
              PresenceShareButton(color: accent, size: 19),
              const SizedBox(height: 2),
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
                markA: (_abA == null || durMs <= 0)
                    ? null
                    : (_abA!.inMilliseconds / durMs).clamp(0.0, 1.0),
                markB: (_abB == null || durMs <= 0)
                    ? null
                    : (_abB!.inMilliseconds / durMs).clamp(0.0, 1.0),
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
  /// A-B key: off → mark A → mark B (loop starts) → off. Hold clears.
  void _cycleAB() {
    if (_index < 0) return;
    final pos = _player.position;
    final a = _abA;
    if (a == null) {
      setState(() => _abA = pos);
      showToast(context, 'A set at ${_fmt(pos)} — tap again where the part ends');
    } else if (_abB == null) {
      if (pos <= a + const Duration(seconds: 1)) {
        showToast(context, 'Let it play a little past A, then tap for B');
        return;
      }
      setState(() => _abB = pos);
      _abLoopAt = DateTime.now();
      _player.seek(a);
      showToast(context, 'Repeating ${_fmt(a)} – ${_fmt(pos)} · tap again to stop');
    } else {
      _clearAB();
    }
  }

  void _clearAB() {
    if (_abA == null && _abB == null) return;
    setState(() {
      _abA = null;
      _abB = null;
    });
    showToast(context, 'A-B repeat off');
  }

  Widget _abPill(ThemeData theme) {
    final scheme = theme.colorScheme;
    final accent = scheme.primary;
    final a = _abA, b = _abB;
    final on = a != null;
    final label = a == null
        ? 'A-B'
        : (b == null ? 'A ${_fmt(a)} · B?' : '${_fmt(a)}–${_fmt(b)}');
    final fg = on ? accent : scheme.onSurface;
    return Tactile(
      child: Tooltip(
        message: 'Repeat a part (A-B) · hold to clear',
        child: GestureDetector(
          onTap: _cycleAB,
          onLongPress: _clearAB,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: on
                  ? accent.withValues(alpha: b != null ? 0.14 : 0.08)
                  : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
              border: Border.all(
                  color: accent.withValues(alpha: on ? 0.6 : 0.22)),
            ),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(b != null ? Icons.repeat_on_rounded : Icons.repeat_rounded,
                      size: 13, color: fg),
                  const SizedBox(width: 4),
                  Text(label,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: fg,
                          fontFeatures: const [FontFeature.tabularFigures()])),
                  if (on) ...[
                    const SizedBox(width: 6),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _clearAB,
                      child: Icon(Icons.close_rounded,
                          size: 14, color: fg.withValues(alpha: 0.8)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

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
  // When the music panel is dragged narrow, lay a row out at its design width
  // and scale it down to fit, instead of letting it overflow.
  Widget _fitNarrow(Widget row, [double designWidth = 320]) {
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth >= designWidth) return row;
      return FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.center,
        child: SizedBox(width: designWidth, child: row),
      );
    });
  }

  Widget _featureRow(ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _featureTile(
          theme,
          icon: Icons.queue_music_rounded,
          label: 'Playlist',
          active: _sheetOpen,
          badge: _queue.isNotEmpty ? '${_queue.length}' : null,
          onTap: () => _sheetOpen ? _closeSheet() : _openSheet(),
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
                        style: TextStyle(
                            color: readableOn(accent),
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
              _speedPill(theme, speedLabel),
            ],
          ),
          // A-B in the exact centre: widens equally both ways as it changes.
          _abPill(theme),
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
        // Tap the title (or the expand button) for the full-height queue.
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _openSheet,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: Text('Queue (${_queue.length})',
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          ),
        ),
        const Spacer(),
        IconButton(
          tooltip: 'Open the full queue',
          iconSize: 18,
          color: theme.colorScheme.primary,
          onPressed: _openSheet,
          icon: const Icon(Icons.open_in_full_rounded),
        ),
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
  Widget _queueRow(ThemeData theme, int i, {bool reorderable = true}) {
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
          // Hold a song to share it with friends (as on Android / Windows).
          onLongPress: () {
            HapticFeedback.mediumImpact();
            _shareAt(i);
          },
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
                _trackMenu(theme, i),
                if (reorderable)
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
        child: const Center(child: PlayingBars(color: Colors.white)),
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
  final double? markA; // A-B repeat points (fractions), null = unset
  final double? markB;

  const _WebWaveformSeekBar({
    required this.fraction,
    required this.accent,
    required this.inactive,
    required this.enabled,
    required this.seed,
    required this.onSeek,
    required this.labelFor,
    this.markA,
    this.markB,
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
                if (widget.markA != null && widget.markB != null)
                  Positioned(
                    left: widget.markA!.clamp(0.0, 1.0) * w,
                    width: (widget.markB! - widget.markA!).clamp(0.0, 1.0) * w,
                    top: -3,
                    bottom: -3,
                    child: IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          color: widget.accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              color: widget.accent.withValues(alpha: 0.35)),
                        ),
                      ),
                    ),
                  ),
                for (final m in [
                  if (widget.markA != null) (widget.markA!, 'A'),
                  if (widget.markB != null) (widget.markB!, 'B'),
                ])
                  Positioned(
                    left: (m.$1.clamp(0.0, 1.0) * w - 6)
                        .clamp(0.0, (w - 12).clamp(0.0, w)),
                    top: -14,
                    child: IgnorePointer(
                      child: SizedBox(
                        width: 12,
                        child: Text(m.$2,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: widget.accent,
                                fontSize: 9,
                                fontWeight: FontWeight.w900)),
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
                        style: TextStyle(
                          color: readableOn(widget.accent),
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
    final len = heights.length;
    if (len == 0) return;
    // Wide screens get MORE, thinner bars (≈4 px each) instead of stretching
    // the same few into fat pills that no longer read as a waveform.
    const pitch = 6.5; // bar + gap
    final fit = (size.width / pitch).floor();
    final n = fit > len ? (fit > 240 ? 240 : fit) : len;
    final gap = n > len ? 2.5 : 2.0;
    final barW = (size.width - gap * (n - 1)) / n;
    if (barW <= 0) return;
    double hAt(int i) {
      if (n == len) return heights[i];
      // Resample the track's pattern smoothly, plus a fixed per-bar wobble so
      // it still looks like a real waveform rather than a gentle curve.
      final t = n == 1 ? 0.0 : i * (len - 1) / (n - 1);
      final j = t.floor();
      final k = j + 1 < len ? j + 1 : len - 1;
      final v = heights[j] + (heights[k] - heights[j]) * (t - j);
      final w = ((i * 7919 + 104729) % 1000) / 1000.0;
      final out = v * (0.7 + 0.6 * w);
      return out < 0.18 ? 0.18 : (out > 1.0 ? 1.0 : out);
    }
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
      final h = (hAt(i) * size.height).clamp(3.0, size.height);
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

