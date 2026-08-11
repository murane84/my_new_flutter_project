import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../utils/app_config.dart';
import '../screens/api_service.dart';

/// "Listen together" live session client.
///
/// The song NEVER leaves memory: the host streams the raw audio bytes over a
/// WebSocket, the server forwards them in memory, and the listener plays them
/// from an in-memory [BytesAudioSource]. Nothing is written to disk on either
/// device or the server, and the session vanishes when it ends.
///
/// This class is platform-agnostic (no `dart:io`), so it also works in the web
/// PWA build. The caller is responsible for obtaining the audio bytes:
///   * mobile/desktop: read the picked file (e.g. `File(path).readAsBytes()`)
///   * web: use the bytes `file_picker` already gives you
///
/// Typical flow:
///   HOST:     await controller.startHost(receiverId, myUserId, token, bytes, title);
///   LISTENER: await controller.joinAsListener(sessionId, myUserId, token);
enum LiveRole { host, listener }

/// The ONE live session currently running, held globally so its popup can be
/// minimised (closed) while the session keeps streaming in the background. A
/// fresh [LiveSessionScreen] can rebind to [controller] to reopen it.
class ActiveLiveSession {
  ActiveLiveSession({
    required this.controller,
    required this.role,
    required this.peerName,
    required this.title,
    required this.token,
    required this.myUserId,
  });

  final LiveSessionController controller;
  final LiveRole role;
  final String peerName;
  String title;
  final String token;
  final int myUserId;

  bool get isHost => role == LiveRole.host;
}

/// Non-null while a live session is active (foreground or minimised).
ActiveLiveSession? activeLiveSession;

/// Set once by the UI layer (see main.dart). Shows a host-facing notification
/// (e.g. "X left the session") that works even when the live popup is minimised,
/// because it routes through the app's global overlay rather than the popup's
/// own context. Left as a global so it survives the screen being disposed.
void Function(String message)? liveHostNotify;

/// Tears down and clears the active session (used by the persistent banner's
/// "End" action, and when a session ends remotely while minimised). Callers in
/// the UI layer should also call `liveSessionNotifier.stop()` afterwards.
Future<void> endActiveLiveSession() async {
  final s = activeLiveSession;
  activeLiveSession = null;
  if (s == null) return;
  try {
    if (s.role == LiveRole.host) await s.controller.endSession(s.token);
  } catch (_) {/* best-effort */}
  try {
    await s.controller.dispose();
  } catch (_) {}
}

/// One song in a live session's host-side queue (audio kept in memory only).
class LiveTrack {
  LiveTrack({required this.bytes, required this.title, this.mime = 'audio/mpeg'});
  final Uint8List bytes;
  final String title;
  final String mime;
}

class LiveSessionController {
  LiveSessionController({this.onEvent, this.onEnded, this.onError}) {
    // On Android, give the live player the same EQ + loudness pipeline the
    // music player uses, so the host's equalizer settings can be applied here
    // (and mirrored to the listener). Elsewhere it's a plain player.
    if (_androidEffects) {
      _eq = AndroidEqualizer();
      _loud = AndroidLoudnessEnhancer();
      player = AudioPlayer(
        audioPipeline: AudioPipeline(androidAudioEffects: [_loud!, _eq!]),
      );
    } else {
      player = AudioPlayer();
    }
  }

  static bool get _androidEffects =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  AndroidEqualizer? _eq;
  AndroidLoudnessEnhancer? _loud;
  Map<String, dynamic>? _hostEq; // last EQ settings (host), re-sent on join

  /// Fired for every control event received (`meta`, `play`, `pause`, `seek`,
  /// `peer_joined`, `peer_left`, `session_state`, ...). Use it to update UI.
  ///
  /// Mutable so a session can be "minimised" (its popup closed) and later
  /// reopened by a fresh screen that re-points these handlers at itself.
  void Function(Map<String, dynamic> event)? onEvent;

  /// Fired once when the session ends (host ended / host left / you left).
  void Function(String reason)? onEnded;

  /// Fired on any transport error.
  void Function(Object error)? onError;

  /// Shared player. For the host it plays the local bytes; for the listener it
  /// plays the streamed-in bytes. Bind your seekbar/controls to this.
  late final AudioPlayer player;

