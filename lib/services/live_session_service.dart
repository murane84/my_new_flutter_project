import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../utils/app_config.dart';

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

class LiveSessionController {
  LiveSessionController({this.onEvent, this.onEnded, this.onError});

  /// Fired for every control event received (`meta`, `play`, `pause`, `seek`,
  /// `peer_joined`, `peer_left`, `session_state`, ...). Use it to update UI.
  final void Function(Map<String, dynamic> event)? onEvent;

  /// Fired once when the session ends (host ended / host left / you left).
  final void Function(String reason)? onEnded;

  /// Fired on any transport error.
  final void Function(Object error)? onError;

  /// Shared player. For the host it plays the local bytes; for the listener it
  /// plays the streamed-in bytes. Bind your seekbar/controls to this.
  final AudioPlayer player = AudioPlayer();

  WebSocketChannel? _channel;
  StreamSubscription? _socketSub;
  StreamSubscription? _posSub;
  StreamSubscription? _playingSub;

  LiveRole? role;
  String? sessionId;

  // Listener-side in-memory buffer for the incoming song.
  final BytesBuilder _incoming = BytesBuilder(copy: false);
  String _incomingMime = 'audio/mpeg';
  bool _listenerStarted = false;

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
  }) async {
    role = LiveRole.host;

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

    // 3) Start local playback from the in-memory bytes.
    await player.setAudioSource(BytesAudioSource(audioBytes, contentType: mime));
    _broadcastHostPlayback(); // mirror play/pause/seek/position to the listener

    // 4) Announce metadata, then stream the bytes, then signal end-of-stream.
    _sendControl({
      'type': 'meta',
      'track': {
        'title': title,
        'artist': artist,
        'duration_ms': durationMs,
        'mime': mime,
      },
    });
    await player.play();
    _sendControl({'type': 'play', 'position_ms': 0});

    // Stream the audio in chunks without blocking the UI thread.
    unawaited(_streamBytesToListener(audioBytes));

    return sessionId!;
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

  Future<void> _startListenerPlayback({bool autoplay = true}) async {
    if (_listenerStarted) return;
    _listenerStarted = true;
    final bytes = _incoming.toBytes();
    if (bytes.isEmpty) return;
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

    if (role != LiveRole.listener) return; // host doesn't react to its own echoes

    switch (type) {
      case 'session_state':
        final track = (msg['data']?['track']) as Map<String, dynamic>?;
        if (track?['mime'] is String) _incomingMime = track!['mime'] as String;
        break;
      case 'meta':
        final track = msg['track'] as Map<String, dynamic>?;
        if (track?['mime'] is String) _incomingMime = track!['mime'] as String;
        break;
      case 'eos':
        // All bytes received — start playback from the in-memory buffer.
        await _startListenerPlayback(autoplay: true);
        break;
      case 'play':
        await _startListenerPlayback(autoplay: false);
        final pos = msg['position_ms'];
        if (pos is int) await player.seek(Duration(milliseconds: pos));
        await player.play();
        break;
      case 'pause':
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
    await _posSub?.cancel();
    await _playingSub?.cancel();
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
