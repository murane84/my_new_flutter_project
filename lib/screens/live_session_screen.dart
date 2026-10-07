import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../services/live_session_service.dart';
import 'api_service.dart';
import '../services/live_audio_cache.dart' show liveTrackFingerprint;
import 'home_page.dart' show playbackBus, playlistNotifier;
import '../state/playback_state.dart';
import '../utils/file_bytes.dart';
import '../utils/toast_helper.dart';
import '../utils/marquee_text.dart';

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
    this.isRoom = false,
    this.myName,
  });

  final LiveRole role;
  final String token;
  final int myUserId;
  final String peerName;
  // The signed-in user's own display name — used to attribute a track a
  // listener contributes to a room ("added by <myName>"). Optional.
  final String? myName;
  // Host-only: true when hosting an OPEN "Listening Room" (drop-in for the whole
  // circle) rather than a 1:1 invite. Drives startRoom() vs startHost() and the
  // "waiting for your circle" copy.
  final bool isRoom;
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

  /// Host an OPEN "Listening Room" — a drop-in space the whole circle can join,
  /// seeded with [audioBytes]/[title]. No receiver; the backend announces it.
  factory LiveSessionScreen.roomHost({
    required String token,
    required int myUserId,
    required Uint8List audioBytes,
    required String title,
    int? durationMs,
    int startPositionMs = 0,
  }) =>
      LiveSessionScreen._(
        role: LiveRole.host,
        token: token,
        myUserId: myUserId,
        peerName: 'your circle',
        audioBytes: audioBytes,
        title: title,
        durationMs: durationMs,
        startPositionMs: startPositionMs,
        isRoom: true,
      );

  factory LiveSessionScreen.listener({
    required String token,
    required int myUserId,
    required String sessionId,
    required Map<String, dynamic> track,
    required String peerName,
    String? myName,
  }) =>
      LiveSessionScreen._(
        role: LiveRole.listener,
        token: token,
        myUserId: myUserId,
        peerName: peerName,
        sessionId: sessionId,
        track: track,
        myName: myName,
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
  // A transport glitch while minimised should NOT kill the session — try to
  // reconnect quietly in the background (host keeps playing locally; a listener
  // rebuffers). Only a real end ('host_left' / 'host_ended' / 'ended') falls
  // through to teardown. If the background reconnect fails, tear down then.
  if (s != null && reason == 'disconnected') {
    final c = s.controller;
    final Future<void> attempt = s.role == LiveRole.host
        ? c.reconnectAsHost(myUserId: s.myUserId, token: s.token)
        : c.reconnectAsListener(
            sessionId: c.sessionId ?? '',
            myUserId: s.myUserId,
            token: s.token,
          );
    attempt.catchError((_) => _finalizeMinimizedEnd());
    return;
  }
  _finalizeMinimizedEnd();
}

void _finalizeMinimizedEnd() {
  final s = activeLiveSession;
  activeLiveSession = null;
  providerContainer.read(liveSessionProvider.notifier).stop();
  s?.controller.dispose();
}

class _LiveSessionScreenState extends State<LiveSessionScreen> {
  late LiveSessionController _c;
  // Song-picker hints: a track's content fingerprint cached by file path (so we
  // only ever read+hash a given file once per session), and whether the partner
  // can already play it instantly. Populated by a bounded background pass when
  // the picker opens; purely advisory (a ⚡ chip), never blocks adding a song.
  final Map<String, String> _fpByPath = {};
  final Set<String> _instantPaths = {};
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
  // Host side: the listener announced a deliberate 'leaving', so a following
  // 'peer_left' should NOT be relabelled as "lost connection".
  bool _peerGoneGraceful = false;
  // ── Live reactions ("concert lighter") ─────────────────────────────────────
  // Ephemeral floating emoji both partners see in real time (relayed over the
  // session WS, nothing stored). _reactionCount tallies the session total for
  // the save-this-session summary.
  final List<_FloatReaction> _floats = [];
  int _floatSeq = 0;
  int _reactionCount = 0;
  // Save-this-session (host 1:1 only): when the set ends, offer to keep it as a
  // dated memory on the Our Space wall. Guarded so it's offered at most once.
  final DateTime _sessionStart = DateTime.now();
  bool _saveOffered = false;
  // The host's bonds, pre-fetched so a Live Room set can be saved to one of
  // them (a room has no single partner). Empty for a listener / no bonds.
  List<Map<String, dynamic>> _hostSpaces = const [];
  final math.Random _rand = math.Random();
  static const List<String> _quickReactions = ['❤️', '🔥', '😍', '🎶', '👏', '🥹'];
  // The music panel also observes session repeat/shuffle. While this popup is
  // open it takes over those callbacks (so its own buttons rebuild on a synced
  // change) but CHAINS the panel's, and restores them on minimise so the
  // persistent panel keeps working underneath.
  VoidCallback? _prevRepeatCb;
  VoidCallback? _prevShuffleCb;
  VoidCallback? _prevContribCb;
  bool _flagCbsBound = false;

  bool get _isHost => widget.role == LiveRole.host;

