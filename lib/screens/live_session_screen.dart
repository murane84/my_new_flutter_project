import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../services/live_session_service.dart';

/// Popup "Listen Together" session UI for both the host (DJ) and a listener.
/// Presented with `showDialog(...)` so it floats over the chat instead of
/// taking over the whole screen.
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
      _dismiss();
    }
  }

  // Closes the popup. Uses pop() (not maybePop) because the PopScope below sets
  // canPop:false, which deliberately blocks maybePop.
  void _dismiss() {
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
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
    _dismiss();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _leaveOrEnd() async {
    // Close immediately so a slow network call can never trap the user in the
    // popup. Teardown of the controller happens in this State's dispose();
    // for the host we also best-effort tell the server the session is over.
    _dismiss();
    if (_isHost) {
      unawaited(_c.endSession(widget.token));
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) await _leaveOrEnd();
      },
      child: Dialog(
        insetPadding:
            const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Header bar with title + close (end/leave) ──────────────
              Container(
                padding: const EdgeInsets.fromLTRB(16, 8, 6, 8),
                color: scheme.surfaceContainerHighest,
                child: Row(
                  children: [
                    Icon(Icons.headphones_rounded,
                        color: scheme.primary, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _isHost
                            ? 'Listen Together · DJ'
                            : 'Listen Together',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      tooltip: _isHost ? 'End session' : 'Leave',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: _leaveOrEnd,
                    ),
                  ],
                ),
              ),
              // ── Body ───────────────────────────────────────────────────
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 22),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: CircleAvatar(
                          radius: 32,
                          backgroundColor: scheme.primaryContainer,
                          child: Icon(Icons.headphones_rounded,
                              size: 32,
                              color: scheme.onPrimaryContainer),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _title,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _isHost
                            ? 'Sharing with ${widget.peerName}'
                            : 'Hosted by ${widget.peerName}',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.hintColor),
                      ),
                      const SizedBox(height: 6),
                      Text(_status,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall),
                      const SizedBox(height: 18),
                      _buildSeekBar(),
                      const SizedBox(height: 12),
                      if (_isHost)
                        _buildHostControls()
                      else
                        _buildListenerHint(theme),
                      const SizedBox(height: 20),
                      FilledButton.tonalIcon(
                        onPressed: _ready ? _leaveOrEnd : null,
                        icon: Icon(_isHost
                            ? Icons.stop_circle_outlined
                            : Icons.logout),
                        label:
                            Text(_isHost ? 'End session' : 'Leave'),
                      ),
                    ],
                  ),
                ),
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
