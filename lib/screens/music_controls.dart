import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_session/audio_session.dart';
import '../screens/home_page.dart'
    show
        playbackBus,
        playlistDrawerBus,
        playlistNotifier,
        playProgressNotifier,
        playClockNotifier,
        PlayClock,
        favoriteNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../state/playback_state.dart';
import '../services/live_session_service.dart';
import '../utils/toast_helper.dart';
import 'equalizer_screen.dart';
import '../utils/popup_shell.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../services/audio_handler.dart';
import '../services/metadata_overrides.dart';
import '../utils/marquee_text.dart';
import 'api_service.dart';
import 'chat/song_cache.dart';
import 'music/song_identifier.dart' show showSongIdentifier;

part 'music/music_control_widgets.dart'; // _CtrlBtn, _CtrlChip, _SpeedPanel
part 'music/music_playlist_overlay.dart'; // _PlaylistOverlay + state
part 'music/music_lyrics_view.dart'; // _LyricsView (synced/plain lyrics sheet)
part 'music/music_share_sheet.dart'; // _ShareSheet (send song file / recommend)

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

class MusicControls extends ConsumerStatefulWidget {
  static const routeName = '/music';
  final Color textColor;
  const MusicControls({super.key, required this.textColor});

  @override
  ConsumerState<MusicControls> createState() => _MusicControlsState();
}

