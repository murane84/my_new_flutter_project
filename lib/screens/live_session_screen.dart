import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../services/live_session_service.dart';
import 'home_page.dart' show liveSessionNotifier, playbackBus, playlistNotifier;
import '../utils/file_bytes.dart';

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
    this.resume = false,
    this.startPositionMs = 0,
  });

  final LiveRole role;
  final String token;
  final int myUserId;
  final String peerName;
  // When true, rebind to the already-running [activeLiveSession] instead of
  // creating/starting a new one (reopening a minimised session).
  final bool resume;
  // Host-only: position (ms) to begin the shared song at, so sharing the
  // currently-playing track blends in without restarting.
  final int startPositionMs;

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
    int startPositionMs = 0,
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
        startPositionMs: startPositionMs,
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

  /// Reopen the currently-minimised session. Reads [activeLiveSession] for its
  /// controller and display info.
  factory LiveSessionScreen.resume() {
    final s = activeLiveSession!;
    return LiveSessionScreen._(
      role: s.role,
      token: s.token,
      myUserId: s.myUserId,
      peerName: s.peerName,
      title: s.title,
      resume: true,
    );
  }

  @override
  State<LiveSessionScreen> createState() => _LiveSessionScreenState();
}

/// Cleans up a session that ended remotely while it was minimised (no screen
/// mounted to handle `onEnded`). Clearing the notifier hides the live banner.
void _handleMinimizedEnd(String reason) {
  final s = activeLiveSession;
  activeLiveSession = null;
  liveSessionNotifier.stop();
  s?.controller.dispose();
}

class _LiveSessionScreenState extends State<LiveSessionScreen> {
  late LiveSessionController _c;
  String _status = 'Connecting…';
  String _title = '';
  bool _ready = false;
  // True while we're closing the popup to minimise (keep the session alive).
  bool _minimizing = false;
  // Listener lost the transport and can choose to reconnect.
  bool _lostConnection = false;
  // True once the user intentionally leaves/ends (so a socket close doesn't
  // pop the reconnect prompt).
  bool _leaving = false;

  bool get _isHost => widget.role == LiveRole.host;

  @override
  void initState() {
    super.initState();
    _title = widget.title ?? (widget.track?['title'] as String?) ?? 'Live song';

    if (widget.resume && activeLiveSession != null) {
      // Reopening a minimised session — rebind to the live controller and
      // re-point its handlers at this fresh screen. No restart.
      _c = activeLiveSession!.controller;
      _c.onEvent = _onEvent;
      _c.onEnded = _onEnded;
      _c.onError = (e) => _snack('Connection error: $e');
      _c.onQueueChanged = () {
        if (mounted) setState(() {});
      };
      _ready = true;
      _status = _isHost
          ? 'Sharing with ${widget.peerName}'
          : 'Listening with ${widget.peerName}';
      return;
    }

    // Fresh session. Stop this device's own music player so only the live
    // stream is heard (host was paused at share time; this covers the
    // listener the moment they join).
    playbackBus.onPause?.call();

    // Broadcast that a live co-listening session is active so ambient UI
    // (the persistent banner / bars) can reflect it.
    liveSessionNotifier.start(peer: widget.peerName, asHost: _isHost);
    _c = LiveSessionController(
      onEvent: _onEvent,
      onEnded: _onEnded,
      onError: (e) => _snack('Connection error: $e'),
    );
    _c.onQueueChanged = () {
      if (mounted) setState(() {});
    };
    activeLiveSession = ActiveLiveSession(
      controller: _c,
      role: widget.role,
      peerName: widget.peerName,
      title: _title,
      token: widget.token,
      myUserId: widget.myUserId,
    );
    _start();
  }

  // Close the popup but keep the session running in the background. Re-point
  // the controller's handlers to a global cleanup so a remote end while
  // minimised still tears down and hides the banner.
  void _minimize() {
    _minimizing = true;
    _c.onEvent = null;
    _c.onError = (_) {};
    _c.onEnded = _handleMinimizedEnd;
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
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
          startPositionMs: widget.startPositionMs,
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
        setState(() {
          _lostConnection = false;
          _status = '${widget.peerName} joined — listening together';
        });
        break;
      case 'peer_left':
        setState(() => _status = '${widget.peerName} left');
        break;
      case 'meta':
        final t = (e['track']?['title']) as String?;
        setState(() {
          if (t != null) _title = t;
          _lostConnection = false; // stream is flowing again after a reconnect
        });
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
    if (!mounted || _leaving) return;
    // A transport drop (not an explicit host end) → let a listener reconnect
    // instead of closing the session on them.
    if (!_isHost && reason == 'disconnected') {
      setState(() {
        _lostConnection = true;
        _ready = false;
        _status = 'Connection lost';
      });
      return;
    }
    final msg = reason == 'host_left' || reason == 'host_ended'
        ? '${widget.peerName} ended the session'
        : 'Session ended';
    _snack(msg);
    _dismiss();
  }

