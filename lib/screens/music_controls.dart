import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_session/audio_session.dart';
import '../screens/home_page.dart'
    show
        nowPlayingNotifier,
        playbackBus,
        playlistNotifier,
        playProgressNotifier,
        playClockNotifier,
        PlayClock,
        favoriteNotifier,
        liveSessionNotifier;
import '../services/live_session_service.dart';
import '../utils/toast_helper.dart';
import 'equalizer_screen.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../services/audio_handler.dart';
import '../services/metadata_overrides.dart';
import '../utils/marquee_text.dart';

bool get _isMobile => Platform.isAndroid || Platform.isIOS;

const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

String _speedLabel(double s) => s == 1.0 ? '1x' : '${s}x';

/// Cleans junk that downloaders bake into filenames, e.g.
/// "Two of us- Downloaded from clipzag.com" → "Two of us".
String _cleanTrackName(String raw) {
  var n = raw;
  n = n.replaceAll(
      RegExp(r'[-_(\[ ]*downloaded\s*from[^)\]]*', caseSensitive: false), ' ');
  n = n.replaceAll(
      RegExp(r'\b(clipzag|y2mate|ytmp3|mp3juice|tubidy|savefrom|snaptube)\S*',
          caseSensitive: false),
      ' ');
  n = n.replaceAll(RegExp(r'\s+'), ' ').trim();
  n = n.replaceAll(RegExp(r'^[\s\-_]+|[\s\-_]+$'), '').trim();
  return n.isEmpty ? raw.trim() : n;
}

