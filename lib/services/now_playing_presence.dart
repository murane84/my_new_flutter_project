import 'dart:async';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_handler.dart';
import 'live_session_service.dart' show activeLiveSession;
import '../screens/api_service.dart';
import 'account_prefs.dart';

/// Live "now playing" presence — the seed of Concept 05's "Listening now" zone
/// and the substrate C1 (Listening Rooms) will reuse.
///
/// Two halves:
///  • EMIT — watches the local audio handler and, whenever the track or
///    play/pause state changes, sends a throttled `now_playing` event over the
///    home WebSocket (the server fans it out to friends only).
///  • CONSUME — tracks what my friends are listening to (seeded once from
///    `/users/friends/listening`, then kept live by `friend_now_playing` events)
///    and exposes it so the friend list can show a live indicator.
///
/// A [ChangeNotifier] so the friend list can repaint when a friend starts/stops.
class NowPlayingPresence extends ChangeNotifier {
  NowPlayingPresence._();
  static final NowPlayingPresence instance = NowPlayingPresence._();

  // friendId -> {title, artist}
  final Map<int, Map<String, dynamic>> _friends = {};

  // User setting: whether to broadcast MY "listening now" to friends. Off keeps
  // listening private (nothing is sent; friends' lists drop me). Persisted.
  bool _shareEnabled = true;
  bool _settingLoaded = false;
  bool get shareEnabled => _shareEnabled;

  // Audience: 'everyone' (all friends) or 'selected' (only _allowedFriends).
  String _shareMode = 'everyone';
  Set<int> _allowedFriends = <int>{};
  String get shareMode => _shareMode;
  bool get shareToSelected => _shareMode == 'selected';
  Set<int> get allowedFriends => Set<int>.from(_allowedFriends);

  /// Load the saved share preference (call once at startup). Emits the current
  /// state once loaded so the first broadcast already respects the choice.
  bool _restoreHooked = false;

  Future<void> loadShareSetting() async {
    if (!_restoreHooked) {
      _restoreHooked = true;
      AccountPrefs.onRestore(loadShareSetting); // privacy back from account
    }
    try {
      final p = await SharedPreferences.getInstance();
      _shareEnabled = p.getBool('share_listening_now') ?? true;
      _shareMode = p.getString('share_listening_mode') ?? 'everyone';
      _allowedFriends = (p.getStringList('share_listening_allowed') ?? const [])
          .map((e) => int.tryParse(e) ?? -1)
          .where((e) => e >= 0)
          .toSet();
    } catch (_) {}
    _settingLoaded = true;
    notifyListeners();
    _emit(force: true);
  }