  Future<void> _reconnect() async {
    setState(() {
      _lostConnection = false;
      _ready = false;
      _status = 'Reconnecting…';
    });
    try {
      await _c.reconnectAsListener(
        sessionId: widget.sessionId!,
        myUserId: widget.myUserId,
        token: widget.token,
      );
      if (mounted) {
        setState(() {
          _ready = true;
          _status = 'Rejoining ${widget.peerName}…';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _lostConnection = true;
          _status = 'Couldn’t reconnect — try again';
        });
      }
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _leaveOrEnd() async {
    // Close immediately so a slow network call can never trap the user in the
    // popup. Teardown of the controller happens in this State's dispose();
    // for the host we also best-effort tell the server the session is over.
    _leaving = true;
    _dismiss();
    if (_isHost) {
      unawaited(_c.endSession(widget.token));
    }
  }

  @override
  void dispose() {
    // If we're just minimising, leave the session (controller, notifier,
    // activeLiveSession) fully intact — only detach this screen.
    if (!_minimizing) {
      liveSessionNotifier.stop();
      activeLiveSession = null;
      _c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return PopScope(
      // Back minimises (keeps the session running); use the ✕ to end/leave.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_ready) {
          _minimize();
        } else {
          _leaveOrEnd();
        }
      },
      child: Dialog(
        // Bottom-anchored sheet styled like the playlist overlay.
        alignment: Alignment.bottomCenter,
        insetPadding: const EdgeInsets.fromLTRB(8, 40, 8, 8),
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Container(
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(20),
              border:
                  Border.all(color: scheme.outlineVariant.withAlpha(60)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(50),
                  blurRadius: 26,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Grab handle — matches the playlist sheet.
                Container(
                  margin: const EdgeInsets.only(top: 8, bottom: 2),
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: scheme.onSurfaceVariant.withAlpha(90),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
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
                      tooltip: 'Minimize — keep listening while you chat',
                      icon: const Icon(Icons.remove_rounded),
                      onPressed: _ready ? _minimize : null,
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
                      if (_lostConnection) ...[
                        _buildReconnect(scheme),
                      ] else ...[
                        const SizedBox(height: 18),
                        _buildSeekBar(),
                        const SizedBox(height: 12),
                        if (_isHost)
                          _buildHostControls()
                        else
                          _buildListenerHint(theme),
                        if (_isHost) _buildQueue(scheme),
                      ],
                      const SizedBox(height: 20),
                      FilledButton.tonalIcon(
                        onPressed: (_ready || _lostConnection)
                            ? _leaveOrEnd
                            : null,
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

  // Shown when a listener's connection drops — offer to rejoin.
  Widget _buildReconnect(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        children: [
          Icon(Icons.wifi_off_rounded, size: 40, color: scheme.error),
          const SizedBox(height: 12),
          Text(
            'You lost connection to the session.',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurface),
          ),
          const SizedBox(height: 4),
          Text(
            'If ${widget.peerName} is still live, you can rejoin.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _reconnect,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Reconnect'),
          ),
        ],
      ),
    );
  }

  // ── Host queue ──────────────────────────────────────────────────────────────
  Widget _buildQueue(ColorScheme scheme) {
    final q = _c.queue;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 18),
        Row(
          children: [
            Icon(Icons.queue_music_rounded, size: 18, color: scheme.primary),
            const SizedBox(width: 6),
            Text('Queue (${q.length})',
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const Spacer(),
            TextButton.icon(
              onPressed: _addSongToQueue,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add song'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 176),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: q.length,
            itemBuilder: (_, i) {
              final t = q[i];
              final isCurrent = i == _c.currentIndex;
              final upcoming = i > _c.currentIndex;
              return ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: Icon(
                  isCurrent
                      ? Icons.graphic_eq_rounded
                      : Icons.music_note_rounded,
                  size: 18,
                  color: isCurrent ? scheme.primary : scheme.onSurfaceVariant,
                ),
                title: Text(
                  t.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight:
                        isCurrent ? FontWeight.bold : FontWeight.normal,
                    color: isCurrent ? scheme.primary : scheme.onSurface,
                  ),
                ),
                subtitle: isCurrent
                    ? Text('Now playing',
                        style: TextStyle(fontSize: 10.5, color: scheme.primary))
                    : null,
                trailing: upcoming
                    ? IconButton(
                        icon: const Icon(Icons.close_rounded, size: 18),
                        tooltip: 'Remove from queue',
                        onPressed: () => _c.removeUpcoming(i),
                      )
                    : null,
                // Tap an upcoming track to jump to it now.
                onTap: isCurrent ? null : () => _c.playIndex(i),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _addSongToQueue() async {
    final loaded = playlistNotifier.value;
    if (loaded.isEmpty) {
      _snack('Load songs in your music player first');
      return;
    }
    final scheme = Theme.of(context).colorScheme;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Add to queue',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: loaded.length,
                itemBuilder: (_, i) {
                  final p = loaded[i];
                  return ListTile(
                    leading: Icon(Icons.music_note_rounded,
                        color: scheme.primary),
                    title: Text(_titleFromPath(p),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.pop(ctx, p),
                  );
                },
              ),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    try {
      final bytes = Uint8List.fromList(await readFileBytes(chosen));
      if (bytes.isEmpty) {
        _snack('That track appears to be empty.');
        return;
      }
      await _c.addTrack(LiveTrack(bytes: bytes, title: _titleFromPath(chosen)));
      _snack('Added to queue');
    } catch (_) {
      _snack('Could not read that track.');
    }
  }

  String _titleFromPath(String path) {
    var name = path;
    final slash = name.lastIndexOf(RegExp(r'[\\/]'));
    if (slash >= 0) name = name.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    return name.trim().isEmpty ? 'Live song' : name.trim();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
