import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../screens/api_service.dart';
import '../state/group_call_state.dart';
import '../state/playback_state.dart' show providerContainer;
import 'ice_config.dart';
import 'notif_service.dart';
import 'telecom_service.dart';

/// One participant in a group call (a peer, or a known roster member).
class GroupParticipant {
  final int id;
  String name;
  String? avatar;
  String? phone;
  MediaStream? stream;
  GroupParticipant(this.id, this.name, this.avatar, {this.phone});
}

/// Aluta in-app **group** voice calling over a WebRTC MESH: each participant
/// holds one peer connection to every other participant, so audio flows
/// directly peer-to-peer and the server only relays signaling (no media, no
/// media-server cost). Solid for small group chats (~5); beyond that an SFU
/// would be the next step.
///
/// Signaling rides the same per-user notification WebSocket as 1:1 calls:
/// [sendSignal] transmits a message (each carries `type` + `room` + `to`) and
/// [onSignal] is fed every inbound `group_*` event.
class GroupCallService {
  GroupCallService._();
  static final GroupCallService instance = GroupCallService._();

  void Function(Map<String, dynamic> msg)? sendSignal;
  void Function()? onShowUI;

  /// Resolve a user id → {'name', 'phone', 'avatar'} from the app's own roster
  /// (friend list + group members). Wired by the app layer. The backend's
  /// group-call signaling carries only bare user ids — no names — so identities
  /// must be filled locally; this makes proper names/phones appear on EVERY
  /// entry path, including accepting a ring (which seeds no member list), and
  /// immediately as each peer appears rather than only once the call connects.
  Map<String, dynamic>? Function(int userId)? resolveIdentity;

  GroupCallPhase phase = GroupCallPhase.idle;
  int? room; // conversation id acting as the call room
  String title = '';
  int? myId;
  bool muted = false;
  bool speakerOn = false;
  DateTime? connectedAt; // when I joined — drives the elapsed-time label

  // Incoming-call caller info (for the ring screen).
  String incomingCaller = '';

  // Group calls currently ACTIVE somewhere that I could join (roomId → title).
  // Populated from group_call_incoming (a call started/ongoing) and a REST
  // check when opening a group; cleared on group_call_ended. The group chat
  // surface watches this to show a "call in progress · Join" banner so a member
  // who missed or declined the ring can still reconnect.
  final ValueNotifier<Map<int, String>> ongoingCalls =
      ValueNotifier<Map<int, String>>({});

  void _setOngoing(int room, String title) {
    final next = Map<int, String>.from(ongoingCalls.value);
    next[room] = title.isEmpty ? 'Group call' : title;
    ongoingCalls.value = next;
  }

  void clearOngoing(int room) {
    if (!ongoingCalls.value.containsKey(room)) return;
    final next = Map<int, String>.from(ongoingCalls.value)..remove(room);
    ongoingCalls.value = next;
  }

  /// Seed/refresh the ongoing flag for a room (called after a REST check when a
  /// group opens, so a call that started while I was away still shows a banner).
  void setOngoingFromServer(int room, String title, bool active) {
    if (active) {
      _setOngoing(room, title);
    } else {
      clearOngoing(room);
    }
  }

  String get elapsedLabel {
    final t = connectedAt;
    if (t == null) return '';
    final s = DateTime.now().difference(t).inSeconds;
    final m = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$m:$ss';
  }

  // Known group members (for showing names/avatars even before they connect).
  final Map<int, GroupParticipant> roster = {};
  // Peers we are actually connected to (excludes me).
  final Map<int, GroupParticipant> participants = {};

  final Map<int, RTCPeerConnection> _peers = {};
  final Map<int, List<RTCIceCandidate>> _pendingIce = {};
  final Map<int, bool> _remoteSet = {};
  // WEB ONLY: one offscreen renderer per participant so the browser plays their
  // remote audio (web can't auto-play a remote WebRTC track like native does).
  final Map<int, RTCVideoRenderer> _renderers = {};
  MediaStream? _localStream;
  Timer? _ringTimeout;

  // Active-speaker detection. We poll each peer's WebRTC audio level and expose
  // the set of participant ids currently talking so the UI can glow their tile.
  final ValueNotifier<Set<int>> speakingIds = ValueNotifier<Set<int>>({});
  Timer? _levelTimer;
  // Per-peer "hold" ticks so a glowing tile doesn't flicker between words.
  final Map<int, int> _speakHold = {};
  // Audio level (0..1) above which a peer counts as speaking.
  static const double _speakThreshold = 0.02;

