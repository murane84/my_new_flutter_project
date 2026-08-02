import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../services/live_session_service.dart';

/// Full-screen "Listen Together" session UI for both the host (DJ) and a listener.
///
/// Host: created with [LiveSessionScreen.host] — starts streaming the picked
/// song's bytes and controls play/pause/seek.
/// Listener: created with [LiveSessionScreen.listener] — joins and mirrors the
/// host's playback from the in-memory stream.
class LiveSessionScreen extends StatefulWidget {
  const LiveSessionScreen._({
    required this.role,
    required this.token,
    required this.myUserId,
    required this.peerName,
    this.receiverId,
    this.audioBytes,
    this.title,
    this.durationMs,
    this.sessionId,
    this.track,
  });

  final LiveRole role;
  final String token;
  final int myUserId;
  final String peerName;

  // Host-only
  final int? receiverId;
  final Uint8List? audioBytes;
  final String? title;
  final int? durationMs;

  // Listener-only
  final String? sessionId;
  final Map<String, dynamic>? track;

  factory LiveSessionScreen.host({
    required String token,
    required int myUserId,
    required int receiverId,
    required Uint8List audioBytes,
    required String title,
    required String peerName,
    int? durationMs,
  }) =>
      LiveSessionScreen._(
        role: LiveRole.host,
        token: token,
        myUserId: myUserId,
        peerName: peerName,
        receiverId: receiverId,
        audioBytes: audioBytes,
        title: title,
        durationMs: durationMs,
      );

  factory LiveSessionScreen.listener({
    required String token,
    required int myUserId,
    required String sessionId,
    required Map<String, dynamic> track,
    required String peerName,
  }) =>
      LiveSessionScreen._(
        role: LiveRole.listener,
        token: token,
        myUserId: myUserId,
        peerName: peerName,
        sessionId: sessionId,
        track: track,
      );

  @override
  State<LiveSessionScreen> createState() => _LiveSessionScreenState();
}

class _LiveSessionScreenState extends State<LiveSessionScreen> {
  late final LiveSessionController _c;
  String _status = 'Connecting…';
  String _title = '';
  bool _ready = false;

  bool get _isHost => widget.role == LiveRole.host;

  @override
  void initState() {
    super.initState();
    _title = widget.title ?? (widget.track?['title'] as String?) ?? 'Live song';
    _c = LiveSessionController(
      onEvent: _onEvent,
      onEnded: _onEnded,
      onError: (e) => _snack('Connection error: $e'),
    );
    _start();
  }

  Future<void> _start() async {
    try {
      if (_isHost) {
        setState(() => _status = 'Starting session…');
        await _c.startHost(
          receiverId: widget.receiverId!,
          myUserId: widget.myUserId,
          token: widget.token,
          audioBytes: widget.audioBytes!,
          title: _title,
          durationMs: widget.durationMs,
        );
        setState(() {
          _ready = true;
          _status = 'Waiting for ${widget.peerName} to join…';
        });
      } else {
        setState(() => _status = 'Joining ${widget.peerName}’s session…');
        await _c.joinAsListener(
          sessionId: widget.sessionId!,
          myUserId: widget.myUserId,
          token: widget.token,
        );
        setState(() {
          _ready = true;
          _status = 'Buffering the song…';
        });
      }
    } catch (e) {
      _snack('Could not start session: $e');
      if (mounted) Navigator.of(context).maybePop();
    }
  }

  void _onEvent(Map<String, dynamic> e) {
    if (!mounted) return;
    switch (e['type']) {
      case 'peer_joined':
        setState(() => _status = '${widget.peerName} joined — listening together');
        break;
      case 'peer_left':
        setState(() => _status = '${widget.peerName} left');
        break;
      case 'meta':
        final t = (e['track']?['title']) as String?;
        if (t != null) setState(() => _title = t);
        break;
      case 'play':
        setState(() => _status = 'Playing');
        break;
      case 'pause':
        setState(() => _status = 'Paused');
        break;
    }
  }

  void _onEnded(String reason) {
    if (!mounted) return;
    final msg = reason == 'host_left' || reason == 'host_ended'
        ? '${widget.peerName} ended the session'
        : 'Session ended';
    _snack(msg);
    Navigator.of(context).maybePop();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _leaveOrEnd() async {
    if (_isHost) {
      await _c.endSession(widget.token);
    } else {
      await _c.dispose();
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) await _leaveOrEnd();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isHost ? 'Listening together (you’re the DJ)' : 'Listening together'),
        ),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.headphones_rounded, size: 96),
              const SizedBox(height: 24),
              Text(
                _title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                _isHost ? 'Sharing with ${widget.peerName}' : 'Hosted by ${widget.peerName}',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
              ),
              const SizedBox(height: 8),
              Text(_status, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
              const SizedBox(height: 24),
              _buildSeekBar(),
              const SizedBox(height: 16),
              if (_isHost) _buildHostControls() else _buildListenerHint(theme),
              const SizedBox(height: 32),
              FilledButton.tonalIcon(
                onPressed: _ready ? _leaveOrEnd : null,
                icon: Icon(_isHost ? Icons.stop_circle_outlined : Icons.logout),
                label: Text(_isHost ? 'End session' : 'Leave'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSeekBar() {
    return StreamBuilder<Duration>(
      stream: _c.player.positionStream,
      builder: (context, posSnap) {
        final pos = posSnap.data ?? Duration.zero;
        final dur = _c.player.duration ?? Duration.zero;
        final max = dur.inMilliseconds.toDouble();
        final value = max <= 0
            ? 0.0
            : pos.inMilliseconds.clamp(0, dur.inMilliseconds).toDouble();
        return Column(
          children: [
            Slider(
              value: value,
              max: max <= 0 ? 1.0 : max,
              onChanged: _isHost && max > 0
                  ? (v) => _c.player.seek(Duration(milliseconds: v.round()))
                  : null, // listeners can't scrub — the host is the DJ
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_fmt(pos)),
                Text(_fmt(dur)),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildHostControls() {
    return StreamBuilder<PlayerState>(
      stream: _c.player.playerStateStream,
      builder: (context, snap) {
        final playing = snap.data?.playing ?? false;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton.filled(
              iconSize: 40,
              onPressed: !_ready
                  ? null
                  : () => playing ? _c.player.pause() : _c.player.play(),
              icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
            ),
          ],
        );
      },
    );
  }

  Widget _buildListenerHint(ThemeData theme) {
    return Text(
      'The host controls playback — sit back and enjoy 🎧',
      textAlign: TextAlign.center,
      style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