  WebSocketChannel? _channel;
  StreamSubscription? _socketSub;
  StreamSubscription? _posSub;
  StreamSubscription? _playingSub;

  LiveRole? role;
  String? sessionId;

  // Host-side call-log style history: post ONE entry to the thread when the
  // session ends, recording the outcome (listened / declined / no-answer).
  int? _logReceiverId; // DM friend (1:1) …
  int? _logConversationId; // … or group conversation
  DateTime? _sessionStartAt;
  bool _hadListener = false;
  bool _declined = false;
  bool _outcomeLogged = false;

  /// The host learned a listener declined — log 'declined' and suppress the
  /// end-of-session entry so we don't also post 'no answer'.
  void markDeclined() {
    if (role != LiveRole.host || _outcomeLogged) return;
    _outcomeLogged = true;
    _declined = true;
    _postLiveLog('declined', 0);
  }

  void _logHostOutcome() {
    if (role != LiveRole.host || _outcomeLogged) return;
    _outcomeLogged = true;
    final secs = _sessionStartAt != null
        ? DateTime.now().difference(_sessionStartAt!).inSeconds
        : 0;
    // 'listened' if someone actually joined; else nobody picked up.
    _postLiveLog(_hadListener ? 'listened' : 'noanswer', secs);
  }

  void _postLiveLog(String outcome, int secs) {
    final rid = _logReceiverId;
    final cid = _logConversationId;
    if (rid == null && cid == null) return;
    unawaited(
      ApiService()
          .sendMessage(rid ?? 0, outcome,
              messageType: 'live',
              mediaDuration: secs,
              conversationId: cid)
          .catchError((_) => null),
    );
  }

  // Listener-side in-memory buffer for the incoming song.
  final BytesBuilder _incoming = BytesBuilder(copy: false);
  String _incomingMime = 'audio/mpeg';
  bool _listenerStarted = false;

  // Host-side: kept so we can (re)stream the song the moment a listener joins,
  // so join timing no longer matters (a late joiner still gets the full audio).
  Uint8List? _hostBytes;
  Map<String, dynamic>? _hostMeta;

  // Host-side queue of songs to play in sequence. [currentIndex] is the one
  // playing now; entries after it are "up next" and can be added/removed.
  final List<LiveTrack> queue = [];
  int currentIndex = 0;
  bool _peerPresent = false; // a listener has joined → stream track changes now
  bool _peerEverPresent = false; // has a listener ever joined? (rejoin detect)
  bool _peerGraceful = false; // listener announced 'leaving' (vs a silent drop)
  bool _switchingTrack = false; // guards auto-advance during a source swap
  StreamSubscription? _completeSub;
  /// Fired whenever the queue or current index changes (host UI refresh, and —
  /// now — the listener's mirrored queue too).
  void Function()? onQueueChanged;

  /// Title of the track playing live right now (host or listener). Held here —
  /// not only in the popup — so it survives the popup being minimised and so
  /// the music-panel console can always mirror the correct live title.
  String currentTitle = '';

  // Listener-side mirror of the host's queue (titles only — audio is never sent
  // until a track actually plays). Lets the listener SEE what the host queued
  // and know which one is current, exactly like the host does.
  final List<String> remoteQueueTitles = [];
  int remoteIndex = 0;

  /// Sets the live title and keeps the global session title in sync so every
  /// surface (popup, music panel, banner) reflects the current song.
  void _setCurrentTitle(String? t) {
    if (t == null || t.isEmpty) return;
    currentTitle = t;
    activeLiveSession?.title = t;
  }

  /// Host → listener: broadcast the queue (titles + current index) so the
  /// listener can render the same "up next" list. Sent on every queue change.
  void _broadcastQueue() {
    _sendControl({
      'type': 'queue',
      'items': queue.map((t) => t.title).toList(),
      'index': currentIndex,
    });
  }

  bool get isConnected => _channel != null;

