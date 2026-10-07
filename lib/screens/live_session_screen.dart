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
import 'music/player_disc_style.dart'
    show PlayerDisc, PlayerStyleController, showPlayerStyleSheet;
import 'relationship_space_page.dart' show pickDiaryReaction;
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

class _LiveSessionScreenState extends State<LiveSessionScreen>
    with SingleTickerProviderStateMixin {
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
  // Who's dropped in (from the server roster) and a live feed of reactions with
  // the sender attached — the "People" + "Chat" regions of the hub.
  final List<_Participant> _participants = [];
  final List<_ReactionLog> _reactionFeed = [];
  // The group-chat composer for the reactions column, and whether the "In the
  // room" avatar strip is collapsed to give the feed more vertical room.
  final TextEditingController _commentCtrl = TextEditingController();
  final FocusNode _commentFocus = FocusNode();
  bool _peopleCollapsed = false;
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

  // Drives the now-playing-style disc rotation (one slow turn), running while
  // audio plays and paused otherwise — like the main Now Playing screen.
  late final AnimationController _discSpin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 10),
  );

  void _syncDiscSpin(bool playing) {
    if (playing) {
      if (!_discSpin.isAnimating) _discSpin.repeat();
    } else {
      if (_discSpin.isAnimating) _discSpin.stop();
    }
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
        final fromId = (e['from_id'] as num?)?.toInt();
        _spawnReaction(em, fromId: fromId);
        break;
      case 'comment':
        final txt = (e['text'] ?? '').toString();
        final cFrom = (e['from_id'] as num?)?.toInt();
        if (txt.trim().isNotEmpty) _logComment(txt, cFrom);
        break;
      case 'session_roster':
        final people = ((e['data'] as Map?)?['people'] as List?) ?? const [];
        _setRoster(people);
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
  void _spawnReaction(String emoji, {bool mine = false, int? fromId}) {
    if (!mounted) return;
    if (mine) _c.sendReaction(emoji);
    final id = _floatSeq++;
    final dx = 0.12 + _rand.nextDouble() * 0.76;
    setState(() {
      _floats.add(_FloatReaction(id, emoji, dx));
      _reactionCount++;
    });
    _logReaction(emoji, mine ? widget.myUserId : fromId, mine: mine);
  }

  void _setRoster(List people) {
    final list = <_Participant>[];
    for (final p in people) {
      if (p is! Map) continue;
      list.add(_Participant(
        id: (p['id'] as num?)?.toInt() ?? 0,
        name: (p['username'] ?? 'Someone').toString(),
        avatar: (p['avatar_url'] as String?),
        isHost: p['is_host'] == true,
      ));
    }
    if (!mounted) return;
    setState(() {
      // Carry each person's last reaction across a roster refresh.
      final prev = {for (final x in _participants) x.id: x.lastReaction};
      for (final x in list) {
        x.lastReaction = prev[x.id];
      }
      _participants
        ..clear()
        ..addAll(list);
    });
  }

  void _logReaction(String emoji, int? fromId, {bool mine = false}) {
    if (!mounted) return;
    String name;
    if (mine) {
      name = 'You';
      final i = _participants.indexWhere((x) => x.id == widget.myUserId);
      if (i != -1) _participants[i].lastReaction = emoji;
    } else {
      final i =
          fromId == null ? -1 : _participants.indexWhere((x) => x.id == fromId);
      name = i == -1 ? 'Someone' : _participants[i].name;
      if (i != -1) _participants[i].lastReaction = emoji;
    }
    setState(() {
      _reactionFeed.insert(0, _ReactionLog(name, emoji, DateTime.now()));
      if (_reactionFeed.length > 50) _reactionFeed.removeLast();
    });
  }

  // A typed chat line in the reactions column. [fromId] == my id (or mine)
  // resolves to "You"; otherwise it's looked up in the roster.
  void _logComment(String text, int? fromId, {bool mine = false}) {
    if (!mounted) return;
    String name;
    if (mine || fromId == widget.myUserId) {
      name = 'You';
      mine = true;
    } else {
      final i =
          fromId == null ? -1 : _participants.indexWhere((x) => x.id == fromId);
      name = i == -1 ? 'Someone' : _participants[i].name;
    }
    setState(() {
      _reactionFeed.insert(
          0, _ReactionLog(name, '', DateTime.now(), text: text, mine: mine));
      if (_reactionFeed.length > 80) _reactionFeed.removeLast();
    });
  }

  // Send whatever is in the composer as a chat line, and echo it locally.
  void _sendComment() {
    final t = _commentCtrl.text.trim();
    if (t.isEmpty) return;
    _c.sendComment(t);
    _commentCtrl.clear();
    _logComment(t, widget.myUserId, mine: true);
    // Keep the keyboard up for a back-and-forth, like a group chat.
    _commentFocus.requestFocus();
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
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: scheme.outlineVariant.withAlpha(55)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final em in _quickReactions)
              _ReactionButton(
                emoji: em,
                onTap: () => _spawnReaction(em, mine: true),
                scheme: scheme,
              ),
            // A slim divider, then "More" → the full emoji keyboard.
            Container(
              width: 1,
              height: 20,
              color: scheme.outlineVariant.withAlpha(70),
            ),
            GestureDetector(
              onTap: _pickMoreReaction,
              child: Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.add_reaction_outlined,
                    size: 17, color: scheme.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickMoreReaction() async {
    final em = await pickDiaryReaction(context, Theme.of(context).colorScheme.primary);
    if (em != null && em.isNotEmpty) _spawnReaction(em, mine: true);
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
    _discSpin.dispose();
    _commentCtrl.dispose();
    _commentFocus.dispose();
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
    // Full-page Listen Together hub (was a bottom sheet). Back/▾ minimises
    // (keeps the session streaming); the ✕ ends/leaves.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (activeLiveSession != null) {
          _minimize();
        } else {
          _leaveOrEnd();
        }
      },
      child: Scaffold(
        backgroundColor: scheme.surface,
        appBar: AppBar(
          backgroundColor: scheme.surfaceContainerHighest,
          elevation: 0,
          leading: IconButton(
            tooltip: 'Minimize — keep listening while you chat',
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
            onPressed: activeLiveSession != null ? _minimize : _leaveOrEnd,
          ),
          titleSpacing: 0,
          title: Row(
            children: [
              Icon(Icons.headphones_rounded, color: scheme.primary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_isHost ? 'Listen Together · DJ' : 'Listen Together',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    Text(
                      _isHost
                          ? 'Sharing with ${widget.peerName}'
                          : 'Hosted by ${widget.peerName}',
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
          actions: [
            IconButton(
              tooltip: _isHost ? 'End session' : 'Leave',
              icon: const Icon(Icons.close_rounded),
              onPressed: _leaveOrEnd,
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Stack(
            children: [
              LayoutBuilder(
                builder: (ctx, c) {
                  // Wide (desktop/window): three columns — people + reactions
                  // on the left, the player in the middle, the queue on the
                  // right — with the transport controls as a bottom bar.
                  // Narrow (phone): the player on top, then [Queue · People]
                  // tabs. Reactions float over everything in both.
                  return c.maxWidth >= 760
                      ? _wideLayout(theme, scheme)
                      : _narrowLayout(theme, scheme);
                },
              ),
              _floatingLayer(),
            ],
          ),
        ),
      ),
    );
  }

  // ── Wide (desktop) three-column layout ──────────────────────────────────────
  Widget _wideLayout(ThemeData theme, ColorScheme scheme) {
    final div = VerticalDivider(
        width: 1, color: scheme.outlineVariant.withAlpha(90));
    return Column(
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 300, child: _peoplePanel(scheme)),
              div,
              Expanded(child: _centerPlayer(theme, scheme)),
              div,
              SizedBox(width: 340, child: _queueSection(scheme)),
            ],
          ),
        ),
        _bottomControlsBar(scheme),
      ],
    );
  }

  // ── Narrow (phone) layout: player on top, [Queue · People] tabs below ───────
  Widget _narrowLayout(ThemeData theme, ColorScheme scheme) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          _mobilePlayerTop(theme, scheme),
          TabBar(
            labelColor: scheme.primary,
            unselectedLabelColor: scheme.onSurfaceVariant,
            indicatorColor: scheme.primary,
            tabs: const [
              Tab(height: 40, child: Text('Queue')),
              Tab(height: 40, child: Text('People')),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _queueSection(scheme),
                _peoplePanel(scheme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // The player in the middle (wide) — disc + waveform only; controls live in
  // the bottom bar there.
  Widget _centerPlayer(ThemeData theme, ColorScheme scheme) {
    // A soft ambient glow behind the disc gives the centre stage a little
    // "concert" depth and balances the visual weight of the two side columns.
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -0.42),
          radius: 0.9,
          colors: [
            scheme.primary.withValues(alpha: 0.09),
            scheme.primary.withValues(alpha: 0.0),
          ],
        ),
      ),
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 26),
              _discHero(theme, scheme, side: 158),
              const SizedBox(height: 18),
              if (_lostConnection)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: _buildReconnect(scheme),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: _buildSeekBar(),
                ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  // The player on top (phone) — disc + waveform + controls + quick reactions.
  Widget _mobilePlayerTop(ThemeData theme, ColorScheme scheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        _discHero(theme, scheme, side: 104),
        const SizedBox(height: 8),
        if (_lostConnection)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: _buildReconnect(scheme),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _buildSeekBar(),
          ),
          const SizedBox(height: 2),
          if (_isHost) _buildHostControls() else _buildListenerControls(),
          const SizedBox(height: 6),
          _reactionBar(scheme),
          const SizedBox(height: 6),
        ],
      ],
    );
  }

  // Bottom controls bar (wide): quick reactions + transport, spanning.
  Widget _bottomControlsBar(ColorScheme scheme) {
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(
            top: BorderSide(color: scheme.outlineVariant.withAlpha(70))),
      ),
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: _reactionBar(scheme),
          ),
          const SizedBox(height: 2),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: _isHost ? _buildHostControls() : _buildListenerControls(),
          ),
        ],
      ),
    );
  }

  // The queue half: a fixed header + the independently-scrolling up-next list.
  Widget _queueSection(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildQueueHeader(scheme),
        Expanded(
          child:
              _isHost ? _buildQueueList(scheme) : _buildRemoteQueueList(scheme),
        ),
      ],
    );
  }

  // Left column (wide) / "People" tab (phone): a strip of who's dropped in with
  // their latest reaction, then the live reactions/chat feed.
  Widget _peoplePanel(ColorScheme scheme) {
    final people = _participants;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── "In the room" header, with a hide/show toggle ──
        InkWell(
          onTap: () => setState(() => _peopleCollapsed = !_peopleCollapsed),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 6),
            child: Row(
              children: [
                Icon(Icons.group_rounded, size: 16, color: scheme.primary),
                const SizedBox(width: 6),
                Text('In the room',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurface)),
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('${people.length}',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: scheme.primary)),
                ),
                const Spacer(),
                // When collapsed, a compact stack of who's here so you still
                // know the room at a glance.
                if (_peopleCollapsed && people.isNotEmpty)
                  _miniAvatarStack(scheme, people),
                const SizedBox(width: 4),
                Icon(
                  _peopleCollapsed
                      ? Icons.keyboard_arrow_down_rounded
                      : Icons.keyboard_arrow_up_rounded,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        // ── The avatar strip (hidden when collapsed) ──
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          child: _peopleCollapsed
              ? const SizedBox(width: double.infinity)
              : SizedBox(
                  height: 70,
                  child: people.isEmpty
                      ? Center(
                          child: Text('Just you so far',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant)))
                      : ListView.separated(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          itemCount: people.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 10),
                          itemBuilder: (_, i) => _personChip(scheme, people[i]),
                        ),
                ),
        ),
        Divider(height: 12, color: scheme.outlineVariant.withAlpha(80)),
        // ── Chat & reactions header ──
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
          child: Row(
            children: [
              Icon(Icons.forum_rounded, size: 15, color: scheme.primary),
              const SizedBox(width: 6),
              Text('Chat & reactions',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface)),
            ],
          ),
        ),
        // ── The live feed (newest at the bottom, like a group chat) ──
        Expanded(
          child: _reactionFeed.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                        'Say something or tap a reaction \u{1F389}',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12.5, color: scheme.onSurfaceVariant)),
                  ),
                )
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: _reactionFeed.length,
                  itemBuilder: (_, i) => _feedRow(scheme, _reactionFeed[i]),
                ),
        ),
        // ── The composer: type a line to everyone in the room ──
        _commentComposer(scheme),
      ],
    );
  }

  // A few overlapping initial-avatars shown in the collapsed header.
  Widget _miniAvatarStack(ColorScheme scheme, List<_Participant> people) {
    final shown = people.take(3).toList();
    return SizedBox(
      width: 20.0 + (shown.length - 1) * 13.0,
      height: 24,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * 13.0,
              child: Container(
                padding: const EdgeInsets.all(1.5),
                decoration: BoxDecoration(
                    color: scheme.surface, shape: BoxShape.circle),
                child: CircleAvatar(
                  radius: 9,
                  backgroundColor: _nameColor(shown[i].name, scheme),
                  child: Text(
                      shown[i].name.isNotEmpty
                          ? shown[i].name[0].toUpperCase()
                          : '?',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // The group-chat composer at the foot of the reactions column.
  Widget _commentComposer(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      decoration: BoxDecoration(
        border: Border(
            top: BorderSide(color: scheme.outlineVariant.withAlpha(70))),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _commentCtrl,
              focusNode: _commentFocus,
              textInputAction: TextInputAction.send,
              minLines: 1,
              maxLines: 3,
              onSubmitted: (_) => _sendComment(),
              style: const TextStyle(fontSize: 13.5),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Message the room…',
                hintStyle: TextStyle(
                    fontSize: 13, color: scheme.onSurfaceVariant),
                filled: true,
                fillColor: scheme.surfaceContainerHighest,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: scheme.primary,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _sendComment,
              child: Padding(
                padding: const EdgeInsets.all(9),
                child: Icon(Icons.send_rounded,
                    size: 18, color: scheme.onPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _nameColor(String name, ColorScheme scheme) {
    var h = 0;
    for (final cu in name.codeUnits) {
      h = (h * 31 + cu) & 0x7fffffff;
    }
    return HSLColor.fromAHSL(1.0, (h % 360).toDouble(), 0.5,
            scheme.brightness == Brightness.dark ? 0.62 : 0.5)
        .toColor();
  }

  Widget _personChip(ColorScheme scheme, _Participant p) {
    final initial = p.name.isNotEmpty ? p.name[0].toUpperCase() : '?';
    return SizedBox(
      width: 56,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: _nameColor(p.name, scheme),
                child: Text(initial,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15)),
              ),
              if (p.isHost)
                Positioned(
                  bottom: -3,
                  right: -3,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.headphones_rounded,
                        size: 12, color: scheme.primary),
                  ),
                ),
              if (p.lastReaction != null)
                Positioned(
                  top: -8,
                  right: -8,
                  child: Text(p.lastReaction!,
                      style: const TextStyle(fontSize: 15)),
                ),
            ],
          ),
          const SizedBox(height: 3),
          Text(p.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10.5, color: scheme.onSurface)),
        ],
      ),
    );
  }

  Widget _feedRow(ColorScheme scheme, _ReactionLog r) {
    // A typed comment → a group-chat bubble (mine tinted + right-aligned).
    if (r.isComment) return _commentBubble(scheme, r);
    // A reaction → a soft inline pill, "<emoji> <name> reacted".
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Text(r.emoji, style: const TextStyle(fontSize: 16)),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: RichText(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              text: TextSpan(
                style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                children: [
                  TextSpan(
                      text: r.name,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: r.mine
                              ? scheme.primary
                              : _nameColor(r.name, scheme))),
                  const TextSpan(text: ' reacted'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // A chat bubble for a typed comment — sender name, then the text, with
  // my own lines tinted and pushed to the right like a messaging thread.
  Widget _commentBubble(ColorScheme scheme, _ReactionLog r) {
    final mine = r.mine;
    final bubbleColor = mine
        ? scheme.primary.withValues(alpha: 0.16)
        : scheme.surfaceContainerHighest;
    final nameColor = mine ? scheme.primary : _nameColor(r.name, scheme);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Column(
        crossAxisAlignment:
            mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Text(r.name,
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: nameColor)),
          const SizedBox(height: 2),
          Align(
            alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 230),
              padding:
                  const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(14),
                  topRight: const Radius.circular(14),
                  bottomLeft: Radius.circular(mine ? 14 : 4),
                  bottomRight: Radius.circular(mine ? 4 : 14),
                ),
              ),
              child: Text(r.text ?? '',
                  style: TextStyle(fontSize: 13, color: scheme.onSurface)),
            ),
          ),
        ],
      ),
    );
  }

  // Now-Playing-style disc hero: the user's chosen player style, spinning while
  // audio plays, tap to restyle — plus the track title and who you're with.
  Widget _discHero(ThemeData theme, ColorScheme scheme, {double side = 132}) {
    final isDark = scheme.brightness == Brightness.dark;
    final accent = scheme.primary;
    return StreamBuilder<PlayerState>(
      stream: _c.player.playerStateStream,
      builder: (ctx, snap) {
        final playing = snap.data?.playing ?? false;
        _syncDiscSpin(playing);
        return AnimatedBuilder(
          animation: PlayerStyleController.instance,
          builder: (ctx2, _) {
            final style = PlayerStyleController.instance.style;
            return Column(
              children: [
                GestureDetector(
                  onTap: () => showPlayerStyleSheet(context, accent: accent),
                  child: SizedBox(
                    width: side,
                    height: side,
                    child: PlayerDisc(
                      style: style,
                      side: side,
                      accent: accent,
                      scheme: scheme,
                      isDark: isDark,
                      spin: _discSpin,
                      playing: playing,
                      dimmed: PlayerStyleController.instance.orbDimmed,
                      artBuilder: (d, [col]) => Center(
                        child: Icon(Icons.music_note_rounded,
                            size: d * 0.4,
                            color: col ?? Colors.white.withValues(alpha: 0.9)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: MarqueeText(
                    text: _title,
                    height: 24,
                    style: (theme.textTheme.titleMedium ??
                            const TextStyle(fontSize: 16))
                        .copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _isHost ? 'You’re the DJ · $_status' : _status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor),
                ),
              ],
            );
          },
        );
      },
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
        final scheme = Theme.of(context).colorScheme;
        final frac = max <= 0 ? 0.0 : (value / max).clamp(0.0, 1.0);
        void seekTo(double f) {
          final ms = (f * max).round();
          if (_isHost) {
            _c.player.seek(Duration(milliseconds: ms));
          } else {
            // Listener scrub → ask the host; host seeks and the new position is
            // broadcast back so everyone stays in sync.
            _c.requestControl('seek', positionMs: ms);
          }
        }

        return Column(
          children: [
            _LiveWaveformSeekBar(
              fraction: frac,
              accent: scheme.primary,
              inactive: scheme.onSurface.withValues(alpha: 0.18),
              enabled: max > 0,
              seed: _title.hashCode,
              onSeek: seekTo,
              labelFor: (f) => _fmt(Duration(milliseconds: (f * max).round())),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_fmt(pos),
                    style: TextStyle(
                        fontSize: 11.5, color: scheme.onSurfaceVariant)),
                Text(_fmt(dur),
                    style: TextStyle(
                        fontSize: 11.5, color: scheme.onSurfaceVariant)),
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

  // Compact shuffle / repeat buttons — now ride at the ends of the single
  // transport row (modernised, one line, so the queue keeps its height).
  Widget _shuffleBtn(ColorScheme scheme) {
    final on = _c.shuffle;
    return IconButton(
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      color: on ? scheme.primary : scheme.onSurface.withAlpha(110),
      tooltip: on ? 'Shuffle on' : 'Shuffle off',
      onPressed: _ready ? () => _c.setShuffle(!on) : null,
      icon: const Icon(Icons.shuffle_rounded),
    );
  }

  Widget _repeatBtn(ColorScheme scheme) {
    final mode = _c.repeatMode;
    final on = mode != 'off';
    return IconButton(
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      color: on ? scheme.primary : scheme.onSurface.withAlpha(110),
      tooltip: mode == 'one'
          ? 'Repeat one'
          : mode == 'all'
              ? 'Repeat all'
              : 'Repeat off',
      onPressed: _ready ? _cycleSessionRepeat : null,
      icon: Icon(
          mode == 'one' ? Icons.repeat_one_rounded : Icons.repeat_rounded),
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
        Widget btn(IconData icon, VoidCallback? onTap, double size) =>
            IconButton(
              iconSize: size,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.all(6),
              constraints: const BoxConstraints(),
              color: onTap == null
                  ? scheme.onSurface.withAlpha(60)
                  : scheme.onSurface,
              onPressed: onTap,
              icon: Icon(icon),
            );
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _shuffleBtn(scheme),
            btn(
                Icons.skip_previous_rounded,
                (_ready && hasPrev)
                    ? () => _c.playIndex(_c.currentIndex - 1)
                    : null,
                28),
            btn(Icons.replay_10_rounded,
                _ready ? () => _liveSeekBy(-10) : null, 24),
            IconButton.filled(
              iconSize: 34,
              onPressed: !_ready
                  ? null
                  : () => playing ? _c.player.pause() : _c.player.play(),
              icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
            ),
            btn(Icons.forward_10_rounded,
                _ready ? () => _liveSeekBy(10) : null, 24),
            btn(Icons.skip_next_rounded,
                (_ready && hasNext) ? _c.nextTrack : null, 28),
            _repeatBtn(scheme),
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
        // Reflect the HOST's authoritative play state, not our local player:
        // after a reconnect our audio may still be buffering (local player
        // paused) while the host keeps playing, and a blind toggle would then
        // flip the host into pause. The stream just keeps this rebuilding; the
        // play/pause control events also setState the screen.
        final playing = _c.hostPlaying;
        Widget btn(IconData icon, VoidCallback? onTap, double size) =>
            IconButton(
              iconSize: size,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.all(6),
              constraints: const BoxConstraints(),
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
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _shuffleBtn(scheme),
                btn(
                    Icons.skip_previous_rounded,
                    (_ready && hasPrev)
                        ? () => _c.requestControl('prev')
                        : null,
                    28),
                btn(Icons.replay_10_rounded,
                    _ready ? () => _listenerSeekBy(-10) : null, 24),
                IconButton.filled(
                  iconSize: 34,
                  onPressed: !_ready
                      ? null
                      : () => _c.requestControl(playing ? 'pause' : 'play'),
                  icon: Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                ),
                btn(Icons.forward_10_rounded,
                    _ready ? () => _listenerSeekBy(10) : null, 24),
                btn(
                    Icons.skip_next_rounded,
                    (_ready && hasNext)
                        ? () => _c.requestControl('next')
                        : null,
                    28),
                _repeatBtn(scheme),
              ],
            ),
            Text(
              'You control the music — the host hears it too 🎧',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 10.5, color: scheme.onSurfaceVariant),
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
          tileColor:
              isCurrent ? scheme.primary.withValues(alpha: 0.07) : null,
          shape: isCurrent
              ? RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10))
              : null,
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
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 0),
      child: Row(
        children: [
          Icon(Icons.queue_music_rounded, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Text('Up next',
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 12.5,
                  color: scheme.onSurface)),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text('$count',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: scheme.primary)),
          ),
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
          tileColor:
              isCurrent ? scheme.primary.withValues(alpha: 0.07) : null,
          shape: isCurrent
              ? RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10))
              : null,
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
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: widget.scheme.surfaceContainerHighest.withValues(alpha: 0.6),
            shape: BoxShape.circle,
          ),
          child: Text(widget.emoji, style: const TextStyle(fontSize: 16)),
        ),
      ),
    );
  }
}

