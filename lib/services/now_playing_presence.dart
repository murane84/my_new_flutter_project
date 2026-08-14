import 'dart:async';
import 'package:flutter/foundation.dart';

import 'audio_handler.dart';
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
    final mi = h.mediaItem.value;
    final title = (mi?.title ?? '').trim();
    final artist = (mi?.artist ?? '').trim();
    // 'Aluta' is the handler's placeholder when nothing real is loaded.
    final playing =
        h.playbackState.value.playing && title.isNotEmpty && title != 'Aluta';
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
    });
  }
}