  // ---------------------------------------------------------------------------
  // HOST
  // ---------------------------------------------------------------------------
  /// Create a session, invite [receiverId], start playing locally, and stream
  /// the bytes to the listener. Returns the created session id.
  Future<String> startHost({
    required int receiverId,
    required int myUserId,
    required String token,
    required Uint8List audioBytes,
    required String title,
    String? artist,
    int? durationMs,
    String mime = 'audio/mpeg',
    int startPositionMs = 0,
  }) async {
    role = LiveRole.host;
    // History: remember who to log to and when we started.
    _logReceiverId = receiverId;
    _logConversationId = null;
    _sessionStartAt = DateTime.now();
    _hadListener = false;
    _declined = false;
    _outcomeLogged = false;

    // 1) Create the session on the server (metadata only — no audio uploaded).
    final base = await AppConfig.baseUrl;
    final res = await http.post(
      Uri.parse('$base/live/sessions'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'receiver_id': receiverId,
        'track': {
          'title': title,
          'artist': artist,
          'duration_ms': durationMs,
          'mime': mime,
        },
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('Failed to create session: ${res.statusCode} ${res.body}');
    }
    sessionId = jsonDecode(res.body)['session_id'] as String;

    // 2) Open the session socket.
    await _openSocket(sessionId!, myUserId, token);

    // 3) Start local playback from the in-memory bytes, at the requested
    //    position (so sharing the currently-playing song blends in without a
    //    restart).
    await player.setAudioSource(BytesAudioSource(audioBytes, contentType: mime));
    if (startPositionMs > 0) {
      await player.seek(Duration(milliseconds: startPositionMs));
    }
    _broadcastHostPlayback(); // mirror play/pause/seek/position to the listener

    // 3b) Apply the host's saved equalizer to the live player AND remember it
    //     so it can be mirrored to the listener.
    await _sendHostEq(alsoSend: false);

    // 4) Announce metadata. The actual audio is streamed only once a listener
    //    joins (see the `peer_joined` handling below), so a late-accepting
    //    receiver still gets the full song.
    final meta = {
      'type': 'meta',
      'track': {
        'title': title,
        'artist': artist,
        'duration_ms': durationMs,
        'mime': mime,
      },
    };
    _hostMeta = meta;
    _hostBytes = audioBytes;
    // Seed the queue with this first track.
    queue
      ..clear()
      ..add(LiveTrack(bytes: audioBytes, title: title, mime: mime));
    currentIndex = 0;
    // Auto-advance to the next queued track when one finishes.
    _completeSub = player.processingStateStream.listen((s) {
      if (role == LiveRole.host &&
          s == ProcessingState.completed &&
          !_switchingTrack) {
        nextTrack();
      }
    });
    _sendControl(meta);
    _setCurrentTitle(title);
    await player.play();
    _sendControl({'type': 'play', 'position_ms': startPositionMs});
    onQueueChanged?.call();
    _broadcastQueue();

    return sessionId!;
  }

  // ---------------------------------------------------------------------------
  // HOST QUEUE
  // ---------------------------------------------------------------------------
  /// Append a song to the up-next queue. If the current track has already
  /// finished (nothing playing), start this one immediately.
  Future<void> addTrack(LiveTrack t) async {
    queue.add(t);
    onQueueChanged?.call();
    _broadcastQueue();
    final ended = player.processingState == ProcessingState.completed ||
        player.processingState == ProcessingState.idle;
    if (ended && currentIndex >= queue.length - 1) {
      await playIndex(queue.length - 1);
    }
  }

  /// Remove an UP-NEXT track (cannot remove the one currently playing).
  Future<void> removeUpcoming(int index) async {
    if (index <= currentIndex || index >= queue.length) return;
    queue.removeAt(index);
    onQueueChanged?.call();
    _broadcastQueue();
  }

  /// Listener → host transport request. The host executes it and broadcasts
  /// the result so playback stays in sync. Actions: playpause / play / pause /
  /// next / prev / seek (with positionMs) / play_index (with index).
  void requestControl(String action, {int? positionMs, int? index}) {
    _sendControl({
      'type': 'ctl',
      'action': action,
      'position_ms': ?positionMs,
      'index': ?index,
    });
  }

  /// Skip to the next queued track, if any.
  Future<void> nextTrack() async {
    if (currentIndex + 1 < queue.length) {
      await playIndex(currentIndex + 1);
    }
  }

  /// Switch playback (host + listener) to queue entry [index].
  Future<void> playIndex(int index) async {
    if (index < 0 || index >= queue.length) return;
    _switchingTrack = true;
    currentIndex = index;
    final t = queue[index];
    _hostBytes = t.bytes;
    _hostMeta = {
      'type': 'meta',
      'track': {'title': t.title, 'mime': t.mime},
    };
    try {
      await player.setAudioSource(
          BytesAudioSource(t.bytes, contentType: t.mime));
      // Tell the listener a new track is starting (resets its buffer), then
      // stream the new bytes, then eos → listener plays it.
      _sendControl({
        'type': 'track_change',
        'track': {'title': t.title, 'mime': t.mime},
      });
      if (_peerPresent) {
        unawaited(_streamBytesToListener(t.bytes));
      }
      _setCurrentTitle(t.title);
      await player.play();
      _sendControl({'type': 'play', 'position_ms': 0});
    } catch (e) {
      onError?.call(e);
    }
    onQueueChanged?.call();
    _broadcastQueue();
    // Clear the guard after the source has settled so genuine end-of-track
    // completion still auto-advances.
    Future<void>.delayed(const Duration(milliseconds: 800), () {
      _switchingTrack = false;
    });
  }

  /// Reads the host's saved equalizer settings, applies them to the live
  /// player, and (optionally) sends them to the listener. Stored so a late
  /// joiner can be re-sent the same settings on `peer_joined`.
  Future<void> _sendHostEq({bool alsoSend = true}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final eqMsg = <String, dynamic>{
        'type': 'eq',
        'enabled': prefs.getBool('eq_enabled') ?? false,
        'gains': prefs.getStringList('eq_gains') ?? <String>[],
        'bass': prefs.getDouble('eq_bass') ?? 0.0,
        'loud': prefs.getDouble('eq_loud') ?? 0.0,
      };
      _hostEq = eqMsg;
      await _applyEq(eqMsg); // shape the host's own live playback too
      if (alsoSend) _sendControl(eqMsg);
    } catch (_) {/* EQ is best-effort — never break the session over it */}
  }