/// Splits a cleaned name into (title, artist) when it looks like "Title - Artist".
(String, String?) _titleArtist(String cleaned) {
  final parts = cleaned
      .split(RegExp(r'\s*-\s*'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.length < 2) return (cleaned, null);
  return (parts.first, parts.sublist(1).join(' · '));
}

// =============================================================================

class MusicControls extends StatefulWidget {
  static const routeName = '/music';
  final Color textColor;
  const MusicControls({super.key, required this.textColor});

  @override
  State<MusicControls> createState() => _MusicControlsState();
}

class _MusicControlsState extends State<MusicControls>
    with TickerProviderStateMixin {
  late final AudioPlayer _player;

  // Native audio effects (Android only). Null on other platforms.
  AndroidEqualizer? _equalizer;
  AndroidLoudnessEnhancer? _loudness;

  List<String> _playlist = [];
  // MediaStore query (fast, indexed device-library access).
  final OnAudioQuery _audioQuery = OnAudioQuery();

  // ── Live "blending" console ────────────────────────────────────────────────
  // When a live session is active the music panel becomes a second control
  // surface for it: it shows the LIVE track and its transport drives the
  // session (host acts directly; a listener sends requests the host executes).
  StreamSubscription? _liveStateSub;
  StreamSubscription? _livePosSub;

  bool get _liveActive =>
      liveSessionNotifier.active && activeLiveSession != null;
  LiveSessionController? get _live => activeLiveSession?.controller;
  bool get _isLiveHost => activeLiveSession?.role == LiveRole.host;

  void _onLiveChanged() {
    _liveStateSub?.cancel();
    _liveStateSub = null;
    _livePosSub?.cancel();
    _livePosSub = null;
    final live = _live;
    if (liveSessionNotifier.active && live != null) {
      // Mirror the live player's state into the panel + ambient bars.
      _liveStateSub = live.player.playerStateStream.listen((_) {
        _pushLiveToAmbient();
        if (mounted) setState(() {});
      });
      _livePosSub = live.player.positionStream.listen((_) {
        _pushLiveToAmbient();
        if (mounted) setState(() {});
      });
      // Establish the media/foreground state immediately so the session is
      // protected from background-kill from the very start.
      _pushLiveToAmbient();
    }
    if (mounted) setState(() {});
  }

  String _liveTitle() {
    final live = _live;
    // Controller-tracked current title works for BOTH host and listener (the
    // listener has no local queue, so this is how its panel follows changes).
    if (live != null && live.currentTitle.isNotEmpty) {
      return live.currentTitle;
    }
    if (live != null &&
        live.currentIndex >= 0 &&
        live.currentIndex < live.queue.length) {
      return live.queue[live.currentIndex].title;
    }
    return activeLiveSession?.title ?? 'Live song';
  }

  // Keep the now-playing bar / footer / media notification showing the live
  // track (and its progress) while a session is active.
  void _pushLiveToAmbient() {
    final live = _live;
    if (!_liveActive || live == null) return;
    final playing = live.player.playing;
    nowPlayingNotifier.update(
        track: _liveTitle(), artist: 'Live', playing: playing);
    final dur = live.player.duration;
    final pos = live.player.position;
    playProgressNotifier.value = (dur != null && dur.inMilliseconds > 0)
        ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    playClockNotifier.value = PlayClock(pos, dur ?? Duration.zero);
    // Also drive the car / lock-screen media notification with the live track.
    audioHandler?.updateFromPlayer(
      id: 'live-session',
      title: _liveTitle(),
      artist: 'Live',
      playing: playing,
      position: pos,
      duration: dur,
    );
  }

  // ── Live-aware transport (routes to the live session when active) ───────────
  void _transportPlayPause() {
    if (!_liveActive) {
      _togglePlayPause();
      return;
    }
    final c = _live!;
    if (_isLiveHost) {
      c.player.playing ? c.player.pause() : c.player.play();
    } else {
      c.requestControl('playpause');
    }
  }

  void _transportNext() {
    if (!_liveActive) return _next();
    _isLiveHost ? _live!.nextTrack() : _live!.requestControl('next');
  }

  void _transportPrev() {
    if (!_liveActive) return _previous();
    final c = _live!;
    if (_isLiveHost) {
      if (c.currentIndex > 0) {
        c.playIndex(c.currentIndex - 1);
      } else {
        c.player.seek(Duration.zero);
      }
    } else {
      c.requestControl('prev');
    }
  }

  void _transportSeek(Duration target) {
    if (!_liveActive) {
      _player.seek(target);
      return;
    }
    final c = _live!;
    _isLiveHost
        ? c.player.seek(target)
        : c.requestControl('seek', positionMs: target.inMilliseconds);
  }

  void _transportSeekBy(int seconds) {
    if (!_liveActive) return _seekBy(seconds);
    final c = _live!;
    final dur = c.player.duration ?? Duration.zero;
    var t = c.player.position + Duration(seconds: seconds);
    if (t < Duration.zero) t = Duration.zero;
    if (dur > Duration.zero && t > dur) t = dur;
    _transportSeek(t);
  }
  int _currentIndex = -1;
  // True while we're swapping the audio source for a manual track change.
  // Guards against a spurious "completed" event auto-advancing to another song.
  bool _switching = false;
  Set<String> _favorites = {};

  String _trackName = 'No track loaded';
  String _artistName = '';

  bool _repeatAll = false;
  bool _repeatOne = false;
  bool _shuffle = false;
  double _volume = 1.0;
  bool _muted = false;
  double _speed = 1.0;
  final Random _rng = Random();

  Timer? _sleepTimer;
  Duration? _sleepRemaining;
  Timer? _sleepTick;

  bool _showPlaylist = false;
  bool _showSpeedPanel = false;
  // Volume popup: appears on tap, auto-hides after a short idle.
  bool _showVolume = false;
  Timer? _volumeHideTimer;
  // Anchors the volume popup to the volume button so it grows out of the icon
  // (instead of floating far away at the bottom of the panel).
  final LayerLink _volumeLink = LayerLink();
  // True while the first-open device scan is running (drives the sheet loader).
  bool _scanning = false;
  bool _scannedOnce = false;

  late AnimationController _discCtrl;
  late AnimationController _playlistCtrl;
  late AnimationController _speedCtrl;
  late AnimationController _volumeCtrl;

  @override
  void initState() {
    super.initState();
    // On Android, build the player with an equalizer + loudness pipeline so
    // the Equalizer screen can actually shape the sound. Elsewhere it's plain.
    if (Platform.isAndroid) {
      _equalizer = AndroidEqualizer();
      _loudness = AndroidLoudnessEnhancer();
      _player = AudioPlayer(
        audioPipeline: AudioPipeline(
          androidAudioEffects: [_loudness!, _equalizer!],
        ),
      );
    } else {
      _player = AudioPlayer();
    }

    _discCtrl = AnimationController(
      duration: const Duration(seconds: 15),
      vsync: this,
    );
    _playlistCtrl = AnimationController(
      duration: const Duration(milliseconds: 320),
      vsync: this,
    );
    _speedCtrl = AnimationController(
      duration: const Duration(milliseconds: 220),
      vsync: this,
    );
    _volumeCtrl = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );

    _configSession();
    _loadFavorites();
    _restorePlaylist();
    _listenPlayer();
    if (Platform.isAndroid) _restoreEqualizer();

    // Ambient controls (now-playing bar, car/lock-screen buttons) drive the
    // local player — or the LIVE session when one is active (live-aware).
    playbackBus.onToggle = _transportPlayPause;
    playbackBus.onNext = _transportNext;
    playbackBus.onPrev = _transportPrev;
    playbackBus.onSeekFraction = (f) {
      final dur =
          _liveActive ? _live!.player.duration : _player.duration;
      if (dur != null && dur > Duration.zero) {
        _transportSeek(dur * f.clamp(0.0, 1.0));
      }
    };
    playbackBus.onPause = () => _liveActive
        ? (_isLiveHost ? _live!.player.pause() : _live!.requestControl('pause'))
        : _player.pause();
    playbackBus.onPlay = () => _liveActive
        ? (_isLiveHost ? _live!.player.play() : _live!.requestControl('play'))
        : _player.play();
    playbackBus.onSeekTo = _transportSeek;

    // Re-bind / refresh when a live session starts or ends.
    liveSessionNotifier.addListener(_onLiveChanged);
    playbackBus.currentPath = () =>
        (_currentIndex >= 0 && _currentIndex < _playlist.length)
            ? _playlist[_currentIndex]
            : null;
    playbackBus.currentPositionMs = () => _player.position.inMilliseconds;
    playbackBus.isPlaying = () => _player.playing;
    playbackBus.onToggleFavorite = _toggleCurrentFavorite;
  }

  // Toggle "favourite" on whatever track is playing now (driven by the bar
  // heart) and refresh the shared favourite state.
  void _toggleCurrentFavorite() {
    if (_currentIndex < 0 || _currentIndex >= _playlist.length) return;
    // _toggleFavorite already refreshes the ambient heart via _syncFavoriteAmbient.
    _toggleFavorite(_playlist[_currentIndex]);
  }

  // Push the current track's favourite state to the ambient bar heart.
  void _syncFavoriteAmbient() {
    favoriteNotifier.value = _currentIndex >= 0 &&
        _currentIndex < _playlist.length &&
        _favorites.contains(_playlist[_currentIndex]);
  }

  // Re-apply saved equalizer settings so they affect playback from launch,
  // not only after the Equalizer screen is opened.
  Future<void> _restoreEqualizer() async {
    final eq = _equalizer;
    if (eq == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool('eq_enabled') ?? false;
      final params = await eq.parameters;
      await eq.setEnabled(enabled);
      await _loudness?.setEnabled(enabled);
      final saved = prefs.getStringList('eq_gains');
      final bass = prefs.getDouble('eq_bass') ?? 0;
      final loudV = prefs.getDouble('eq_loud') ?? 0;
      if (saved != null && saved.length == params.bands.length) {
        for (var i = 0; i < params.bands.length; i++) {
          final g = double.tryParse(saved[i]) ?? 0;
          final extra = i == 0 ? bass * (params.maxDecibels * 0.8) : 0.0;
          await params.bands[i].setGain(
              (g + extra).clamp(params.minDecibels, params.maxDecibels));
        }
      }
      await _loudness?.setTargetGain(loudV * 12);
    } catch (_) {}
  }

  @override
  void dispose() {
    // Only clear the bus if we're still the registered owner.
    if (playbackBus.onToggle == _transportPlayPause) {
      playbackBus.onToggle = null;
      playbackBus.onNext = null;
      playbackBus.onPrev = null;
      playbackBus.onSeekFraction = null;
      playbackBus.onPause = null;
      playbackBus.onPlay = null;
      playbackBus.onSeekTo = null;
      playbackBus.currentPath = null;
      playbackBus.currentPositionMs = null;
      playbackBus.isPlaying = null;
      playbackBus.onToggleFavorite = null;
    }
    liveSessionNotifier.removeListener(_onLiveChanged);
    _liveStateSub?.cancel();
    _livePosSub?.cancel();
    _volumeHideTimer?.cancel();
    _volumeCtrl.dispose();
    _sleepTimer?.cancel();
    _sleepTick?.cancel();
    _discCtrl.dispose();
    _playlistCtrl.dispose();
    _speedCtrl.dispose();
    _player.dispose();
    super.dispose();
  }

  // ── Setup ──────────────────────────────────────────────────────────────────

  Future<void> _configSession() async {
    final s = await AudioSession.instance;
    await s.configure(const AudioSessionConfiguration.music());
  }

  Future<void> _loadFavorites() async {
    final p = await SharedPreferences.getInstance();
    setState(() =>
        _favorites = (p.getStringList('music_favorites') ?? []).toSet());
  }

  Future<void> _saveFavorites() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('music_favorites', _favorites.toList());
  }

  // ── Player listeners ───────────────────────────────────────────────────────

  // Mirror the player's state into the media session (notification + car /
  // Bluetooth / lock-screen controls). No-op when there's no media session.
  void _pushMediaState({bool buffering = false}) {
    final h = audioHandler;
    if (h == null) return;
    final hasTrack = _currentIndex >= 0 && _currentIndex < _playlist.length;
    h.updateFromPlayer(
      id: hasTrack ? _playlist[_currentIndex] : 'aluta',
      title: _trackName,
      artist: _artistName,
      playing: _player.playing,
      position: _player.position,
      duration: _player.duration,
      buffering: buffering,
    );
  }

  void _listenPlayer() {
    _player.playerStateStream.listen((s) {
      if (!mounted) return;
      setState(() {});
      // While a live session owns the ambient bar/notification, don't let the
      // (paused) local player overwrite the live play/pause state.
      if (!_liveActive) {
        nowPlayingNotifier.update(
            track: _trackName, artist: _artistName, playing: s.playing);
        _pushMediaState(
            buffering: s.processingState == ProcessingState.loading ||
                s.processingState == ProcessingState.buffering);
      }
      if (s.playing) {
        _discCtrl.repeat();
      } else {
        _discCtrl.stop();
      }
    });

    // Completion is handled separately — avoids calling _play() synchronously
    // inside a stream callback, which causes just_audio race conditions.
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        // Ignore the spurious "completed" emitted while we swap the source for
        // a manual track change — only advance on a genuine end-of-track.
        if (_switching) return;
        Future.delayed(const Duration(milliseconds: 150), () {
          if (mounted && !_switching) _onComplete();
        });
      }
    });

    _player.positionStream.listen((pos) {
      // Feed the ambient bar's slim progress indicator (0..1). This updates a
      // standalone ValueNotifier so only that widget rebuilds, not the chat.
      final dur = _player.duration;
      if (dur != null && dur.inMilliseconds > 0) {
        playProgressNotifier.value =
            (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
      } else {
        playProgressNotifier.value = 0;
      }
      if (!_liveActive) {
        playClockNotifier.value = PlayClock(pos, dur ?? Duration.zero);
      }
      _pushMediaState();
      if (mounted) setState(() {});
    });
    _player.durationStream.listen((_) {
      if (mounted) setState(() {});
      _pushMediaState();
    });
  }

  // ── Playback ───────────────────────────────────────────────────────────────

  Future<void> _play(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    final path = _playlist[index];

    // Suppress auto-advance while swapping the source (see _switching).
    _switching = true;

    final initTitle = metadataStore.title(path, _nameFromPath(path));
    final initArtist = metadataStore.artist(path, '');
    setState(() {
      _currentIndex = index;
      _trackName = initTitle;
      _artistName = initArtist;
    });
    nowPlayingNotifier.update(
        track: initTitle, artist: initArtist, playing: true);
    _syncFavoriteAmbient();

    try {
      // setFilePath implicitly stops previous — no need for explicit stop()
      await _player.setFilePath(path);
      await _player.setVolume(_muted ? 0 : _volume);
      await _player.setSpeed(_speed);
      await _player.play();
    } on PlayerException catch (e) {
      _switching = false;
      if (mounted) _snack('Cannot play: ${e.message}');
      return;
    } catch (_) {
      _switching = false;
      if (mounted) _snack('Playback error — check file format');
      return;
    }
    // Re-enable auto-advance once playback has actually settled.
    Future.delayed(const Duration(milliseconds: 600), () {
      _switching = false;
    });
    if (_isMobile) _fetchMetadata(path);
  }

  Future<void> _fetchMetadata(String path) async {
    try {
      final q = OnAudioQuery();
      final songs = await q.querySongs();
      final m = songs
          .cast<SongModel?>()
          .firstWhere((s) => s?.data == path, orElse: () => null);
      if (m != null && mounted) {
        // User overrides win over the file's own tags.
        final t = metadataStore.title(
            path, m.title.isNotEmpty ? m.title : _nameFromPath(path));
        final a = metadataStore.artist(path, m.artist ?? '');
        setState(() {
          _trackName = t;
          _artistName = a;
        });
        nowPlayingNotifier.update(track: t, artist: a, playing: true);
      }
    } catch (_) {}
  }

  void _onComplete() {
    if (_playlist.isEmpty) return;
    if (_repeatOne) {
      _play(_currentIndex);
    } else if (_shuffle) {
      _play(_rng.nextInt(_playlist.length));
    } else if (_repeatAll) {
      _play((_currentIndex + 1) % _playlist.length);
    } else if (_currentIndex + 1 < _playlist.length) {
      _play(_currentIndex + 1);
    } else {
      // End of playlist, no repeat
      nowPlayingNotifier.update(
          track: _trackName, artist: _artistName, playing: false);
      if (mounted) setState(() {});
    }
  }

  Future<void> _togglePlayPause() async {
    if (_playlist.isEmpty) {
      _snack('Add music first — tap the folder icon');
      return;
    }
    if (_currentIndex < 0) {
      _play(0);
      return;
    }
    _player.playing ? await _player.pause() : await _player.play();
  }

  void _next() {
    if (_playlist.isEmpty) return;
    if (_shuffle) {
      _play(_rng.nextInt(_playlist.length));
    } else if (_currentIndex + 1 < _playlist.length) {
      _play(_currentIndex + 1);
    } else if (_repeatAll) {
      _play(0);
    } else {
      _snack('End of playlist');
    }
  }

  void _previous() {
    if (_playlist.isEmpty) return;
    if (_player.position.inSeconds > 3) {
      _player.seek(Duration.zero);
      return;
    }
    if (_currentIndex > 0) {
      _play(_currentIndex - 1);
    } else if (_repeatAll) {
      _play(_playlist.length - 1);
    } else {
      _player.seek(Duration.zero);
    }
  }

  /// Mirror the current playlist to the global notifier so other features
  /// (e.g. starting a live session from loaded songs) can read it.
  void _publishPlaylist() {
    playlistNotifier.value = List<String>.unmodifiable(_playlist);
    _savePlaylist();
  }

  // Persist the loaded playlist so it survives a full app restart (no re-scan).
  Future<void> _savePlaylist() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList('music_playlist', _playlist);
    } catch (_) {}
  }

  // On launch: restore the saved playlist immediately (pruning any files that
  // were deleted since), then quietly merge in any NEW media on the device —
  // so the list persists and stays fresh like other music apps.
  Future<void> _restorePlaylist() async {
    try {
      final p = await SharedPreferences.getInstance();
      final saved = p.getStringList('music_playlist') ?? const [];
      if (saved.isNotEmpty) {
        final existing = <String>[];
        for (final path in saved) {
          try {
            if (File(path).existsSync()) existing.add(path);
          } catch (_) {
            existing.add(path);
          }
        }
        if (!mounted) return;
        setState(() => _playlist = existing);
        _publishPlaylist();
      }
    } catch (_) {}
    if (Platform.isAndroid) {
      if (_playlist.isEmpty) {
        // Fresh install / nothing saved yet: auto-load the whole library via
        // MediaStore (prompts for media permission once) so the user never has
        // to manually tap "scan" after installing.
        _scanIntoPlaylist();
      } else {
        // Returning user: keep the saved list and quietly merge any new songs.
        _mergeNewMedia();
      }
    }
  }

  Future<void> _mergeNewMedia() async {
    try {
      // Silent (no prompt): only merge if MediaStore access is already granted.
      final granted = await _audioQuery.permissionsStatus();
      if (!granted) return;
      final songs = await _audioQuery.querySongs(uriType: UriType.EXTERNAL);
      final current = _playlist.toSet();
      final additions = songs
          .map((s) => s.data)
          .where((p) => p.isNotEmpty && !current.contains(p))
          .toList();
      if (additions.isEmpty || !mounted) return;
      setState(() => _playlist = [..._playlist, ...additions]);
      _publishPlaylist();
      _snack(
          'Added ${additions.length} new track${additions.length == 1 ? '' : 's'}');
    } catch (_) {}
  }

  /// Nudge the playback position by [seconds] (negative rewinds), clamped
  /// to the current track's bounds.
  void _seekBy(int seconds) {
    final dur = _player.duration ?? Duration.zero;
    var target = _player.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (dur > Duration.zero && target > dur) target = dur;
    _player.seek(target);
  }

  void _cycleRepeat() {
    setState(() {
      if (!_repeatAll && !_repeatOne) {
        _repeatAll = true;
        _repeatOne = false;
        _shuffle = false;
        _snack('Repeat All');
      } else if (_repeatAll) {
        _repeatAll = false;
        _repeatOne = true;
        _shuffle = false;
        _snack('Repeat One');
      } else {
        _repeatAll = false;
        _repeatOne = false;
        _snack('Repeat Off');
      }
    });
  }

  void _toggleShuffle() {
    setState(() {
      _shuffle = !_shuffle;
      if (_shuffle) {
        _repeatAll = false;
        _repeatOne = false;
      }
      _snack(_shuffle ? 'Shuffle On' : 'Shuffle Off');
    });
  }

  void _setVolume(double v) {
    setState(() => _volume = v);
    _player.setVolume(_muted ? 0 : v);
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _player.setVolume(_muted ? 0 : _volume);
  }

  void _setSpeed(double s) {
    setState(() => _speed = s);
    _player.setSpeed(s);
  }

  // ── Sleep timer ────────────────────────────────────────────────────────────

  void _showSleepTimerDialog() {
    final opts = <String, Duration?>{
      'Off': null,
      '5 min': const Duration(minutes: 5),
      '15 min': const Duration(minutes: 15),
      '30 min': const Duration(minutes: 30),
      '45 min': const Duration(minutes: 45),
      '60 min': const Duration(minutes: 60),
    };
    final scheme = Theme.of(context).colorScheme;
    // How many whole minutes are currently armed (null/0 => Off) so we can
    // highlight the active row.
    final activeMin = _sleepRemaining?.inMinutes;

    showDialog(
      context: context,
      barrierColor: Colors.black.withAlpha(120),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: scheme.outlineVariant.withAlpha(90)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(70),
                  blurRadius: 28,
                  offset: const Offset(0, 10),
                ),
                BoxShadow(
                  color: scheme.primary.withAlpha(28),
                  blurRadius: 20,
                  spreadRadius: -4,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Title row with the sleep glyph.
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
                  child: Row(
                    children: [
                      Icon(Icons.snooze_rounded,
                          size: 20, color: scheme.primary),
                      const SizedBox(width: 10),
                      Text('Sleep Timer',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface,
                          )),
                    ],
                  ),
                ),
                ...opts.entries.map((e) {
                  final isOff = e.value == null;
                  final selected = isOff
                      ? activeMin == null
                      : activeMin == e.value!.inMinutes;
                  return _sleepOption(
                    scheme,
                    label: e.key,
                    selected: selected,
                    onTap: () {
                      Navigator.pop(ctx);
                      _setSleepTimer(e.value);
                    },
                  );
                }),
                const SizedBox(height: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sleepOption(
    ColorScheme scheme, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary.withAlpha(30)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? scheme.primary.withAlpha(120)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? scheme.primary : scheme.onSurface,
                  ),
                ),
              ),
              if (selected)
                Icon(Icons.check_rounded, size: 18, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }

  void _setSleepTimer(Duration? d) {
    _sleepTimer?.cancel();
    _sleepTick?.cancel();
    if (d == null) {
      setState(() => _sleepRemaining = null);
      _snack('Sleep timer off');
      return;
    }
    setState(() => _sleepRemaining = d);
    _snack('Sleep in ${d.inMinutes} min');
    _sleepTimer = Timer(d, () {
      _player.pause();
      if (mounted) setState(() => _sleepRemaining = null);
    });
    _sleepTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_sleepRemaining != null && _sleepRemaining!.inSeconds > 0) {
          _sleepRemaining = _sleepRemaining! - const Duration(seconds: 1);
        }
      });
    });
  }

  // ── Favorites ──────────────────────────────────────────────────────────────

  void _toggleFavorite(String path) {
    setState(() => _favorites.contains(path)
        ? _favorites.remove(path)
        : _favorites.add(path));
    _saveFavorites();
    _syncFavoriteAmbient();
  }

  // ── File picking ───────────────────────────────────────────────────────────

  Future<void> _pickMusic() async {
    if (_isMobile) {
      await _pickAndroid();
    } else {
      await _pickDesktop();
    }
  }

  Future<void> _pickDesktop() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: true, // ignore: deprecated_member_use
      type: FileType.custom,
      allowedExtensions: ['mp3', 'wav', 'm4a', 'ogg', 'flac', 'aac'],
    );
    if (result == null || result.files.isEmpty) return;
    final paths =
        result.files.map((f) => f.path).whereType<String>().toList();
    if (paths.isEmpty) return;
    final newPaths = paths.where((p) => !_playlist.contains(p)).toList();
    setState(() => _playlist = [..._playlist, ...newPaths]);
    _publishPlaylist();
    _snack(
        'Added ${newPaths.length} track${newPaths.length == 1 ? '' : 's'}');
    if (!mounted) return;
    _openPlaylist();
  }

  Future<void> _pickAndroid() async {
    await _scanIntoPlaylist();
    if (!mounted || _playlist.isEmpty) return;
    _openPlaylist();
  }

  /// Loads the device's music library via MediaStore (fast, indexed), prompting
  /// for permission if needed. Does NOT open the sheet — callers decide when to
  /// show it.
  Future<void> _scanIntoPlaylist() async {
    bool granted = await _audioQuery.permissionsStatus();
    if (!granted) granted = await _audioQuery.permissionsRequest();
    if (!granted) {
      _snack('Media permission denied');
      return;
    }
    final songs = await _audioQuery.querySongs(
      sortType: SongSortType.TITLE,
      orderType: OrderType.ASC_OR_SMALLER,
      uriType: UriType.EXTERNAL,
    );
    final paths = songs.map((s) => s.data).where((p) => p.isNotEmpty).toList();
    if (paths.isEmpty) {
      _snack('No audio files found');
      return;
    }
    if (!mounted) return;
    setState(() => _playlist = paths);
    _publishPlaylist();
  }

  // ── Overlays ───────────────────────────────────────────────────────────────

  void _openPlaylist() {
    if (_playlist.isEmpty) {
      _snack('No tracks — add music first');
      return;
    }
    setState(() => _showPlaylist = true);
    _playlistCtrl.forward(from: 0);
  }

  /// Unified Playlist action (the "Add" button folded into this). If songs are
  /// already loaded it just opens the sheet; the first time on an empty list it
  /// opens the sheet with a loader and scans the device (Android) or opens the
  /// file picker (desktop/web).
  Future<void> _openOrScanPlaylist() async {
    if (_playlist.isNotEmpty) {
      setState(() => _showPlaylist = true);
      _playlistCtrl.forward(from: 0);
      return;
    }
    if (!_isMobile) {
      // Desktop/web: the file picker opens the sheet itself on success.
      await _pickDesktop();
      _scannedOnce = true;
      return;
    }
    // Android first-open: show the sheet with a loading animation, then scan.
    setState(() {
      _showPlaylist = true;
      _scanning = true;
    });
    _playlistCtrl.forward(from: 0);
    try {
      await _scanIntoPlaylist();
    } finally {
      _scannedOnce = true;
      if (mounted) setState(() => _scanning = false);
      // If the scan found nothing, close the empty sheet again.
      if (mounted && _playlist.isEmpty) _closePlaylist();
    }
  }

  void _closePlaylist() {
    _playlistCtrl.reverse().then((_) {
      if (mounted) setState(() => _showPlaylist = false);
    });
  }

  void _openEqualizer() {
    // Real EQ only works on Android — elsewhere just let the user know.
    if (!Platform.isAndroid || _equalizer == null) {
      showToast(
        context,
        'The equalizer works on the Android app — install Aluta on an Android device to use it.',
        type: ToastType.info,
        duration: const Duration(seconds: 3),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EqualizerScreen(
          equalizer: _equalizer,
          loudness: _loudness,
        ),
      ),
    );
  }

  void _toggleSpeedPanel() {
    if (_showSpeedPanel) {
      _speedCtrl.reverse().then((_) {
        if (mounted) setState(() => _showSpeedPanel = false);
      });
    } else {
      setState(() => _showSpeedPanel = true);
      _speedCtrl.forward(from: 0);
    }
  }

  // ── Volume popup (tap-to-reveal, auto-hide) ─────────────────────────────────
  void _openVolume() {
    if (_showVolume) {
      _closeVolume();
      return;
    }
    setState(() => _showVolume = true);
    _volumeCtrl.forward(from: 0);
    _armVolumeHide();
  }

  // Restart the idle countdown whenever the user touches the control.
  void _armVolumeHide() {
    _volumeHideTimer?.cancel();
    _volumeHideTimer =
        Timer(const Duration(milliseconds: 1500), _closeVolume);
  }

  void _closeVolume() {
    _volumeHideTimer?.cancel();
    if (!mounted || !_showVolume) return;
    _volumeCtrl.reverse().then((_) {
      if (mounted) setState(() => _showVolume = false);
    });
  }

  // The pill that grows rightward out of the volume button. Its leading 40×40
  // icon sits exactly on top of the button (same size / centre), so while the
  // popup is open the user sees a single volume icon — never two.
  Widget _buildVolumePopup(ColorScheme scheme) {
    final onSurface = scheme.onSurface;
    return GestureDetector(
      onTap: () {}, // absorb taps inside the card (barrier handles outside)
      child: Container(
        // Fixed, compact height == the volume button (44). The pill can never
        // grow tall; it only extends sideways out of the icon.
        height: 44,
        padding: const EdgeInsets.only(right: 12),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: scheme.outlineVariant.withAlpha(90)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(60),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Leading icon — same 40×40 footprint as the button, so it lands
            // precisely over it. Doubles as the mute toggle.
            GestureDetector(
              onTap: () {
                _toggleMute();
                _armVolumeHide();
              },
              child: SizedBox(
                width: 40,
                height: 44,
                child: Icon(
                  _muted || _volume == 0
                      ? Icons.volume_off_rounded
                      : _volume < 0.5
                          ? Icons.volume_down_rounded
                          : Icons.volume_up_rounded,
                  size: 18,
                  color: _muted ? scheme.error : onSurface.withAlpha(200),
                ),
              ),
            ),
            SizedBox(
              width: 150,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 7),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 14),
                  activeTrackColor:
                      _muted ? scheme.outlineVariant : scheme.primary,
                  inactiveTrackColor: onSurface.withAlpha(28),
                  thumbColor: _muted ? scheme.outlineVariant : scheme.primary,
                  overlayColor: scheme.primary.withAlpha(30),
                ),
                child: Slider(
                  value: _muted ? 0 : _volume,
                  onChanged: (v) {
                    if (_muted) setState(() => _muted = false);
                    _setVolume(v);
                    _armVolumeHide();
                  },
                ),
              ),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 46,
              child: Text(
                _muted ? 'mute' : '${(_volume * 100).round()}%',
                maxLines: 1,
                overflow: TextOverflow.visible,
                softWrap: false,
                style: TextStyle(
                    color: onSurface.withAlpha(160),
                    fontSize: 11,
                    fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _nameFromPath(String path) {
    final sep = Platform.pathSeparator;
    final name = path.contains(sep)
        ? path.substring(path.lastIndexOf(sep) + 1)
        : path.contains('/')
            ? path.substring(path.lastIndexOf('/') + 1)
            : path;
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    return _cleanTrackName(base);
  }

  String _fmt(Duration d) {
    final m = NumberFormat('00').format(d.inMinutes.remainder(60));
    final s = NumberFormat('00').format(d.inSeconds.remainder(60));
    return '$m:$s';
  }

  String _fmtSleep(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
  }

  void _snack(String msg, {bool isError = false}) {
    if (!mounted) return;
    showToast(context, msg,
        type: isError ? ToastType.error : ToastType.info);
  }

  // ── BUILD ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;

    return KeyboardListener(
      focusNode: FocusNode(),
      autofocus: false,
      onKeyEvent: (e) {
        if (e is! KeyDownEvent) return;
        if (e.logicalKey == LogicalKeyboardKey.space) _togglePlayPause();
        if (e.logicalKey == LogicalKeyboardKey.arrowRight) _next();
        if (e.logicalKey == LogicalKeyboardKey.arrowLeft) _previous();
        if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
          _setVolume((_volume + 0.1).clamp(0, 1));
        }
        if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
          _setVolume((_volume - 0.1).clamp(0, 1));
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── Main content ──────────────────────────────────────────────
          _buildMain(context, scheme, isDark),

          // ── Playlist sheet — slides UP from the bottom, half-height so the
          //    spinning disc stays visible, and WIDTH-CAPPED + centred so it
          //    doesn't span the whole screen on desktop/tablet. ────────────
          if (_showPlaylist)
            LayoutBuilder(
              builder: (ctx, cons) {
                // Fill the panel width so the header (and its right-aligned
                // collapse chevron) reach the far edge instead of floating in a
                // centred 520-wide column that looks orphaned on desktop.
                final sheetW = cons.maxWidth;
                final sheetH = cons.maxHeight * 0.62;
                return Align(
                  alignment: Alignment.bottomCenter,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 1),
                      end: Offset.zero,
                    ).animate(CurvedAnimation(
                      parent: _playlistCtrl,
                      curve: Curves.easeOutCubic,
                      reverseCurve: Curves.easeInCubic,
                    )),
                    child: FadeTransition(
                      opacity: _playlistCtrl,
                      child: SizedBox(
                        width: sheetW,
                        height: sheetH,
                        child: _PlaylistOverlay(
                  playlist: _playlist,
                  currentIndex: _currentIndex,
                  favorites: _favorites,
                  loading: _scanning,
                  onPlay: (i) {
                    _closePlaylist();
                    _play(i);
                  },
                  onClose: _closePlaylist,
                  onRemove: (i) {
                    setState(() {
                      _playlist.removeAt(i);
                      if (_currentIndex >= _playlist.length) {
                        _currentIndex = _playlist.length - 1;
                      }
                    });
                    _publishPlaylist();
                  },
                  onFavorite: _toggleFavorite,
                  onReorder: (o, n) {
                    setState(() {
                      // Remember the playing track by PATH so the now-playing
                      // pointer follows it wherever it lands after the move.
                      final playingPath = (_currentIndex >= 0 &&
                              _currentIndex < _playlist.length)
                          ? _playlist[_currentIndex]
                          : null;
                      if (n > o) n--;
                      final item = _playlist.removeAt(o);
                      _playlist.insert(n, item);
                      if (playingPath != null) {
                        _currentIndex = _playlist.indexOf(playingPath);
                      }
                    });
                    _publishPlaylist();
                  },
                  onAdd: _pickMusic,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),

          // ── Speed popup — scales from the speed button (bottom-right) ──
          if (_showSpeedPanel)
            Positioned(
              right: 0,
              bottom: 0,
              left: 0,
              child: ScaleTransition(
                scale: CurvedAnimation(
                  parent: _speedCtrl,
                  curve: Curves.easeOutBack,
                  reverseCurve: Curves.easeIn,
                ),
                // Anchor at bottom-right where the speed button lives
                alignment: Alignment.bottomRight,
                child: FadeTransition(
                  opacity: _speedCtrl,
                  child: _SpeedPanel(
                    currentSpeed: _speed,
                    onSelect: (s) {
                      _setSpeed(s);
                      _toggleSpeedPanel();
                    },
                    onClose: _toggleSpeedPanel,
                  ),
                ),
              ),
            ),

          // ── Volume popup — grows rightward out of the volume button ─────────
          // A transparent full-screen barrier catches taps outside; the pill
          // itself is anchored to the button via the LayerLink so it appears
          // right on top of the icon and expands forward (to the right).
          if (_showVolume)
            Positioned.fill(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: _closeVolume,
                      behavior: HitTestBehavior.opaque,
                      child: const SizedBox.expand(),
                    ),
                  ),
                  CompositedTransformFollower(
                    link: _volumeLink,
                    showWhenUnlinked: false,
                    // Pin the pill's centre-left to the button's centre-left, so
                    // the pill's leading icon lands exactly over the button icon.
                    targetAnchor: Alignment.centerLeft,
                    followerAnchor: Alignment.centerLeft,
                    child: ScaleTransition(
                      scale: CurvedAnimation(
                        parent: _volumeCtrl,
                        curve: Curves.easeOutBack,
                        reverseCurve: Curves.easeIn,
                      ),
                      // Grow out of the icon toward the right.
                      alignment: Alignment.centerLeft,
                      child: FadeTransition(
                        opacity: _volumeCtrl,
                        child: _buildVolumePopup(scheme),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMain(
      BuildContext context, ColorScheme scheme, bool isDark) {
    final accent = scheme.primary;
    final onSurface = scheme.onSurface;

    // When a live session is active the panel becomes its console: it shows
    // and drives the LIVE track instead of the local library.
    final live = _liveActive;
    final lc = _live;
    final isPlaying =
        live ? (lc?.player.playing ?? false) : _player.playing;
    final hasTrack = _currentIndex >= 0 && _playlist.isNotEmpty; // local
    final controlsOn = live || hasTrack;
    final position =
        live ? (lc?.player.position ?? Duration.zero) : _player.position;
    final duration = live
        ? (lc?.player.duration ?? Duration.zero)
        : (_player.duration ?? Duration.zero);
    final buffering = live
        ? (lc?.player.processingState == ProcessingState.buffering ||
            lc?.player.processingState == ProcessingState.loading)
        : (_player.processingState == ProcessingState.buffering ||
            _player.processingState == ProcessingState.loading);
    final sliderMax = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    final sliderVal =
        position.inMilliseconds.toDouble().clamp(0.0, sliderMax);
    final isFav =
        hasTrack && _favorites.contains(_playlist[_currentIndex]);
    final displayTitle =
        live ? _liveTitle() : (hasTrack ? _trackName : 'No track loaded');
    final displayArtist = live
        ? 'Live · ${_isLiveHost ? 'streaming to' : 'with'} ${activeLiveSession?.peerName ?? ''}'
        : _artistName;

    return LayoutBuilder(builder: (context, box) {
      final isNarrow = box.maxWidth < 220;

      return SingleChildScrollView(
        padding:
            EdgeInsets.fromLTRB(16, 14, 16, isNarrow ? 10 : 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [

            // ── Disc + track info card ────────────────────────────────
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                // Subtle brand-tinted wash: a whisper of red in the corner that
                // fades out — modern and "alive" without overpowering the text.
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isDark
                      ? [
                          accent.withAlpha(38),
                          Colors.white.withAlpha(10),
                        ]
                      : [
                          accent.withAlpha(28),
                          accent.withAlpha(8),
                        ],
                ),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withAlpha(20)
                      : accent.withAlpha(40),
                ),
              ),
              child: Row(
                children: [
                  // Spinning disc
                  AnimatedBuilder(
                    animation: _discCtrl,
                    builder: (ctx, child) => Transform.rotate(
                      angle: _discCtrl.value * 2 * pi,
                      child: child,
                    ),
                    child: Container(
                      width: isNarrow ? 58 : 76,
                      height: isNarrow ? 58 : 76,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(colors: [
                          accent.withAlpha(230),
                          isDark
                              ? const Color(0xFF1A1A2E)
                              : Colors.grey[200]!,
                        ]),
                        boxShadow: [
                          BoxShadow(
                            color: accent
                                .withAlpha(isPlaying ? 120 : 40),
                            blurRadius: isPlaying ? 18 : 8,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                      child: buffering
                          ? Padding(
                              padding: const EdgeInsets.all(18),
                              child: CircularProgressIndicator(
                                color: Colors.white.withAlpha(200),
                                strokeWidth: 2,
                              ),
                            )
                          : Icon(Icons.music_note_rounded,
                              size: isNarrow ? 28 : 38,
                              color: Colors.white.withAlpha(220)),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        MarqueeText(
                          text: displayTitle,
                          height: isNarrow ? 17 : 19,
                          style: TextStyle(
                            color: onSurface,
                            fontSize: isNarrow ? 12 : 13.5,
                            fontWeight: FontWeight.bold,
                            height: 1.3,
                          ),
                        ),
                        if (displayArtist.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(displayArtist,
                              style: TextStyle(
                                  color: live
                                      ? accent
                                      : onSurface.withAlpha(160),
                                  fontWeight: live
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                  fontSize: 11.5),
                              overflow: TextOverflow.ellipsis),
                        ],
                        if (live) ...[
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: accent,
                                ),
                              ),
                              const SizedBox(width: 5),
                              Text('LIVE',
                                  style: TextStyle(
                                      color: accent,
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1)),
                            ],
                          ),
                        ] else if (_playlist.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            '${_currentIndex + 1} / ${_playlist.length}',
                            style: TextStyle(
                                color: onSurface.withAlpha(100),
                                fontSize: 10.5),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (!live && hasTrack)
                    GestureDetector(
                      onTap: () =>
                          _toggleFavorite(_playlist[_currentIndex]),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: Icon(
                          isFav
                              ? Icons.favorite
                              : Icons.favorite_border,
                          key: ValueKey(isFav),
                          color: isFav
                              ? Colors.pinkAccent
                              : onSurface.withAlpha(130),
                          size: 24,
                        ),
                      ),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ── Position bar — accent colour, taller thumb ────────────
            Row(
              children: [
                Text(_fmt(position),
                    style: TextStyle(
                        color: onSurface.withAlpha(150), fontSize: 11)),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 7),
                      overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 16),
                      activeTrackColor: accent,
                      inactiveTrackColor: accent.withAlpha(50),
                      thumbColor: accent,
                      overlayColor: accent.withAlpha(35),
                    ),
                    child: Slider(
                      value: sliderVal,
                      max: sliderMax,
                      onChanged: controlsOn
                          ? (v) => _transportSeek(
                              Duration(milliseconds: v.toInt()))
                          : null,
                    ),
                  ),
                ),
                Text(_fmt(duration),
                    style: TextStyle(
                        color: onSurface.withAlpha(150), fontSize: 11)),
              ],
            ),

            const SizedBox(height: 12),

            // ── Transport: shuffle · prev · −10 · play · +10 · next · repeat
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _CtrlChip(
                    icon: Icons.shuffle_rounded,
                    active: _shuffle,
                    activeColor: Colors.green,
                    onTap: _toggleShuffle,
                    tooltip: 'Shuffle',
                  ),
                  const SizedBox(width: 14),
                  _CtrlBtn(
                    icon: Icons.skip_previous_rounded,
                    size: 32,
                    color: controlsOn ? onSurface : onSurface.withAlpha(40),
                    onTap: controlsOn ? _transportPrev : null,
                    tooltip: 'Previous',
                  ),
                  const SizedBox(width: 8),
                  _CtrlBtn(
                    icon: Icons.replay_10_rounded,
                    size: 28,
                    color: controlsOn ? onSurface : onSurface.withAlpha(40),
                    onTap: controlsOn ? () => _transportSeekBy(-10) : null,
                    tooltip: 'Back 10s',
                  ),
                  const SizedBox(width: 14),
                  GestureDetector(
                    onTap: _transportPlayPause,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 68,
                      height: 68,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        // Glossy red gradient gives the transport a lively,
                        // "spark" feel instead of a flat maroon disc.
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
                            color: accent
                                .withAlpha(isPlaying ? 150 : 70),
                            blurRadius: isPlaying ? 24 : 12,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: buffering
                          ? const Padding(
                              padding: EdgeInsets.all(18),
                              child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2.5),
                            )
                          : Icon(
                              isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              size: 40,
                              color: Colors.white,
                            ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  _CtrlBtn(
                    icon: Icons.forward_10_rounded,
                    size: 28,
                    color: controlsOn ? onSurface : onSurface.withAlpha(40),
                    onTap: controlsOn ? () => _transportSeekBy(10) : null,
                    tooltip: 'Forward 10s',
                  ),
                  const SizedBox(width: 8),
                  _CtrlBtn(
                    icon: Icons.skip_next_rounded,
                    size: 32,
                    color: controlsOn ? onSurface : onSurface.withAlpha(40),
                    onTap: controlsOn ? _transportNext : null,
                    tooltip: 'Next',
                  ),
                  const SizedBox(width: 14),
                  _CtrlChip(
                    icon: _repeatOne
                        ? Icons.repeat_one_rounded
                        : Icons.repeat_rounded,
                    active: _repeatAll || _repeatOne,
                    activeColor: accent,
                    onTap: _cycleRepeat,
                    tooltip: _repeatOne
                        ? 'Repeat One'
                        : _repeatAll
                            ? 'Repeat All'
                            : 'Repeat Off',
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ── Utilities ─────────────────────────────────────────────
            // Shuffle & repeat now live in the transport row, so this row
            // is reserved for the less-frequent library actions. Each one
            // is a labelled tile, evenly spaced to breathe across the width.
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _utility(
                  scheme,
                  onSurface,
                  // "Add" folded in here: first tap scans the device, later
                  // taps just open the playlist.
                  icon: Icons.queue_music_rounded,
                  label: 'Playlist',
                  color: accent,
                  active: _showPlaylist || _playlist.isNotEmpty,
                  badge: _playlist.isNotEmpty ? '${_playlist.length}' : null,
                  onTap: _openOrScanPlaylist,
                ),
                _utility(
                  scheme,
                  onSurface,
                  // Snooze "Zᶻ" glyph — deliberately distinct from the crescent
                  // moon used by the dark-theme toggle in the app header.
                  icon: Icons.snooze_rounded,
                  label: 'Sleep',
                  color: Colors.indigo,
                  active: _sleepRemaining != null,
                  badge: _sleepRemaining != null
                      ? _fmtSleep(_sleepRemaining!)
                      : null,
                  onTap: _showSleepTimerDialog,
                ),
                _utility(
                  scheme,
                  onSurface,
                  icon: Icons.graphic_eq_rounded,
                  label: 'Equalizer',
                  color: accent,
                  onTap: _openEqualizer,
                ),
              ],
            ),

            const SizedBox(height: 18),
            Divider(height: 1, color: scheme.outlineVariant.withAlpha(50)),
            const SizedBox(height: 14),

            // ── Volume (left ~45%) + Speed button (right) on same row ────
            Row(
              children: [
                // Volume — tap to reveal a popup slider that auto-hides. Keeps
                // the row clean and stops the volume track from clashing with
                // the accent seek bar above it.
                CompositedTransformTarget(
                  link: _volumeLink,
                  child: GestureDetector(
                    onTap: _openVolume,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        // While the popup is open it sits over this spot, so the
                        // button box/icon fade out — the user sees one icon only.
                        color: _showVolume
                            ? Colors.transparent
                            : (_muted
                                ? scheme.error.withAlpha(28)
                                : scheme.surfaceContainerHighest),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _showVolume
                              ? Colors.transparent
                              : scheme.outlineVariant.withAlpha(80),
                        ),
                      ),
                      child: Icon(
                        _muted || _volume == 0
                            ? Icons.volume_off_rounded
                            : _volume < 0.5
                                ? Icons.volume_down_rounded
                                : Icons.volume_up_rounded,
                        size: 18,
                        color: _showVolume
                            ? Colors.transparent
                            : (_muted
                                ? scheme.error
                                : onSurface.withAlpha(180)),
                      ),
                    ),
                  ),
                ),
                const Spacer(),

                const SizedBox(width: 10),

                // Sleep remaining (compact, inline)
                if (_sleepRemaining != null) ...[
                  Icon(Icons.timer_outlined,
                      size: 11, color: Colors.indigo.withAlpha(200)),
                  const SizedBox(width: 3),
                  Text(
                    _fmtSleep(_sleepRemaining!),
                    style: TextStyle(
                        fontSize: 10, color: Colors.indigo.withAlpha(200)),
                  ),
                  GestureDetector(
                    onTap: () => _setSleepTimer(null),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(Icons.close,
                          size: 11, color: onSurface.withAlpha(110)),
                    ),
                  ),
                ],

                // Speed button — anchored right so popup scales from here
                GestureDetector(
                  onTap: _toggleSpeedPanel,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 11, vertical: 7),
                    decoration: BoxDecoration(
                      color: _showSpeedPanel
                          ? accent.withAlpha(30)
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: _showSpeedPanel
                            ? accent
                            : scheme.outlineVariant.withAlpha(80),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.speed_rounded,
                            size: 14,
                            color: _showSpeedPanel
                                ? accent
                                : onSurface.withAlpha(160)),
                        const SizedBox(width: 4),
                        Text(
                          _speedLabel(_speed),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: _showSpeedPanel
                                ? accent
                                : onSurface.withAlpha(170),
                          ),
                        ),
                        const SizedBox(width: 3),
                        Icon(
                          _showSpeedPanel
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 13,
                          color: _showSpeedPanel
                              ? accent
                              : onSurface.withAlpha(120),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),

          ],
        ),
      );
    });
  }

  /// A labelled utility tile — icon in a soft rounded chip with a caption
  /// underneath, and an optional corner badge (playlist count / sleep time).
  Widget _utility(
    ColorScheme scheme,
    Color onSurface, {
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
    bool active = false,
    String? badge,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: active
                      ? color.withAlpha(38)
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: active
                        ? color.withAlpha(150)
                        : scheme.outlineVariant.withAlpha(70),
                  ),
                ),
                child: Icon(
                  icon,
                  size: 21,
                  color: active ? color : onSurface.withAlpha(190),
                ),
              ),
              if (badge != null)
                Positioned(
                  top: -5,
                  right: -5,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: scheme.surface, width: 1.5),
                    ),
                    child: Text(
                      badge,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 8.5,
                        fontWeight: FontWeight.bold,
                        height: 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
              color: active ? color : onSurface.withAlpha(160),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Small reusable widgets ───────────────────────────────────────────────────

class _CtrlBtn extends StatelessWidget {
  final IconData icon;
  final double size;
  final Color color;
  final VoidCallback? onTap;
  final String tooltip;

  const _CtrlBtn({
    required this.icon,
    required this.size,
    required this.color,
    required this.tooltip,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, size: size, color: color),
        ),
      ),
    );
  }
}

