import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_handler.dart';
import 'live_session_service.dart' show activeLiveSession;
import '../screens/api_service.dart';

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
  Future<void> loadShareSetting() async {
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
  }

  /// Set by HomePage to the home socket's send function.
  void Function(Map<String, dynamic>)? emitSink;

  /// The track a friend is playing right now, or null.
  Map<String, dynamic>? trackFor(int id) => _friends[id];
  bool get anyListening => _friends.isNotEmpty;
  int get listeningCount => _friends.length;

  // ── consume: friends' presence ─────────────────────────────────────────────
  void applyEvent(Map<String, dynamic> e) {
    final id = (e['user_id'] as num?)?.toInt();
    if (id == null) return;
    final playing = e['playing'] == true;
    final track = e['track'];
    if (playing && track is Map) {
      _friends[id] = Map<String, dynamic>.from(track);
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

  /// Begin watching local playback and emitting presence. Safe to call more
  /// than once (idempotent) and a no-op until the audio handler exists.
  void start() {
    final h = audioHandler;
    if (h == null) return;
    if (!_settingLoaded) loadShareSetting();
    _miSub ??= h.mediaItem.listen((_) => _emit());
    _psSub ??= h.playbackState.listen((_) => _emit());
    // Refresh within the server's presence TTL so a long, uninterrupted play
    // never silently expires and drops us off friends' lists.
    _heartbeat ??= Timer.periodic(
      const Duration(seconds: 60),
      (_) {
        if (_lastPlaying) _emit(force: true);
      },
    );
    _emit();
  }

  /// Stop emitting and announce we're no longer listening (e.g. on sign-out).
  void stop() {
    _miSub?.cancel();
    _miSub = null;
    _psSub?.cancel();
    _psSub = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    if (_lastPlaying) {
      _lastPlaying = false;
      _lastKey = '';
      emitSink?.call({'type': 'now_playing', 'playing': false, 'track': null});
    }
  }

  void _emit({bool force = false}) {
    final h = audioHandler;
    final sink = emitSink;
    if (h == null || sink == null) return;
    if (!_settingLoaded) return; // don't broadcast before the choice is known
    final mi = h.mediaItem.value;
    final title = (mi?.title ?? '').trim();
    final artist = (mi?.artist ?? '').trim();
    // "Our Space" privacy: a Listen Together session is a sacred, PRIVATE space
    // between the two of you. While one is active, we do NOT broadcast the
    // now-playing to third-party friends — they should never see what the pair
    // are sharing in the session. Presence resumes (announcing the real local
    // track) the moment the session ends and the local player takes over.
    final inLiveSession = activeLiveSession != null;
    // 'Aluta' is the handler's placeholder when nothing real is loaded.
    final playing = _shareEnabled &&
        !inLiveSession &&
        h.playbackState.value.playing &&
        title.isNotEmpty &&
        title != 'Aluta';
    final key = playing ? '$title|$artist' : '';
    if (!force && playing == _lastPlaying && key == _lastKey) return;
    _lastPlaying = playing;
    _lastKey = key;
    sink({
      'type': 'now_playing',
      'playing': playing,
      'track': playing
          ? {'title': title, 'artist': artist == 'Aluta' ? '' : artist}
          : null,
      // null = every friend; a list = only these friend ids may see it.
      'audience': (playing && _shareMode == 'selected')
          ? _allowedFriends.toList()
          : null,
    });
  }
}
