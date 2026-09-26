import 'dart:async';
import 'dart:convert';
import 'dart:math';
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
import 'ice_config.dart';
import 'live_audio_cache.dart';

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
    this.isRoom = false,
  });

  final LiveSessionController controller;
  final LiveRole role;
  final String peerName;
  String title;
  final String token;
  final int myUserId;
  // True when this is an OPEN "Listening Room" I'm hosting (vs a 1:1 session),
  // so the Live Room card can show "your room is live".
  final bool isRoom;

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
  LiveTrack({
    required this.bytes,
    required this.title,
    this.mime = 'audio/mpeg',
    this.contributor,
  });
  final Uint8List bytes;
  final String title;
  final String mime;
  // Set when a listener contributed this track (their display name); null for
  // the host's own tracks. Drives the "added by X" attribution in the queue.
  final String? contributor;

  // Content fingerprint of [bytes] (lazy + cached). Used to offer/skip transfers
  // so a listener that already holds this exact song plays it from its own cache
  // instead of waiting for the whole stream again.
  String? _hash;
  String get hash => _hash ??= liveTrackFingerprint(bytes);
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
    // Warm the persistent audio cache so cache hits (skip re-download) work from
    // the first track. Best-effort; never blocks session start.
    LiveAudioCache.instance.init();
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
  // ICE (STUN/TURN) is fetched from the server via IceConfig so TURN can be
  // swapped/renewed without an app rebuild (see ice_config.dart). This const is
  // only a STUN-only last resort if that fetch ever fails — cross-network needs
  // the TURN the server adds on top.
  static Future<Map<String, dynamic>> get _iceConfig => IceConfig.instance.servers();

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

  // ── prefetch / cache state ────────────────────────────────────────────────
  // Host: fingerprint of the current track's bytes, so we can OFFER it (by hash)
  // before streaming — a listener that already cached it skips the transfer.
  String? _hostHash;
  // Host: bumped on every track change so a stale scheduled prefetch (for the
  // previous track) never fires.
  int _prefetchGen = 0;
  // The union of content-hashes the OTHER side(s) already hold, learned from a
  // one-shot "manifest" each device sends when its data channel opens. On the
  // host this lets the "Add song" picker flag tracks the partner can start
  // instantly (zero transfer, via the have/need cache path). Best-effort and
  // purely advisory — an empty or stale set just means no ⚡ hints, never a bug.
  final Set<String> _peerInstantHashes = <String>{};
  // Listener: the hash to file the streamed song under once it fully arrives
  // (set on a cache MISS; cleared after caching on eos).
  String? _pendingCacheHash;
  // Listener: an in-flight PREFETCH transfer (a not-yet-current queue track the
  // host is pushing ahead), reassembled separately from the live audio buffer.
  bool _receivingPrefetch = false;
  final BytesBuilder _prefetchBuf = BytesBuilder(copy: false);
  String? _prefetchHash;
  // Listener's view of the host's transport, tracked from session_state / play /
  // pause / position so that when a freshly-buffered track's `eos` fires we
  // resume at the host's position and DON'T autoplay if the host is paused.
  bool _hostPlaying = true;
  int _hostPositionMs = 0;
  // Real-time (ms) that the FIRST byte of the listener's current buffer maps to.
  // 0 for a full-from-start transfer; >0 when the host trimmed the already-played
  // head and streamed only from its current position (MP3 fast-join, see
  // _streamTrackToPeer). The listener's player timeline is then offset by this,
  // so every real host position is translated by subtracting it (and displays
  // add it back). Kept at 0 for the host and for non-trimmed transfers, so the
  // full-file path behaves exactly as before.
  int _listenerBaseMs = 0;

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

  /// Repeat mode for the whole SESSION: 'off' | 'one' | 'all'. Shared by host
  /// and listener — either side can set it (see [setRepeatMode]); the host is
  /// authoritative for the queue and re-broadcasts so everyone stays in sync.
  String repeatMode = 'off';

  /// Fired when [repeatMode] changes (set locally or synced from the peer), so
  /// the music panel's repeat button refreshes for both sides.
  void Function()? onRepeatChanged;

  /// Shuffle for the whole SESSION. Like [repeatMode], shared by host and
  /// listener — either side can toggle it (see [setShuffle]) and the host is
  /// authoritative for what actually plays next. When on, [nextTrack] jumps to
  /// a random queue position instead of the next in order.
  bool shuffle = false;

  /// Fired when [shuffle] changes (set locally or synced from the peer).
  void Function()? onShuffleChanged;

  final Random _shuffleRand = Random();

  /// Title of the track playing live right now (host or listener). Held here —
  /// not only in the popup — so it survives the popup being minimised and so
  /// the music-panel console can always mirror the correct live title.
  String currentTitle = '';

  // Listener-side mirror of the host's queue (titles only — audio is never sent
  // until a track actually plays). Lets the listener SEE what the host queued
  // and know which one is current, exactly like the host does.
  final List<String> remoteQueueTitles = [];
  // Parallel to [remoteQueueTitles]: who contributed each entry (null = host's
  // own track). Lets a listener see "added by X" on the mirrored queue.
  final List<String?> remoteQueueBy = [];
  int remoteIndex = 0;

  /// Whether guests (listeners) may add songs to THIS room's queue. The host
  /// owns [allowContributions] and broadcasts it; each listener mirrors it into
  /// [remoteContribAllowed] to know whether to show its "Add a song" button.
  /// Off by default (Stage C: host opts in per room).
  bool allowContributions = false; // host's authoritative switch
  bool remoteContribAllowed = false; // listener's mirror of the host switch

  /// Fired when the contribution switch changes (host toggled it, or a listener
  /// synced it from the host), so the room UI refreshes.
  void Function()? onContribChanged;

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
      // Parallel attribution list (null for the host's own tracks) so listeners
      // can show "added by X" on contributed entries.
      'by': queue.map((t) => t.contributor).toList(),
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

    // 2) Common bring-up (socket, playback, EQ, meta, queue, play).
    await _beginHostPlayback(
      myUserId: myUserId,
      token: token,
      audioBytes: audioBytes,
      title: title,
      artist: artist,
      durationMs: durationMs,
      mime: mime,
      startPositionMs: startPositionMs,
    );
    return sessionId!;
  }

  /// Open an OPEN "Listening Room": like [startHost] but the server creates a
  /// drop-in room (POST /live/rooms) that the host's whole circle can join,
  /// instead of a single 1:1 invite. Returns the room's session id.
  Future<String> startRoom({
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
    // A room isn't a 1:1 conversation, so there's no per-friend history to log.
    _logReceiverId = null;
    _logConversationId = null;
    _sessionStartAt = DateTime.now();
    _hadListener = false;
    _outcomeLogged = false;

    final base = await AppConfig.baseUrl;
    final res = await http.post(
      Uri.parse('$base/live/rooms'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'track': {
          'title': title,
          'artist': artist,
          'duration_ms': durationMs,
          'mime': mime,
        },
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('Failed to create room: ${res.statusCode} ${res.body}');
    }
    sessionId = jsonDecode(res.body)['session_id'] as String;

    await _beginHostPlayback(
      myUserId: myUserId,
      token: token,
      audioBytes: audioBytes,
      title: title,
      artist: artist,
      durationMs: durationMs,
      mime: mime,
      startPositionMs: startPositionMs,
    );
    return sessionId!;
  }

  /// Shared host playback bring-up used by both [startHost] (1:1) and
  /// [startRoom] (open room). [sessionId] must already be set. Opens the session
  /// socket, starts local playback at [startPositionMs], applies the saved EQ,
  /// seeds the queue with the first track, and announces meta + play. The audio
  /// bytes are streamed to each peer only once they join (see `peer_joined`).
  Future<void> _beginHostPlayback({
    required int myUserId,
    required String token,
    required Uint8List audioBytes,
    required String title,
    String? artist,
    int? durationMs,
    required String mime,
    required int startPositionMs,
  }) async {
    await _openSocket(sessionId!, myUserId, token);

    await player.setAudioSource(BytesAudioSource(audioBytes, contentType: mime));
    if (startPositionMs > 0) {
      await player.seek(Duration(milliseconds: startPositionMs));
    }
    _broadcastHostPlayback(); // mirror play/pause/seek/position to listeners

    // Apply the host's saved equalizer to the live player AND remember it so it
    // can be mirrored to each listener.
    await _sendHostEq(alsoSend: false);

    // Announce metadata. The actual audio is streamed only once a listener
    // joins (see the `peer_joined` handling), so a late joiner still gets it.
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
    _hostHash = liveTrackFingerprint(audioBytes);
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
        // Respect the session repeat mode: one → replay; otherwise advance.
        if (repeatMode == 'one') {
          playIndex(currentIndex);
        } else {
          nextTrack();
        }
      }
    });
    _sendControl(meta);
    _setCurrentTitle(title);
    // Do NOT await: play()'s future completes only when the song ENDS.
    unawaited(player.play());
    _sendControl({'type': 'play', 'position_ms': startPositionMs});
    onQueueChanged?.call();
    _broadcastQueue();
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

  /// Set the SESSION repeat mode from EITHER side. Applies locally at once (so
  /// the button feels instant) then syncs: the host broadcasts it to everyone;
  /// a listener asks the host, who applies + re-broadcasts to confirm.
  void setRepeatMode(String mode) {
    if (mode != 'off' && mode != 'one' && mode != 'all') mode = 'off';
    repeatMode = mode;
    onRepeatChanged?.call();
    if (role == LiveRole.host) {
      _sendControl({'type': 'repeat', 'mode': mode});
    } else {
      _sendControl({'type': 'ctl', 'action': 'repeat', 'mode': mode});
    }
  }

  /// Toggle SESSION shuffle from EITHER side. Same sync shape as
  /// [setRepeatMode]: applies locally at once, then the host broadcasts and a
  /// listener asks the host (who applies + re-broadcasts to confirm).
  void setShuffle(bool on) {
    shuffle = on;
    onShuffleChanged?.call();
    if (role == LiveRole.host) {
      _sendControl({'type': 'shuffle', 'on': on});
    } else {
      _sendControl({'type': 'ctl', 'action': 'shuffle', 'on': on});
    }
  }

  /// HOST: allow or deny guests adding songs to the room's queue. Broadcast so
  /// every listener shows/hides its "Add a song" button. Off by default; the
  /// host opts in per room (Stage C). Contributed tracks land as up-next and the
  /// host can still remove any before they play.
  void setAllowContributions(bool on) {
    allowContributions = on;
    onContribChanged?.call();
    _sendControl({'type': 'contrib', 'on': on});
  }

  /// LISTENER: contribute a track into the room's queue by uploading its bytes
  /// to the host over our data channel (the host reassembles + enqueues it,
  /// attributed to [by]). Framed exactly like the host's outbound stream
  /// (contribute_start → binary frames → contribute_eos). No-op unless guest
  /// contributions are enabled and the channel is open.
  Future<bool> contributeTrack(Uint8List bytes, String title,
      {String mime = 'audio/mpeg', String? by}) async {
    if (role != LiveRole.listener) return false;
    if (!remoteContribAllowed) return false;
    final ch = _lchan;
    if (ch == null) return false;
    if (bytes.isEmpty || bytes.length > _maxContribBytes) return false;
    try {
      ch.send(RTCDataChannelMessage(jsonEncode({
        't': 'contribute_start',
        'title': title,
        'mime': mime,
        'by': ?by,
      })));
      const chunkSize = 16 * 1024;
      const framesPerBurst = 8;
      var sinceYield = 0;
      for (var offset = 0; offset < bytes.length; offset += chunkSize) {
        final end = (offset + chunkSize < bytes.length)
            ? offset + chunkSize
            : bytes.length;
        ch.send(RTCDataChannelMessage.fromBinary(
            Uint8List.sublistView(bytes, offset, end)));
        if (++sinceYield >= framesPerBurst) {
          sinceYield = 0;
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }
      ch.send(RTCDataChannelMessage(jsonEncode({'t': 'contribute_eos'})));
      return true;
    } catch (e) {
      onError?.call(e);
      return false;
    }
  }

  /// Pick the next queue index. Shuffle → a random OTHER entry (never the same
  /// track twice in a row when the queue has more than one). In order → the
  /// next entry, wrapping to 0 only when repeat=all.
  int _nextIndex() {
    final n = queue.length;
    if (n <= 1) return currentIndex + 1 < n ? currentIndex + 1 : -1;
    if (shuffle) {
      int pick = _shuffleRand.nextInt(n);
      if (pick == currentIndex) pick = (pick + 1) % n;
      return pick;
    }
    if (currentIndex + 1 < n) return currentIndex + 1;
    if (repeatMode == 'all') return 0;
    return -1;
  }

  /// Skip to the next queued track. Honours shuffle, and wraps to the top when
  /// repeat=all.
  Future<void> nextTrack() async {
    final next = _nextIndex();
    if (next >= 0) await playIndex(next);
  }

  /// Switch playback (host + listener) to queue entry [index].
  Future<void> playIndex(int index) async {
    if (index < 0 || index >= queue.length) return;
    _switchingTrack = true;
    currentIndex = index;
    final t = queue[index];
    _hostBytes = t.bytes;
    _hostHash = t.hash;
    // Abort any in-flight prefetch to every peer BEFORE we start this track's
    // live transfer, so a stray prefetch frame can never interleave with the
    // live audio on the reliable (ordered) channel.
    for (final p in _peers.values) {
      p.prefetchEpoch++;
    }
    final gen = ++_prefetchGen;
    _hostMeta = {
      'type': 'meta',
      'track': {'title': t.title, 'mime': t.mime},
    };
    try {
      await player.setAudioSource(
          BytesAudioSource(t.bytes, contentType: t.mime));
      // Tell the listener a new track is starting (UI title/clear "lost"), then
      // OFFER it by hash: a listener that already cached this exact song plays
      // it from its own copy instantly; only a miss triggers the byte stream.
      _sendControl({
        'type': 'track_change',
        'track': {'title': t.title, 'mime': t.mime},
      });
      if (_peerPresent) {
        _offerTrackToAllPeers();
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
    // Once the live transfer has surely settled, quietly pre-push the NEXT
    // queued track to each listener so advancing to it is instant.
    Future<void>.delayed(const Duration(milliseconds: 3500), () {
      if (_prefetchGen == gen) _maybePrefetch();
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
      final pc = await createPeerConnection(await _iceConfig);
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
      // Listener → host messages over this same channel: guest contributions
      // AND the cache-control replies (have / need / prefetch_need).
      ch.onMessage = (RTCDataChannelMessage m) => _onPeerInbound(peer, m);
      ch.onDataChannelState = (RTCDataChannelState s) {
        _log('host: dc($peerId) state → $s');
        if (s == RTCDataChannelState.RTCDataChannelOpen) {
          // Tell this listener which songs we can serve instantly (and it will
          // reply with its own) so the picker can flag zero-transfer choices.
          _sendManifest(peer.channel);
          // Offer the current track by hash instead of blindly streaming: the
          // listener plays from its cache if it already has this exact song
          // (instant — a huge win on re-joins), else it asks us to stream.
          _offerTrackToPeer(peer);
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
    p.liveStreaming = true; // block prefetch from interleaving while we stream
    try {
      // Fast-join (#1): for an MP3, once the host is a few seconds into the
      // track, skip streaming the already-played head — send only from ~the
      // current position to the end. The listener plays that tail; the `base_ms`
      // offset keeps its timeline and sync correct. This roughly halves (or
      // better) what a late joiner must pull over a slow relay before they hear
      // anything. Container formats (M4A/AAC) can't start mid-file, so they —
      // and early joins — stream full-from-0 exactly as before.
      int startByte = 0;
      int baseMs = 0;
      final durMs = player.duration?.inMilliseconds ?? 0;
      final posMs = player.position.inMilliseconds;
      const trimAfterMs = 8000; // only worth trimming once we're into the song
      if (_isMp3(mime) &&
          durMs > 0 &&
          posMs > trimAfterMs &&
          bytes.length > 96 * 1024) {
        final frac = (posMs / durMs).clamp(0.0, 0.95);
        // Back off ~48 KB before the estimated offset so the decoder has clean
        // frames to resync on plus a small lead-in, then map that byte to a
        // real-time base.
        var off = (frac * bytes.length).floor() - 48 * 1024;
        if (off < 0) off = 0;
        startByte = off;
        baseMs = ((startByte / bytes.length) * durMs).floor();
      }

      _log('host: streaming ${bytes.length - startByte}/${bytes.length} bytes '
          '($mime)${baseMs > 0 ? ' from ${baseMs}ms' : ''}');
      ch.send(RTCDataChannelMessage(
          jsonEncode({'t': 'track_start', 'mime': mime, 'base_ms': baseMs})));
      // 16 KB frames stay under every WebRTC implementation's reliable
      // single-message limit (browsers included), so the web PWA interops too.
      // Faster pacing (#2): send in short bursts and yield only BETWEEN bursts.
      // The old fixed 4 ms sleep PER 16 KB frame capped throughput at ~4 MB/s
      // even on a fast/LAN link; a burst yield keeps the UI responsive and lets
      // the channel drain while pushing bytes far faster. Local buffering stays
      // bounded for song-sized files.
      const chunkSize = 16 * 1024;
      const framesPerBurst = 8; // ~128 KB between yields
      var sinceYield = 0;
      for (var offset = startByte; offset < bytes.length; offset += chunkSize) {
        if (p.streamEpoch != epoch) return; // superseded by a newer track
        final end = (offset + chunkSize < bytes.length)
            ? offset + chunkSize
            : bytes.length;
        ch.send(RTCDataChannelMessage.fromBinary(
            Uint8List.sublistView(bytes, offset, end)));
        if (++sinceYield >= framesPerBurst) {
          sinceYield = 0;
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
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
    } finally {
      // Only the CURRENT stream clears the flag — a superseded one mustn't clear
      // the flag its replacement just set.
      if (p.streamEpoch == epoch) p.liveStreaming = false;
    }
  }

  // ── offer / prefetch (cache-aware transfer) ───────────────────────────────
  /// Offer the CURRENT track (by hash) to every connected peer, so a listener
  /// that already cached it plays from its copy instead of re-downloading.
  void _offerTrackToAllPeers() {
    for (final p in _peers.values) {
      if (p.channel != null) _offerTrackToPeer(p);
    }
  }

  /// Content-hashes the other side already holds (learned from its manifest), so
  /// the "Add song" picker can flag which tracks a partner can start instantly.
  /// A read-only snapshot; empty until the first manifest arrives.
  Set<String> get peerInstantHashes => Set<String>.of(_peerInstantHashes);

  /// Announce which songs THIS device can play with zero transfer, so the other
  /// side's picker can flag them. Sent once per channel as it opens; capped by
  /// [LiveAudioCache.knownKeys] so the control message stays small. Best-effort.
  void _sendManifest(RTCDataChannel? ch) {
    if (ch == null) return;
    try {
      final hashes = LiveAudioCache.instance.knownKeys();
      ch.send(RTCDataChannelMessage(
          jsonEncode({'t': 'manifest', 'hashes': hashes})));
    } catch (_) {}
  }

  /// Fold a peer's manifest into our instant-playable set (advisory only).
  void _ingestManifest(Map<String, dynamic> j) {
    final raw = j['hashes'];
    if (raw is! List) return;
    for (final h in raw) {
      if (h is String && h.isNotEmpty) _peerInstantHashes.add(h);
    }
  }

  /// Offer the current track to one peer: send its hash + the host's current
  /// transport, then wait briefly for `have`/`need`. If neither arrives (an old
  /// client, or a lost reply), fall back to streaming so playback never stalls.
  void _offerTrackToPeer(_Peer p) {
    final ch = p.channel;
    final bytes = _hostBytes;
    if (ch == null || bytes == null) return;
    final hash = _hostHash ??= liveTrackFingerprint(bytes);
    p.pendingOfferHash = hash;
    final epoch = ++p.offerEpoch;
    try {
      ch.send(RTCDataChannelMessage(jsonEncode({
        't': 'track_offer',
        'hash': hash,
        'mime': _hostMime(),
        'pos': player.position.inMilliseconds,
        'playing': player.playing,
      })));
    } catch (_) {}
    Future<void>.delayed(const Duration(milliseconds: 900), () {
      // Still unanswered for THIS offer → stream it the old way.
      if (p.offerEpoch == epoch && p.pendingOfferHash == hash) {
        p.pendingOfferHash = null;
        final b = _hostBytes;
        if (b != null && p.channel != null) {
          unawaited(_streamTrackToPeer(p, b, _hostMime()));
        }
      }
    });
  }

  /// Pre-push the NEXT queued track to each peer during idle time, so advancing
  /// to it is instant. Best-effort; a listener that already has it stays silent.
  void _maybePrefetch() {
    if (role != LiveRole.host) return;
    final ni = currentIndex + 1;
    if (ni < 0 || ni >= queue.length) return;
    final t = queue[ni];
    for (final p in _peers.values) {
      if (p.channel != null) _prefetchToPeer(p, t);
    }
  }

  void _prefetchToPeer(_Peer p, LiveTrack t) {
    final ch = p.channel;
    if (ch == null) return;
    try {
      // Offer only; the listener replies `prefetch_need` ONLY if it lacks it.
      ch.send(RTCDataChannelMessage(jsonEncode({
        't': 'prefetch_offer',
        'hash': t.hash,
        'mime': t.mime,
      })));
    } catch (_) {}
  }

  /// Stream a prefetch track to one peer (framed prefetch_start → binary →
  /// prefetch_eos, kept distinct from live audio). Aborts the instant a track
  /// change bumps this peer's prefetch epoch, so it can never collide with the
  /// live stream on the ordered channel.
  Future<void> _streamPrefetchToPeer(_Peer p, LiveTrack t) async {
    final ch = p.channel;
    if (ch == null || p.liveStreaming) return;
    final epoch = ++p.prefetchEpoch;
    try {
      ch.send(RTCDataChannelMessage(jsonEncode({
        't': 'prefetch_start',
        'hash': t.hash,
        'mime': t.mime,
      })));
      final bytes = t.bytes;
      const chunkSize = 16 * 1024;
      const framesPerBurst = 4; // gentler than live — this is background
      var sinceYield = 0;
      for (var offset = 0; offset < bytes.length; offset += chunkSize) {
        if (p.prefetchEpoch != epoch) return; // aborted by a track change
        final end = (offset + chunkSize < bytes.length)
            ? offset + chunkSize
            : bytes.length;
        ch.send(RTCDataChannelMessage.fromBinary(
            Uint8List.sublistView(bytes, offset, end)));
        if (++sinceYield >= framesPerBurst) {
          sinceYield = 0;
          await Future<void>.delayed(const Duration(milliseconds: 3));
        }
      }
      if (p.prefetchEpoch != epoch) return;
      ch.send(RTCDataChannelMessage(jsonEncode({
        't': 'prefetch_eos',
        'hash': t.hash,
      })));
    } catch (_) {}
  }

  LiveTrack? _trackByHash(String hash) {
    for (final t in queue) {
      if (t.hash == hash) return t;
    }
    return null;
  }

  // A single guest contribution can't exceed this (keeps one listener from
  // flooding the room over a relay). ~20 MB comfortably covers a full song.
  static const int _maxContribBytes = 20 * 1024 * 1024;

  /// HOST: inbound from a listener over its data channel. Binary is only ever a
  /// guest contribution upload; text is either a contribution marker
  /// (contribute_start/eos) or a cache-control reply (have / need /
  /// prefetch_need). Per-peer buffers live on [_Peer] so concurrent uploads
  /// don't interleave.
  void _onPeerInbound(_Peer p, RTCDataChannelMessage m) {
    if (m.isBinary) {
      if (!p.contribbing) return;
      p.contribBytes += m.binary.length;
      if (p.contribBytes > _maxContribBytes) {
        // Overflowed the cap — abandon this contribution quietly.
        p.contribbing = false;
        p.contribChunks.clear();
        p.contribBytes = 0;
      } else {
        p.contribChunks.add(m.binary);
      }
      return;
    }
    try {
      final j = jsonDecode(m.text) as Map<String, dynamic>;
      switch (j['t']) {
        case 'contribute_start':
          if (!allowContributions) return; // guests aren't allowed right now
          p.contribbing = true;
          p.contribChunks.clear();
          p.contribBytes = 0;
          p.contribTitle = (j['title'] as String?)?.trim();
          p.contribMime = (j['mime'] as String?) ?? 'audio/mpeg';
          p.contribBy = (j['by'] as String?)?.trim();
          break;
        case 'contribute_eos':
          if (!p.contribbing) return;
          p.contribbing = false;
          final total = p.contribBytes;
          if (total <= 0) {
            p.contribChunks.clear();
            return;
          }
          final bytes = Uint8List(total);
          var off = 0;
          for (final c in p.contribChunks) {
            bytes.setRange(off, off + c.length, c);
            off += c.length;
          }
          p.contribChunks.clear();
          p.contribBytes = 0;
          final title = (p.contribTitle?.isNotEmpty ?? false)
              ? p.contribTitle!
              : 'A guest track';
          final by =
              (p.contribBy?.isNotEmpty ?? false) ? p.contribBy! : 'a guest';
          unawaited(addTrack(LiveTrack(
            bytes: bytes,
            title: title,
            mime: p.contribMime ?? 'audio/mpeg',
            contributor: by,
          )));
          liveHostNotify?.call('$by added "$title" to the queue');
          break;
        case 'have':
          // The listener already had this song cached and is playing from it —
          // cancel our pending offer so we don't also stream it.
          if ((j['hash'] ?? '').toString() == p.pendingOfferHash) {
            p.pendingOfferHash = null;
            p.offerEpoch++;
          }
          break;
        case 'need':
          {
            // The listener lacks it → stream now (offer fallback cancelled).
            final h = (j['hash'] ?? '').toString();
            p.pendingOfferHash = null;
            p.offerEpoch++;
            final bytes = _hostBytes;
            if (bytes != null && h == _hostHash) {
              unawaited(_streamTrackToPeer(p, bytes, _hostMime()));
            }
          }
          break;
        case 'prefetch_need':
          {
            // The listener wants the offered NEXT track pre-cached → push it in
            // the background.
            final h = (j['hash'] ?? '').toString();
            final t = _trackByHash(h);
            // Never start a prefetch while a live transfer to this peer is still
            // going — it would interleave with the audio on the channel.
            if (t != null && !p.liveStreaming) {
              unawaited(_streamPrefetchToPeer(p, t));
            }
          }
          break;
        case 'manifest':
          // The listener told us which songs it can play instantly → fold into
          // the set the picker consults. Advisory only.
          _ingestManifest(j);
          break;
      }
    } catch (_) {}
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
      final pc = await createPeerConnection(await _iceConfig);
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
    // Announce our own cached songs to the host so its picker can flag the ones
    // we can start instantly. Best-effort, once per bind.
    _sendManifest(ch);
    ch.onMessage = (RTCDataChannelMessage m) async {
      if (m.isBinary) {
        // While a PREFETCH transfer is in progress its bytes go to a separate
        // buffer (destined for the cache, not the player); otherwise it's live
        // audio for the current track.
        if (_receivingPrefetch) {
          _prefetchBuf.add(m.binary);
        } else {
          _incoming.add(m.binary);
        }
        return;
      }
      try {
        final j = jsonDecode(m.text) as Map<String, dynamic>;
        switch (j['t']) {
          case 'track_offer':
            await _onTrackOffer(j);
            break;
          case 'track_start':
            _log('listener: track_start');
            // A live track begins — any partial prefetch is now moot; drop it.
            _receivingPrefetch = false;
            _prefetchBuf.clear();
            final mime = j['mime'];
            if (mime is String) _incomingMime = mime;
            // Real-time offset of the first byte we're about to receive: >0 when
            // the host trimmed the already-played head (MP3 fast-join), 0 for a
            // full-from-start transfer.
            final base = j['base_ms'];
            _listenerBaseMs = (base is int && base > 0) ? base : 0;
            _incoming.clear();
            _listenerStarted = false;
            try {
              await player.stop();
            } catch (_) {}
            break;
          case 'eos':
            final full = _incoming.toBytes();
            _log('listener: eos — buffered ${full.length} bytes');
            // The host stamped its position + play state on the terminator.
            final pos = j['pos'];
            if (pos is int) _hostPositionMs = pos;
            final playing = j['playing'];
            if (playing is bool) _hostPlaying = playing;
            // Cache the freshly-streamed song for instant reuse next time — but
            // only a FULL-from-start transfer (a trimmed fast-join tail is only
            // part of the song and must never be cached as the whole thing).
            final h = _pendingCacheHash;
            if (h != null && _listenerBaseMs == 0 && full.isNotEmpty) {
              unawaited(LiveAudioCache.instance.put(h, full));
            }
            _pendingCacheHash = null;
            await _startListenerPlayback(autoplay: true);
            break;
          case 'prefetch_offer':
            {
              final hash = (j['hash'] ?? '').toString();
              // Request it ONLY if we don't already hold it.
              if (hash.isNotEmpty && !LiveAudioCache.instance.hasSync(hash)) {
                try {
                  _lchan?.send(RTCDataChannelMessage(
                      jsonEncode({'t': 'prefetch_need', 'hash': hash})));
                } catch (_) {}
              }
            }
            break;
          case 'prefetch_start':
            _receivingPrefetch = true;
            _prefetchHash = (j['hash'] ?? '').toString();
            _prefetchBuf.clear();
            break;
          case 'prefetch_eos':
            {
              _receivingPrefetch = false;
              final h = _prefetchHash;
              final bytes = _prefetchBuf.toBytes();
              _prefetchBuf.clear();
              _prefetchHash = null;
              if (h != null && h.isNotEmpty && bytes.isNotEmpty) {
                unawaited(LiveAudioCache.instance.put(h, bytes));
              }
            }
            break;
          case 'manifest':
            // The host announced its instant-playable songs. We fold them in for
            // symmetry (harmless; the picker lives host-side).
            _ingestManifest(j);
            break;
        }
      } catch (_) {}
    };
  }

  /// LISTENER: the host offered the current track by hash. Play from our cache
  /// if we have it (instant, no transfer), else ask the host to stream it and
  /// file it away as it arrives.
  Future<void> _onTrackOffer(Map<String, dynamic> j) async {
    final hash = (j['hash'] ?? '').toString();
    final mime = (j['mime'] ?? 'audio/mpeg').toString();
    final pos = j['pos'];
    final playing = j['playing'];
    if (pos is int) _hostPositionMs = pos;
    if (playing is bool) _hostPlaying = playing;
    _incomingMime = mime;
    if (hash.isEmpty) return;
    final cached = await LiveAudioCache.instance.get(hash);
    final ch = _lchan;
    if (cached != null && cached.isNotEmpty) {
      _log('listener: cache HIT $hash (${cached.length}b) — instant play');
      try {
        ch?.send(RTCDataChannelMessage(jsonEncode({'t': 'have', 'hash': hash})));
      } catch (_) {}
      await _playListenerBytes(cached, mime);
    } else {
      _log('listener: cache MISS $hash — requesting stream');
      _pendingCacheHash = hash;
      try {
        ch?.send(RTCDataChannelMessage(jsonEncode({'t': 'need', 'hash': hash})));
      } catch (_) {}
    }
  }

  /// LISTENER: play a full song we already hold (from cache), synced to the
  /// host's current position — no waiting on a transfer.
  Future<void> _playListenerBytes(Uint8List bytes, String mime) async {
    if (bytes.isEmpty) return;
    _incoming.clear();
    _listenerBaseMs = 0; // a cached copy is always full-from-0
    _listenerStarted = true;
    try {
      await player.stop();
    } catch (_) {}
    try {
      await player.setAudioSource(BytesAudioSource(bytes, contentType: mime));
      if (_hostPositionMs > 0) {
        await _listenerSeekReal(_hostPositionMs);
      }
      if (_hostPlaying) unawaited(player.play());
    } catch (e) {
      _listenerStarted = false;
      _log('listener: cache playback failed: $e');
      onError?.call(e);
    }
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
    _listenerBaseMs = 0;
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
    _listenerBaseMs = 0;
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

  // ── Trimmed-join helpers (MP3 fast-join) ────────────────────────────────────
  static bool _isMp3(String? mime) {
    final m = (mime ?? '').toLowerCase();
    return m.contains('mpeg') || m.contains('mp3');
  }

  /// The REAL playback position, accounting for a trimmed listener buffer. Host
  /// (base 0) → the player's own position; a trimmed listener → offset back onto
  /// the full-song timeline. Use this for anything user-facing (progress bar).
  Duration get livePosition =>
      player.position + Duration(milliseconds: _listenerBaseMs);

  /// The REAL track duration (the whole song), even when the listener holds only
  /// a trimmed tail of it.
  Duration? get liveDuration {
    final d = player.duration;
    if (d == null) return null;
    return d + Duration(milliseconds: _listenerBaseMs);
  }

  int get _listenerRealPositionMs =>
      player.position.inMilliseconds + _listenerBaseMs;

  /// Seek the listener's player to a REAL host position, translated onto the
  /// (possibly trimmed) local buffer timeline.
  Future<void> _listenerSeekReal(int realMs) async {
    final local = realMs - _listenerBaseMs;
    try {
      await player.seek(Duration(milliseconds: local < 0 ? 0 : local));
    } catch (_) {}
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
      // mid-track, lands us in sync instead of blasting from 0:00. Translated
      // onto the local buffer timeline (a no-op when the buffer is full-from-0,
      // an offset when the host trimmed the already-played head).
      if (_hostPositionMs > _listenerBaseMs) {
        await _listenerSeekReal(_hostPositionMs);
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
        // And the current repeat mode + shuffle, so their buttons match from
        // the start.
        if (repeatMode != 'off') _sendControl({'type': 'repeat', 'mode': repeatMode});
        if (shuffle) _sendControl({'type': 'shuffle', 'on': true});
        // Catch a late joiner up on whether guest contributions are open.
        if (allowContributions) _sendControl({'type': 'contrib', 'on': true});
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
          case 'repeat':
            // Listener toggled repeat — apply authoritatively + re-broadcast.
            setRepeatMode((msg['mode'] as String?) ?? 'off');
            break;
          case 'shuffle':
            // Listener toggled shuffle — apply authoritatively + re-broadcast.
            setShuffle(msg['on'] == true);
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
        // Parallel attribution list (may be absent on older hosts).
        final by = (msg['by'] as List?)
            ?.map((e) => e?.toString())
            .toList();
        remoteQueueBy.clear();
        if (by != null) remoteQueueBy.addAll(by);
        final idx = msg['index'];
        if (idx is int) remoteIndex = idx;
        onQueueChanged?.call();
        break;
      case 'contrib':
        // Host toggled whether guests may add songs — mirror it so our
        // "Add a song" button appears/hides.
        remoteContribAllowed = msg['on'] == true;
        onContribChanged?.call();
        break;
      case 'repeat':
        // Host set the session repeat mode — mirror it so our button matches.
        final m = msg['mode'];
        if (m is String) {
          repeatMode = m;
          onRepeatChanged?.call();
        }
        break;
      case 'shuffle':
        // Host set session shuffle — mirror it so our button matches.
        shuffle = msg['on'] == true;
        onShuffleChanged?.call();
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
        if (playPos is int) await _listenerSeekReal(playPos);
        unawaited(player.play()); // future resolves on track END — don't await
        break;
      case 'pause':
        _hostPlaying = false;
        final pausePos = msg['position_ms'];
        if (pausePos is int) _hostPositionMs = pausePos;
        if (!_listenerStarted) break;
        if (pausePos is int) await _listenerSeekReal(pausePos);
        await player.pause();
        break;
      case 'seek':
      case 'position':
        final pos = msg['position_ms'];
        if (pos is int) {
          _hostPositionMs = pos;
          if (_listenerStarted) {
            // Only correct if we've drifted noticeably (>1.5s) to avoid stutter.
            // Compare on the REAL timeline (buffer may be trimmed).
            final drift = (_listenerRealPositionMs - pos).abs();
            if (drift > 1500) await _listenerSeekReal(pos);
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
    _listenerBaseMs = 0;
    // Reset cache/prefetch transfer state so a later session starts clean.
    _receivingPrefetch = false;
    _prefetchBuf.clear();
    _prefetchHash = null;
    _pendingCacheHash = null;
    _peerInstantHashes.clear();
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
  // True while a LIVE track transfer to this peer is in progress, so a prefetch
  // never starts mid-stream and interleave-corrupts the audio on the channel.
  bool liveStreaming = false;
  // Cache offer in flight for this peer: the hash we offered and an epoch that a
  // have/need reply (or a newer offer) supersedes, cancelling the stream-anyway
  // fallback timer.
  String? pendingOfferHash;
  int offerEpoch = 0;
  // Bumped whenever the host changes track, so an in-flight background PREFETCH
  // to this peer aborts before it can interleave with the new live stream.
  int prefetchEpoch = 0;
  // Inbound contribution (this guest → host upload) reassembly, per peer so
  // concurrent uploads from different guests never interleave.
  bool contribbing = false;
  final List<Uint8List> contribChunks = [];
  int contribBytes = 0;
  String? contribTitle;
  String? contribMime;
  String? contribBy;
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