class _MusicControlsState extends ConsumerState<MusicControls>
    with TickerProviderStateMixin {
  late final AudioPlayer _player;
  // Riverpod subscription that replaces liveSessionNotifier.addListener.
  ProviderSubscription<LiveSession>? _liveSub;

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
      ref.read(liveSessionProvider).active && activeLiveSession != null;
  LiveSessionController? get _live => activeLiveSession?.controller;
  bool get _isLiveHost => activeLiveSession?.role == LiveRole.host;

  void _onLiveChanged() {
    _liveStateSub?.cancel();
    _liveStateSub = null;
    _livePosSub?.cancel();
    _livePosSub = null;
    final live = _live;
    if (ref.read(liveSessionProvider).active && live != null) {
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
    } else {
      // The live session just ended (or was cleared). Control reverts to the
      // local music player, so re-sync the ambient now-playing bar + media
      // notification to its REAL state right now. Without this the last live
      // update (playing: true) stays latched: the paused local player emits no
      // fresh state event to correct it, so the footer play/pause button
      // freezes showing the stopped live track as if it were still playing.
      ref.read(nowPlayingProvider.notifier).update(
          track: _trackName, artist: _artistName, playing: _player.playing);
      _pushMediaState();
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
    ref.read(nowPlayingProvider.notifier).update(
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
  // User-defined groups: name -> ordered list of song paths. Persisted locally
  // (the songs are device-local files, so groups are too).
  Map<String, List<String>> _groups = {};
  // Listening stats for the "smart" auto-lists (Most played / Recently played).
  Map<String, int> _playCounts = {}; // path -> times played
  Map<String, int> _lastPlayed = {}; // path -> last-played epoch ms
  // MediaStore id of the current track (Android), for embedded album-art lookup
  // via QueryArtworkWidget. null = no art (file-picker song / non-mobile).
  int? _currentArtId;
  // In-app lyrics the user pasted, path -> raw text (LRC or plain). Persisted.
  // A `.lrc`/`.txt` file sitting next to the song is used as a fallback source.
  Map<String, String> _lyrics = {};
  // When non-null, transport (next/prev/auto-advance) cycles ONLY within this
  // ordered subset of paths — e.g. "play all gospels". null = the whole library
  // (default behaviour, unchanged).
  List<String>? _activeQueue;

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

  // True while the app-wide playlist drawer is open. The drawer itself is
  // rendered by the HOST (home_page) — below the active header — using the
  // playlist body MusicControls exposes via playlistDrawerBus.contentBuilder.
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
    _loadGroups();
    _loadStats();
    _loadLyrics();
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
    // (Was: liveSessionNotifier.addListener(_onLiveChanged). listenManual is the
    // Riverpod equivalent for listening outside build; closed in dispose.)
    _liveSub = ref.listenManual(
        liveSessionProvider, (_, _) => _onLiveChanged());
    playbackBus.currentPath = () =>
        (_currentIndex >= 0 && _currentIndex < _playlist.length)
            ? _playlist[_currentIndex]
            : null;
    playbackBus.currentPositionMs = () => _player.position.inMilliseconds;
    playbackBus.isPlaying = () => _player.playing;
    playbackBus.onToggleFavorite = _toggleCurrentFavorite;
    playbackBus.onShareToChat = _shareCurrentSong;

    // App-wide playlist drawer. MusicControls owns the playlist UI + data and
    // is always mounted, so it registers the drawer handlers here — any screen
    // (e.g. a chat thread header) can summon the drawer through the bus.
    playlistDrawerBus.open = _openPlaylistDrawer;
    playlistDrawerBus.close = _closePlaylistDrawer;
    playlistDrawerBus.toggle = _togglePlaylistDrawer;
    // Expose the playlist body so the host (home_page) can render it below the
    // active header.
    playlistDrawerBus.contentBuilder = (_) => _buildPlaylistOverlayWidget();
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

  // Keep the externally-hosted drawer in sync: any setState that changes the
  // playlist / current track / favourites should refresh the host's copy too
  // (it lives outside this element's subtree). Only bump while it's open.
  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    if (playlistDrawerBus.isOpen.value) {
      playlistDrawerBus.revision.value++;
    }
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
      playbackBus.onShareToChat = null;
    }
    // Relinquish the playlist drawer if we own it.
    if (playlistDrawerBus.toggle == _togglePlaylistDrawer) {
      playlistDrawerBus.isOpen.value = false;
      playlistDrawerBus.open = null;
      playlistDrawerBus.close = null;
      playlistDrawerBus.toggle = null;
      playlistDrawerBus.contentBuilder = null;
    }
    _liveSub?.close();
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

  // ── Groups (user-named collections, e.g. "Gospels") ─────────────────────────

  Future<void> _loadGroups() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('music_groups');
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final loaded = <String, List<String>>{};
      decoded.forEach((k, v) {
        loaded[k] = (v as List).map((e) => e.toString()).toList();
      });
      if (mounted) setState(() => _groups = loaded);
    } catch (_) {}
  }

  Future<void> _saveGroups() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('music_groups', jsonEncode(_groups));
    } catch (_) {}
  }

  // ── Listening stats (Most played / Recently played smart lists) ─────────────

  Future<void> _loadStats() async {
    try {
      final p = await SharedPreferences.getInstance();
      final counts = p.getString('music_playcounts');
      final last = p.getString('music_lastplayed');
      final pc = <String, int>{};
      final lp = <String, int>{};
      if (counts != null && counts.isNotEmpty) {
        (jsonDecode(counts) as Map<String, dynamic>)
            .forEach((k, v) => pc[k] = (v as num).toInt());
      }
      if (last != null && last.isNotEmpty) {
        (jsonDecode(last) as Map<String, dynamic>)
            .forEach((k, v) => lp[k] = (v as num).toInt());
      }
      if (mounted) {
        setState(() {
          _playCounts = pc;
          _lastPlayed = lp;
        });
      }
    } catch (_) {}
  }

  Future<void> _saveStats() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('music_playcounts', jsonEncode(_playCounts));
      await p.setString('music_lastplayed', jsonEncode(_lastPlayed));
    } catch (_) {}
  }

  // Count a play + stamp the time (drives the smart lists).
  void _recordPlay(String path) {
    _playCounts[path] = (_playCounts[path] ?? 0) + 1;
    _lastPlayed[path] = DateTime.now().millisecondsSinceEpoch;
    _saveStats();
  }

  // The centre of the spinning disc: real embedded album art when we know the
  // track's MediaStore id (Android), else the music-note glyph. QueryArtworkWidget
  // loads + caches the art itself and shows nullArtworkWidget when there's none.
  Widget _discArt(bool isNarrow) {
    final fallback = Icon(Icons.music_note_rounded,
        size: isNarrow ? 28 : 38, color: Colors.white.withAlpha(220));
    if (_currentArtId == null) return fallback;
    final d = isNarrow ? 58.0 : 76.0;
    return ClipOval(
      child: QueryArtworkWidget(
        id: _currentArtId!,
        type: ArtworkType.AUDIO,
        artworkWidth: d,
        artworkHeight: d,
        artworkFit: BoxFit.cover,
        keepOldArtwork: true,
        nullArtworkWidget: fallback,
      ),
    );
  }

  // ── Lyrics ──────────────────────────────────────────────────────────────────

  Future<void> _loadLyrics() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('music_lyrics');
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final loaded = <String, String>{};
      decoded.forEach((k, v) => loaded[k] = v.toString());
      if (mounted) setState(() => _lyrics = loaded);
    } catch (_) {}
  }

  Future<void> _saveLyrics() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('music_lyrics', jsonEncode(_lyrics));
    } catch (_) {}
  }

  void _setLyrics(String path, String text) {
    setState(() {
      if (text.trim().isEmpty) {
        _lyrics.remove(path);
      } else {
        _lyrics[path] = text;
      }
    });
    _saveLyrics();
  }

  // Best-available lyrics for a song: the in-app text if set, else a `.lrc`/`.txt`
  // file sitting next to the audio file. Returns '' if none.
  String _lyricsRaw(String path) {
    final stored = _lyrics[path];
    if (stored != null && stored.trim().isNotEmpty) return stored;
    try {
      final dot = path.lastIndexOf('.');
      final base = dot > 0 ? path.substring(0, dot) : path;
      for (final ext in const ['.lrc', '.txt']) {
        final f = File('$base$ext');
        if (f.existsSync()) return f.readAsStringSync();
      }
    } catch (_) {}
    return '';
  }

  void _openLyrics() {
    if (_currentIndex < 0 || _currentIndex >= _playlist.length) {
      _snack('Play a song to see its lyrics');
      return;
    }
    final path = _playlist[_currentIndex];
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LyricsView(
        title: _trackName,
        artist: _artistName,
        raw: _lyricsRaw(path),
        onSave: (text) => _setLyrics(path, text),
      ),
    );
  }

  // ── Share a song into a chat (async attachment / recommendation) ────────────

  void _shareSong(String path) {
    final title = metadataStore.title(path, _nameFromPath(path));
    final artist = metadataStore.artist(path, '');
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ShareSheet(path: path, title: title, artist: artist),
    );
  }

  /// Share whatever is playing right now to a chat — driven by the now-playing
  /// bar's "Share to chat" button (playbackBus.onShareToChat).
  void _shareCurrentSong() {
    if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
      _shareSong(_playlist[_currentIndex]);
    } else {
      showToast(context, 'No song is playing to share.',
          type: ToastType.info);
    }
  }

  void _createGroup(String name) {
    final n = name.trim();
    if (n.isEmpty || _groups.containsKey(n)) return;
    setState(() => _groups[n] = <String>[]);
    _saveGroups();
  }

  void _deleteGroup(String name) {
    if (!_groups.containsKey(name)) return;
    setState(() => _groups.remove(name));
    _saveGroups();
  }

  void _renameGroup(String oldName, String newName) {
    final n = newName.trim();
    if (n.isEmpty || !_groups.containsKey(oldName) || _groups.containsKey(n)) {
      return;
    }
    setState(() {
      _groups[n] = _groups.remove(oldName)!;
    });
    _saveGroups();
  }

  // Set the FULL membership of a song across all groups (checkbox sheet).
  void _setSongGroups(String path, Set<String> groups) {
    setState(() {
      for (final entry in _groups.entries) {
        final inGroup = groups.contains(entry.key);
        if (inGroup && !entry.value.contains(path)) {
          entry.value.add(path);
        } else if (!inGroup) {
          entry.value.remove(path);
        }
      }
    });
    _saveGroups();
  }

  // Add several songs to one group at once (bulk "add to group").
  void _addManyToGroup(List<String> paths, String group) {
    if (!_groups.containsKey(group)) return;
    setState(() {
      for (final p in paths) {
        if (!_groups[group]!.contains(p)) _groups[group]!.add(p);
      }
    });
    _saveGroups();
  }

  // ── Bulk selection actions ──────────────────────────────────────────────────

  void _removeMany(List<String> paths) {
    setState(() {
      final playingPath = (_currentIndex >= 0 && _currentIndex < _playlist.length)
          ? _playlist[_currentIndex]
          : null;
      _playlist.removeWhere(paths.contains);
      // Keep group membership consistent when songs leave the library.
      for (final g in _groups.values) {
        g.removeWhere(paths.contains);
      }
      _currentIndex =
          playingPath != null ? _playlist.indexOf(playingPath) : -1;
    });
    _publishPlaylist();
    _saveGroups();
  }

  void _favoriteMany(List<String> paths, bool makeFav) {
    setState(() {
      if (makeFav) {
        _favorites.addAll(paths);
      } else {
        _favorites.removeAll(paths);
      }
    });
    _saveFavorites();
    _syncFavoriteAmbient();
  }

  // ── Scope-aware playback (play/shuffle a filter, e.g. a group) ───────────────

  // Ordered LIBRARY indices for the current playback scope: the active queue
  // (a filtered/shuffled subset) mapped to indices, or the whole library.
  List<int> _scopeIndices() {
    final q = _activeQueue;
    if (q == null) {
      return List<int>.generate(_playlist.length, (i) => i);
    }
    final out = <int>[];
    for (final p in q) {
      final i = _playlist.indexOf(p);
      if (i >= 0) out.add(i);
    }
    return out;
  }

  // Start playback from a specific view (filtered + sorted paths). Tapping a song
  // OR "Play all"/"Shuffle" a group all route here, so auto-advance stays within
  // whatever the user is looking at. A full-library, in-order view clears the
  // queue so default behaviour is unchanged.
  void _playScope(List<String> paths, int startIndex, bool shuffle) {
    if (paths.isEmpty) return;
    var q = List<String>.from(paths);
    var startPath = (startIndex >= 0 && startIndex < paths.length)
        ? paths[startIndex]
        : paths.first;
    if (shuffle) {
      q.shuffle(_rng);
      startPath = q.first;
    }
    final isFullLibraryInOrder = !shuffle &&
        q.length == _playlist.length &&
        () {
          for (var i = 0; i < q.length; i++) {
            if (q[i] != _playlist[i]) return false;
          }
          return true;
        }();
    setState(() => _activeQueue = isFullLibraryInOrder ? null : q);
    final idx = _playlist.indexOf(startPath);
    if (idx >= 0) _play(idx);
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
      // Keep the global ambient notifier (footer play/pause icon + media
      // notification) in sync with the REAL player state regardless of whether
      // this widget is currently mounted — otherwise a pause can leave the
      // footer button stuck showing "playing".
      // While a live session owns the ambient bar/notification, don't let the
      // (paused) local player overwrite the live play/pause state.
      if (!_liveActive) {
        ref.read(nowPlayingProvider.notifier).update(
            track: _trackName, artist: _artistName, playing: s.playing);
        _pushMediaState(
            buffering: s.processingState == ProcessingState.loading ||
                s.processingState == ProcessingState.buffering);
      }
      if (!mounted) return;
      setState(() {});
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
    _recordPlay(path); // stats for the smart lists

    // Suppress auto-advance while swapping the source (see _switching).
    _switching = true;

    final initTitle = metadataStore.title(path, _nameFromPath(path));
    final initArtist = metadataStore.artist(path, '');
    setState(() {
      _currentIndex = index;
      _trackName = initTitle;
      _artistName = initArtist;
      _currentArtId = null; // resolved by _fetchMetadata once the song is found
    });
    ref.read(nowPlayingProvider.notifier).update(
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
      if (_pruneIfMissing(path)) {
        if (mounted) _snack('Track no longer on device — removed');
      } else if (mounted) {
        _snack('Cannot play: ${e.message}');
      }
      return;
    } catch (_) {
      _switching = false;
      if (_pruneIfMissing(path)) {
        if (mounted) _snack('Track no longer on device — removed');
      } else if (mounted) {
        _snack('Playback error — check file format');
      }
      return;
    }
    // Re-enable auto-advance once playback has actually settled.
    Future.delayed(const Duration(milliseconds: 600), () {
      _switching = false;
    });
    if (_isMobile) _fetchMetadata(path);
  }

  /// Lazy validation: if a track failed to play because its file is gone (moved
  /// or deleted since it was saved to the playlist), drop it from the list. This
  /// is a SINGLE stat, only for the track we actually tried to play — never a
  /// launch-time sweep of the whole saved playlist. Returns true if it pruned.
  bool _pruneIfMissing(String path) {
    if (kIsWeb || !_isMobile) return false;
    try {
      if (File(path).existsSync()) return false; // exists → a real format error
    } catch (_) {
      return false;
    }
    final i = _playlist.indexOf(path);
    if (i < 0) return false;
    setState(() {
      _playlist.removeAt(i);
      if (_currentIndex >= _playlist.length) {
        _currentIndex = _playlist.length - 1;
      }
    });
    _publishPlaylist();
    return true;
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
          _currentArtId = m.id; // enables embedded album art on the disc
        });
        // Use the real player state — a late metadata fetch must not re-mark a
        // paused track as playing.
        ref.read(nowPlayingProvider.notifier).update(track: t, artist: a, playing: _player.playing);
      }
    } catch (_) {}
  }

  void _onComplete() {
    if (_playlist.isEmpty) return;
    if (_repeatOne) {
      _play(_currentIndex);
      return;
    }
    // Navigate within the current scope (active queue, or whole library).
    final scope = _scopeIndices();
    if (scope.isEmpty) return;
    if (_shuffle) {
      _play(scope[_rng.nextInt(scope.length)]);
      return;
    }
    final pos = scope.indexOf(_currentIndex);
    if (pos >= 0 && pos + 1 < scope.length) {
      _play(scope[pos + 1]);
    } else if (_repeatAll) {
      _play(scope.first);
    } else {
      // End of scope, no repeat
      ref.read(nowPlayingProvider.notifier).update(
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
    final scope = _scopeIndices();
    if (scope.isEmpty) return;
    if (_shuffle) {
      _play(scope[_rng.nextInt(scope.length)]);
      return;
    }
    final pos = scope.indexOf(_currentIndex);
    if (pos >= 0 && pos + 1 < scope.length) {
      _play(scope[pos + 1]);
    } else if (_repeatAll) {
      _play(scope.first);
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
    final scope = _scopeIndices();
    if (scope.isEmpty) return;
    final pos = scope.indexOf(_currentIndex);
    if (pos > 0) {
      _play(scope[pos - 1]);
    } else if (_repeatAll) {
      _play(scope.last);
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
        // Load saved paths AS-IS — no per-file existsSync sweep at launch (that
        // device I/O is what we're eliminating). Any file that has since moved or
        // been deleted is pruned LAZILY, on the single play attempt that first
        // touches it (see _pruneIfMissing in _play).
        if (!mounted) return;
        setState(() => _playlist = List<String>.from(saved));
        _publishPlaylist();
      }
    } catch (_) {}
    // LAZY BY DESIGN: we do NOT scan the device library at launch. A cold scan
    // of the whole MediaStore (+ its permission prompt) on a fresh install was
    // contending with cold-start work and could stall the first launch. Instead,
    // the saved playlist (if any) is restored above, and the FIRST tap on
    // "Playlist" triggers the scan on demand (with a spinner) — see
    // _openOrScanPlaylist. Nothing here touches the device until the user asks.
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
        // This dialog draws its own (inner) card border — drop the app-wide
        // dialogTheme border so it isn't doubled.
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(22)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: scheme.primary.withAlpha(130)),
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
    _openPlaylistDrawer();
  }

  /// Unified Playlist action (the "Add" button folded into this). If songs are
  /// already loaded it just opens the drawer; the first time on an empty list it
  /// opens the drawer with a loader and scans the device (Android) or opens the
  /// file picker (desktop/web).
  Future<void> _openOrScanPlaylist() async {
    // Web has no access to the device's music library, so there's nothing to
    // scan or play — tell the user which apps DO support it instead of silently
    // failing. (Reading `_isMobile` here would touch dart:io's Platform, which
    // throws on web — this guard also sidesteps that.)
    if (kIsWeb) {
      _snack('Playlists use the music saved on your device — open Aluta on your '
          'phone or desktop app to build and play your library.');
      return;
    }
    if (_playlist.isNotEmpty) {
      _openPlaylistDrawer();
      return;
    }
    if (!_isMobile) {
      // Desktop/web: the file picker opens the drawer itself on success.
      await _pickDesktop();
      return;
    }
    // Android first-open: show the drawer with a loading animation, then scan.
    setState(() => _scanning = true);
    _openPlaylistDrawer();
    try {
      await _scanIntoPlaylist();
    } finally {
      if (mounted) setState(() => _scanning = false);
      // If the scan found nothing, close the empty drawer again.
      if (mounted && _playlist.isEmpty) _closePlaylist();
    }
  }

  void _closePlaylist() => _closePlaylistDrawer();

  // ── App-wide playlist DRAWER (right-side, full-height, root-overlay) ────────
  // Hosted in the ROOT overlay so it floats over whatever's on screen (chat or
  // music), sliding in from the right and covering the area between the app
  // header and footer. Toggled from the music panel's Playlist tile AND from a
  // chat-thread header button (via playlistDrawerBus).

  void _togglePlaylistDrawer() {
    if (playlistDrawerBus.isOpen.value) {
      _closePlaylistDrawer();
    } else {
      _openOrScanPlaylist();
    }
  }

  void _openPlaylistDrawer() {
    if (playlistDrawerBus.isOpen.value) return;
    setState(() => _showPlaylist = true);
    playlistDrawerBus.isOpen.value = true; // the host animates it in
  }

  void _closePlaylistDrawer() {
    if (!playlistDrawerBus.isOpen.value) return;
    setState(() => _showPlaylist = false);
    playlistDrawerBus.isOpen.value = false; // the host animates it out
  }

  /// The playlist body itself, wired to this widget's state + callbacks. The
  /// host (home_page) frames it as the sliding drawer.
  Widget _buildPlaylistOverlayWidget() {
    return _PlaylistOverlay(
      playlist: _playlist,
      currentIndex: _currentIndex,
      favorites: _favorites,
      groups: _groups,
      playCounts: _playCounts,
      lastPlayed: _lastPlayed,
      loading: _scanning,
      player: _player,
      currentTitle: _trackName,
      hasTrack: _currentIndex >= 0 && _currentIndex < _playlist.length,
      // Tapping a song, "Play all", and "Shuffle" all route here so auto-advance
      // stays within whatever the user is viewing.
      onPlayScope: _playScope,
      onTogglePlay: _togglePlayPause,
      onNext: _next,
      onPrev: _previous,
      onSeekFraction: (f) {
        final d = _player.duration;
        if (d != null && d > Duration.zero) {
          _player.seek(d * f.clamp(0.0, 1.0));
        }
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
      onShare: _shareSong,
      onAdd: _pickMusic,
      onCreateGroup: _createGroup,
      onDeleteGroup: _deleteGroup,
      onRenameGroup: _renameGroup,
      onSetSongGroups: _setSongGroups,
      onAddManyToGroup: _addManyToGroup,
      onRemoveMany: _removeMany,
      onFavoriteMany: _favoriteMany,
      drawer: true,
      // The host marks which surface it's on right before building this; on the
      // chat surface the app now-playing bar handles transport (skip the strip).
      hostIsChat: playlistDrawerBus.hostIsChatSurface,
    );
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
    showAppPopup(
      context,
      EqualizerScreen(
        equalizer: _equalizer,
        loudness: _loudness,
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
          border: Border.all(color: scheme.primary.withAlpha(130)),
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
    // The Now Playing surface is themed as a dark "stage" by its host sheet
    // (PlayerTheme in home_page), so this reads the ambient (dark) scheme.
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

          // Playlist is now a right-side, full-height DRAWER rendered by the
          // HOST (home_page) BELOW the active header — via
          // playlistDrawerBus.contentBuilder — so it can float over the chat
          // thread while the header (and its toggle) stay visible. It is no
          // longer rendered inline in the music panel here.

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
                          : _discArt(isNarrow),
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
                _utility(
                  scheme,
                  onSurface,
                  icon: Icons.lyrics_rounded,
                  label: 'Lyrics',
                  color: accent,
                  onTap: _openLyrics,
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

                // ── Identify song (Shazam-style) — centred between the volume
                // and speed controls. Listens via the mic and names the song.
                // Uses an "ear/listen" icon so it never reads like the Equalizer
                // (which is graphic-eq bars). ──
                Tooltip(
                  message: 'Identify song',
                  child: GestureDetector(
                    onTap: () => showSongIdentifier(context),
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: accent.withAlpha(28),
                        shape: BoxShape.circle,
                        border: Border.all(color: accent.withAlpha(120)),
                      ),
                      child: Icon(Icons.hearing_rounded, size: 20, color: accent),
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

