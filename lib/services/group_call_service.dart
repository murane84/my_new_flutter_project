import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../state/group_call_state.dart';
import '../state/playback_state.dart' show providerContainer;
import 'notif_service.dart';

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

  GroupCallPhase phase = GroupCallPhase.idle;
  int? room; // conversation id acting as the call room
  String title = '';
  int? myId;
  bool muted = false;
  bool speakerOn = false;

  // Incoming-call caller info (for the ring screen).
  String incomingCaller = '';

  // Known group members (for showing names/avatars even before they connect).
  final Map<int, GroupParticipant> roster = {};
  // Peers we are actually connected to (excludes me).
  final Map<int, GroupParticipant> participants = {};

  final Map<int, RTCPeerConnection> _peers = {};
  final Map<int, List<RTCIceCandidate>> _pendingIce = {};
  final Map<int, bool> _remoteSet = {};
  MediaStream? _localStream;
  Timer? _ringTimeout;

  bool get isActive =>
      phase == GroupCallPhase.active || phase == GroupCallPhase.ringing;

  // Same ICE config as 1:1 calls (STUN + free Open Relay TURN).
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
    _publish();
    onShowUI?.call();
    await _ensureLocalStream();
    sendSignal?.call({'type': 'group_call_start', 'room': room});
    return true;
  }

  /// An inbound group-call ring (from WS or a tapped push).
  void handleIncoming(Map<String, dynamic> msg) {
    final r = _asInt(msg['room']);
    if (r == null) return;
    if (isActive) return; // already busy
    _reset();
    room = r;
    title = (msg['title'] ?? 'Group call').toString();
    incomingCaller = (msg['caller_name'] ?? '').toString();
    phase = GroupCallPhase.ringing;
    _publish();
    onShowUI?.call();
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
    _publish();
    await _ensureLocalStream();
    sendSignal?.call({'type': 'group_call_join', 'room': room});
  }

  /// Leave / decline / hang up the group call.
  Future<void> leave() async {
    final r = room;
    if (r != null && phase == GroupCallPhase.active) {
      sendSignal?.call({'type': 'group_call_leave', 'room': r});
    }
    _ringTimeout?.cancel();
    cancelCallNotification();
    await _teardown();
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
        await leave();
        break;
    }
  }

  void _addParticipant(int pid, Map? info) {
    final r = roster[pid];
    final name = (info?['name'] ?? r?.name ?? '').toString();
    final avatar = (info?['avatar'] as String?) ?? r?.avatar;
    final phone = (info?['phone'] as String?) ?? r?.phone;
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
    final pc = await createPeerConnection(_iceConfig);
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
    pc.onTrack = (RTCTrackEvent e) {
      // Remote audio plays automatically; keep a handle for future UI use.
      if (e.streams.isNotEmpty) participants[pid]?.stream = e.streams.first;
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
    for (final pc in _peers.values) {
      try {
        await pc.close();
      } catch (_) {}
    }
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