  /// Applies an EQ settings message to this device's live player (Android).
  Future<void> _applyEq(Map<String, dynamic> msg) async {
    final eq = _eq;
    if (eq == null) return;
    try {
      final enabled = msg['enabled'] == true;
      await eq.setEnabled(enabled);
      await _loud?.setEnabled(enabled);
      final params = await eq.parameters;
      final rawGains = (msg['gains'] as List?) ?? const [];
      final gains =
          rawGains.map((e) => double.tryParse(e.toString()) ?? 0.0).toList();
      final bass = (msg['bass'] as num?)?.toDouble() ?? 0.0;
      for (var i = 0; i < params.bands.length && i < gains.length; i++) {
        final extra = i == 0 ? bass * (params.maxDecibels * 0.8) : 0.0;
        await params.bands[i].setGain(
            (gains[i] + extra).clamp(params.minDecibels, params.maxDecibels));
      }
      final loudV = (msg['loud'] as num?)?.toDouble() ?? 0.0;
      await _loud?.setTargetGain(loudV * 12);
    } catch (_) {/* best-effort */}
  }

  Future<void> _streamBytesToListener(Uint8List bytes) async {
    const chunkSize = 32 * 1024; // 32 KB frames
    try {
      for (var offset = 0; offset < bytes.length; offset += chunkSize) {
        final end =
            (offset + chunkSize < bytes.length) ? offset + chunkSize : bytes.length;
        _channel?.sink.add(Uint8List.sublistView(bytes, offset, end));
        // Yield so we don't flood the socket buffer or freeze the UI.
        await Future<void>.delayed(const Duration(milliseconds: 4));
      }
      _sendControl({'type': 'eos'}); // end of stream — all bytes sent
    } catch (e) {
      onError?.call(e);
    }
  }

  void _broadcastHostPlayback() {
    // Mirror play/pause to the listener.
    _playingSub = player.playingStream.listen((playing) {
      _sendControl({
        'type': playing ? 'play' : 'pause',
        'position_ms': player.position.inMilliseconds,
      });
    });
    // Periodic position so the listener stays in sync (also covers seeks).
    _posSub = player.positionStream
        .where((_) => role == LiveRole.host)
        .listen((pos) {
      // throttle: only send on ~1s boundaries
      if (pos.inMilliseconds % 1000 < 250) {
        _sendControl({'type': 'position', 'position_ms': pos.inMilliseconds});
      }
    });
  }