  // Call-history logging: the STARTER posts one call-log message to the group
  // thread when the call ends (single source of truth), with the duration and
  // whether anyone actually joined.
  bool _starter = false;
  bool _everConnected = false;
  bool _groupLogged = false;

  void _logGroupCallIfStarter() {
    if (!_starter || _groupLogged) return;
    final r = room;
    if (r == null) return;
    _groupLogged = true;
    final secs = connectedAt != null
        ? DateTime.now().difference(connectedAt!).inSeconds
        : 0;
    // 'answered' if others joined (success), else 'missed' (no one picked up).
    final outcome = (_everConnected && secs > 0) ? 'answered' : 'missed';
    unawaited(
      ApiService()
          .sendMessage(0, outcome,
              messageType: 'call', mediaDuration: secs, conversationId: r)
          .catchError((_) => null),
    );
  }

  bool get isActive =>
      phase == GroupCallPhase.active || phase == GroupCallPhase.ringing;

  // Stable id for mirroring this group call into the system telecom stack.
  String get _telecomId => 'grp_${room ?? 0}';

  /// Poll every peer connection's inbound audio level and publish who's talking.
  void _startLevelMonitor() {
    _levelTimer?.cancel();
    _levelTimer =
        Timer.periodic(const Duration(milliseconds: 350), (_) async {
      if (_peers.isEmpty) {
        if (speakingIds.value.isNotEmpty) speakingIds.value = <int>{};
        return;
      }
      final speaking = <int>{};
      for (final entry in _peers.entries) {
        final pid = entry.key;
        double level = 0;
        try {
          final reports = await entry.value.getStats();
          for (final r in reports) {
            // Only the REMOTE (inbound) audio level — this pc also carries our
            // own outbound mic level (media-source/outbound-rtp), which would
            // otherwise glow this peer when WE talk.
            final isInbound = r.type == 'inbound-rtp' ||
                (r.type == 'track' && r.values['remoteSource'] == true);
            if (!isInbound) continue;
            final a = r.values['audioLevel'];
            if (a is num && a.toDouble() > level) level = a.toDouble();
          }
        } catch (_) {/* stats unavailable this tick */}
        if (level > _speakThreshold) {
          _speakHold[pid] = 2; // ~700ms hold at a 350ms tick
        } else if ((_speakHold[pid] ?? 0) > 0) {
          _speakHold[pid] = _speakHold[pid]! - 1;
        }
        if ((_speakHold[pid] ?? 0) > 0) speaking.add(pid);
      }
      // Only publish on change so listeners don't rebuild needlessly.
      final cur = speakingIds.value;
      if (speaking.length != cur.length ||
          !speaking.every(cur.contains)) {
        speakingIds.value = speaking;
      }
    });
  }

  void _stopLevelMonitor() {
    _levelTimer?.cancel();
    _levelTimer = null;
    _speakHold.clear();
    if (speakingIds.value.isNotEmpty) speakingIds.value = <int>{};
  }

  // Same ICE config as 1:1 calls + Listen Together — fetched from the server
  // (see ice_config.dart) so the TURN relay can be swapped without an app
  // rebuild. STUN-only fallback if the fetch fails.
  static Future<Map<String, dynamic>> get _iceConfig =>
      IceConfig.instance.servers();

  static const Map<String, dynamic> _mediaConstraints = {
    'audio': true,
    'video': false,
  };

