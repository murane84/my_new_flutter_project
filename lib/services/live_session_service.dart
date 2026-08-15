import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform, debugPrint;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../utils/app_config.dart';
import '../screens/api_service.dart';
import 'audio_handler.dart';

/// "Listen together" live session client.
///
/// The song NEVER leaves memory and NEVER passes through our server: the host
/// streams the raw audio bytes to the listener PEER-TO-PEER over a WebRTC data
/// channel (direct, or TURN-relayed when a direct path can't be punched), and
/// the listener plays them from an in-memory [BytesAudioSource]. The session
/// WebSocket is used only for signaling (SDP/ICE) and as the sync clock
/// (play/pause/seek/position/meta/queue/eq + session lifecycle) — it carries no
/// audio. Nothing is written to disk anywhere, and the session vanishes when it
/// ends.
///
/// Signaling is peer-addressed (`to`/`from` user ids) so the 1:1 flow here can
/// extend to rooms: the host keeps one peer connection + data channel PER
/// listener, and the server routes addressed messages to a single peer while
/// broadcasting the sync clock to everyone.
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
  int? _myUserId; // this device's user id — stamped as `from` on signaling.

  // Host-side call-log style history: post ONE entry to the thread when the
  // session ends, recording the outcome (listened / declined / no-answer).
  int? _logReceiverId; // DM friend (1:1) …
  int? _logConversationId; // … or group conversation
  DateTime? _sessionStartAt;
  bool _hadListener = false;
  bool _outcomeLogged = false;

  /// The host learned a listener declined — log 'declined' and suppress the
  /// end-of-session entry so we don't also post 'no answer'.
  void markDeclined() {
    if (role != LiveRole.host || _outcomeLogged) return;
    _outcomeLogged = true;
    _postLiveLog('declined', 0);
  }

  void _logHostOutcome() {
    if (role != LiveRole.host || _outcomeLogged) return;
    _outcomeLogged = true;
    final secs = _sessionStartAt != null
        ? DateTime.now().difference(_sessionStartAt!).inSeconds
        : 0;
    _postLiveLog(_hadListener ? 'listened' : 'noanswer', secs);
  }

  void _postLiveLog(String outcome, int secs) {
    final rid = _logReceiverId;
    final cid = _logConversationId;
    if (rid == null && cid == null) return;
    unawaited(
      ApiService()
          .sendMessage(rid ?? 0, outcome,
              messageType: 'live', mediaDuration: secs, conversationId: cid)
          .catchError((_) => null),
    );
  }

  // ── WebRTC (peer-to-peer audio) ────────────────────────────────────────────
  // Free STUN keeps same-network / simple-NAT peers direct; the TURN entries
  // relay when a direct path can't be punched (common on cellular). Mirrors
  // call_service.dart — swap in your own TURN for production reliability.
  static const Map<String, dynamic> _iceConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {
        'urls': 'turn:openrelay.metered.ca:80',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
      {
        'urls': 'turn:openrelay.metered.ca:443',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
      {
        'urls': 'turn:openrelay.metered.ca:443?transport=tcp',
        'username': 'openrelayproject',
        'credential': 'openrelayproject',
      },
    ],
    'sdpSemantics': 'unified-plan',
  };

  // HOST: one peer connection + data channel per listener, keyed by their user
  // id (room-ready). LISTENER: a single connection back to the host.
  final Map<int, _Peer> _peers = {}; // host side
  RTCPeerConnection? _lpc; // listener side
  RTCDataChannel? _lchan;
  bool _lRemoteSet = false;
  final List<RTCIceCandidate> _lPendingIce = [];

  // Listener-side in-memory buffer for the incoming song.
  final BytesBuilder _incoming = BytesBuilder(copy: false);
  String _incomingMime = 'audio/mpeg';
  bool _listenerStarted = false;
  // Listener's view of the host's transport, tracked from session_state / play /
  // pause / position so that when a freshly-buffered track's `eos` fires we
  // resume at the host's position and DON'T autoplay if the host is paused.
  bool _hostPlaying = true;
  int _hostPositionMs = 0;

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
    // Push the new title straight into the media session so the now-playing
    // PRESENCE (NowPlayingPresence reads audioHandler.mediaItem) updates for
    // BOTH host and listener — even if the MusicControls panel isn't the
    // mounted surface. Without this the listener's "Listening now" stayed stuck
    // on the track that opened the session while the host advanced the queue.
    audioHandler?.updateFromPlayer(
      id: 'live-session',
      title: t,
      artist: 'Live',
      playing: player.playing,
      position: player.position,
      duration: player.duration,
    );
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
    // Do NOT await: just_audio's play() future completes only when playback
    // FINISHES (the song ends), so awaiting it would block startHost from
    // returning for the whole track — leaving the host's controls disabled the
    // entire time on backends (e.g. Android) that honour that contract.
    unawaited(player.play());
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
      // Tell the listener a new track is starting (UI title/clear "lost"),
      // then stream the new bytes P2P over each open data channel. The data
      // channel's own track_start → eos framing drives the listener's buffer
      // reset + playback (see _streamTrackToPeer / _bindListenerChannel).
      _sendControl({
        'type': 'track_change',
        'track': {'title': t.title, 'mime': t.mime},
      });
      if (_peerPresent) {
        _streamTrackToAllPeers(t.bytes, t.mime);
      }
      _setCurrentTitle(t.title);
      // Fire-and-forget (see startHost): play()'s future completes on track END.
      unawaited(player.play());
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

  // ── WebRTC audio transport (host → listener, peer-to-peer) ─────────────────

  String _hostMime() =>
      (currentIndex >= 0 && currentIndex < queue.length)
          ? queue[currentIndex].mime
          : 'audio/mpeg';

  /// Send `data` to a single peer over the signaling socket (rtc_offer /
  /// rtc_answer / rtc_ice), stamped with who it's `to` and `from`.
  void _signalTo(int peerId, Map<String, dynamic> data) {
    _sendControl({...data, 'to': peerId, 'from': _myUserId});
  }

  /// HOST: (re)negotiate a peer connection + audio data channel with [peerId].
  /// When the channel opens, the current track is streamed over it. Tears down
  /// any stale connection to that peer first (e.g. on a reconnect).
  Future<void> _hostConnectToPeer(int peerId) async {
    await _closePeer(peerId);
    try {
      _log('host: negotiating peer connection to $peerId');
      final pc = await createPeerConnection(_iceConfig);
      final peer = _Peer(pc);
      _peers[peerId] = peer;

      pc.onIceCandidate = (RTCIceCandidate c) {
        if (c.candidate == null) return;
        _signalTo(peerId, {
          'type': 'rtc_ice',
          'candidate': {
            'candidate': c.candidate,
            'sdpMid': c.sdpMid,
            'sdpMLineIndex': c.sdpMLineIndex,
          },
        });
      };
      pc.onConnectionState =
          (s) => _log('host: pc($peerId) state → $s');

      final ch = await pc.createDataChannel(
        'audio',
        RTCDataChannelInit()..ordered = true, // reliable + ordered file transfer
      );
      peer.channel = ch;
      ch.onDataChannelState = (RTCDataChannelState s) {
        _log('host: dc($peerId) state → $s');
        if (s == RTCDataChannelState.RTCDataChannelOpen) {
          final bytes = _hostBytes;
          if (bytes != null) {
            unawaited(_streamTrackToPeer(peer, bytes, _hostMime()));
          }
        }
      };

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      _signalTo(peerId, {'type': 'rtc_offer', 'sdp': offer.sdp});
      _log('host: sent offer to $peerId');
    } catch (e) {
      _log('host: connect-to-peer error: $e');
      onError?.call(e);
    }
  }

  /// Stream one track to a single peer over its data channel, self-delimited:
  /// a `track_start` marker (resets the listener's buffer), the raw bytes in
  /// small ordered frames, then `eos` (listener plays). All on the reliable
  /// channel, so ordering — and thus framing — is guaranteed.
  Future<void> _streamTrackToPeer(_Peer p, Uint8List bytes, String mime) async {
    final ch = p.channel;
    if (ch == null) return;
    // Claim this peer's stream; any earlier in-flight stream sees a newer epoch
    // and bails out mid-loop. The listener's `track_start` clears the buffer, so
    // even a straggler frame from the old stream is discarded harmlessly.
    final epoch = ++p.streamEpoch;
    try {
      _log('host: streaming ${bytes.length} bytes ($mime)');
      ch.send(RTCDataChannelMessage(jsonEncode({'t': 'track_start', 'mime': mime})));
      // 16 KB frames stay under every WebRTC implementation's reliable
      // single-message limit (browsers included), so the web PWA interops too.
      const chunkSize = 16 * 1024;
      for (var offset = 0; offset < bytes.length; offset += chunkSize) {
        if (p.streamEpoch != epoch) return; // superseded by a newer track
        final end = (offset + chunkSize < bytes.length)
            ? offset + chunkSize
            : bytes.length;
        ch.send(RTCDataChannelMessage.fromBinary(
            Uint8List.sublistView(bytes, offset, end)));
        // Pace so we don't overrun the channel's send buffer or freeze the UI.
        await Future<void>.delayed(const Duration(milliseconds: 4));
      }
      if (p.streamEpoch != epoch) return; // don't terminate a superseded stream
      // Stamp the host's exact position + play state at the moment the transfer
      // finished, so the listener resumes in sync without waiting on a separate
      // WS play/position message (which may not arrive if the host is paused).
      ch.send(RTCDataChannelMessage(jsonEncode({
        't': 'eos',
        'pos': player.position.inMilliseconds,
        'playing': player.playing,
      })));
      _log('host: sent eos');
    } catch (e) {
      _log('host: stream error: $e');
      onError?.call(e);
    }
  }

  /// Stream a track to every connected peer (1 today; N in a room).
  void _streamTrackToAllPeers(Uint8List bytes, String mime) {
    for (final p in _peers.values) {
      if (p.channel != null) unawaited(_streamTrackToPeer(p, bytes, mime));
    }
  }

  Future<void> _closePeer(int peerId) async {
    final p = _peers.remove(peerId);
    if (p == null) return;
    try {
      await p.channel?.close();
    } catch (_) {}
    try {
      await p.pc.close();
    } catch (_) {}
  }

  /// LISTENER: answer the host's offer — build the peer connection, wire the
  /// inbound data channel, and send the answer back. Replaces any stale one.
  Future<void> _listenerAnswer(int hostId, String? sdp) async {
    // Drop stale ICE from any prior offer SYNCHRONOUSLY, before the first await,
    // so candidates that trickle in for THIS offer (they arrive right after it)
    // queue into a clean list and survive until the remote SDP is applied.
    _lPendingIce.clear();
    _lRemoteSet = false;
    await _closeListenerPc();
    try {
      _log('listener: got offer from $hostId — answering');
      final pc = await createPeerConnection(_iceConfig);
      _lpc = pc;

      pc.onIceCandidate = (RTCIceCandidate c) {
        if (c.candidate == null) return;
        _signalTo(hostId, {
          'type': 'rtc_ice',
          'candidate': {
            'candidate': c.candidate,
            'sdpMid': c.sdpMid,
            'sdpMLineIndex': c.sdpMLineIndex,
          },
        });
      };
      pc.onConnectionState = (s) => _log('listener: pc state → $s');
      pc.onDataChannel = (RTCDataChannel ch) => _bindListenerChannel(ch);

      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      _lRemoteSet = true;
      await _drainIce(pc, _lPendingIce);
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      _signalTo(hostId, {'type': 'rtc_answer', 'sdp': answer.sdp});
      _log('listener: sent answer to $hostId');
    } catch (e) {
      _log('listener: answer error: $e');
      onError?.call(e);
    }
  }

  /// LISTENER: the host's audio data channel arrived — reset our buffer on
  /// `track_start`, accumulate binary frames, and play on `eos`.
  void _bindListenerChannel(RTCDataChannel ch) {
    _lchan = ch;
    _log('listener: audio data channel bound');
    ch.onMessage = (RTCDataChannelMessage m) async {
      if (m.isBinary) {
        _incoming.add(m.binary);
        return;
      }
      try {
        final j = jsonDecode(m.text) as Map<String, dynamic>;
        switch (j['t']) {
          case 'track_start':
            _log('listener: track_start');
            final mime = j['mime'];
            if (mime is String) _incomingMime = mime;
            _incoming.clear();
            _listenerStarted = false;
            try {
              await player.stop();
            } catch (_) {}
            break;
          case 'eos':
            _log('listener: eos — buffered ${_incoming.length} bytes');
            // The host stamped its position + play state on the terminator.
            final pos = j['pos'];
            if (pos is int) _hostPositionMs = pos;
            final playing = j['playing'];
            if (playing is bool) _hostPlaying = playing;
            await _startListenerPlayback(autoplay: true);
            break;
        }
      } catch (_) {}
    };
  }

  Future<void> _closeListenerPc() async {
    try {
      await _lchan?.close();
    } catch (_) {}
    _lchan = null;
    try {
      await _lpc?.close();
    } catch (_) {}
    _lpc = null;
    _lRemoteSet = false;
    // NOTE: _lPendingIce is intentionally NOT cleared here — _listenerAnswer
    // clears it synchronously at its start, so candidates that arrive for the
    // new offer while this close is still awaiting aren't wiped.
  }

  /// Inbound WebRTC signaling (both roles). Host handles answer/ice from each
  /// listener; listener handles offer/ice from the host.
  Future<void> _handleSignaling(String type, Map<String, dynamic> msg) async {
    final from = _asInt(msg['from']);
    if (from == null) return;
    if (role == LiveRole.host) {
      final peer = _peers[from];
      if (peer == null) return;
      if (type == 'rtc_answer') {
        try {
          await peer.pc.setRemoteDescription(
              RTCSessionDescription(msg['sdp'] as String?, 'answer'));
          peer.remoteSet = true;
          await _drainIce(peer.pc, peer.pendingIce);
        } catch (e) {
          onError?.call(e);
        }
      } else if (type == 'rtc_ice') {
        await _addOrQueueIce(
            peer.pc, peer.remoteSet, peer.pendingIce, msg['candidate']);
      }
    } else if (role == LiveRole.listener) {
      if (type == 'rtc_offer') {
        await _listenerAnswer(from, msg['sdp'] as String?);
      } else if (type == 'rtc_ice') {
        // Queue even if the connection isn't up yet (the offer may still be
        // negotiating) — drained once the remote SDP is set in _listenerAnswer.
        await _addOrQueueIce(_lpc, _lRemoteSet, _lPendingIce, msg['candidate']);
      }
    }
  }

  Future<void> _addOrQueueIce(RTCPeerConnection? pc, bool remoteSet,
      List<RTCIceCandidate> pending, dynamic c) async {
    if (c is! Map) return;
    final cand = RTCIceCandidate(
      c['candidate'] as String?,
      c['sdpMid'] as String?,
      (c['sdpMLineIndex'] as num?)?.toInt(),
    );
    if (pc != null && remoteSet) {
      try {
        await pc.addCandidate(cand);
      } catch (_) {}
    } else {
      // Queue until the connection exists AND its remote SDP is applied.
      pending.add(cand);
    }
  }

  Future<void> _drainIce(
      RTCPeerConnection pc, List<RTCIceCandidate> pending) async {
    for (final c in pending) {
      try {
        await pc.addCandidate(c);
      } catch (_) {}
    }
    pending.clear();
  }

  Future<void> _closeAllPeers() async {
    for (final id in _peers.keys.toList()) {
      await _closePeer(id);
    }
    await _closeListenerPc();
  }

  int? _asInt(dynamic v) => v is int ? v : int.tryParse(v?.toString() ?? '');

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
    await _closeListenerPc();
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
    // The old peer connection died with the socket; drop it so the host's
    // fresh offer (triggered by our rejoin) negotiates a clean one.
    await _closeListenerPc();
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
    // Drop stale peer connections; each still-present listener is renegotiated
    // from scratch when the server re-delivers its `peer_joined` on reconnect.
    await _closeAllPeers();
    role = LiveRole.host;
    await _openSocket(sid, myUserId, token);
    // The re-negotiation + re-stream is triggered by the server's `peer_joined`
    // (handled below). Re-announce metadata now so the listener's title/mime is
    // refreshed even before the audio channel comes back up.
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
    try {
      _log('listener: starting playback (${bytes.length} bytes, '
          '$_incomingMime, hostPlaying=$_hostPlaying)');
      await player.setAudioSource(
          BytesAudioSource(bytes, contentType: _incomingMime));
      // Resume at the host's position, and only play if the host is playing — so
      // joining (or re-buffering after a reconnect) while the host is paused, or
      // mid-track, lands us in sync instead of blasting from 0:00.
      if (_hostPositionMs > 0) {
        try {
          await player.seek(Duration(milliseconds: _hostPositionMs));
        } catch (_) {}
      }
      if (autoplay && _hostPlaying) unawaited(player.play());
    } catch (e) {
      // A playback failure was previously silent — surface it so the listener
      // screen can show an error instead of sitting mute at 00:00.
      _listenerStarted = false;
      _log('listener: playback failed: $e');
      onError?.call(e);
    }
  }

  // ---------------------------------------------------------------------------
  // SOCKET
  // ---------------------------------------------------------------------------
  Future<void> _openSocket(String sessionId, int myUserId, String token) async {
    _myUserId = myUserId;
    final wsBase = await AppConfig.wsBaseUrl; // wss://aluta.ozilane.com (release)
    final uri = Uri.parse('$wsBase/live/ws/$sessionId?token=$token&user_id=$myUserId');
    final ch = WebSocketChannel.connect(uri);
    // WebSocketChannel.connect is LAZY: it returns immediately and connects in
    // the background. Without awaiting readiness, callers (startHost /
    // joinAsListener / the reconnect paths) proceed as if connected, so a
    // failed or blocked connect just hangs on "Connecting…" — the error only
    // surfaces later, out-of-band, via onError, and onDone can't tell a failed
    // connect from a clean close. Awaiting .ready makes the failure throw HERE,
    // where those callers already catch it and show a real "couldn't connect"
    // state; the timeout bounds a dead network instead of waiting forever.
    try {
      await ch.ready.timeout(const Duration(seconds: 10));
    } catch (e) {
      try {
        await ch.sink.close();
      } catch (_) {}
      rethrow; // startHost/joinAsListener/reconnect* surface this to the UI.
    }
    _channel = ch;
    _socketSub = ch.stream.listen(
      _onSocketMessage,
      onError: (e) => onError?.call(e),
      onDone: () => onEnded?.call('disconnected'),
      cancelOnError: false,
    );
  }

  void _log(String m) => debugPrint('[live] $m');

  void _onSocketMessage(dynamic message) {
    // Audio is peer-to-peer now — the socket carries only JSON control. Ignore
    // any stray binary frame so it can never splice into the P2P audio buffer.
    if (message is! String) return;
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(message) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    // Fire-and-forget — do NOT serialize handling behind a future chain. A slow
    // WebRTC offer/answer on one platform must never block the sync clock or the
    // queue broadcast behind it. ICE that arrives before the peer connection is
    // ready is queued (see _addOrQueueIce), so out-of-order handling is safe.
    _handleControl(msg);
  }

  Future<void> _handleControl(Map<String, dynamic> msg) async {
    final type = msg['type'] as String?;
    onEvent?.call(msg);

    // WebRTC signaling is peer-addressed and handled the same way regardless of
    // role, so dispatch it before the host/listener split.
    if (type == 'rtc_offer' || type == 'rtc_answer' || type == 'rtc_ice') {
      await _handleSignaling(type!, msg);
      return;
    }

    // Host: the one inbound event it acts on is a listener joining — that's when
    // it (re)negotiates the P2P audio channel and streams the song, so join
    // timing doesn't matter (a late/rejoining listener still gets the audio).
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
        // Announce the current track as a `track_change` over the socket so the
        // listener screen updates its title and clears any "Connection lost"
        // state. The actual buffer reset + audio now ride the P2P data channel
        // (track_start → bytes → eos), set up just below.
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
        // (Re)establish the peer-to-peer audio channel with this listener. When
        // it opens, the current track is streamed over it. This replaces the
        // old server-relayed byte stream and also covers reconnects (a fresh
        // peer connection is negotiated each time).
        final peerId = _asInt((msg['data'] as Map?)?['user_id']);
        if (peerId != null) {
          unawaited(_hostConnectToPeer(peerId));
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
        // Tear down the dead peer connection; a rejoin negotiates a fresh one.
        final peerId = _asInt((msg['data'] as Map?)?['user_id']);
        if (peerId != null) unawaited(_closePeer(peerId));
      }
      return;
    }

    switch (type) {
      case 'session_state':
        final data = msg['data'] as Map<String, dynamic>?;
        final track = data?['track'] as Map<String, dynamic>?;
        if (track?['mime'] is String) _incomingMime = track!['mime'] as String;
        // Seed the host's transport state so the first `eos` resumes in sync.
        if (data?['is_playing'] is bool) _hostPlaying = data!['is_playing'] as bool;
        final sp = data?['position_ms'];
        if (sp is int) _hostPositionMs = sp;
        break;
      case 'host_reconnecting':
        // The host's socket dropped (likely a glitch). Hold playback where it
        // is and wait — the host has a grace window to come back, after which it
        // renegotiates the peer connection and re-streams the current track over
        // the data channel to resume us. If the host never returns, the server
        // sends 'end'.
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
        // UI only now: update the title/mime shown on screen. The actual buffer
        // reset + playback ride the P2P data channel (track_start → bytes →
        // eos), so we must NOT clear the buffer here — a socket message could
        // race the data-channel bytes and drop them.
        final track = msg['track'] as Map<String, dynamic>?;
        if (track?['mime'] is String) _incomingMime = track!['mime'] as String;
        _setCurrentTitle(track?['title'] as String?);
        break;
      case 'play':
        // Always remember the host is playing (drives autoplay on the next
        // `eos`), even before our own buffer is ready.
        _hostPlaying = true;
        final playPos = msg['position_ms'];
        if (playPos is int) _hostPositionMs = playPos;
        // Ignore the actual transport until the full song is buffered (started
        // via 'eos'); otherwise playback would begin from a partial buffer.
        if (!_listenerStarted) break;
        if (playPos is int) await player.seek(Duration(milliseconds: playPos));
        unawaited(player.play()); // future resolves on track END — don't await
        break;
      case 'pause':
        _hostPlaying = false;
        final pausePos = msg['position_ms'];
        if (pausePos is int) _hostPositionMs = pausePos;
        if (!_listenerStarted) break;
        if (pausePos is int) await player.seek(Duration(milliseconds: pausePos));
        await player.pause();
        break;
      case 'seek':
      case 'position':
        final pos = msg['position_ms'];
        if (pos is int) {
          _hostPositionMs = pos;
          if (_listenerStarted) {
            // Only correct if we've drifted noticeably (>1.5s) to avoid stutter.
            final drift = (player.position.inMilliseconds - pos).abs();
            if (drift > 1500) await player.seek(Duration(milliseconds: pos));
          }
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
    // Close every peer connection + data channel (host peers and listener side).
    await _closeAllPeers();
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

/// Host-side per-listener WebRTC state: the peer connection, its outbound audio
/// data channel, and ICE candidates queued until the remote SDP is applied.
/// One of these per listener makes the 1:1 flow trivially extend to a room.
class _Peer {
  _Peer(this.pc);
  final RTCPeerConnection pc;
  RTCDataChannel? channel;
  bool remoteSet = false;
  final List<RTCIceCandidate> pendingIce = [];
  // Bumped every time a new track stream starts for this peer, so an in-flight
  // stream (which yields between frames) aborts instead of interleaving its
  // frames/eos with the newer track's on the same channel.
  int streamEpoch = 0;
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