class _CtrlChip extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color activeColor;
  final VoidCallback onTap;
  final String tooltip;

  const _CtrlChip({
    required this.icon,
    required this.active,
    required this.activeColor,
    required this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: active
                ? activeColor.withAlpha(25)
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active
                  ? activeColor.withAlpha(120)
                  : scheme.outlineVariant.withAlpha(60),
            ),
          ),
          child: Icon(
            icon,
            size: 20,
            color: active ? activeColor : scheme.onSurface.withAlpha(130),
          ),
        ),
      ),
    );
  }
}

// ─── Speed panel ──────────────────────────────────────────────────────────────

class _SpeedPanel extends StatelessWidget {
  final double currentSpeed;
  final void Function(double) onSelect;
  final VoidCallback onClose;

  const _SpeedPanel({
    required this.currentSpeed,
    required this.onSelect,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onClose,
      behavior: HitTestBehavior.opaque,
      child: Align(
        alignment: Alignment.bottomRight,
        child: GestureDetector(
          onTap: () {}, // absorb inner taps
          child: Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 56),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: scheme.outlineVariant.withAlpha(80)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(70),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.speed_rounded,
                        size: 16, color: scheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      'Playback Speed',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: scheme.onSurface),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: onClose,
                      child: Icon(Icons.close,
                          size: 18,
                          color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _speeds.map((s) {
                    final active = (s - currentSpeed).abs() < 0.01;
                    return GestureDetector(
                      onTap: () => onSelect(s),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 10),
                        decoration: BoxDecoration(
                          color: active
                              ? scheme.primary
                              : scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: active
                                ? scheme.primary
                                : scheme.outlineVariant.withAlpha(80),
                          ),
                        ),
                        child: Text(
                          _speedLabel(s),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: active
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: active
                                ? scheme.onPrimary
                                : scheme.onSurface.withAlpha(170),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Playlist overlay ─────────────────────────────────────────────────────────

class _PlaylistOverlay extends StatefulWidget {
  final List<String> playlist;
  final int currentIndex;
  final Set<String> favorites;
  final void Function(int) onPlay;
  final void Function(int) onRemove;
  final void Function(String) onFavorite;
  final void Function(int, int) onReorder;
  final VoidCallback onClose;
  final VoidCallback onAdd;
  final bool loading;

  const _PlaylistOverlay({
    required this.playlist,
    required this.currentIndex,
    required this.favorites,
    required this.onPlay,
    required this.onRemove,
    required this.onFavorite,
    required this.onReorder,
    required this.onClose,
    required this.onAdd,
    this.loading = false,
  });

  @override
  State<_PlaylistOverlay> createState() => _PlaylistOverlayState();
}

class _PlaylistOverlayState extends State<_PlaylistOverlay> {
  String _search = '';
  bool _favOnly = false;

  String _name(String path) {
    final sep = Platform.pathSeparator;
    final n = path.contains(sep)
        ? path.substring(path.lastIndexOf(sep) + 1)
        : path.contains('/')
            ? path.substring(path.lastIndexOf('/') + 1)
            : path;
    final d = n.lastIndexOf('.');
    return _cleanTrackName(d > 0 ? n.substring(0, d) : n);
  }

  // Display title/artist with the user's in-app override applied on top of the
  // heuristic derived from the filename.
  String _effTitle(String path) {
    final ta = _titleArtist(_name(path));
    return metadataStore.title(path, ta.$1);
  }

  String _effArtist(String path) {
    final ta = _titleArtist(_name(path));
    return metadataStore.artist(path, ta.$2 ?? '');
  }

  // Per-track options sheet (opened from the ⋮ button).
  void _showTrackOptions(
      BuildContext context, String path, int realIdx, bool isFav) {
    final scheme = Theme.of(context).colorScheme;
    final title = _effTitle(path);
    final artist = _effArtist(path);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(22),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.onSurfaceVariant.withAlpha(80),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                    if (artist.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant)),
                      ),
                  ],
                ),
              ),
              Divider(height: 1, color: scheme.outlineVariant.withAlpha(70)),
              _optionTile(scheme, Icons.play_arrow_rounded, 'Play now', () {
                Navigator.pop(ctx);
                widget.onPlay(realIdx);
              }),
              _optionTile(scheme, Icons.edit_rounded, 'Edit details', () {
                Navigator.pop(ctx);
                _showEditDetails(context, path);
              }),
              _optionTile(
                scheme,
                isFav ? Icons.favorite : Icons.favorite_border,
                isFav ? 'Remove from favourites' : 'Add to favourites',
                () {
                  Navigator.pop(ctx);
                  widget.onFavorite(path);
                },
                iconColor: isFav ? Colors.pinkAccent : null,
              ),
              _optionTile(
                scheme,
                Icons.playlist_remove_rounded,
                'Remove from list',
                () {
                  Navigator.pop(ctx);
                  widget.onRemove(realIdx);
                },
                danger: true,
              ),
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    );
  }