// ── Waveform seek bar (Now-Playing style) ────────────────────────────────────
// A scrubbable waveform matching the main player's look, wired to the session's
// position fraction. Deterministic bar heights per track for a stable pattern.
class _LiveWaveformSeekBar extends StatefulWidget {
  final double fraction; // 0..1 played
  final Color accent;
  final Color inactive;
  final bool enabled;
  final int seed;
  final ValueChanged<double> onSeek;
  final String Function(double fraction) labelFor;

  const _LiveWaveformSeekBar({
    required this.fraction,
    required this.accent,
    required this.inactive,
    required this.enabled,
    required this.seed,
    required this.onSeek,
    required this.labelFor,
  });

  @override
  State<_LiveWaveformSeekBar> createState() => _LiveWaveformSeekBarState();
}

class _LiveWaveformSeekBarState extends State<_LiveWaveformSeekBar> {
  static const int _bars = 48;
  double? _dragFrac;
  late List<double> _heights;

  @override
  void initState() {
    super.initState();
    _heights = _gen(widget.seed);
  }

  @override
  void didUpdateWidget(covariant _LiveWaveformSeekBar old) {
    super.didUpdateWidget(old);
    if (old.seed != widget.seed) _heights = _gen(widget.seed);
  }

  List<double> _gen(int seed) {
    var x = (seed & 0x7fffffff) | 1;
    final out = <double>[];
    for (var i = 0; i < _bars; i++) {
      x = (x * 1103515245 + 12345) & 0x7fffffff;
      out.add(0.26 + (x % 1000) / 1000.0 * 0.74);
    }
    return out;
  }