  // ---------------------------------------------------------------------------
  // LISTENER
  // ---------------------------------------------------------------------------
  /// Join a session you were invited to (via a `live_invite` notification) and
  /// play the incoming stream from memory.
  Future<void> joinAsListener({
    required String sessionId,
    required int myUserId,
    required String token,
  }) async {
    role = LiveRole.listener;
    this.sessionId = sessionId;
    _incoming.clear();
    _listenerStarted = false;
    await _openSocket(sessionId, myUserId, token);
  }

  /// Re-open the socket after a transport drop and rejoin the same session.
  /// The host re-sends metadata/EQ and re-streams the current track on
  /// `peer_joined`, so playback resumes. Throws if the session is gone.
  Future<void> reconnectAsListener({
    required String sessionId,
    required int myUserId,
    required String token,
  }) async {
    // Drop the dead socket first.
    try {
      await _socketSub?.cancel();
    } catch (_) {}
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _incoming.clear();
    _listenerStarted = false;
    try {
      await player.stop();
    } catch (_) {}
    role = LiveRole.listener;
    this.sessionId = sessionId;
    await _openSocket(sessionId, myUserId, token);
  }

  /// Re-open the socket after the HOST's transport dropped (a network glitch),
  /// WITHOUT restarting the session. The host's LOCAL playback never stopped —
  /// only the socket died — so we keep the player and queue exactly as they are
  /// and just re-establish the pipe. The server kept the session alive during
  /// the grace window and, on reconnect, delivers a `peer_joined` for the
  /// listener who is still there, which drives the existing re-stream path so
  /// the listener catches back up. Throws if the session is already gone.
  Future<void> reconnectAsHost({
    required int myUserId,
    required String token,
  }) async {
    final sid = sessionId;
    if (sid == null) {
      throw StateError('No active session to reconnect to');
    }
    // Drop the dead socket. Do NOT touch the player, queue, _hostBytes or the
    // play/pause/position mirror subscriptions — they survive the reconnect
    // and immediately start feeding the new channel once it's open.
    try {
      await _socketSub?.cancel();
    } catch (_) {}
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    role = LiveRole.host;
    await _openSocket(sid, myUserId, token);
    // The re-stream to the listener is triggered by the server's `peer_joined`
    // (handled below). Re-announce metadata now so the listener's title/mime is
    // refreshed even before the bytes arrive.
    final meta = _hostMeta;
    if (meta != null) _sendControl(meta);
  }

  Future<void> _startListenerPlayback({bool autoplay = true}) async {
    if (_listenerStarted) return;
    final bytes = _incoming.toBytes();
    // Check for an empty buffer BEFORE claiming _listenerStarted. If an early
    // (empty) eos arrives — e.g. right after a reconnect, before the host has
    // re-streamed any bytes — we must NOT latch _listenerStarted, or the real
    // eos that follows the re-stream would be ignored and playback would jam
    // at 00:00 forever.
    if (bytes.isEmpty) return;
    _listenerStarted = true;
    await player.setAudioSource(BytesAudioSource(bytes, contentType: _incomingMime));
    if (autoplay) await player.play();
  }

  // ---------------------------------------------------------------------------
  // SOCKET
  // ---------------------------------------------------------------------------
  Future<void> _openSocket(String sessionId, int myUserId, String token) async {
    final wsBase = await AppConfig.wsBaseUrl; // wss://aluta.ozilane.com (release)
    final uri = Uri.parse('$wsBase/live/ws/$sessionId?token=$token&user_id=$myUserId');
    _channel = WebSocketChannel.connect(uri);
    _socketSub = _channel!.stream.listen(
      _onSocketMessage,
      onError: (e) => onError?.call(e),
      onDone: () => onEnded?.call('disconnected'),
      cancelOnError: false,
    );
  }

  void _onSocketMessage(dynamic message) {
    // Binary frame = audio chunk (listener buffers it in memory).
    if (message is List<int>) {
      if (role == LiveRole.listener) {
        _incoming.add(message);
      }
      return;
    }
    // Text frame = JSON control message.
    if (message is String) {
      Map<String, dynamic> msg;
      try {
        msg = jsonDecode(message) as Map<String, dynamic>;
      } catch (_) {
        return;
      }
      _handleControl(msg);
    }
  }