  Widget _optionTile(ColorScheme scheme, IconData icon, String label,
      VoidCallback onTap,
      {Color? iconColor, bool danger = false}) {
    final c = danger ? scheme.error : scheme.onSurface;
    return ListTile(
      dense: true,
      leading: Icon(icon, color: iconColor ?? c, size: 22),
      title: Text(label, style: TextStyle(color: c, fontSize: 14)),
      onTap: onTap,
    );
  }

  // ── Edit track details (in-app, Play-safe — no file rewrite) ────────────────
  Future<void> _showEditDetails(BuildContext context, String path) async {
    final scheme = Theme.of(context).colorScheme;
    final o = metadataStore.of(path);
    final ta = _titleArtist(_name(path));
    final titleC = TextEditingController(text: o?.title ?? ta.$1);
    final artistC = TextEditingController(text: o?.artist ?? (ta.$2 ?? ''));
    final albumC = TextEditingController(text: o?.album ?? '');
    final genreC = TextEditingController(text: o?.genre ?? '');
    final yearC = TextEditingController(text: o?.year ?? '');

    Widget field(String label, TextEditingController c,
        {TextInputType? kb, IconData? icon}) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          keyboardType: kb,
          decoration: InputDecoration(
            labelText: label,
            prefixIcon: icon != null ? Icon(icon, size: 20) : null,
            isDense: true,
            filled: true,
            fillColor: scheme.surfaceContainerHighest,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      );
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        // Lift above the keyboard.
        padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 8,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 4, bottom: 12),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.onSurfaceVariant.withAlpha(80),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Icon(Icons.edit_note_rounded, color: scheme.primary),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Edit details',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                  // One-tap cleanup of junk titles.
                  TextButton.icon(
                    onPressed: () {
                      titleC.text = _cleanTrackName(titleC.text);
                    },
                    icon: const Icon(Icons.auto_fix_high_rounded, size: 16),
                    label: const Text('Clean'),
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              field('Title', titleC, icon: Icons.music_note_rounded),
              field('Artist', artistC, icon: Icons.person_rounded),
              field('Album', albumC, icon: Icons.album_rounded),
              Row(
                children: [
                  Expanded(child: field('Genre', genreC)),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 110,
                    child: field('Year', yearC,
                        kb: TextInputType.number),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              FilledButton.icon(
                onPressed: () async {
                  await metadataStore.set(
                    path,
                    TrackMeta(
                      title: titleC.text.trim(),
                      artist: artistC.text.trim(),
                      album: albumC.text.trim(),
                      genre: genreC.text.trim(),
                      year: yearC.text.trim(),
                    ),
                  );
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (mounted) setState(() {}); // refresh the list
                },
                icon: const Icon(Icons.check_rounded),
                label: const Text('Save details'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final q = _search.toLowerCase();

    final displayed = widget.playlist
        .asMap()
        .entries
        .where((e) =>
            _name(e.value).toLowerCase().contains(q) &&
            (!_favOnly || widget.favorites.contains(e.value)))
        .toList();

    return Container(
      margin: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant.withAlpha(60)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(50),
            blurRadius: 26,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          // Grab handle — tap OR slide down to dismiss the sheet.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            onVerticalDragEnd: (details) {
              // A downward flick (or drag) collapses the panel.
              if ((details.primaryVelocity ?? 0) > 0) widget.onClose();
            },
            child: Container(
              // Generous padding gives the thin bar a comfortable hit area.
              padding: const EdgeInsets.symmetric(vertical: 10),
              width: double.infinity,
              alignment: Alignment.center,
              child: Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: scheme.onSurfaceVariant.withAlpha(90),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withAlpha(120),
              border: Border(
                  bottom: BorderSide(
                      color: scheme.outlineVariant.withAlpha(80))),
            ),
            child: Row(
              children: [
                Icon(Icons.queue_music_rounded,
                    color: scheme.primary, size: 18),
                const SizedBox(width: 6),
                // Flexible prevents overflow when panel is narrow
                Flexible(
                  child: Text(
                    'Playlist (${widget.playlist.length})',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 14),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Action icons — compact sizing to fit small panels
                GestureDetector(
                  onTap: widget.onAdd,
                  child: Tooltip(
                    message: 'Add music',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 4),
                      child: Icon(Icons.add_rounded,
                          color: scheme.primary, size: 20),
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () =>
                      setState(() => _favOnly = !_favOnly),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 4),
                    child: Icon(
                      _favOnly
                          ? Icons.favorite
                          : Icons.favorite_border,
                      color: _favOnly
                          ? Colors.pinkAccent
                          : scheme.onSurfaceVariant,
                      size: 18,
                    ),
                  ),
                ),
                // Push the close control to the far edge, away from the
                // add/favourite actions.
                const Spacer(),
                // Close / collapse — down chevron matches the slide-down gesture
                GestureDetector(
                  onTap: widget.onClose,
                  child: Tooltip(
                    message: 'Close',
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        // Red accent touch to match the brand.
                        color: scheme.primary.withAlpha(28),
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.primary.withAlpha(70)),
                      ),
                      child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 22,
                          color: scheme.primary),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Search bar
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: TextField(
              onChanged: (v) => setState(() => _search = v),
              decoration: InputDecoration(
                hintText: 'Search tracks...',
                prefixIcon: const Icon(Icons.search, size: 18),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                filled: true,
                fillColor: scheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),

          // Track list
          Expanded(
            child: widget.loading && widget.playlist.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 30,
                          height: 30,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.6,
                            color: scheme.primary,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'Scanning your music…',
                          style: TextStyle(
                              color: scheme.onSurfaceVariant, fontSize: 13),
                        ),
                      ],
                    ),
                  )
                : displayed.isEmpty
                    ? Center(
                        child: Text(
                          _favOnly ? 'No favorites yet' : 'No tracks match',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      )
                    : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 4),
                    itemCount: displayed.length,
                    itemBuilder: (ctx, i) {
                      final entry = displayed[i];
                      // entry.key IS the real index in the full playlist.
                      final realIdx = entry.key;
                      final isNow = realIdx == widget.currentIndex;
                      final isFav =
                          widget.favorites.contains(entry.value);

                      return Dismissible(
                        key: ValueKey(entry.value),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 16),
                          color: scheme.error.withAlpha(180),
                          child: const Icon(Icons.delete_outline,
                              color: Colors.white),
                        ),
                        onDismissed: (_) =>
                            widget.onRemove(realIdx),
                        child: ListTile(
                          key: ValueKey('tile_$i'),
                          dense: true,
                          visualDensity:
                              const VisualDensity(vertical: -3),
                          minVerticalPadding: 0,
                          horizontalTitleGap: 10,
                          selected: isNow,
                          selectedTileColor: scheme.primary.withAlpha(22),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 0),
                          leading: CircleAvatar(
                            radius: 15,
                            backgroundColor: isNow
                                ? scheme.primary
                                : scheme.surfaceContainerHighest,
                            child: isNow
                                ? Icon(Icons.equalizer_rounded,
                                    size: 15, color: scheme.onPrimary)
                                : Text('${realIdx + 1}',
                                    style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: scheme.onSurfaceVariant)),
                          ),
                          title: Text(
                            _effTitle(entry.value),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: isNow
                                  ? FontWeight.bold
                                  : FontWeight.w500,
                              color: isNow ? scheme.primary : null,
                            ),
                          ),
                          subtitle: _effArtist(entry.value).isEmpty
                              ? null
                              : Text(
                                  _effArtist(entry.value),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isFav)
                                const Padding(
                                  padding: EdgeInsets.only(right: 2),
                                  child: Icon(Icons.favorite,
                                      size: 14,
                                      color: Colors.pinkAccent),
                                ),
                              IconButton(
                                icon: Icon(Icons.more_vert,
                                    size: 20,
                                    color: scheme.onSurfaceVariant),
                                visualDensity: VisualDensity.compact,
                                tooltip: 'Options',
                                onPressed: () => _showTrackOptions(
                                    context, entry.value, realIdx, isFav),
                              ),
                            ],
                          ),
                          onTap: () => widget.onPlay(realIdx),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
