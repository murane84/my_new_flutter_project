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
import 'package:palette_generator/palette_generator.dart';
import '../services/song_library.dart';
import '../services/song_insights.dart';
import '../utils/bounce_tap.dart';
import 'music/player_disc_style.dart';
import 'listening_audience_sheet.dart';
import '../services/audio_handler.dart';
import '../services/metadata_overrides.dart';
import '../utils/marquee_text.dart';
import '../utils/typing_guard.dart';
import 'api_service.dart';
import 'chat/song_cache.dart';
import 'music/song_identifier.dart' show showSongIdentifier;
import '../widgets/genie_menu.dart';
import '../widgets/tap_chip.dart';
import '../widgets/person_avatar.dart';
import '../widgets/playing_bars.dart';
import '../widgets/song_feel_strip.dart';
import '../utils/readable.dart';
import '../services/contact_names.dart';
import '../services/app_busy.dart';
import '../utils/app_config.dart';
import '../utils/avatar_widget.dart';
import 'package:visibility_detector/visibility_detector.dart';
import '../services/account_prefs.dart';

part 'music/music_control_widgets.dart'; // _CtrlBtn, _CtrlChip, _SpeedPanel
part 'music/music_playlist_overlay.dart'; // _PlaylistOverlay + state
part 'music/music_lyrics_view.dart'; // _LyricsView (synced/plain lyrics sheet)
part 'music/music_share_sheet.dart'; // _ShareSheet (send song file / recommend)
part 'music/music_controls_helpers_1.dart'; // _MusicControlsState helpers (22 methods)
part 'music/music_controls_helpers_2.dart'; // _MusicControlsState helpers (19 methods)
part 'music/music_dedicate.dart'; // _DedicateSheet, _DiscLoadRing, _PeekName

bool get _isMobile => Platform.isAndroid || Platform.isIOS;

const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

String _speedLabel(double s) {
  // 1.0 → "1×", 1.25 → "1.25×", 1.10 → "1.1×" (never float noise).
  var t = s.toStringAsFixed(2);
  t = t.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return '$t×';
}