  /// Flip the share preference. OFF immediately announces not-listening so
  /// friends' lists drop me; ON re-announces the current track.
  Future<void> setShareEnabled(bool v) async {
    if (_shareEnabled == v) return;
    _shareEnabled = v;
    notifyListeners();
    _emit(force: true);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('share_listening_now', v);
    } catch (_) {}
    AccountPrefs.touch();
  }

  /// Choose WHO sees my listening now: mode 'everyone' or 'selected' (with the
  /// given friend ids). Persisted; re-broadcasts so the change applies live
  /// (friends removed from the audience get a 'stopped' event server-side).
  Future<void> setAudience(String mode, Set<int> allowed) async {
    _shareMode = mode == 'selected' ? 'selected' : 'everyone';
    _allowedFriends = Set<int>.from(allowed);
    notifyListeners();
    _emit(force: true);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('share_listening_mode', _shareMode);
      await p.setStringList('share_listening_allowed',
          _allowedFriends.map((e) => e.toString()).toList());
    } catch (_) {}
    AccountPrefs.touch();
  }

  /// Set by HomePage to the home socket's send function.
  void Function(Map<String, dynamic>)? emitSink;

  /// What I'm broadcasting right now (title, artist), or null when I'm not
  /// sharing / not playing. Only a shared play counts for "you're both
  /// listening" — if they can't see mine, I shouldn't get theirs as a match.
  ({String title, String artist})? get myTrack {
    if (!_lastPlaying || _lastKey.isEmpty) return null;
    final i = _lastKey.indexOf('|');
    return (
      title: i < 0 ? _lastKey : _lastKey.substring(0, i),
      artist: i < 0 ? '' : _lastKey.substring(i + 1),
    );
  }

  /// Friends allowed to see my listening (everyone, or the picked few).
  bool sharesWith(int friendId) =>
      _shareEnabled && (!shareToSelected || _allowedFriends.contains(friendId));

  /// The track a friend is PLAYING right now, or null (a paused track
  /// doesn't count as listening — see [pausedTrackFor]).
  Map<String, dynamic>? trackFor(int id) {
    final t = _friends[id];
    return (t == null || t['paused'] == true) ? null : t;
  }

  /// The track a friend has PAUSED (shown for a few minutes as a frozen,
  /// dimmed ring), or null.
  Map<String, dynamic>? pausedTrackFor(int id) {
    final t = _friends[id];
    return (t != null && t['paused'] == true) ? t : null;
  }

  /// The song's cover colour a friend sent with their track (ARGB), if any.
  int? colorFor(int id) => (_friends[id]?['color'] as num?)?.toInt();

  /// How far into their song a friend is right now (0..1), extrapolated from
  /// the position they last sent; null when they didn't send one.
  double? progressFor(int id) {
    final t = _friends[id];
    if (t == null) return null;
    final dur = (t['dur'] as num?)?.toDouble();
    final pos = (t['pos'] as num?)?.toDouble();
    final at = (t['at'] as num?)?.toInt();
    if (dur == null || dur <= 0 || pos == null) return null;
    if (t['paused'] == true) return (pos / dur).clamp(0.0, 1.0); // frozen
    // A live event reaches me within moments, so count from when it
    // ARRIVED (immune to their phone's clock being off). Only a snapshot
    // (loaded later, no arrival stamp) uses their send time — and only if
    // it looks sane.
    final now = DateTime.now().millisecondsSinceEpoch;
    var sent = t['_rx'] as int? ?? at ?? now;
    if ((now - sent).abs() > 6 * 3600 * 1000) sent = now;
    final cur = pos + (now - sent).clamp(0, dur.toInt() * 2);
    return (cur / dur).clamp(0.0, 1.0);
  }

  /// Milliseconds left in their song right now (null = unknown / paused).
  int? remainingMsFor(int id) {
    final t = _friends[id];
    if (t == null || t['paused'] == true) return null;
    final dur = (t['dur'] as num?)?.toDouble();
    final pr = progressFor(id);
    if (dur == null || dur <= 0 || pr == null) return null;
    return (dur * (1 - pr)).round();
  }

  bool get anyListening => _friends.values.any((t) => t['paused'] != true);
  int get listeningCount =>
      _friends.values.where((t) => t['paused'] != true).length;

  // ── consume: friends' presence ─────────────────────────────────────────────
  void applyEvent(Map<String, dynamic> e) {
    final id = (e['user_id'] as num?)?.toInt();
    if (id == null) return;
    final playing = e['playing'] == true;
    final track = e['track'];
    if (playing && track is Map) {
      _friends[id] = Map<String, dynamic>.from(track)
        ..['_rx'] = DateTime.now().millisecondsSinceEpoch;
    } else {
      _friends.remove(id);
    }
    notifyListeners();
  }

  Future<void> loadSnapshot() async {
    final list = await ApiService().friendsListening();
    _friends.clear();
    for (final m in list) {
      final id = (m['user_id'] as num?)?.toInt();
      final track = m['track'];
      if (id != null && track is Map) {
        _friends[id] = Map<String, dynamic>.from(track);
      }
    }
    notifyListeners();
  }

  // ── receive-side freshness (independent of local playback) ──────────────────
  // The friends' "listening now" list is seeded by loadSnapshot() and kept live
  // by `friend_now_playing` events. But those events can be MISSED (notably on
  // web, where the socket is less reliable and audioHandler — hence the emit
  // side — is null), leaving the zone permanently empty even while a friend is
  // playing. This keeps it eventually-consistent by re-seeding the snapshot on
  // a gentle timer. It does NOT depend on audioHandler, so it works on web.
  Timer? _snapshotTimer;

  /// Start keeping the friends-listening list fresh. [poll] adds a periodic
  /// re-seed (used on web as a safety net); every platform still gets the
  /// immediate seed + live events. Idempotent.
  void startReceiving({bool poll = false}) {
    loadSnapshot();
    if (poll) {
      _snapshotTimer ??= Timer.periodic(
        const Duration(seconds: 30),
        (_) => loadSnapshot(),
      );
    }
  }

  void stopReceiving() {
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
  }

  void clearAll() {
    if (_friends.isEmpty) return;
    _friends.clear();
    notifyListeners();
  }

  // ── emit: my presence ──────────────────────────────────────────────────────
  StreamSubscription<dynamic>? _miSub;
  StreamSubscription<dynamic>? _psSub;
  Timer? _heartbeat;
  bool _lastPlaying = false;
  String _lastKey = '';

  // Paused: friends keep seeing the song (a frozen, dimmed ring) for a short
  // grace instead of it vanishing on every pause — then it's dropped.
  static const Duration _pauseGrace = Duration(minutes: 5);
  DateTime? _pausedSince;
  bool _lastPausedShown = false;
  Timer? _pauseTimer;

  // The current song's cover colour (ARGB), sent so friends' rings take it.
  int? _coverColor;

  /// The Now Playing page found the cover's accent colour (null = none).
  void setCoverColor(Color? c) {
    final v = c?.toARGB32();
    if (v == _coverColor) return;
    _coverColor = v;
    if (_lastPlaying || _lastPausedShown) _emit(force: true);
  }

  /// Begin watching local playback and emitting presence. Safe to call more
  /// than once (idempotent). When there is an audio handler (mobile/desktop) it
  /// is observed directly; on web there is none, so presence is driven by
  /// [reportManual] from the web player — either way the heartbeat keeps a live
  /// play from expiring off friends' lists.
  void start() {
    if (!_settingLoaded) loadShareSetting();
    final h = audioHandler;
    if (!kIsWeb && h != null) {
      _miSub ??= h.mediaItem.listen((_) => _emit());
      _psSub ??= h.playbackState.listen((_) => _emit());
    }
    // Refresh within the server's presence TTL so a long, uninterrupted play
    // never silently expires and drops us off friends' lists.
    _heartbeat ??= Timer.periodic(
      const Duration(seconds: 60),
      (_) {
        if (_lastPlaying || _lastPausedShown) _emit(force: true);
      },
    );
    _emit();
  }

  // ── manual (web) now-playing source ─────────────────────────────────────────
  // The web/lite build has no audio_service handler, so the normal emit has no
  // track to read. The web player calls this directly on play / pause / track
  // change so a web listener still appears in friends' "Listening now". Ignored
  // where a real audioHandler exists (that path already drives presence).
  bool _manualActive = false;
  String _manualTitle = '';
  String _manualArtist = '';
  bool _manualPlaying = false;

  void reportManual(
      {required String title, String artist = '', required bool playing}) {
    // Web has an audio_service handler too, but the web ("lite") player drives
    // just_audio directly and never feeds that handler — so on web THIS manual
    // report is the only now-playing source. Native keeps using the handler.
    if (!kIsWeb) return; // native platforms drive presence from the handler
    _manualActive = true;
    _manualTitle = title.trim();
    _manualArtist = artist.trim();
    _manualPlaying = playing;
    if (!_settingLoaded) {
      loadShareSetting().then((_) => _emit());
    } else {
      _emit();
    }
  }

  /// Stop emitting and announce we're no longer listening (e.g. on sign-out).
  void stop() {
    _miSub?.cancel();
    _miSub = null;
    _psSub?.cancel();
    _psSub = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    _pauseTimer?.cancel();
    _pauseTimer = null;
    _pausedSince = null;
    if (_lastPlaying || _lastPausedShown) {
      _lastPlaying = false;
      _lastPausedShown = false;
      _lastKey = '';
      emitSink?.call({'type': 'now_playing', 'playing': false, 'track': null});
    }
  }

  void _emit({bool force = false}) {
    final h = audioHandler;
    final sink = emitSink;
    if (sink == null) return;
    if (!_settingLoaded) return; // don't broadcast before the choice is known
    // Source the current track from the audio handler (mobile/desktop) or the
    // manual web report. With neither, there's nothing to announce.
    final String title;
    final String artist;
    final bool localPlaying;
    int? posMs;
    int? durMs;
    if (!kIsWeb && h != null) {
      final mi = h.mediaItem.value;
      title = (mi?.title ?? '').trim();
      artist = (mi?.artist ?? '').trim();
      localPlaying = h.playbackState.value.playing;
      posMs = h.playbackState.value.position.inMilliseconds;
      durMs = mi?.duration?.inMilliseconds;
    } else if (_manualActive) {
      title = _manualTitle;
      artist = _manualArtist;
      localPlaying = _manualPlaying;
    } else {
      return;
    }
    // "Our Space" privacy: a Listen Together session is a sacred, PRIVATE space
    // between the two of you. While one is active, we do NOT broadcast the
    // now-playing to third-party friends — they should never see what the pair
    // are sharing in the session. Presence resumes (announcing the real local
    // track) the moment the session ends and the local player takes over.
    final inLiveSession = activeLiveSession != null;
    // 'Aluta' is the handler's placeholder when nothing real is loaded.
    final hasTrack = _shareEnabled &&
        !inLiveSession &&
        title.isNotEmpty &&
        title != 'Aluta';
    final playing = hasTrack && localPlaying;
    // Paused (track still loaded): keep showing it for [_pauseGrace].
    if (hasTrack && !localPlaying) {
      _pausedSince ??= DateTime.now();
    } else {
      _pausedSince = null;
    }
    final since = _pausedSince;
    final pausedShown =
        since != null && DateTime.now().difference(since) < _pauseGrace;
    _pauseTimer?.cancel();
    if (since != null && pausedShown) {
      // Re-check when the grace ends so the song is dropped on time.
      _pauseTimer = Timer(
          _pauseGrace -
              DateTime.now().difference(since) +
              const Duration(seconds: 1),
          () => _emit(force: true));
    }
    final key = (playing || pausedShown) ? '$title|$artist' : '';
    if (!force &&
        playing == _lastPlaying &&
        pausedShown == _lastPausedShown &&
        key == _lastKey) {
      return;
    }
    final changed = playing != _lastPlaying || key != _lastKey;
    _lastPlaying = playing;
    _lastPausedShown = pausedShown;
    _lastKey = key;
    if (changed) notifyListeners(); // lets home spot "you're both listening"
    final shown = playing || pausedShown;
    sink({
      'type': 'now_playing',
      'playing': shown,
      'track': shown
          ? {
              'title': title,
              'artist': artist == 'Aluta' ? '' : artist,
              if (pausedShown) 'paused': true,
              'color': ?_coverColor,
              // Where the song was when this went out — friends' lists fill
              // the ring around my photo with the song's progress.
              if (durMs != null && durMs > 0) 'dur': durMs,
              if (durMs != null && durMs > 0 && posMs != null) 'pos': posMs,
              if (durMs != null && durMs > 0)
                'at': DateTime.now().millisecondsSinceEpoch,
            }
          : null,
      // null = every friend; a list = only these friend ids may see it.
      'audience': (shown && _shareMode == 'selected')
          ? _allowedFriends.toList()
          : null,
    });
  }
}