  void _setFromDx(double dx, double w) {
    if (w <= 0) return;
    setState(() => _dragFrac = (dx / w).clamp(0.0, 1.0));
  }

  void _commit() {
    final f = _dragFrac;
    if (f != null) widget.onSeek(f);
    setState(() => _dragFrac = null);
  }

  @override
  Widget build(BuildContext context) {
    final frac = (_dragFrac ?? widget.fraction).clamp(0.0, 1.0);
    return LayoutBuilder(
      builder: (ctx, c) {
        final w = c.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown:
              widget.enabled ? (d) => _setFromDx(d.localPosition.dx, w) : null,
          onTapUp: widget.enabled ? (_) => _commit() : null,
          onTapCancel:
              widget.enabled ? () => setState(() => _dragFrac = null) : null,
          onHorizontalDragStart:
              widget.enabled ? (d) => _setFromDx(d.localPosition.dx, w) : null,
          onHorizontalDragUpdate:
              widget.enabled ? (d) => _setFromDx(d.localPosition.dx, w) : null,
          onHorizontalDragEnd: widget.enabled ? (_) => _commit() : null,
          child: SizedBox(
            height: 38,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _LiveWavePainter(
                      heights: _heights,
                      fraction: frac,
                      accent: widget.accent,
                      inactive: widget.inactive,
                    ),
                  ),
                ),
                if (_dragFrac != null)
                  Positioned(
                    left: (frac * w - 24).clamp(0.0, (w - 48).clamp(0.0, w)),
                    top: -24,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: widget.accent,
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.25),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Text(
                        widget.labelFor(frac),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LiveWavePainter extends CustomPainter {
  final List<double> heights;
  final double fraction;
  final Color accent;
  final Color inactive;

  _LiveWavePainter({
    required this.heights,
    required this.fraction,
    required this.accent,
    required this.inactive,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = heights.length;
    if (n == 0) return;
    const gap = 2.0;
    final barW = (size.width - gap * (n - 1)) / n;
    if (barW <= 0) return;
    final playedX = fraction * size.width;
    final mid = size.height / 2;
    final aPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = accent;
    final iPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = inactive;
    for (var i = 0; i < n; i++) {
      final x = i * (barW + gap);
      final h = (heights[i] * size.height).clamp(3.0, size.height);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, mid - h / 2, barW, h),
        Radius.circular(barW / 2),
      );
      canvas.drawRRect(rect, (x + barW) <= playedX ? aPaint : iPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _LiveWavePainter old) =>
      old.fraction != fraction ||
      old.accent != accent ||
      old.inactive != inactive ||
      old.heights != heights;
}

// ── People & reactions models ────────────────────────────────────────────────
class _Participant {
  _Participant({
    required this.id,
    required this.name,
    this.avatar,
    this.isHost = false,
  });
  final int id;
  final String name;
  final String? avatar;
  final bool isHost;
  String? lastReaction; // their most recent emoji, shown beside the avatar
}

class _ReactionLog {
  _ReactionLog(this.name, this.emoji, this.at, {this.text, this.mine = false});
  final String name;
  final String emoji; // '' for a typed comment
  final String? text; // non-null → this entry is a typed chat line
  final bool mine; // sent by this device (align/colour differently)
  final DateTime at;
  bool get isComment => text != null;
}