/// Cleans junk that downloaders bake into filenames, e.g.
/// "Two of us- Downloaded from clipzag.com" → "Two of us".
String _cleanTrackName(String raw) {
  var n = raw;
  // Ringtone / caller-tune promo spam common on East-African music files, e.g.
  // "… sms skiza 7301521 to 811" — drop everything from that phrase onward.
  n = n.replaceAll(RegExp(r'\bsms\s*skiza\b.*', caseSensitive: false), ' ');
  n = n.replaceAll(RegExp(r'\bskiza\b.*', caseSensitive: false), ' ');
  // Downloader tags, e.g. "… Downloaded from clipzag.com".
  n = n.replaceAll(
      RegExp(r'[-_(\[ ]*downloaded\s*from[^)\]]*', caseSensitive: false), ' ');
  n = n.replaceAll(
      RegExp(r'\b(clipzag|y2mate|ytmp3|mp3juice|tubidy|savefrom|snaptube)\S*',
          caseSensitive: false),
      ' ');
  // Bare website / domain noise (e.g. "mdundo.com", "www.something.net").
  n = n.replaceAll(
      RegExp(r'\b(www\.)?\S+\.(com|net|co|info|xyz|me|tz)\b',
          caseSensitive: false),
      ' ');
  // Video/audio tags: "(Official Lyrics Video)", "[Official Music Video]",
  // "(Audio)", "[HD]", "(4K)", "(Visualizer)", "(Dir by …)" …
  n = n.replaceAll(
      RegExp(r'[\(\[][^\)\]]*\b(official|lyric|lyrics|video|audio|visuali[sz]er|hd|4k|mv|dir(ected)?\s*by)\b[^\)\]]*[\)\]]?',
          caseSensitive: false),
      ' ');
  // Empty leftover groups "()" / "[]".
  n = n.replaceAll(RegExp(r'\(\s*\)|\[\s*\]'), ' ');
  n = n.replaceAll(RegExp(r'\s+'), ' ').trim();
  // Strip stray leading/trailing separators and unbalanced brackets / pipes
  // (kills the leftover "Goon Flavour )" style closer).
  n = n.replaceAll(RegExp(r'^[\s\-_|)\]\(\[]+|[\s\-_|)\]\(\[]+$'), '').trim();
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
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final AudioPlayer _player;
  // Riverpod subscription that replaces liveSessionNotifier.addListener.
  ProviderSubscription<LiveSession>? _liveSub;

  // Native audio effects (Android only). Null on other platforms.
  AndroidEqualizer? _equalizer;
  AndroidLoudnessEnhancer? _loudness;

  List<String> _playlist = [];
  Timer? _lastTrackTimer; // periodic save of the last-played track + position
  bool _lastTrackRestored = false;
  // True while the saved song is being re-opened and seeked on launch: the
  // player emits position 0 in between, and saving that would wipe the spot
  // the user was cut off at.
  bool _restoringPos = false;
  // Android scoped storage can't reliably open many media by raw file PATH
  // (WhatsApp audio, downloads, etc.) — playback then fails with a bogus
  // "check file format". So we play through each song's MediaStore CONTENT URI
  // instead, resolved here (raw path -> content:// uri) from a one-off scan.
  final Map<String, String> _uriByPath = {};
  bool _uriMapBuilt = false;
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
        // The spinning disc must follow the LIVE player during a session — the
        // local _player is paused, so its state listener (which normally drives
        // the disc) would leave it frozen mid-session.
        _syncDiscSpin(live.player.playing);
        if (mounted) setState(() {});
      });
      _livePosSub = live.player.positionStream.listen((_) {
        _pushLiveToAmbient();
        if (mounted) setState(() {});
      });
      // Refresh the repeat/shuffle buttons whenever the SHARED session state
      // changes — whether we set it or it was synced from the peer.
      live.onRepeatChanged = () {
        if (mounted) setState(() {});
      };
      live.onShuffleChanged = () {
        if (mounted) setState(() {});
      };
      // Establish the media/foreground state immediately so the session is
      // protected from background-kill from the very start.
      _pushLiveToAmbient();
      _syncDiscSpin(live.player.playing);
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
      _syncDiscSpin(_player.playing);
    }
    if (mounted) setState(() {});
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
  // Album-art adaptive accent for the full-screen player (mobile only, where
  // embedded art exists): derived from the current track's artwork; null → fall
  // back to the theme accent. Cached per-id so we don't re-derive each build.
  final ValueNotifier<Color?> _artAccentVN = ValueNotifier<Color?>(null);
  int? _artAccentForId;
  // Cached parsed LRC lines for the now-playing synced-lyric ticker.
  String? _lrcCachePath;
  List<(Duration, String)> _lrcCache = const [];
  static final RegExp _lrcTagRe =
      RegExp(r'\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]');
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
  // Soft transitions: a short fade-in at the start of a track and fade-out
  // over its last moments, so songs flow into each other instead of cutting.
  // [_edgeFade] is that envelope; [_sleepFade] eases the music away during
  // the sleep timer's final 30s. Effective volume = volume × both.
  double _edgeFade = 1.0;
  double _sleepFade = 1.0;
  double _appliedVol = -1;

  void _applyVolume() {
    final v = _muted ? 0.0 : (_volume * _edgeFade * _sleepFade);
    if (v != 0 && v != 1 && (v - _appliedVol).abs() < 0.015) return;
    _appliedVol = v;
    _player.setVolume(v);
  }

  /// Fade envelope for the current position (1.0 = full).
  void _updateEdgeFade(Duration pos) {
    final dur = _player.duration;
    var f = 1.0;
    if (!_liveActive &&
        dur != null &&
        dur.inMilliseconds > 8000 &&
        _effRepeatMode != 'one') {
      const inMs = 700.0, outMs = 2200.0;
      final p = pos.inMilliseconds.toDouble();
      final rem = (dur.inMilliseconds - pos.inMilliseconds).toDouble();
      final fin = (p / inMs).clamp(0.2, 1.0);
      final fout = (rem / outMs).clamp(0.0, 1.0);
      f = fin < fout ? fin : fout;
    }
    if ((f - _edgeFade).abs() > 0.01) {
      _edgeFade = f;
      _applyVolume();
    }
  }
  double _speed = 1.0;
  // A-B repeat: loop one stretch of the current song (a favourite line or
  // chorus). Cleared on every track change; off during live sessions.
  Duration? _abA;
  Duration? _abB;
  DateTime _abLoopAt = DateTime.fromMillisecondsSinceEpoch(0);
  // "Dedicate this song" row: the people I chat with most (by latest message).
  List<Map<String, dynamic>> _dedicateTo = const [];
  DateTime? _dedicateLoadedAt;
  String _apiBase = '';
  // True while the hero record is on screen and shows app-busy as its ring
  // (the centred loader then stays away from the title).
  bool _hostingBusy = false;
  // Shuffle's NEXT song, picked ahead of time so the peeking record, Up next
  // and the actual skip always agree. Cleared whenever a song starts.
  int? _shuffleNext;
  final Random _rng = Random();

  Timer? _sleepTimer;
  Duration? _sleepRemaining;
  // Ticks with the sleep countdown so the Now Playing page (its own route,
  // not rebuilt by setState here) can show the minutes live.
  final ValueNotifier<Duration?> _sleepVN = ValueNotifier<Duration?>(null);
  // Known song lengths (ms) by path — for the queue's "min left".
  final Map<String, int> _durMs = {};
  bool _durLoaded = false;
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
  late AnimationController _queueCtrl; // drives the in-page queue open/close
  final ScrollController _queueScrollCtrl = ScrollController();
  // Identifies the playing row so the queue can centre it on open.
  final GlobalKey _nowQueueRowKey = GlobalKey();
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
    PlayerStyleController.instance.load();
    _queueCtrl = AnimationController(
      duration: const Duration(milliseconds: 320),
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
    WidgetsBinding.instance.addObserver(this);
    _restorePlayModes();
    _restorePlaylist();
    _listenPlayer();
    // Keep the "last played" marker fresh so an update/relaunch lands the user
    // back on their song at roughly where they left it.
    _lastTrackTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_player.playing) _saveLastTrack();
    });
    if (Platform.isAndroid) {
      _restoreEqualizer();
      AccountPrefs.onRestore(_eqRestore); // EQ back from the account
    }

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

  // A real method (its tear-offs compare equal — extension tear-offs don't),
  // so offRestore really removes it.
  Future<void> _eqRestore() => _restoreEqualizer();

  @override
  void dispose() {
    _sleepVN.dispose();
    AccountPrefs.offRestore(_eqRestore);
    _setHostingBusy(false);
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
    _lastTrackTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _saveLastTrack();
    _discCtrl.dispose();
    _queueCtrl.dispose();
    _queueScrollCtrl.dispose();
    _artAccentVN.dispose();
    _playlistCtrl.dispose();
    _speedCtrl.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _loadFavorites() async {
    final p = await SharedPreferences.getInstance();
    setState(() =>
        _favorites = (p.getStringList('music_favorites') ?? []).toSet());
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

  // The centre of the spinning disc: real embedded album art when we know the
  // track's MediaStore id (Android), else the music-note glyph. QueryArtworkWidget
  // loads + caches the art itself and shows nullArtworkWidget when there's none.
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

  void _setLyrics(String path, String text) {
    _lrcCachePath = null; // force the synced-ticker parser to refresh
    setState(() {
      if (text.trim().isEmpty) {
        _lyrics.remove(path);
      } else {
        _lyrics[path] = text;
      }
    });
    _saveLyrics();
  }

  void _openLyrics() {
    if (_currentIndex < 0 || _currentIndex >= _playlist.length) {
      _snack('Play a song to see its lyrics');
      return;
    }
    final path = _playlist[_currentIndex];
    // Genie in from the Lyrics button (consistent with the rest of the app),
    // instead of the old slide-up. _LyricsView is a full-height
    // DraggableScrollableSheet, so it still anchors + drags from the bottom.
    showGeniePopup(
      context,
      barrierColor: Colors.black.withAlpha(120),
      builder: (_) => _LyricsView(
        title: _trackName,
        artist: _artistName,
        raw: _lyricsRaw(path),
        onSave: (text) => _setLyrics(path, text),
        onSeek: _transportSeek,
      ),
    );
  }

  // ── Share a song into a chat (async attachment / recommendation) ────────────

  void _shareSong(String path) => _shareSongs([path]);

  /// The Glow partner, when bonded — null otherwise.
  int? get _partnerId => SongBridge.instance.partnerId?.call();

  /// Fill [_durMs] once from the device library (mobile has lengths there);
  /// songs played elsewhere get theirs as they load.
  Future<void> _loadQueueDurations(StateSetter setFull) async {
    if (_durLoaded) return;
    _durLoaded = true;
    try {
      final songs = await SongLibrary.songs();
      for (final s in songs) {
        final d = s.duration;
        if (d != null && d > 0) _durMs[s.data] = d;
      }
      if (mounted) setFull(() {});
    } catch (_) {}
  }

  /// "· 48 min left" for the queue header — the rest of this song plus every
  /// song after it. Estimated (~) when some lengths are unknown; null when
  /// none are known.
  String? _queueTimeLeft() {
    if (_currentIndex < 0 || _currentIndex >= _playlist.length) return null;
    final cur = _playlist[_currentIndex];
    final pd = _player.duration;
    if (pd != null && pd.inMilliseconds > 0) _durMs[cur] = pd.inMilliseconds;
    var ms = 0, known = 0, n = 0;
    for (var i = _currentIndex + 1; i < _playlist.length; i++) {
      n++;
      final d = _durMs[_playlist[i]];
      if (d != null) {
        ms += d;
        known++;
      }
    }
    if (n > 0 && known == 0) return null;
    if (known < n) ms = (ms * n / known).round();
    final curMs = _durMs[cur];
    if (curMs != null) {
      ms += (curMs - _player.position.inMilliseconds).clamp(0, curMs);
    }
    final min = (ms / 60000).round();
    if (min < 1) return null;
    final t = min >= 60
        ? '${min ~/ 60} h ${min % 60} min'
        : '$min min';
    return '${known < n ? '~' : ''}$t left';
  }

  /// One-tap "Send to my partner": the share sheet sends straight away.
  void _sendSongToPartner(String path) {
    final id = _partnerId;
    if (id == null) return _shareSong(path);
    _shareSongs([path], sendTo: id);
  }

  void _shareSongs(List<String> paths, {int? sendTo}) {
    if (paths.isEmpty) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // No theme outline — this sheet draws its own card.
      shape: const RoundedRectangleBorder(),
      builder: (_) => _ShareSheet(
        paths: paths,
        library: _playlist,
        titleOf: (p) => metadataStore.title(p, _nameFromPath(p)),
        artistOf: (p) => metadataStore.artist(p, ''),
        sendTo: sendTo,
      ),
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

  void _listenPlayer() {
    _player.playerStateStream.listen((s) {
      // Keep the global ambient notifier (footer play/pause icon + media
      // notification) in sync with the REAL player state regardless of whether
      // this widget is currently mounted — otherwise a pause can leave the
      // footer button stuck showing "playing".
      // While a live session owns the ambient bar/notification, don't let the
      // (paused) local player overwrite the live play/pause state.
      // At end-of-track just_audio PARKS with playing==true but
      // processingState==completed — that is not real playback. Treat it as
      // stopped everywhere (disc, footer, now-playing/presence) so the disc
      // doesn't keep spinning (and we don't report a false "playing") after a
      // song ends with no repeat, instead of relying on the delayed completion
      // handler to pause.
      final bool realPlaying =
          s.playing && s.processingState != ProcessingState.completed;
      if (!_liveActive) {
        ref.read(nowPlayingProvider.notifier).update(
            track: _trackName, artist: _artistName, playing: realPlaying);
        _pushMediaState(
            buffering: s.processingState == ProcessingState.loading ||
                s.processingState == ProcessingState.buffering);
      }
      if (!mounted) return;
      setState(() {});
      if (realPlaying) {
        _discCtrl.repeat();
      } else {
        _discCtrl.stop();
      }
      _saveLastTrack();
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
      // A-B repeat: past B → straight back to A. The short guard stops a
      // stale position (reported before the seek lands) re-triggering it.
      final abA = _abA, abB = _abB;
      if (abA != null &&
          abB != null &&
          !_liveActive &&
          !_switching &&
          pos >= abB &&
          DateTime.now().difference(_abLoopAt).inMilliseconds > 400) {
        _abLoopAt = DateTime.now();
        _player.seek(abA);
      }
      _updateEdgeFade(pos);
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

  // ── Full-screen "Now Playing" ───────────────────────────────────────────────

  void _openFullPlayer() {
    final hasTrack = _currentIndex >= 0 && _playlist.isNotEmpty;
    if (!hasTrack && !_liveActive) return;
    _queueCtrl.value = 0; // always open the full player with the queue closed
    Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder(
        // Non-opaque so the home route underneath stays "on stage" and its
        // TickerMode keeps running — otherwise the spinning disc's controller
        // (_discCtrl, vsynced to the covered MusicControls) freezes and the
        // full-screen disc is stuck mid-rotation. The full player's own Scaffold
        // background is opaque, so nothing shows through once it's in.
        opaque: false,
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 240),
        pageBuilder: (ctx, a, b) => _fullPlayerBody(),
        transitionsBuilder: (ctx, anim, sec, child) => FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween<Offset>(
                    begin: const Offset(0, 0.05), end: Offset.zero)
                .animate(
                    CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
            child: child,
          ),
        ),
      ),
    );
  }

  // Parse (and cache) the current song's LRC lines, sorted by time. Empty when
  // the lyrics are plain text with no [mm:ss.xx] timestamps.
  List<(Duration, String)> _syncedLyricLines(String path) {
    if (_lrcCachePath == path) return _lrcCache;
    final raw = _lyricsRaw(path);
    final out = <(Duration, String)>[];
    for (final line in raw.split('\n')) {
      final matches = _lrcTagRe.allMatches(line).toList();
      if (matches.isEmpty) continue;
      final text = line.replaceAll(_lrcTagRe, '').trim();
      if (text.isEmpty) continue;
      for (final m in matches) {
        final mm = int.parse(m.group(1)!);
        final ss = int.parse(m.group(2)!);
        final fr = m.group(3);
        final ms =
            fr != null ? int.parse(fr.padRight(3, '0').substring(0, 3)) : 0;
        out.add((Duration(minutes: mm, seconds: ss, milliseconds: ms), text));
      }
    }
    out.sort((a, b) => a.$1.compareTo(b.$1));
    _lrcCachePath = path;
    _lrcCache = out;
    return out;
  }

  // newI here is the onReorderItem index: already adjusted for the removal of
  // the item at oldI, so we insert at it directly.
  void _reorderQueue(int oldI, int newI, StateSetter setFull) {
    if (oldI < 0 || oldI >= _playlist.length) return;
    setState(() {
      final cur = (_currentIndex >= 0 && _currentIndex < _playlist.length)
          ? _playlist[_currentIndex]
          : null;
      final path = _playlist.removeAt(oldI);
      _playlist.insert(newI.clamp(0, _playlist.length), path);
      if (cur != null) _currentIndex = _playlist.indexOf(cur);
      _activeQueue = null;
    });
    _publishPlaylist();
    setFull(() {});
  }

  void _removeFromQueue(int i, StateSetter setFull) {
    if (i < 0 || i >= _playlist.length || i == _currentIndex) return;
    setState(() {
      final cur = (_currentIndex >= 0 && _currentIndex < _playlist.length)
          ? _playlist[_currentIndex]
          : null;
      final removed = _playlist.removeAt(i);
      _activeQueue?.remove(removed);
      if (cur != null) _currentIndex = _playlist.indexOf(cur);
    });
    _publishPlaylist();
    setFull(() {});
  }

  /// Shuffle only the songs AFTER the one playing — what's playing and what
  /// already played stay put.
  void _shuffleUpcoming(StateSetter setFull) {
    final start = _currentIndex + 1;
    if (start < 1 || _playlist.length - start < 2) return;
    setState(() {
      final rest = _playlist.sublist(start)..shuffle();
      _playlist.replaceRange(start, _playlist.length, rest);
      _activeQueue = null;
    });
    _publishPlaylist();
    setFull(() {});
    _snack('Up next shuffled');
  }

  void _playNextInQueue(int i, StateSetter setFull) {
    if (i < 0 || i >= _playlist.length || i == _currentIndex) return;
    setState(() {
      final cur = (_currentIndex >= 0 && _currentIndex < _playlist.length)
          ? _playlist[_currentIndex]
          : null;
      final path = _playlist.removeAt(i);
      var at = (cur != null ? _playlist.indexOf(cur) : _currentIndex) + 1;
      at = at.clamp(0, _playlist.length);
      _playlist.insert(at, path);
      if (cur != null) _currentIndex = _playlist.indexOf(cur);
      _activeQueue = null;
    });
    _publishPlaylist();
    setFull(() {});
  }

  Future<void> _play(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    final path = _playlist[index];
    _recordPlay(path); // stats for the smart lists
    unawaited(_loadDedicateFriends());

    // Suppress auto-advance while swapping the source (see _switching).
    _switching = true;

    final initTitle = metadataStore.title(path, _nameFromPath(path));
    final initArtist = metadataStore.artist(path, '');
    // Aluta learns what you play (on-device only) → gentle music nudges.
    SongInsights.instance.recordPlay(initTitle, artist: initArtist);
    setState(() {
      _currentIndex = index;
      _abA = null; // A-B points belong to the previous song
      _abB = null;
      _shuffleNext = null; // pick a fresh shuffle "next" for this song
      _trackName = initTitle;
      _artistName = initArtist;
      _currentArtId = null; // resolved by _fetchMetadata once the song is found
      _artAccentForId = null; // re-derive the artwork accent for the new track
      _artAccentVN.value = null;
    });
    ref.read(nowPlayingProvider.notifier).update(
        track: initTitle, artist: initArtist, playing: true);
    _syncFavoriteAmbient();
    _saveLastTrack(resetPos: true);

    // The VERY FIRST play after a cold start often fails because the audio
    // engine / background service hasn't finished coming up yet — the exact
    // transient the user worked around by closing and reopening the app. So try
    // once, and on failure wait a beat and retry (re-resolving the URI) before
    // surfacing any error. That makes first-launch playback "just work".
    var err = await _openSource(path);
    if (err != null && mounted) {
      await Future.delayed(const Duration(milliseconds: 500));
      _uriMapBuilt = false; // force a fresh URI resolve on the retry
      err = await _openSource(path);
    }
    if (err != null) {
      _switching = false;
      if (_pruneIfMissing(path)) {
        if (mounted) _snack('Track no longer on device — removed');
      } else if (mounted) {
        _snack(err == 'format'
            ? 'Playback error — check file format'
            : 'Cannot play: $err');
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
    if (kIsWeb) return false;
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
      final songs = await SongLibrary.songs();
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
        _resolveArtAccent(m.id);
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
      _play(_peekNextIndex() ?? scope.first);
      return;
    }
    final pos = scope.indexOf(_currentIndex);
    if (pos >= 0 && pos + 1 < scope.length) {
      _play(scope[pos + 1]);
    } else if (_repeatAll) {
      _play(scope.first);
    } else {
      // End of scope, no repeat: just_audio parks at the end with playing still
      // true, so the disc kept spinning and the button stayed on pause. Pause
      // and rewind to the start so the player reads as genuinely stopped (disc
      // halts, button shows play) and the track is ready to replay from 0.
      _player.pause();
      _player.seek(Duration.zero);
      _discCtrl.stop();
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
      _play(_peekNextIndex() ?? scope.first);
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

  /// The song a skip forward will play (null = none: end of the list with
  /// repeat off). Under shuffle it is picked once, ahead of time, and kept.
  int? _peekNextIndex() {
    if (_playlist.isEmpty || _currentIndex < 0) return null;
    final scope = _scopeIndices();
    if (scope.isEmpty) return null;
    if (_shuffle) {
      if (scope.length < 2) return null;
      final s = _shuffleNext;
      if (s == null || s == _currentIndex || !scope.contains(s)) {
        var pick = scope[_rng.nextInt(scope.length)];
        if (pick == _currentIndex) {
          pick = scope[(scope.indexOf(pick) + 1) % scope.length];
        }
        _shuffleNext = pick;
      }
      return _shuffleNext;
    }
    final pos = scope.indexOf(_currentIndex);
    if (pos >= 0 && pos + 1 < scope.length) return scope[pos + 1];
    if (_repeatAll && scope.length > 1) return scope.first;
    return null;
  }

  /// The song before this one in the list (null at the start, repeat off).
  int? _peekPrevIndex() {
    if (_playlist.isEmpty || _currentIndex < 0) return null;
    final scope = _scopeIndices();
    final pos = scope.indexOf(_currentIndex);
    if (pos > 0) return scope[pos - 1];
    if (_repeatAll && scope.length > 1) return scope.last;
    return null;
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
        _restoreLastTrack();
      }
    } catch (_) {}
    // LAZY BY DESIGN: we do NOT scan the device library at launch. A cold scan
    // of the whole MediaStore (+ its permission prompt) on a fresh install was
    // contending with cold-start work and could stall the first launch. Instead,
    // the saved playlist (if any) is restored above, and the FIRST tap on
    // "Playlist" triggers the scan on demand (with a spinner) — see
    // _openOrScanPlaylist. Nothing here touches the device until the user asks.
  }

  // Persist which track is current and where playback is, so an app restart or
  // version update can land the user back on it. Reads the position BEFORE any
  // await so it's safe to call from dispose().
  Future<void> _saveLastTrack({bool resetPos = false}) async {
    try {
      if (_restoringPos) return;
      if (_currentIndex < 0 || _currentIndex >= _playlist.length) return;
      final path = _playlist[_currentIndex];
      final pos = resetPos ? 0 : _player.position.inMilliseconds;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('music_last_track',
          jsonEncode({'path': path, 'pos': pos < 0 ? 0 : pos}));
    } catch (_) {}
  }

  // On launch (after the saved playlist is restored): re-select the last track
  // and LOAD it PAUSED at its last position — the user lands on their song and
  // presses play when ready. Never auto-plays. Light: the source is just
  // prepared, and the one metadata/URI lookup rides the persisted SongLibrary
  // cache, so this adds no device scan to startup.
  Future<void> _restoreLastTrack() async {
    if (_lastTrackRestored) return;
    _lastTrackRestored = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('music_last_track');
      if (raw == null || raw.isEmpty) return;
      final obj = jsonDecode(raw) as Map<String, dynamic>;
      final path = obj['path'] as String?;
      final posMs = (obj['pos'] as num?)?.toInt() ?? 0;
      if (path == null) return;
      final idx = _playlist.indexOf(path);
      if (idx < 0) return; // track no longer in the playlist — skip
      final initTitle = metadataStore.title(path, _nameFromPath(path));
      final initArtist = metadataStore.artist(path, '');
      if (!mounted) return;
      setState(() {
        _currentIndex = idx;
        _trackName = initTitle;
        _artistName = initArtist;
        _currentArtId = null;
      });
      ref.read(nowPlayingProvider.notifier).update(
          track: initTitle, artist: initArtist, playing: false);
      _syncFavoriteAmbient();
      _switching = true; // don't let a prepare emit a spurious auto-advance
      _restoringPos = posMs > 0;
      final err = await _openSource(path, autoplay: false);
      Future.delayed(const Duration(milliseconds: 600), () {
        _switching = false;
      });
      if (err == null) {
        if (posMs > 0) {
          try {
            await _player.seek(Duration(milliseconds: posMs));
          } catch (_) {}
          _restoringPos = false;
        }
        if (_isMobile) _fetchMetadata(path);
      }
    } catch (_) {}
    _restoringPos = false; // never leave saving blocked if the reopen failed
  }

  // ── Effective repeat/shuffle: during a live session these read the SHARED
  // session state (set by whoever — host or listener — last touched it), so the
  // buttons reflect what everyone in the room is on. Off-session they fall back
  // to the local player's own flags.
  String get _effRepeatMode {
    if (_liveActive && _live != null) return _live!.repeatMode;
    if (_repeatOne) return 'one';
    if (_repeatAll) return 'all';
    return 'off';
  }

  bool get _effShuffle =>
      (_liveActive && _live != null) ? _live!.shuffle : _shuffle;

  void _cycleRepeat() {
    // In a live session, cycle the SHARED repeat mode (host or listener — the
    // controller broadcasts so it affects everyone). The onRepeatChanged hook
    // refreshes the button for both sides.
    if (_liveActive && _live != null) {
      const order = ['off', 'all', 'one'];
      final next = order[(order.indexOf(_live!.repeatMode) + 1) % order.length];
      _live!.setRepeatMode(next);
      _snack(next == 'all'
          ? 'Repeat All · session'
          : next == 'one'
              ? 'Repeat One · session'
              : 'Repeat Off · session');
      setState(() {});
      return;
    }
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
    _savePlayModes();
  }

  void _toggleShuffle() {
    // In a live session, toggle the SHARED shuffle (host or listener — the
    // controller broadcasts so it affects everyone).
    if (_liveActive && _live != null) {
      final on = !_live!.shuffle;
      _live!.setShuffle(on);
      _snack(on ? 'Shuffle On · session' : 'Shuffle Off · session');
      setState(() {});
      return;
    }
    setState(() {
      _shuffle = !_shuffle;
      if (_shuffle) {
        _repeatAll = false;
        _repeatOne = false;
      }
      _snack(_shuffle ? 'Shuffle On' : 'Shuffle Off');
    });
    _savePlayModes();
  }

  // Backgrounded, swiped away, or about to be replaced by an APK update (which
  // kills the process with no further warning): write the exact spot now.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _saveLastTrack();
    }
  }

  // Repeat One / Repeat All / Off and Shuffle are the listener's own habit —
  // keep them across restarts and APK updates instead of resetting to Off.
  Future<void> _savePlayModes() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('music_repeat_mode',
          _repeatOne ? 'one' : (_repeatAll ? 'all' : 'off'));
      await p.setBool('music_shuffle', _shuffle);
    } catch (_) {}
  }

  Future<void> _restorePlayModes() async {
    try {
      final p = await SharedPreferences.getInstance();
      final mode = p.getString('music_repeat_mode') ?? 'off';
      final shuffle = p.getBool('music_shuffle') ?? false;
      if (!mounted) return;
      setState(() {
        _repeatOne = mode == 'one';
        _repeatAll = mode == 'all';
        _shuffle = shuffle && mode == 'off';
      });
    } catch (_) {}
  }

  void _setVolume(double v) {
    setState(() => _volume = v);
    _applyVolume();
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _applyVolume();
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
      '90 min': const Duration(minutes: 90),
      // Stops when this song ends (resolved to what's left of it).
      'Song end': const Duration(seconds: -1),
    };
    final scheme = Theme.of(context).colorScheme;
    // How many whole minutes are currently armed (null/0 => Off) so we can
    // highlight the active row.
    final activeMin = _sleepRemaining?.inMinutes;

    // Genie in from the Sleep button, to match Equalizer / Our Space / the rest.
    // A Dialog self-centres, so scaling it from the tapped point reads clean.
    showGeniePopup(
      context,
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
                // Header — same layout as the speed card: gradient icon chip,
                // title + what's armed, close.
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 12, 14),
                  child: Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Color.lerp(scheme.primary, Colors.white, 0.18)!,
                              Color.lerp(scheme.primary, Colors.black, 0.15)!,
                            ],
                          ),
                        ),
                        child: const Icon(Icons.bedtime_rounded,
                            size: 18, color: Colors.white),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Sleep timer',
                                style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 13.5,
                                    color: scheme.onSurface)),
                            Text(
                                activeMin == null
                                    ? 'Music fades out and stops'
                                    : 'Stops in about ${activeMin + 1} min',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: scheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                      InkWell(
                        onTap: () => Navigator.pop(ctx),
                        borderRadius: BorderRadius.circular(20),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(Icons.close_rounded,
                              size: 18, color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
                // Options as the same 3-column chip grid as speed.
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Builder(builder: (_) {
                    final isDark =
                        Theme.of(ctx).brightness == Brightness.dark;
                    final entries = opts.entries.toList();
                    return Column(
                      children: [
                        for (int r = 0; r < entries.length; r += 3)
                          Padding(
                            padding: EdgeInsets.only(
                                bottom: r + 3 < entries.length ? 8 : 0),
                            child: Row(
                              children: [
                                for (int c = 0; c < 3; c++) ...[
                                  if (c > 0) const SizedBox(width: 8),
                                  Expanded(
                                    child: (r + c) < entries.length
                                        ? _musicPickChip(
                                            scheme,
                                            isDark,
                                            label: entries[r + c].key,
                                            active: entries[r + c].value == null
                                                ? activeMin == null
                                                : !entries[r + c]
                                                        .value!
                                                        .isNegative &&
                                                    activeMin ==
                                                        entries[r + c]
                                                            .value!
                                                            .inMinutes,
                                            onTap: () {
                                              Navigator.pop(ctx);
                                              _setSleepTimer(_resolveSleep(
                                                  entries[r + c].value));
                                            },
                                          )
                                        : const SizedBox.shrink(),
                                  ),
                                ],
                              ],
                            ),
                          ),
                      ],
                    );
                  }),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// "Song end" → whatever is left of the current song (null if unknown).
  Duration? _resolveSleep(Duration? d) {
    if (d == null || !d.isNegative) return d;
    final dur = _player.duration;
    if (dur == null || dur <= Duration.zero) return null;
    final left = dur - _player.position;
    return left > const Duration(seconds: 2) ? left : null;
  }

  void _setSleepTimer(Duration? d) {
    _sleepTimer?.cancel();
    _sleepTick?.cancel();
    _sleepFade = 1.0;
    _applyVolume();
    if (d == null) {
      _sleepFade = 1.0;
      _applyVolume();
      setState(() => _sleepRemaining = null);
      _sleepVN.value = null;
      _snack('Sleep timer off');
      return;
    }
    setState(() => _sleepRemaining = d);
    _sleepVN.value = d;
    _snack('Sleep in ${d.inMinutes} min');
    _sleepTimer = Timer(d, () async {
      await _player.pause();
      // Restore the level for next time (the fade did its job).
      _sleepFade = 1.0;
      _applyVolume();
      _sleepTick?.cancel();
      _sleepVN.value = null;
      if (mounted) setState(() => _sleepRemaining = null);
    });
    _sleepTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_sleepRemaining != null && _sleepRemaining!.inSeconds > 0) {
          _sleepRemaining = _sleepRemaining! - const Duration(seconds: 1);
        }
      });
      _sleepVN.value = _sleepRemaining;
      // The last 30s: ease the music away instead of a sudden stop.
      final r = _sleepRemaining?.inSeconds ?? 99;
      final f = r >= 30 ? 1.0 : (r / 30).clamp(0.0, 1.0);
      if (f != _sleepFade) {
        _sleepFade = f;
        _applyVolume();
      }
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
    // Rescan the device library, giving clear feedback either way — so tapping
    // "+" never feels dead when there's nothing new to add.
    final before = _playlist.toSet();
    if (mounted) setState(() => _scanning = true);
    try {
      await _scanIntoPlaylist();
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
    if (!mounted) return;
    final added = _playlist.where((p) => !before.contains(p)).length;
    if (added > 0) {
      _snack('Added $added new track${added == 1 ? '' : 's'}');
    } else if (_playlist.isNotEmpty) {
      _snack('No new music found — your library is up to date');
    }
    if (_playlist.isNotEmpty) _openPlaylist();
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
      onShareMany: _shareSongs,
      onSendToPartner: _sendSongToPartner,
      onDedicate: (p) => showSongDedicate(
        context,
        fileName: p.replaceAll('\\', '/').split('/').last,
        title: metadataStore.title(p, _nameFromPath(p)),
        artist: metadataStore.artist(p, ''),
        loadBytes: () => File(p).readAsBytes(),
        durationMs: p == (_currentIndex >= 0 && _currentIndex < _playlist.length
                ? _playlist[_currentIndex]
                : null)
            ? _player.duration?.inMilliseconds
            : null,
      ),
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
      // Music surface => full page (own header + back arrow). Chat => card drawer.
      fullPage: !playlistDrawerBus.hostIsChatSurface,
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
        songTitle: _trackName,
      ),
    );
  }

  /// Refresh the "Dedicate" row (at most every 10 minutes).
  Future<void> _loadDedicateFriends({bool force = false}) async {
    final at = _dedicateLoadedAt;
    if (!force && at != null && DateTime.now().difference(at).inMinutes < 10) {
      return;
    }
    _dedicateLoadedAt = DateTime.now();
    try {
      final base = await AppConfig.baseUrl;
      final all = await ApiService().getFriends();
      final talked = all
          .where((f) => (f['last_timestamp'] ?? '').toString().isNotEmpty)
          .toList()
        ..sort((a, b) => b['last_timestamp']
            .toString()
            .compareTo(a['last_timestamp'].toString()));
      for (final f in talked) {
        ContactNames.instance.rememberPhone(f['id'], f['phone']?.toString());
      }
      if (!mounted) return;
      setState(() {
        _apiBase = base;
        _dedicateTo = talked.take(5).toList();
      });
    } catch (_) {
      _dedicateLoadedAt = null; // try again next time
    }
  }

  String? _avatarOf(Map<String, dynamic> f) {
    final s = (f['avatar_url'] ?? '').toString();
    if (s.isEmpty) return null;
    return s.startsWith('http') ? s : '$_apiBase$s';
  }

  String _nameOf(Map<String, dynamic> f) => ContactNames.instance.displayName(
      of: f, registered: (f['username'] ?? 'friend').toString());

  void _openDedicate(Map<String, dynamic> friend, Color accent) {
    if (_liveActive || _currentIndex < 0 || _currentIndex >= _playlist.length) {
      return;
    }
    final path = _playlist[_currentIndex];
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // No theme outline — this sheet draws its own card.
      shape: const RoundedRectangleBorder(),
      builder: (_) => _DedicateSheet(
        friend: friend,
        name: _nameOf(friend),
        avatarUrl: _avatarOf(friend),
        path: path,
        title: _trackName,
        artist: _artistName,
        durationMs: _player.duration?.inMilliseconds,
        accent: accent,
      ),
    );
  }

  /// The hero record on/off screen: while it is visible it hosts app-busy as
  /// its ring, so the centred loader never covers the song title.
  void _setHostingBusy(bool on) {
    if (on == _hostingBusy) return;
    _hostingBusy = on;
    discHostsBusy.value += on ? 1 : -1;
  }

  /// A-B repeat key: off → mark A → mark B (loop starts) → off.
  void _cycleAB() {
    if (_liveActive) {
      showToast(context, 'A-B repeat is off during a live session');
      return;
    }
    if (_currentIndex < 0) return;
    final pos = _player.position;
    final a = _abA;
    if (a == null) {
      setState(() => _abA = pos);
      showToast(context,
          'A set at ${_fmt(pos)} — tap again where the part ends');
    } else if (_abB == null) {
      if (pos <= a + const Duration(seconds: 1)) {
        showToast(context, 'Let it play a little past A, then tap for B');
        return;
      }
      setState(() => _abB = pos);
      _abLoopAt = DateTime.now();
      _player.seek(a);
      showToast(context,
          'Repeating ${_fmt(a)} – ${_fmt(pos)} · tap again to stop');
    } else {
      setState(() {
        _abA = null;
        _abB = null;
      });
      showToast(context, 'A-B repeat off');
    }
  }

  /// Long-press on the A-B key: clear straight away from any step.
  void _clearAB() {
    if (_abA == null && _abB == null) return;
    setState(() {
      _abA = null;
      _abB = null;
    });
    showToast(context, 'A-B repeat off');
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
        // Keys typed into a field (playlist search, rename…) are text, not
        // player controls.
        if (isTypingInTextField()) return;
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

          // ── Speed popup — genies straight up out of / down into the speed
          // button (bottom-right), instead of drifting to the screen corner. ──
          if (_showSpeedPanel)
            Positioned.fill(
              child: Stack(
                children: [
                  // Tap-outside barrier, fading in/out with the panel.
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _toggleSpeedPanel,
                      child: FadeTransition(
                        opacity: _speedCtrl,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                  // The card sits just above the speed button and scales from its
                  // OWN bottom-right corner, so it collapses straight down into
                  // the button rather than toward the screen corner.
                  Positioned(
                    right: 16,
                    bottom: 56,
                    child: FadeTransition(
                      opacity: _speedCtrl,
                      child: ScaleTransition(
                        scale: CurvedAnimation(
                          parent: _speedCtrl,
                          curve: Curves.easeOutBack,
                          reverseCurve: Curves.easeIn,
                        ),
                        alignment: Alignment.bottomRight,
                        child: _SpeedPanel(
                          currentSpeed: _speed,
                          onSelect: (s) {
                            _setSpeed(s);
                            _toggleSpeedPanel();
                          },
                          onChanged: _setSpeed,
                          onClose: _toggleSpeedPanel,
                        ),
                      ),
                    ),
                  ),
                ],
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
}