  Future<void> _handleControl(Map<String, dynamic> msg) async {
    final type = msg['type'] as String?;
    onEvent?.call(msg);

    // Host: the one inbound event it acts on is a listener joining — that's when
    // it (re)sends metadata and streams the song, so join timing doesn't matter.
    if (role == LiveRole.host) {
      if (type == 'peer_joined') {
        // Notify the host only on a genuine REJOIN (they were here before and
        // had dropped), not on the very first join.
        final rejoined = _peerEverPresent && !_peerPresent;
        _peerPresent = true;
        _peerEverPresent = true;
        _peerGraceful = false;
        _hadListener = true; // someone joined → history logs "listened"
        if (rejoined) {
          final name = activeLiveSession?.peerName ?? 'Your friend';
          liveHostNotify?.call('$name reconnected');
        }
        // Announce the current track as a `track_change` (NOT a plain `meta`).
        // A reconnecting listener needs its buffer/player fully reset before
        // the host re-streams the bytes; only `track_change` does that reset
        // (and also clears the listener screen's "Connection lost" state).
        // Sending `meta` here left a reconnecting listener jammed at 00:00
        // because its stale buffer/started-flag were never cleared.
        final meta = _hostMeta;
        if (meta != null) {
          final track = meta['track'];
          _sendControl({
            'type': 'track_change',
            'track': ?track,
          });
        }
        // Re-send the equalizer settings so a late joiner hears the same shape.
        final eq = _hostEq;
        if (eq != null) _sendControl(eq);
        final bytes = _hostBytes;
        if (bytes != null) {
          unawaited(_streamBytesToListener(bytes));
        }
        // Send the current queue so the freshly-joined listener sees it.
        _broadcastQueue();
      } else if (type == 'ctl') {
        // A listener requested a transport action. The host executes it
        // authoritatively; the resulting play/pause/position/track_change
        // broadcast keeps everyone in sync.
        final action = msg['action'];
        switch (action) {
          case 'playpause':
            player.playing ? player.pause() : player.play();
            break;
          case 'play':
            player.play();
            break;
          case 'pause':
            player.pause();
            break;
          case 'next':
            nextTrack();
            break;
          case 'prev':
            if (currentIndex > 0) {
              playIndex(currentIndex - 1);
            } else {
              player.seek(Duration.zero);
            }
            break;
          case 'seek':
            final pos = msg['position_ms'];
            if (pos is int) player.seek(Duration(milliseconds: pos));
            break;
          case 'play_index':
            // Listener tapped a specific queue track — jump to it.
            final idx = msg['index'];
            if (idx is int) playIndex(idx);
            break;
        }
      } else if (type == 'leaving') {
        // The listener chose to leave (sent right before they close). Mark it
        // graceful so the follow-up 'peer_left' isn't reported as a glitch.
        _peerGraceful = true;
        _peerPresent = false;
        final name = activeLiveSession?.peerName ?? 'Your friend';
        liveHostNotify?.call('$name left the session');
      } else if (type == 'peer_left') {
        // The listener's socket dropped. If they didn't announce 'leaving'
        // first, it's an unexpected disconnect (e.g. a WiFi glitch) — tell the
        // host they may rejoin.
        _peerPresent = false;
        if (!_peerGraceful) {
          final name = activeLiveSession?.peerName ?? 'Your friend';
          liveHostNotify?.call('$name lost connection — they may rejoin');
        }
        _peerGraceful = false;
      }
      return;
    }

    switch (type) {
      case 'session_state':
        final track = (msg['data']?['track']) as Map<String, dynamic>?;
        if (track?['mime'] is String) _incomingMime = track!['mime'] as String;
        break;
      case 'host_reconnecting':
        // The host's socket dropped (likely a glitch). Hold playback where it
        // is and wait — the host has a grace window to come back, after which
        // a fresh track re-stream ('track_change' → 'eos') resumes us. If the
        // host never returns the server sends 'end'.
        try {
          await player.pause();
        } catch (_) {}
        break;
      case 'meta':
        final track = msg['track'] as Map<String, dynamic>?;
        if (track?['mime'] is String) _incomingMime = track!['mime'] as String;
        _setCurrentTitle(track?['title'] as String?);
        break;
      case 'queue':
        // Host's queue snapshot — mirror it so the listener can see "up next".
        final items = (msg['items'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const <String>[];
        remoteQueueTitles
          ..clear()
          ..addAll(items);
        final idx = msg['index'];
        if (idx is int) remoteIndex = idx;
        onQueueChanged?.call();
        break;
      case 'eq':
        // Mirror the host's equalizer onto our live player.
        await _applyEq(msg);
        break;
      case 'track_change':
        // The host switched songs: reset our buffer so the incoming bytes
        // become a fresh track, played once its 'eos' arrives.
        final track = msg['track'] as Map<String, dynamic>?;
        if (track?['mime'] is String) _incomingMime = track!['mime'] as String;
        _setCurrentTitle(track?['title'] as String?);
        _incoming.clear();
        _listenerStarted = false;
        try {
          await player.stop();
        } catch (_) {}
        break;
      case 'eos':
        // All bytes received — start playback from the in-memory buffer.
        await _startListenerPlayback(autoplay: true);
        break;
      case 'play':
        // Ignore until the full song is buffered (started via 'eos'); otherwise
        // playback would begin from a partial in-memory buffer.
        if (!_listenerStarted) break;
        final pos = msg['position_ms'];
        if (pos is int) await player.seek(Duration(milliseconds: pos));
        await player.play();
        break;
      case 'pause':
        if (!_listenerStarted) break;
        final pos = msg['position_ms'];
        if (pos is int) await player.seek(Duration(milliseconds: pos));
        await player.pause();
        break;
      case 'seek':
      case 'position':
        final pos = msg['position_ms'];
        if (pos is int && _listenerStarted) {
          // Only correct if we've drifted noticeably (>1.5s) to avoid stutter.
          final drift = (player.position.inMilliseconds - pos).abs();
          if (drift > 1500) await player.seek(Duration(milliseconds: pos));
        }
        break;
      case 'end':
        final reason = (msg['reason'] as String?) ?? 'ended';
        await _teardown();
        onEnded?.call(reason);
        break;
    }
  }

  void _sendControl(Map<String, dynamic> data) {
    try {
      _channel?.sink.add(jsonEncode(data));
    } catch (e) {
      onError?.call(e);
    }
  }

  /// Listener → host: announce an intentional leave just before tearing down,
  /// so the host can tell "left on purpose" apart from a silent connection drop
  /// (the server still relays this like any control message). Best-effort.
  void notifyLeaving() {
    if (role == LiveRole.listener) _sendControl({'type': 'leaving'});
  }

  // ---------------------------------------------------------------------------
  // TEARDOWN
  // ---------------------------------------------------------------------------
  /// Host: tell the server to end the session for everyone. Then clean up.
  Future<void> endSession(String token) async {
    if (role == LiveRole.host && sessionId != null) {
      try {
        final base = await AppConfig.baseUrl;
        await http.post(
          Uri.parse('$base/live/sessions/$sessionId/end'),
          headers: {'Authorization': 'Bearer $token'},
        );
      } catch (_) {/* best-effort */}
    }
    await _teardown();
  }

  Future<void> _teardown() async {
    // Post the host's one-and-only history entry for this session (guarded).
    _logHostOutcome();
    await _posSub?.cancel();
    await _playingSub?.cancel();
    await _completeSub?.cancel();
    await _socketSub?.cancel();
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _incoming.clear();
    _listenerStarted = false;
    try {
      await player.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await _teardown();
    await player.dispose();
  }
}

/// A [StreamAudioSource] backed entirely by an in-memory byte buffer.
/// just_audio pulls byte ranges from here — nothing is ever written to disk.
class BytesAudioSource extends StreamAudioSource {
  BytesAudioSource(this._bytes, {String contentType = 'audio/mpeg'})
      : _contentType = contentType,
        super(tag: 'AlutaLiveAudio');

  final Uint8List _bytes;
  final String _contentType;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    start ??= 0;
    end ??= _bytes.length;
    return StreamAudioResponse(
      sourceLength: _bytes.length,
      contentLength: end - start,
      offset: start,
      stream: Stream<List<int>>.value(_bytes.sublist(start, end)),
      contentType: _contentType,
    );
  }
}
