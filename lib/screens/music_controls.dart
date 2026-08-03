import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_session/audio_session.dart';
import '../screens/home_page.dart' show nowPlayingNotifier;
import '../utils/toast_helper.dart';
import 'package:on_audio_query/on_audio_query.dart';

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

  List<String> _playlist = [];
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

  late AnimationController _discCtrl;
  late AnimationController _playlistCtrl;
  late AnimationController _speedCtrl;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();

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

    _configSession();
    _loadFavorites();
    _listenPlayer();
  }

  @override
  void dispose() {
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

  void _listenPlayer() {
    _player.playerStateStream.listen((s) {
      if (!mounted) return;
      setState(() {});
      nowPlayingNotifier.update(
          track: _trackName, artist: _artistName, playing: s.playing);
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

    _player.positionStream.listen((_) {
      if (mounted) setState(() {});
    });
    _player.durationStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  // ── Playback ───────────────────────────────────────────────────────────────

  Future<void> _play(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    final path = _playlist[index];

    // Suppress auto-advance while swapping the source (see _switching).
    _switching = true;

    setState(() {
      _currentIndex = index;
      _trackName = _nameFromPath(path);
      _artistName = '';
    });
    nowPlayingNotifier.update(
        track: _nameFromPath(path), artist: '', playing: true);

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
        final t = m.title.isNotEmpty ? m.title : _nameFromPath(path);
        setState(() {
          _trackName = t;
          _artistName = m.artist ?? '';
        });
        nowPlayingNotifier.update(
            track: t, artist: m.artist ?? '', playing: true);
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
    final opts = {
      'Off': null,
      '5 min': const Duration(minutes: 5),
      '15 min': const Duration(minutes: 15),
      '30 min': const Duration(minutes: 30),
      '45 min': const Duration(minutes: 45),
      '60 min': const Duration(minutes: 60),
    };
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Sleep Timer'),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        children: opts.entries
            .map((e) => SimpleDialogOption(
                  child: Text(e.key),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _setSleepTimer(e.value);
                  },
                ))
            .toList(),
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
    _snack(
        'Added ${newPaths.length} track${newPaths.length == 1 ? '' : 's'}');
    if (!mounted) return;
    _openPlaylist();
  }

  Future<void> _pickAndroid() async {
    bool granted = await Permission.manageExternalStorage.isGranted ||
        await Permission.audio.isGranted;
    if (!granted) {
      final s1 = await Permission.manageExternalStorage.request();
      final s2 = await Permission.audio.request();
      granted = s1.isGranted || s2.isGranted;
    }
    if (!granted) {
      _snack('Storage permission denied');
      return;
    }
    final files = await _scanAudio();
    if (files.isEmpty) {
      _snack('No audio files found');
      return;
    }
    final paths = files.map((f) => f.path).toList();
    setState(() => _playlist = paths);
    if (!mounted) return;
    _openPlaylist();
  }

  Future<List<FileSystemEntity>> _scanAudio() async {
    final exts = {'.mp3', '.wav', '.m4a', '.flac', '.ogg', '.aac'};
    final result = <FileSystemEntity>[];
    for (final d in [
      '/storage/emulated/0/Music',
      '/storage/emulated/0/Download',
      '/storage/emulated/0/',
    ]) {
      try {
        final dir = Directory(d);
        if (!await dir.exists()) continue;
        await for (final f in dir.list(recursive: true)) {
          if (f is File && exts.any(f.path.toLowerCase().endsWith)) {
            result.add(f);
          }
        }
      } catch (_) {}
    }
    return result;
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

  void _closePlaylist() {
    _playlistCtrl.reverse().then((_) {
      if (mounted) setState(() => _showPlaylist = false);
    });
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
          //    spinning disc above stays visible ──────────────────────────
          if (_showPlaylist)
            Align(
              alignment: Alignment.bottomCenter,
              child: FractionallySizedBox(
                heightFactor: 0.62,
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
                    child: _PlaylistOverlay(
                  playlist: _playlist,
                  currentIndex: _currentIndex,
                  favorites: _favorites,
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
                  },
                  onAdd: _pickMusic,
                    ),
                  ),
                ),
              ),
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
        ],
      ),
    );
  }

  Widget _buildMain(
      BuildContext context, ColorScheme scheme, bool isDark) {
    final accent = scheme.primary;
    final onSurface = scheme.onSurface;

    final isPlaying = _player.playing;
    final hasTrack = _currentIndex >= 0 && _playlist.isNotEmpty;
    final position = _player.position;
    final duration = _player.duration ?? Duration.zero;
    final buffering =
        _player.processingState == ProcessingState.buffering ||
            _player.processingState == ProcessingState.loading;
    final sliderMax = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    final sliderVal =
        position.inMilliseconds.toDouble().clamp(0.0, sliderMax);
    final isFav =
        hasTrack && _favorites.contains(_playlist[_currentIndex]);

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
                color: isDark
                    ? Colors.white.withAlpha(10)
                    : Colors.black.withAlpha(6),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withAlpha(18)
                      : Colors.black.withAlpha(12),
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
                        Text(
                          hasTrack ? _trackName : 'No track loaded',
                          style: TextStyle(
                            color: onSurface,
                            fontSize: isNarrow ? 12 : 13.5,
                            fontWeight: FontWeight.bold,
                            height: 1.3,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (_artistName.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(_artistName,
                              style: TextStyle(
                                  color: onSurface.withAlpha(160),
                                  fontSize: 11.5),
                              overflow: TextOverflow.ellipsis),
                        ],
                        if (_playlist.isNotEmpty) ...[
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
                  if (hasTrack)
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
                      onChanged: hasTrack
                          ? (v) => _player.seek(
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

            // ── Play / Prev / Next ────────────────────────────────────
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _CtrlBtn(
                    icon: Icons.skip_previous_rounded,
                    size: 36,
                    color: hasTrack
                        ? onSurface
                        : onSurface.withAlpha(40),
                    onTap: hasTrack ? _previous : null,
                    tooltip: 'Previous',
                  ),
                  const SizedBox(width: 24),
                  GestureDetector(
                    onTap: _togglePlayPause,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 68,
                      height: 68,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: accent,
                        boxShadow: [
                          BoxShadow(
                            color: accent
                                .withAlpha(isPlaying ? 140 : 60),
                            blurRadius: isPlaying ? 22 : 10,
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
                  const SizedBox(width: 24),
                  _CtrlBtn(
                    icon: Icons.skip_next_rounded,
                    size: 36,
                    color: hasTrack
                        ? onSurface
                        : onSurface.withAlpha(40),
                    onTap: hasTrack ? _next : null,
                    tooltip: 'Next',
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ── Secondary controls ────────────────────────────────────
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
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
                  const SizedBox(width: 12),
                  _CtrlChip(
                    icon: Icons.shuffle_rounded,
                    active: _shuffle,
                    activeColor: Colors.green,
                    onTap: _toggleShuffle,
                    tooltip: 'Shuffle',
                  ),
                  const SizedBox(width: 12),
                  _CtrlChip(
                    icon: Icons.folder_open_rounded,
                    active: false,
                    activeColor: accent,
                    onTap: _pickMusic,
                    tooltip: 'Add music',
                  ),
                  const SizedBox(width: 12),
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      _CtrlChip(
                        icon: Icons.queue_music_rounded,
                        active: _showPlaylist || _playlist.isNotEmpty,
                        activeColor: accent,
                        onTap: _openPlaylist,
                        tooltip: 'Playlist',
                      ),
                      if (_playlist.isNotEmpty)
                        Positioned(
                          top: -4,
                          right: -4,
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                                color: accent,
                                shape: BoxShape.circle),
                            child: Text('${_playlist.length}',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 8,
                                    fontWeight: FontWeight.bold)),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  _CtrlChip(
                    icon: Icons.timer_outlined,
                    active: _sleepRemaining != null,
                    activeColor: Colors.indigo,
                    onTap: _showSleepTimerDialog,
                    tooltip: _sleepRemaining != null
                        ? _fmtSleep(_sleepRemaining!)
                        : 'Sleep Timer',
                  ),
                ],
              ),
            ),

            const SizedBox(height: 18),
            Divider(height: 1, color: scheme.outlineVariant.withAlpha(50)),
            const SizedBox(height: 14),

            // ── Volume (left ~45%) + Speed button (right) on same row ────
            Row(
              children: [
                // Mute toggle
                GestureDetector(
                  onTap: _toggleMute,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: _muted
                          ? scheme.error.withAlpha(28)
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      _muted || _volume == 0
                          ? Icons.volume_off_rounded
                          : _volume < 0.5
                              ? Icons.volume_down_rounded
                              : Icons.volume_up_rounded,
                      size: 17,
                      color: _muted
                          ? scheme.error
                          : onSurface.withAlpha(180),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Volume slider + % chip — grouped and WIDTH-CAPPED so the
                // volume control never stretches full-width and visually
                // collides with the accent seek bar above it. Left-aligned;
                // the empty space it leaves pushes the speed button right.
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 210),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Expanded(
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 3,
                                thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 5),
                                overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 11),
                                // Grey palette — distinct from accent seek bar
                                activeTrackColor: _muted
                                    ? scheme.outlineVariant
                                    : onSurface.withAlpha(155),
                                inactiveTrackColor:
                                    onSurface.withAlpha(28),
                                thumbColor: _muted
                                    ? scheme.outlineVariant
                                    : onSurface.withAlpha(200),
                                overlayColor: onSurface.withAlpha(18),
                              ),
                              child: Slider(
                                value: _muted ? 0 : _volume,
                                onChanged: (v) {
                                  if (_muted) {
                                    setState(() => _muted = false);
                                  }
                                  _setVolume(v);
                                },
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          // Volume percentage chip
                          Container(
                            width: 40,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 4),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: Text(
                              _muted
                                  ? 'mut'
                                  : '${(_volume * 100).round()}%',
                              style: TextStyle(
                                  color: onSurface.withAlpha(150),
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w600),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

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

            if (!_isMobile) ...[
              const SizedBox(height: 10),
              Text(
                'Space: play/pause  .  arrows: skip / volume',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 9.5, color: onSurface.withAlpha(70)),
              ),
            ],
          ],
        ),
      );
    });
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

  // Per-track options sheet (opened from the ⋮ button).
  void _showTrackOptions(
      BuildContext context, String path, int realIdx, bool isFav) {
    final scheme = Theme.of(context).colorScheme;
    final ta = _titleArtist(_name(path));
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
                    Text(ta.$1,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                    if (ta.$2 != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(ta.$2!,
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
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(22)),
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withAlpha(70)),
          left: BorderSide(color: scheme.outlineVariant.withAlpha(45)),
          right: BorderSide(color: scheme.outlineVariant.withAlpha(45)),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(55),
            blurRadius: 26,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: Column(
        children: [
          // Grab handle
          Container(
            margin: const EdgeInsets.only(top: 8, bottom: 2),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: scheme.onSurfaceVariant.withAlpha(80),
              borderRadius: BorderRadius.circular(2),
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
                // Close / minimize arrow
                GestureDetector(
                  onTap: widget.onClose,
                  child: Tooltip(
                    message: 'Close',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 4),
                      child: Icon(
                          Icons.keyboard_arrow_up_rounded,
                          size: 22,
                          color: scheme.onSurfaceVariant),
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
            child: displayed.isEmpty
                ? Center(
                    child: Text(
                      _favOnly ? 'No favorites yet' : 'No tracks match',
                      style:
                          TextStyle(color: scheme.onSurfaceVariant),
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
                            _titleArtist(_name(entry.value)).$1,
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
                          subtitle: _titleArtist(_name(entry.value)).$2 == null
                              ? null
                              : Text(
                                  _titleArtist(_name(entry.value)).$2!,
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