  // Take over (chained) the controller's repeat/shuffle notifications so this
  // popup rebuilds when the SHARED mode changes — whether we set it or it was
  // synced from the peer. Scheduled post-frame so it runs after the music
  // panel has bound its own (microtask), letting the popup win while it's up.
  void _bindFlagCallbacks() {
    if (_flagCbsBound) return;
    _flagCbsBound = true;
    _prevRepeatCb = _c.onRepeatChanged;
    _c.onRepeatChanged = () {
      _prevRepeatCb?.call();
      if (mounted) setState(() {});
    };
    _prevShuffleCb = _c.onShuffleChanged;
    _c.onShuffleChanged = () {
      _prevShuffleCb?.call();
      if (mounted) setState(() {});
    };
    // Stage C: rebuild when guest-contribution availability changes (host
    // toggled it, or a listener synced it from the host).
    _prevContribCb = _c.onContribChanged;
    _c.onContribChanged = () {
      _prevContribCb?.call();
      if (mounted) setState(() {});
    };
  }

  // Hand the repeat/shuffle callbacks back to whatever held them (the music
  // panel) when the popup goes away, so the persistent panel keeps updating.
  void _restoreFlagCallbacks() {
    if (!_flagCbsBound) return;
    _flagCbsBound = false;
    _c.onRepeatChanged = _prevRepeatCb;
    _c.onShuffleChanged = _prevShuffleCb;
    _c.onContribChanged = _prevContribCb;
  }

  @override
  void initState() {
    super.initState();
    _title = widget.title ?? (widget.track?['title'] as String?) ?? 'Live song';
    // Pre-fetch the host's bonds so a Live Room set can be saved to one of them.
    if (_isHost) _prefetchHostSpaces();

    if (widget.resume && activeLiveSession != null) {
      // Reopening a minimised session — rebind to the live controller and
      // re-point its handlers at this fresh screen. No restart.
      _c = activeLiveSession!.controller;
      _c.onEvent = _onEvent;
      _c.onEnded = _onEnded;
      _c.onError = (e) => _snack('Connection error: $e');
      _c.onQueueChanged = _syncFromQueue;
      _ready = true;
      _status = _isHost
          ? 'Sharing with ${widget.peerName}'
          : 'Listening with ${widget.peerName}';
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _bindFlagCallbacks());
      return;
    }

    // Fresh session. Stop this device's own music player so only the live
    // stream is heard (host was paused at share time; this covers the
    // listener the moment they join).
    playbackBus.onPause?.call();