  static const Map<String, dynamic> _sdpConstraints = {
    'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': false},
    'optional': [],
  };

  void _publish() {
    final ids = participants.keys.toList()..sort();
    providerContainer.read(groupCallProvider.notifier).set(GroupCallSnapshot(
          phase: phase,
          title: title,
          participantIds: ids,
          muted: muted,
          speakerOn: speakerOn,
        ));
  }

  // ── Start / accept / leave ─────────────────────────────────────────────────

  /// Start a group call in [room] (the conversation id). Rings all members.
  Future<bool> startGroupCall({
    required int room,
    required String title,
    required int myId,
    required String myName,
    List<GroupParticipant> members = const [],
  }) async {
    if (isActive) return false;
    _reset();
    this.room = room;
    this.title = title;
    this.myId = myId;
    for (final m in members) {
      roster[m.id] = m;
    }
    phase = GroupCallPhase.active;
    connectedAt = DateTime.now();
    _starter = true; // I started this call → I post the call-log entry.
    clearOngoing(room);
    _publish();
    onShowUI?.call();
    TelecomService.instance.startOutgoing(_telecomId, title);
    TelecomService.instance.setActive(_telecomId);
    await _ensureLocalStream();
    _startLevelMonitor();
    sendSignal?.call({'type': 'group_call_start', 'room': room});
    return true;
  }

  /// Join an ONGOING group call from the "call in progress · Join" banner — a
  /// member who missed or declined the initial ring reconnecting. Same as
  /// accept() but seeded with the room/title/members directly instead of a ring.
  Future<bool> joinRoom({
    required int room,
    required String title,
    required int myId,
    required String myName,
    List<GroupParticipant> members = const [],
  }) async {
    if (isActive) return false;
    _reset();
    this.room = room;
    this.title = title;
    this.myId = myId;
    for (final m in members) {
      roster[m.id] = m;
    }
    phase = GroupCallPhase.active;
    connectedAt = DateTime.now();
    clearOngoing(room);
    _publish();
    onShowUI?.call();
    TelecomService.instance.startOutgoing(_telecomId, title);
    TelecomService.instance.setActive(_telecomId);
    await _ensureLocalStream();
    _startLevelMonitor();
    sendSignal?.call({'type': 'group_call_join', 'room': room});
    return true;
  }

  /// An inbound group-call ring (from WS or a tapped push).
  void handleIncoming(Map<String, dynamic> msg) {
    final r = _asInt(msg['room']);
    if (r == null) return;
    final t = (msg['title'] ?? 'Group call').toString();
    // Remember there's a live call in this group — powers the "Join" banner even
    // if the ring is missed or declined.
    _setOngoing(r, t);
    if (isActive) return; // already busy in a call; the banner lets me switch
    _reset();
    room = r;
    title = t;
    incomingCaller = (msg['caller_name'] ?? '').toString();
    phase = GroupCallPhase.ringing;
    _publish();
    onShowUI?.call();
    TelecomService.instance.reportIncoming(_telecomId, title);
    _ringTimeout = Timer(const Duration(seconds: 45), () {
      if (phase == GroupCallPhase.ringing) leave();
    });
  }

  /// Accept an incoming group call: join the room; the mesh forms as the server
  /// tells us who's already in.
  Future<void> accept() async {
    if (phase != GroupCallPhase.ringing || room == null) return;
    _ringTimeout?.cancel();
    cancelCallNotification();
    phase = GroupCallPhase.active;
    connectedAt = DateTime.now();
    clearOngoing(room!);
    _publish();
    TelecomService.instance.setActive(_telecomId);
    await _ensureLocalStream();
    _startLevelMonitor();
    sendSignal?.call({'type': 'group_call_join', 'room': room});
  }

  /// Leave / decline / hang up the group call.
  Future<void> leave() async {
    final r = room;
    final leftOthersBehind =
        phase == GroupCallPhase.active && participants.isNotEmpty;
    if (r != null && phase == GroupCallPhase.active) {
      sendSignal?.call({'type': 'group_call_leave', 'room': r});
    }
    // If the call is still going on (others remain), keep a Join banner so I can
    // hop back in. If I was the last one, the server broadcasts
    // group_call_ended which clears it for everyone.
    if (r != null && leftOthersBehind) {
      _setOngoing(r, title);
    }
    // Post the group's call-log entry (starter only) while room + connectedAt
    // are still valid.
    _logGroupCallIfStarter();
    TelecomService.instance.endCall(_telecomId);
    _ringTimeout?.cancel();
    cancelCallNotification();
    await _teardown();
    connectedAt = null;
    phase = GroupCallPhase.idle;
    _publish();
  }

  Future<void> _ensureLocalStream() async {
    if (_localStream != null) return;
    try {
      _localStream =
          await navigator.mediaDevices.getUserMedia(_mediaConstraints);
    } catch (_) {/* mic denied — call proceeds muted/limited */}
  }

  // ── Inbound signaling dispatch ─────────────────────────────────────────────

  Future<void> onSignal(Map<String, dynamic> msg) async {
    final type = msg['type']?.toString() ?? '';
    switch (type) {
      case 'group_call_incoming':
        handleIncoming(msg);
        break;
      case 'group_call_participants':
        final users = (msg['users'] as List?) ?? const [];
        for (final u in users) {
          final pid = _asInt(u is Map ? u['id'] : u);
          if (pid != null) {
            _addParticipant(pid, u is Map ? u : null);
            await _maybeOffer(pid);
          }
        }
        _publish();
        break;
      case 'group_call_peer_joined':
        final pid = _asInt(msg['user_id']);
        if (pid != null) {
          _addParticipant(pid, msg);
          await _maybeOffer(pid);
          _publish();
        }
        break;
      case 'group_call_peer_left':
        final pid = _asInt(msg['user_id']);
        if (pid != null) {
          await _removePeer(pid);
          _publish();
        }
        break;
      case 'group_offer':
        await _onOffer(msg);
        break;
      case 'group_answer':
        await _onAnswer(msg);
        break;
      case 'group_ice':
        await _onIce(msg);
        break;
      case 'group_call_ended':
        final er = _asInt(msg['room']);
        if (er != null) {
          clearOngoing(er);
          if (isActive && room == er) await leave();
        } else {
          // Legacy/no-room payload: only leave if we're actually in a call.
          if (isActive) await leave();
        }
        break;
    }
  }

  void _addParticipant(int pid, Map? info) {
    _everConnected = true; // someone else joined → the call actually happened
    final r = roster[pid];
    var name = (info?['name'] ?? r?.name ?? '').toString();
    var avatar = (info?['avatar'] as String?) ?? r?.avatar;
    var phone = (info?['phone'] as String?) ?? r?.phone;
    // The signaling (and the accept-a-ring path) may give us only an id. Fill
    // any missing identity from the app's own friend/group roster keyed by id,
    // so the tile shows the person's saved/registered name — never "Member".
    if (name.trim().isEmpty || (phone == null || phone.trim().isEmpty)) {
      final res = resolveIdentity?.call(pid);
      if (res != null) {
        if (name.trim().isEmpty) name = (res['name'] ?? '').toString();
        final rp = res['phone'] as String?;
        if ((phone == null || phone.trim().isEmpty) &&
            rp != null &&
            rp.trim().isNotEmpty) {
          phone = rp;
        }
        avatar ??= res['avatar'] as String?;
      }
    }
    final existing = participants[pid];
    if (existing == null) {
      participants[pid] = GroupParticipant(pid, name, avatar, phone: phone);
    } else {
      if (name.isNotEmpty) existing.name = name;
      if (avatar != null) existing.avatar = avatar;
      if (phone != null) existing.phone = phone;
    }
  }

  // Glare-free initiator rule: the peer with the SMALLER user id sends the
  // offer, the other waits — so exactly one offer is created per pair.
  Future<void> _maybeOffer(int pid) async {
    final me = myId;
    if (me == null || me >= pid) return;
    final pc = await _ensurePeer(pid);
    final offer = await pc.createOffer(_sdpConstraints);
    await pc.setLocalDescription(offer);
    _send(pid, {'type': 'group_offer', 'sdp': offer.sdp});
  }

  Future<RTCPeerConnection> _ensurePeer(int pid) async {
    final existing = _peers[pid];
    if (existing != null) return existing;
    final pc = await createPeerConnection(await _iceConfig);
    _peers[pid] = pc;
    _remoteSet[pid] = false;
    final ls = _localStream;
    if (ls != null) {
      for (final t in ls.getTracks()) {
        await pc.addTrack(t, ls);
      }
    }
    pc.onIceCandidate = (RTCIceCandidate c) {
      if (c.candidate == null) return;
      _send(pid, {
        'type': 'group_ice',
        'candidate': {
          'candidate': c.candidate,
          'sdpMid': c.sdpMid,
          'sdpMLineIndex': c.sdpMLineIndex,
        },
      });
    };
    pc.onTrack = (RTCTrackEvent e) async {
      if (e.streams.isEmpty) return;
      participants[pid]?.stream = e.streams.first;
      // Native plays remote audio automatically; on WEB each participant's
      // stream must be attached to a media element or their voice is silent.
      if (kIsWeb) {
        var r = _renderers[pid];
        if (r == null) {
          r = RTCVideoRenderer();
          await r.initialize();
          _renderers[pid] = r;
        }
        r.srcObject = e.streams.first;
      }
    };
    pc.onConnectionState = (RTCPeerConnectionState s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _removePeer(pid).then((_) => _publish());
      }
    };
    return pc;
  }

  Future<void> _onOffer(Map msg) async {
    final from = _asInt(msg['from']);
    if (from == null) return;
    _addParticipant(from, msg);
    final pc = await _ensurePeer(from);
    await pc.setRemoteDescription(
        RTCSessionDescription(msg['sdp'] as String?, 'offer'));
    _remoteSet[from] = true;
    await _drainIce(from);
    final answer = await pc.createAnswer(_sdpConstraints);
    await pc.setLocalDescription(answer);
    _send(from, {'type': 'group_answer', 'sdp': answer.sdp});
    _publish();
  }

  Future<void> _onAnswer(Map msg) async {
    final from = _asInt(msg['from']);
    if (from == null) return;
    final pc = _peers[from];
    if (pc == null) return;
    await pc.setRemoteDescription(
        RTCSessionDescription(msg['sdp'] as String?, 'answer'));
    _remoteSet[from] = true;
    await _drainIce(from);
  }

  Future<void> _onIce(Map msg) async {
    final from = _asInt(msg['from']);
    if (from == null) return;
    final c = msg['candidate'];
    if (c is! Map) return;
    final cand = RTCIceCandidate(
      c['candidate'] as String?,
      c['sdpMid'] as String?,
      (c['sdpMLineIndex'] as num?)?.toInt(),
    );
    final pc = _peers[from];
    if (pc != null && (_remoteSet[from] ?? false)) {
      await pc.addCandidate(cand);
    } else {
      (_pendingIce[from] ??= []).add(cand);
    }
  }

  Future<void> _drainIce(int pid) async {
    final list = _pendingIce[pid];
    if (list == null) return;
    final pc = _peers[pid];
    for (final c in list) {
      try {
        await pc?.addCandidate(c);
      } catch (_) {}
    }
    list.clear();
  }

  Future<void> _removePeer(int pid) async {
    final pc = _peers.remove(pid);
    try {
      await pc?.close();
    } catch (_) {}
    final r = _renderers.remove(pid);
    try {
      r?.srcObject = null;
      await r?.dispose();
    } catch (_) {}
    _remoteSet.remove(pid);
    _pendingIce.remove(pid);
    participants.remove(pid);
  }

  void _send(int to, Map<String, dynamic> data) {
    final r = room;
    if (r == null) return;
    sendSignal?.call({...data, 'room': r, 'to': to});
  }

  // ── Controls ───────────────────────────────────────────────────────────────
  void toggleMute() {
    muted = !muted;
    for (final t in _localStream?.getAudioTracks() ?? const []) {
      t.enabled = !muted;
    }
    _publish();
  }

  Future<void> toggleSpeaker() async {
    speakerOn = !speakerOn;
    try {
      await Helper.setSpeakerphoneOn(speakerOn);
    } catch (_) {}
    _publish();
  }

  // ── Teardown ───────────────────────────────────────────────────────────────
  Future<void> _teardown() async {
    _stopLevelMonitor();
    for (final pc in _peers.values) {
      try {
        await pc.close();
      } catch (_) {}
    }
    for (final r in _renderers.values) {
      try {
        r.srcObject = null;
        await r.dispose();
      } catch (_) {}
    }
    _renderers.clear();
    _peers.clear();
    _pendingIce.clear();
    _remoteSet.clear();
    participants.clear();
    try {
      for (final t in _localStream?.getTracks() ?? const []) {
        await t.stop();
      }
      await _localStream?.dispose();
    } catch (_) {}
    _localStream = null;
    try {
      await Helper.setSpeakerphoneOn(false);
    } catch (_) {}
  }

  void _reset() {
    _ringTimeout?.cancel();
    _stopLevelMonitor();
    _starter = false;
    _everConnected = false;
    _groupLogged = false;
    _peers.clear();
    _pendingIce.clear();
    _remoteSet.clear();
    participants.clear();
    roster.clear();
    muted = false;
    speakerOn = false;
    incomingCaller = '';
    room = null;
    title = '';
  }

  int? _asInt(dynamic v) => v is int ? v : int.tryParse(v?.toString() ?? '');
}