    _c = LiveSessionController(
      onEvent: _onEvent,
      onEnded: _onEnded,
      onError: (e) => _snack('Connection error: $e'),
    );
    _c.onQueueChanged = _syncFromQueue;
    // Register the active session BEFORE announcing it. The music panel listens
    // for the announcement and immediately reads activeLiveSession.controller to
    // subscribe to the live player's play/pause stream — if we announced first,
    // that read would be null and the now-playing bar would never learn the
    // live playing state (its play/pause icon would stay stuck).
    activeLiveSession = ActiveLiveSession(
      controller: _c,
      role: widget.role,
      peerName: widget.peerName,
      title: _title,
      token: widget.token,
      myUserId: widget.myUserId,
      isRoom: widget.isRoom,
    );
    // Broadcast that a live co-listening session is active so ambient UI
    // (the persistent banner / bars) can reflect it.
    providerContainer
        .read(liveSessionProvider.notifier)
        .start(peer: widget.peerName, asHost: _isHost);
    _start();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bindFlagCallbacks());
  }

  // Close the popup but keep the session running in the background. Re-point
  // the controller's handlers to a global cleanup so a remote end while
  // minimised still tears down and hides the banner.
  void _minimize() {
    _minimizing = true;
    _restoreFlagCallbacks();
    _c.onEvent = null;
    _c.onError = (_) {};
    _c.onEnded = _handleMinimizedEnd;
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  Future<void> _start() async {
    try {
      if (_isHost) {
        setState(() =>
            _status = widget.isRoom ? 'Opening your room…' : 'Starting session…');
        if (widget.isRoom) {
          await _c.startRoom(
            myUserId: widget.myUserId,
            token: widget.token,
            audioBytes: widget.audioBytes!,
            title: _title,
            durationMs: widget.durationMs,
            startPositionMs: widget.startPositionMs,
          );
        } else {
          await _c.startHost(
            receiverId: widget.receiverId!,
            myUserId: widget.myUserId,
            token: widget.token,
            audioBytes: widget.audioBytes!,
            title: _title,
            durationMs: widget.durationMs,
            startPositionMs: widget.startPositionMs,
          );
        }
        setState(() {
          _ready = true;
          _status = widget.isRoom
              ? 'Your room is live — your circle can drop in'
              : 'Waiting for ${widget.peerName} to join…';
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

  // Rebuild on any queue/index change and keep the popup title correct for
  // whichever role we are: the host reads its own queue, the listener reads the
  // title the controller mirrored from the host.
  void _syncFromQueue() {
    if (!mounted) return;
    setState(() {
      if (_isHost) {
        if (_c.currentIndex >= 0 && _c.currentIndex < _c.queue.length) {
          _title = _c.queue[_c.currentIndex].title;
        }
      } else if (_c.currentTitle.isNotEmpty) {
        _title = _c.currentTitle;
      }
    });
  }

  void _onEvent(Map<String, dynamic> e) {
    if (!mounted) return;
    switch (e['type']) {
      case 'peer_joined':
        setState(() {
          _lostConnection = false;
          _peerGoneGraceful = false;
          _status = '${widget.peerName} joined — listening together';
        });
        break;
      case 'leaving':
        // Listener left on purpose (host side).
        setState(() {
          _peerGoneGraceful = true;
          _status = '${widget.peerName} left the session';
        });
        break;
      case 'peer_left':
        // Listener's socket dropped (host side). Only relabel as a connection
        // loss if they didn't just announce a deliberate leave.
        if (!_peerGoneGraceful) {
          setState(() => _status = '${widget.peerName} lost connection');
        }
        break;
      case 'host_reconnecting':
        // Listener side: the host had a network glitch. Show a waiting state
        // (playback was paused by the controller) until they come back.
        setState(() => _status = '${widget.peerName} reconnecting…');
        break;
      case 'meta':
      case 'track_change':
        // Host switched songs (or initial meta) — follow the new title.
        final t = (e['track']?['title']) as String?;
        setState(() {
          if (t != null && t.isNotEmpty) {
            _title = t;
            // Keep the global session title in sync so the music-panel console
            // (which mirrors the live track) updates on the listener too.
            activeLiveSession?.title = t;
          }
          _lostConnection = false; // stream is flowing again after a reconnect
        });
        break;
      case 'reaction':
        final em = (e['emoji'] ?? '❤').toString();
        _spawnReaction(em);
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
    // A transport drop (not an explicit host end) → keep the session alive and
    // reconnect instead of closing it. The host's local playback keeps going,
    // so we auto-reconnect it silently; a listener stopped hearing audio, so we
    // surface a "Connection lost" state with a Reconnect button.
    if (reason == 'disconnected') {
      // A transport drop (not an explicit end). Both roles auto-attempt a
      // reconnect first — the host's local playback never stopped and the
      // server keeps the session alive through the grace window, so a brief
      // blip self-heals without the user doing anything. _reconnect() falls
      // back to a manual Reconnect button only if the attempt fails.
      setState(() {
        _ready = false;
        _status = 'Reconnecting…';
        if (!_isHost) _lostConnection = false;
      });
      _reconnect();
      return;
    }
    if (reason == 'session_gone') {
      // The session no longer exists (the host ended it, or it was reaped after
      // a long outage). Reconnecting to the same id would loop forever, so end
      // cleanly here — the host can start a fresh room.
      _snack(_isHost
          ? 'Your session ended'
          : '${widget.peerName}\'s session has ended');
      _dismiss();
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
      if (_isHost) {
        // Host keeps its local player/queue; just re-establish the pipe. The
        // server re-drives the re-stream to the listener via `peer_joined`.
        await _c.reconnectAsHost(
          myUserId: widget.myUserId,
          token: widget.token,
        );
      } else {
        await _c.reconnectAsListener(
          // Prefer the controller's live session id so reconnect still works
          // after the popup was minimised and reopened (widget.sessionId is
          // null on a resumed screen).
          sessionId: _c.sessionId ?? widget.sessionId ?? '',
          myUserId: widget.myUserId,
          token: widget.token,
        );
      }
      if (mounted) {
        setState(() {
          _ready = true;
          _status = _isHost
              ? 'Reconnected — resuming with ${widget.peerName}…'
              : 'Rejoining ${widget.peerName}…';
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

  // Float a reaction locally. [mine] also sends it to the partner over the WS.
  void _spawnReaction(String emoji, {bool mine = false}) {
    if (!mounted) return;
    if (mine) _c.sendReaction(emoji);
    final id = _floatSeq++;
    final dx = 0.12 + _rand.nextDouble() * 0.76;
    setState(() {
      _floats.add(_FloatReaction(id, emoji, dx));
      _reactionCount++;
    });
  }

  void _removeFloat(int id) {
    if (!mounted) return;
    setState(() => _floats.removeWhere((f) => f.id == id));
  }

  // Build the warm one-line summary shown in the save prompt and on the card.
  String _listenSummary(List<String> titles) {
    final n = titles.length;
    final songs = n == 1 ? '1 song' : '$n songs';
    final r = _reactionCount;
    return r > 0
        ? 'Listened together · $songs · $r reaction${r == 1 ? '' : 's'}'
        : 'Listened together · $songs';
  }

  // Host 1:1: offer to keep this session as a dated moment on the wall. The
  // saved memory mirrors to both partners (pair bond), so the listener sees it
  // too. Songs are listed by title + the live-reaction tally; no audio/refs are
  // stored (the set streamed local files).
  Future<void> _maybeOfferSave() async {
    _saveOffered = true;
    // 1:1 → that partner (resolved server-side). Room → null, resolved to a
    // picked bond after the user confirms.
    final partnerId = widget.receiverId;
    final titles = <String>[];
    for (final t in _c.queue) {
      final tt = t.title.trim();
      if (tt.isNotEmpty && !titles.contains(tt)) titles.add(tt);
    }
    if (titles.isEmpty) return;
    final summary = _listenSummary(titles);
    final save = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final sc = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: const Text('Save this listen?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(summary,
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: sc.onSurface)),
              const SizedBox(height: 8),
              Text(
                  'Keep it as a memory on your Our Space wall — you can react and write about it later.',
                  style: TextStyle(fontSize: 12.5, color: sc.onSurfaceVariant)),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Not now')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save to Our Space')),
          ],
        );
      },
    );
    if (save != true || !mounted) return;
    final mins = DateTime.now().difference(_sessionStart).inMinutes;
    final ref = jsonEncode({
      'songs': titles,
      'reactions': _reactionCount,
      'minutes': mins,
    });
    Map<String, dynamic>? res;
    if (partnerId != null) {
      // 1:1 set → that partner's bond space (resolved server-side).
      res = await ApiService()
          .saveListenMoment(partnerId, caption: summary, ref: ref);
    } else {
      // Live Room set → a bond the host picks (rooms have no single partner).
      final spaceId = await _pickSaveSpace();
      if (spaceId == null || !mounted) return;
      res = await ApiService()
          .addMoment(spaceId, kind: 'listen', caption: summary, ref: ref);
    }
    if (!mounted) return;
    _snack(res != null
        ? 'Saved to Our Space 💞'
        : 'Could not save this listen');
  }

  // Pick which bond to keep a Live Room set in: straight to the only one, a
  // chooser when there are several, or null when the host has no bonds.
  Future<int?> _pickSaveSpace() async {
    final spaces = _hostSpaces;
    if (spaces.isEmpty) {
      _snack('Bond in Our Space first to keep a set together.');
      return null;
    }
    if (spaces.length == 1) {
      return (spaces.first['id'] as num?)?.toInt();
    }
    return showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (bctx) {
        final sc = Theme.of(bctx).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
                child: Text('Save to\u2026',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: sc.onSurface)),
              ),
              for (final sp in spaces)
                ListTile(
                  leading: CircleAvatar(
                    radius: 20,
                    backgroundColor: sc.primaryContainer,
                    child: Icon(Icons.favorite_rounded,
                        size: 18, color: sc.primary),
                  ),
                  title: Text(_spaceTitle(sp)),
                  onTap: () =>
                      Navigator.pop(bctx, (sp['id'] as num?)?.toInt()),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  String _spaceTitle(Map<String, dynamic> sp) {
    final name = (sp['name'] ?? '').toString().trim();
    return name.isEmpty ? 'Our Space' : name;
  }

  Future<void> _prefetchHostSpaces() async {
    try {
      final sp = await ApiService().listSpaces();
      if (mounted) setState(() => _hostSpaces = sp);
    } catch (_) {/* no bonds / offline — room save just won't be offered */}
  }

  // The full-width floating layer (rising emoji) laid over the session sheet.
  Widget _floatingLayer() {
    return Positioned.fill(
      child: IgnorePointer(
        child: ClipRect(
          child: Stack(
            children: [
              for (final f in _floats)
                Positioned.fill(
                  child: _RisingEmoji(
                    key: ValueKey(f.id),
                    emoji: f.emoji,
                    dx: f.dx,
                    onDone: () => _removeFloat(f.id),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // A compact quick-reaction bar — tap to float a lighter that your partner
  // sees live too.
  Widget _reactionBar(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final em in _quickReactions) ...[
            _ReactionButton(
              emoji: em,
              onTap: () => _spawnReaction(em, mine: true),
              scheme: scheme,
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }

  void _snack(String m, {ToastType type = ToastType.info}) {
    if (!mounted) return;
    // Use the overlay toast (inserted on top of the overlay) rather than a
    // ScaffoldMessenger SnackBar — the SnackBar anchors to the root Scaffold
    // and renders BEHIND this session dialog (an unstyled black bar peeking
    // out from under the card). The overlay pill shows above the card.
    showToast(context, m, type: type);
  }

  Future<void> _leaveOrEnd() async {
    // Host: offer to keep the set as a memory before closing — a 1:1 set saves
    // to that partner's space; a Live Room set saves to a bond the host picks
    // (only offered when they actually have one).
    if (_isHost &&
        !_saveOffered &&
        _c.queue.isNotEmpty &&
        (widget.receiverId != null || _hostSpaces.isNotEmpty)) {
      await _maybeOfferSave();
      if (!mounted) return;
    }
    // Close immediately so a slow network call can never trap the user in the
    // popup. Teardown of the controller happens in this State's dispose();
    // for the host we also best-effort tell the server the session is over.
    _leaving = true;
    if (_isHost) {
      _dismiss();
      unawaited(_c.endSession(widget.token));
    } else {
      // Tell the host we're leaving on purpose BEFORE the socket closes, so
      // they see "left the session" rather than "lost connection".
      _c.notifyLeaving();
      _dismiss();
    }
  }

  @override
  void dispose() {
    // If we're just minimising, leave the session (controller, notifier,
    // activeLiveSession) fully intact — only detach this screen.
    if (!_minimizing) {
      providerContainer.read(liveSessionProvider.notifier).stop();
      activeLiveSession = null;
      _c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Cap the sheet height so the queue becomes an independent scroll region
    // once it grows past the visible space.
    final maxSheetH = MediaQuery.of(context).size.height * 0.82;
    return PopScope(
      // Back minimises (keeps the session running); use the ✕ to end/leave.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Minimising is always safe (it just detaches this screen and keeps the
        // session streaming). Available to host AND listener, ready or still
        // connecting — so the listener can always tuck it away and keep chatting.
        if (activeLiveSession != null) {
          _minimize();
        } else {
          _leaveOrEnd();
        }
      },
      child: Dialog(
        // Bottom-anchored sheet styled like the playlist overlay. Add the
        // system navigation-bar inset to the bottom so its controls never sit
        // under the Android 3-button nav bar (~0 on gesture nav).
        alignment: Alignment.bottomCenter,
        insetPadding: EdgeInsets.fromLTRB(
            8, 40, 8, 8 + MediaQuery.of(context).padding.bottom),
        backgroundColor: Colors.transparent,
        elevation: 0,
        // Drop the app-wide dialogTheme border here — this sheet draws its own
        // (inner) card border, so the theme border was doubling it up.
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 520, maxHeight: maxSheetH),
          child: Container(
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(20),
              border:
                  Border.all(color: scheme.primary.withAlpha(130)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(50),
                  blurRadius: 26,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Column(
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
                      // Always minimisable (host or listener, even mid-connect).
                      onPressed:
                          activeLiveSession != null ? _minimize : null,
                    ),
                    IconButton(
                      tooltip: _isHost ? 'End session' : 'Leave',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: _leaveOrEnd,
                    ),
                  ],
                ),
              ),
              // ── Body (compact; only the queue scrolls) ────────────────
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Compact now-playing header — small avatar + info on one
                    // left-aligned row (was a big centred block).
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 22,
                            backgroundColor: scheme.primaryContainer,
                            child: Icon(Icons.headphones_rounded,
                                size: 22, color: scheme.onPrimaryContainer),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                MarqueeText(
                                  text: _title,
                                  height: 20,
                                  style: (theme.textTheme.titleSmall ??
                                          const TextStyle(fontSize: 14))
                                      .copyWith(fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _isHost
                                      ? 'Sharing with ${widget.peerName} · $_status'
                                      : 'Hosted by ${widget.peerName} · $_status',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall
                                      ?.copyWith(color: theme.hintColor),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_lostConnection)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: _buildReconnect(scheme),
                      )
                    else ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _buildSeekBar(),
                      ),
                      const SizedBox(height: 6),
                      if (_isHost)
                        _buildHostControls()
                      else
                        _buildListenerControls(),
                      const SizedBox(height: 4),
                      _reactionBar(scheme),
                      // Queue: fixed header + independently-scrolling list.
                      // Shown for BOTH roles now — the listener sees the same
                      // "up next" list the host queued (read-only).
                      const SizedBox(height: 6),
                      _buildQueueHeader(scheme),
                      Flexible(
                        child: _isHost
                            ? _buildQueueList(scheme)
                            : _buildRemoteQueueList(scheme),
                      ),
                    ],
                    // Footer action (fixed).
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: FilledButton.tonalIcon(
                        onPressed:
                            (_ready || _lostConnection) ? _leaveOrEnd : null,
                        icon: Icon(_isHost
                            ? Icons.stop_circle_outlined
                            : Icons.logout),
                        label: Text(_isHost ? 'End session' : 'Leave'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
                _floatingLayer(),
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
        // Real song timeline (accounts for a trimmed MP3 tail on the listener).
        final pos = _c.livePosition;
        final dur = _c.liveDuration ?? Duration.zero;
        final max = dur.inMilliseconds.toDouble();
        final value = max <= 0
            ? 0.0
            : pos.inMilliseconds.clamp(0, dur.inMilliseconds).toDouble();
        return Column(
          children: [
            Slider(
              value: value,
              max: max <= 0 ? 1.0 : max,
              onChanged: max <= 0
                  ? null
                  : (v) {
                      if (_isHost) {
                        _c.player.seek(Duration(milliseconds: v.round()));
                      } else {
                        // Listener scrub → ask the host; host seeks and the new
                        // position is broadcast back so everyone stays in sync.
                        _c.requestControl('seek', positionMs: v.round());
                      }
                    },
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

  void _liveSeekBy(int seconds) {
    final dur = _c.player.duration ?? Duration.zero;
    var target = _c.player.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (dur > Duration.zero && target > dur) target = dur;
    _c.player.seek(target);
  }

  // Cycle the SHARED session repeat mode off → all → one → off. Works for host
  // and listener alike (the controller routes a listener's change through the
  // host, who re-broadcasts), so whoever taps it sets the mode for everyone.
  void _cycleSessionRepeat() {
    const order = ['off', 'all', 'one'];
    final next = order[(order.indexOf(_c.repeatMode) + 1) % order.length];
    _c.setRepeatMode(next);
  }

  // The shared shuffle + repeat controls shown to BOTH sides of the session.
  Widget _sessionFlagControls(ColorScheme scheme) {
    final mode = _c.repeatMode;
    final repeatOn = mode != 'off';
    Color tint(bool on) =>
        on ? scheme.primary : scheme.onSurface.withAlpha(120);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          iconSize: 22,
          color: tint(_c.shuffle),
          tooltip: _c.shuffle ? 'Shuffle on' : 'Shuffle off',
          onPressed: _ready ? () => _c.setShuffle(!_c.shuffle) : null,
          icon: const Icon(Icons.shuffle_rounded),
        ),
        const SizedBox(width: 24),
        IconButton(
          iconSize: 22,
          color: tint(repeatOn),
          tooltip: mode == 'one'
              ? 'Repeat one'
              : mode == 'all'
                  ? 'Repeat all'
                  : 'Repeat off',
          onPressed: _ready ? _cycleSessionRepeat : null,
          icon: Icon(
              mode == 'one' ? Icons.repeat_one_rounded : Icons.repeat_rounded),
        ),
      ],
    );
  }

  Widget _buildHostControls() {
    final scheme = Theme.of(context).colorScheme;
    final hasPrev = _c.currentIndex > 0;
    final hasNext = _c.currentIndex < _c.queue.length - 1;
    return StreamBuilder<PlayerState>(
      stream: _c.player.playerStateStream,
      builder: (context, snap) {
        final playing = snap.data?.playing ?? false;
        Widget btn(IconData icon, VoidCallback? onTap, double size) => IconButton(
              iconSize: size,
              color: onTap == null
                  ? scheme.onSurface.withAlpha(60)
                  : scheme.onSurface,
              onPressed: onTap,
              icon: Icon(icon),
            );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Previous track in the queue
                btn(
                    Icons.skip_previous_rounded,
                    (_ready && hasPrev)
                        ? () => _c.playIndex(_c.currentIndex - 1)
                        : null,
                    30),
                btn(Icons.replay_10_rounded,
                    _ready ? () => _liveSeekBy(-10) : null, 26),
                IconButton.filled(
                  iconSize: 40,
                  onPressed: !_ready
                      ? null
                      : () => playing ? _c.player.pause() : _c.player.play(),
                  icon: Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                ),
                btn(Icons.forward_10_rounded,
                    _ready ? () => _liveSeekBy(10) : null, 26),
                // Next track in the queue
                btn(Icons.skip_next_rounded,
                    (_ready && hasNext) ? _c.nextTrack : null, 30),
              ],
            ),
            _sessionFlagControls(scheme),
          ],
        );
      },
    );
  }

  // Listener transport. Buttons don't touch the local player directly — they
  // send a request to the host, who executes it and broadcasts the result, so
  // host and listener stay perfectly in sync (and the host keeps final say).
  void _listenerSeekBy(int seconds) {
    // Work in REAL song time (our buffer may be a trimmed tail) so the seek we
    // ask the host for lands where the user expects.
    final dur = _c.liveDuration ?? Duration.zero;
    var target = _c.livePosition + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (dur > Duration.zero && target > dur) target = dur;
    _c.requestControl('seek', positionMs: target.inMilliseconds);
  }

  Widget _buildListenerControls() {
    final scheme = Theme.of(context).colorScheme;
    final hasPrev = _c.remoteIndex > 0;
    final hasNext = _c.remoteIndex < _c.remoteQueueTitles.length - 1;
    return StreamBuilder<PlayerState>(
      stream: _c.player.playerStateStream,
      builder: (context, snap) {
        final playing = snap.data?.playing ?? false;
        Widget btn(IconData icon, VoidCallback? onTap, double size) =>
            IconButton(
              iconSize: size,
              color: onTap == null
                  ? scheme.onSurface.withAlpha(60)
                  : scheme.onSurface,
              onPressed: onTap,
              icon: Icon(icon),
            );
        return Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                btn(
                    Icons.skip_previous_rounded,
                    (_ready && hasPrev)
                        ? () => _c.requestControl('prev')
                        : null,
                    30),
                btn(Icons.replay_10_rounded,
                    _ready ? () => _listenerSeekBy(-10) : null, 26),
                IconButton.filled(
                  iconSize: 40,
                  onPressed:
                      !_ready ? null : () => _c.requestControl('playpause'),
                  icon: Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                ),
                btn(Icons.forward_10_rounded,
                    _ready ? () => _listenerSeekBy(10) : null, 26),
                btn(
                    Icons.skip_next_rounded,
                    (_ready && hasNext)
                        ? () => _c.requestControl('next')
                        : null,
                    30),
              ],
            ),
            _sessionFlagControls(scheme),
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 2),
              child: Text(
                'Play, pause, or skip — the host hears it too 🎧',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        );
      },
    );
  }

  // Listener's read-only view of the host's queue.
  Widget _buildRemoteQueueList(ColorScheme scheme) {
    final titles = _c.remoteQueueTitles;
    if (titles.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Text(
          'The host hasn’t queued any extra songs yet.',
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: 4),
      itemCount: titles.length,
      itemBuilder: (_, i) {
        final isCurrent = i == _c.remoteIndex;
        final by = (i < _c.remoteQueueBy.length) ? _c.remoteQueueBy[i] : null;
        final hasBy = by != null && by.isNotEmpty;
        return ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          leading: Icon(
            isCurrent ? Icons.graphic_eq_rounded : Icons.music_note_rounded,
            size: 18,
            color: isCurrent ? scheme.primary : scheme.onSurfaceVariant,
          ),
          title: MarqueeText(
            text: titles[i],
            height: 18,
            style: TextStyle(
              fontSize: 13,
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              color: isCurrent ? scheme.primary : scheme.onSurface,
            ),
          ),
          subtitle: isCurrent
              ? Text('Now playing',
                  style: TextStyle(fontSize: 10.5, color: scheme.primary))
              : Text(hasBy ? 'added by $by · tap to play' : 'Tap to play',
                  style: TextStyle(
                      fontSize: 10.5, color: scheme.onSurfaceVariant)),
          // Tap a track → ask the host to jump to it (host stays authoritative).
          onTap: isCurrent
              ? null
              : () => _c.requestControl('play_index', index: i),
        );
      },
    );
  }

  // Shown when the connection drops — offer to reconnect. For the host this
  // only appears if the automatic reconnect couldn't get through; for the
  // listener it's the normal "rejoin" prompt.
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
            _isHost
                ? 'Your session is still open — reconnect to keep sharing with '
                    '${widget.peerName}.'
                : 'If ${widget.peerName} is still live, you can rejoin.',
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

  // ── Host queue (fixed header + independently-scrolling list) ─────────────────
  Widget _buildQueueHeader(ColorScheme scheme) {
    final count = _isHost ? _c.queue.length : _c.remoteQueueTitles.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      child: Row(
        children: [
          Icon(Icons.queue_music_rounded, size: 18, color: scheme.primary),
          const SizedBox(width: 6),
          Text('Queue ($count)',
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          const Spacer(),
          // Host of a room: toggle whether guests may add songs (Stage C).
          if (widget.isRoom && _isHost) _guestToggle(scheme),
          // Only the host can add to their own queue directly.
          if (_isHost)
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
          // Guest in a room where the host opened contributions → add a song.
          if (!_isHost && _c.remoteContribAllowed)
            TextButton.icon(
              onPressed: _contributeSong,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add a song'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
        ],
      ),
    );
  }

  /// HOST (room): a compact switch for "let guests add songs to the queue".
  Widget _guestToggle(ColorScheme scheme) {
    final on = _c.allowContributions;
    return InkWell(
      onTap: () => setState(() => _c.setAllowContributions(!on)),
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(on ? Icons.group_add_rounded : Icons.group_outlined,
                size: 16,
                color: on ? scheme.primary : scheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(on ? 'Guests can add' : 'Guests off',
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: on ? scheme.primary : scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  Widget _buildQueueList(ColorScheme scheme) {
    final q = _c.queue;
    return ListView.builder(
      // Fills the space the parent Flexible gives it; scrolls independently as
      // the queue grows. shrinkWrap keeps it small when the queue is short.
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: 4),
      itemCount: q.length,
      itemBuilder: (_, i) {
        final t = q[i];
        final isCurrent = i == _c.currentIndex;
        final upcoming = i > _c.currentIndex;
        return ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          leading: Icon(
            isCurrent ? Icons.graphic_eq_rounded : Icons.music_note_rounded,
            size: 18,
            color: isCurrent ? scheme.primary : scheme.onSurfaceVariant,
          ),
          title: MarqueeText(
            text: t.title,
            height: 18,
            style: TextStyle(
              fontSize: 13,
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              color: isCurrent ? scheme.primary : scheme.onSurface,
            ),
          ),
          subtitle: isCurrent
              ? Text('Now playing',
                  style: TextStyle(fontSize: 10.5, color: scheme.primary))
              : (t.contributor != null
                  ? Text('added by ${t.contributor}',
                      style: TextStyle(
                          fontSize: 10.5, color: scheme.onSurfaceVariant))
                  : null),
          trailing: upcoming
              ? IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  tooltip: 'Remove from queue',
                  onPressed: () => _c.removeUpcoming(i),
                )
              : null,
          onTap: isCurrent ? null : () => _c.playIndex(i),
        );
      },
    );
  }

  /// Present the loaded music library and return the chosen path (or null).
  Future<String?> _pickLoadedSong(String heading) async {
    final loaded = playlistNotifier.value;
    if (loaded.isEmpty) {
      _snack('Load songs in your music player first');
      return null;
    }
    final scheme = Theme.of(context).colorScheme;
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          // Kick off the (bounded) pass that flags partner-instant songs, then
          // rebuild the sheet as each result lands. Runs once per open.
          _computeInstantHints(loaded, () {
            if (ctx.mounted) setSheet(() {});
          });
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(heading,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: loaded.length,
                    itemBuilder: (_, i) {
                      final p = loaded[i];
                      final instant = _instantPaths.contains(p);
                      return ListTile(
                        leading: Icon(Icons.music_note_rounded,
                            color: scheme.primary),
                        title: Text(_titleFromPath(p),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: instant
                            ? Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: scheme.primary.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.bolt_rounded,
                                        size: 14, color: scheme.primary),
                                    const SizedBox(width: 2),
                                    Text('Instant',
                                        style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: scheme.primary)),
                                  ],
                                ),
                              )
                            : null,
                        onTap: () => Navigator.pop(ctx, p),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 4),
              ],
            ),
          );
        },
      ),
    );
  }

  // Whether the instant-hint pass is already running for the current open (so
  // the StatefulBuilder rebuild doesn't launch a second one).
  bool _computingHints = false;

  /// Read+fingerprint each loaded song (bounded, sequential, cached by path) and
  /// mark the ones the partner can play with zero transfer. Best-effort: any
  /// read error just leaves that song un-flagged. [onProgress] is called as
  /// results accumulate so the open picker can repaint.
  Future<void> _computeInstantHints(
      List<String> loaded, VoidCallback onProgress) async {
    if (_computingHints) return;
    final peerHashes = _c.peerInstantHashes;
    if (peerHashes.isEmpty) return; // nothing known yet → no hints to show
    _computingHints = true;
    try {
      const cap = 80; // don't hash an unbounded library on one picker open
      for (final p in loaded.take(cap)) {
        var fp = _fpByPath[p];
        if (fp == null) {
          try {
            final bytes = Uint8List.fromList(await readFileBytes(p));
            if (bytes.isEmpty) continue;
            fp = liveTrackFingerprint(bytes);
            _fpByPath[p] = fp;
          } catch (_) {
            continue;
          }
        }
        // Newly discovered instant match → repaint the open sheet.
        if (peerHashes.contains(fp) && _instantPaths.add(p)) onProgress();
      }
    } finally {
      _computingHints = false;
    }
  }

  Future<void> _addSongToQueue() async {
    final chosen = await _pickLoadedSong('Add to queue');
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

  /// LISTENER (room, contributions on): pick a song and upload it to the host,
  /// who drops it into the shared queue attributed to me.
  Future<void> _contributeSong() async {
    final chosen = await _pickLoadedSong('Add a song to the room');
    if (chosen == null || !mounted) return;
    try {
      final bytes = Uint8List.fromList(await readFileBytes(chosen));
      if (bytes.isEmpty) {
        _snack('That track appears to be empty.');
        return;
      }
      if (bytes.length > 20 * 1024 * 1024) {
        _snack('That song is too large to add to the room.');
        return;
      }
      _snack('Sending to the room…');
      final ok = await _c.contributeTrack(
        bytes,
        _titleFromPath(chosen),
        by: widget.myName,
      );
      if (!mounted) return;
      _snack(ok ? 'Added to the room queue 🎶' : 'Could not add that song');
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

// ── Live reaction floats ("concert lighter") ─────────────────────────────────
class _FloatReaction {
  _FloatReaction(this.id, this.emoji, this.dx);
  final int id;
  final String emoji;
  final double dx; // 0..1 horizontal position across the sheet
}

// A single emoji that rises and fades, then removes itself via [onDone].
class _RisingEmoji extends StatefulWidget {
  const _RisingEmoji({
    super.key,
    required this.emoji,
    required this.dx,
    required this.onDone,
  });
  final String emoji;
  final double dx;
  final VoidCallback onDone;

  @override
  State<_RisingEmoji> createState() => _RisingEmojiState();
}

class _RisingEmojiState extends State<_RisingEmoji>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ac = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1700),
  );

  @override
  void initState() {
    super.initState();
    _ac.addStatusListener((st) {
      if (st == AnimationStatus.completed) widget.onDone();
    });
    _ac.forward();
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ac,
      builder: (context, _) {
        final t = _ac.value;
        final rise = 150.0 * Curves.easeOut.transform(t);
        final fade = t < 0.12 ? (t / 0.12) : (1.0 - (t - 0.12) / 0.88);
        final scale = 0.7 + 0.5 * Curves.easeOutBack.transform(t.clamp(0.0, 1.0));
        return Align(
          // dx 0..1 → alignment -1..1 (left→right), anchored to the bottom.
          alignment: Alignment(widget.dx * 2 - 1, 1.0),
          child: Transform.translate(
            offset: Offset(10.0 * math.sin(t * math.pi * 3), -(28 + rise)),
            child: Opacity(
              opacity: fade.clamp(0.0, 1.0),
              child: Transform.scale(
                scale: scale,
                child: Text(widget.emoji, style: const TextStyle(fontSize: 28)),
              ),
            ),
          ),
        );
      },
    );
  }
}

// A tappable quick-reaction chip (emoji) with a tiny press bounce.
class _ReactionButton extends StatefulWidget {
  const _ReactionButton({
    required this.emoji,
    required this.onTap,
    required this.scheme,
  });
  final String emoji;
  final VoidCallback onTap;
  final ColorScheme scheme;

  @override
  State<_ReactionButton> createState() => _ReactionButtonState();
}

class _ReactionButtonState extends State<_ReactionButton> {
  double _scale = 1.0;

  void _bounce() {
    widget.onTap();
    setState(() => _scale = 1.3);
    Future.delayed(const Duration(milliseconds: 120), () {
      if (mounted) setState(() => _scale = 1.0);
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _bounce,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: widget.scheme.surfaceContainerHighest.withValues(alpha: 0.6),
            shape: BoxShape.circle,
          ),
          child: Text(widget.emoji, style: const TextStyle(fontSize: 18)),
        ),
      ),
    );
  }
}
