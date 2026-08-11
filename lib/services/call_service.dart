import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../screens/api_service.dart';
import '../state/call_state.dart';
import '../state/playback_state.dart' show providerContainer;
import 'notif_service.dart';

/// High-level state of the single active Aluta voice call.
enum CallState {
  idle, // nothing happening
  calling, // outgoing: offer sent, waiting for the other side to pick up
  ringing, // incoming: an offer arrived, waiting for us to accept/decline
  connecting, // accepted on one side, media negotiating
  connected, // media flowing — talk!
  ended, // just finished (screens use this to pop, then we reset to idle)
}

/// Why a call ended — lets the UI show the right message / offer a phone
/// fallback when the friend couldn't be reached over the internet.
/// `unreachable` = the friend's device is offline / not reachable at all (no
/// live app, no push token), so it never even rang.
enum CallEndReason {
  none,
  hangup,
  declined,
  busy,
  cancelled,
  failed,
  unanswered,
  unreachable,
}

/// The caller's OUTGOING progress before the callee answers, so the UI can be
/// honest about what's happening instead of a blind "Calling…":
///   dialing   → offer sent, no confirmation yet
///   notified  → their app is closed; we've pushed a ring to their phone
///   ringing   → their device actually received the call and is ringing now
enum CallOutgoing { none, dialing, notified, ringing }

/// Aluta in-app **voice** calling over WebRTC.
///
/// Signaling (offer / answer / ICE) rides the app's existing per-user
/// notification WebSocket: [sendSignal] is wired by the app to push a message
/// to the peer, and [onSignal] is fed every inbound `call_*` event. Media never
/// touches our server — it's a direct (or TURN-relayed) peer connection.
///
/// This is a singleton because there is only ever one active call, and it must
/// outlive individual screens (an incoming call can arrive on any screen).
class CallService {
  CallService._();
  static final CallService instance = CallService._();

  /// Publish the current call state into Riverpod. Replaces notifyListeners():
  /// screens now `ref.watch(callProvider)` instead of add/removeListener. Called
  /// from non-widget engine code, so it writes through the app-wide container.
  void _publish() {
    providerContainer.read(callProvider.notifier).set(CallSnapshot(
          state: state,
          endReason: endReason,
          muted: muted,
          speakerOn: speakerOn,
          outgoing: outgoing,
        ));
  }

  // ── Public state (screens listen to this) ────────────────────────────────
  CallState state = CallState.idle;
  int? peerId;
  String peerName = '';
  String? peerAvatar;
  bool isCaller = false;
  bool muted = false;
  bool speakerOn = false;
  CallEndReason endReason = CallEndReason.none;
  // Caller-side: how far the outgoing call has progressed (see CallOutgoing).
  CallOutgoing outgoing = CallOutgoing.none;
  DateTime? connectedAt;
  // Guards against posting more than one call-log message per call (the caller
  // posts it when the call ends). Reset when the call is torn down.
  bool _callLogged = false;
  /// The friend's phone number, if known — used to offer a normal phone call
  /// when the Aluta (internet) call can't be connected.
  String? fallbackPhone;

  String _myName = '';
  String? _myAvatar;

  /// Wired by the app layer to actually transmit a signaling message to the
  /// peer over the notification WebSocket. `msg` always carries `to` + `type`.
  void Function(Map<String, dynamic> msg)? sendSignal;

  /// Called by the app when a call should be shown to the user (incoming ring
  /// or an outgoing call we just started) so it can push the call screen.
  void Function()? onShowCallUI;

  bool get isActive => state != CallState.idle && state != CallState.ended;

  // ── Internals ─────────────────────────────────────────────────────────────
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  RTCSessionDescription? _pendingOffer; // incoming offer awaiting accept
  final List<RTCIceCandidate> _pendingRemote = []; // ICE before remote SDP set
  bool _remoteDescSet = false;
  Timer? _ringTimeout;

  // STUN keeps it free for same-network / simple NATs; the TURN entries relay
  // media when a direct path can't be punched (common on cellular). These are
  // Open Relay's FREE public TURN servers (no signup) — swap in your own from
  // metered.ca / a coturn box for production reliability + higher limits.
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

  static const Map<String, dynamic> _offerAnswerConstraints = {
    'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': false},
    'optional': [],
  };

  // ── Outgoing ──────────────────────────────────────────────────────────────
  /// Start calling [peerId]. Returns false if we're already in a call.
  Future<bool> startCall({
    required int peerId,
    required String peerName,
    String? peerAvatar,
    required String myName,
    String? myAvatar,
    String? fallbackPhone,
  }) async {
    if (isActive) return false;
    _reset();
    this.peerId = peerId;
    this.peerName = peerName;
    this.peerAvatar = peerAvatar;
    this.fallbackPhone = fallbackPhone;
    _myName = myName;
    _myAvatar = myAvatar;
    isCaller = true;
    state = CallState.calling;
    endReason = CallEndReason.none;
    outgoing = CallOutgoing.dialing;
    _publish();
    onShowCallUI?.call();

    try {
      await _createPeer();
      final offer = await _pc!.createOffer(_offerAnswerConstraints);
      await _pc!.setLocalDescription(offer);
      _signal({
        'type': 'call_offer',
        'sdp': offer.sdp,
        'call_type': 'voice',
        // The caller's own identity, so the callee's ring screen shows who it
        // is (peer_name/peer_avatar on their side = us).
        'caller_name': _myName,
        if (_myAvatar != null) 'caller_avatar': _myAvatar,
      });
      // If nobody picks up in 45s, treat as unanswered and clean up.
      _ringTimeout = Timer(const Duration(seconds: 45), () {
        if (state == CallState.calling) {
          _signal({'type': 'call_cancel'});
          _finish(CallEndReason.unanswered);
        }
      });
      return true;
    } catch (_) {
      _finish(CallEndReason.failed);
      return false;
    }
  }

  // ── Incoming ──────────────────────────────────────────────────────────────
  /// Handle an inbound offer. If we're already busy, auto-reply busy.
  Future<void> _handleOffer(Map<String, dynamic> msg) async {
    final from = _asInt(msg['from']);
    if (from == null) return;
    if (isActive) {
      sendSignal?.call({'type': 'call_busy', 'to': from});
      return;
    }
    _reset();
    peerId = from;
    peerName = (msg['caller_name'] ?? '').toString();
    peerAvatar = (msg['caller_avatar'] as String?)?.trim();
    isCaller = false;
    _pendingOffer = RTCSessionDescription(msg['sdp'] as String?, 'offer');
    state = CallState.ringing;
    endReason = CallEndReason.none;
    _publish();
    onShowCallUI?.call();
    // Tell the caller our device actually received the call and is ringing NOW,
    // so their screen can show a confirmed "Ringing…" instead of a blind
    // "Calling…". (The caller flips to CallOutgoing.ringing on this.)
    _signal({'type': 'call_ringing'});
    // Auto-miss if we don't answer in 45s.
    _ringTimeout = Timer(const Duration(seconds: 45), () {
      if (state == CallState.ringing) {
        _signal({'type': 'call_decline'});
        _finish(CallEndReason.unanswered);
      }
    });
  }

  /// Accept the incoming call (build answer, send it back).
  Future<void> acceptCall() async {
    if (state != CallState.ringing || _pendingOffer == null) return;
    _ringTimeout?.cancel();
    cancelCallNotification(); // stop the ringing notification once we answer
    state = CallState.connecting;
    _publish();
    try {
      await _createPeer();
      await _pc!.setRemoteDescription(_pendingOffer!);
      _remoteDescSet = true;
      await _drainPendingCandidates();
      final answer = await _pc!.createAnswer(_offerAnswerConstraints);
      await _pc!.setLocalDescription(answer);
      _signal({'type': 'call_answer', 'sdp': answer.sdp});
    } catch (_) {
      _signal({'type': 'call_end'});
      _finish(CallEndReason.failed);
    }
  }

  /// Reject an incoming call.
  void declineCall() {
    if (state == CallState.ringing) _signal({'type': 'call_decline'});
    _finish(CallEndReason.declined);
  }

  /// Hang up (or cancel a still-ringing outgoing call).
  void hangUp() {
    if (state == CallState.calling) {
      _signal({'type': 'call_cancel'});
    } else if (isActive) {
      _signal({'type': 'call_end'});
    }
    _finish(CallEndReason.hangup);
  }

  // ── Inbound signaling dispatch ────────────────────────────────────────────
  Future<void> onSignal(Map<String, dynamic> msg) async {
    switch (msg['type']) {
      case 'call_offer':
        await _handleOffer(msg);
        break;
      case 'call_answer':
        if (isCaller && _pc != null) {
          _ringTimeout?.cancel();
          state = CallState.connecting;
          _publish();
          await _pc!.setRemoteDescription(
              RTCSessionDescription(msg['sdp'] as String?, 'answer'));
          _remoteDescSet = true;
          await _drainPendingCandidates();
        }
        break;
      case 'call_ice':
        final c = msg['candidate'];
        if (c is Map) {
          final cand = RTCIceCandidate(
            c['candidate'] as String?,
            c['sdpMid'] as String?,
            (c['sdpMLineIndex'] as num?)?.toInt(),
          );
          if (_pc != null && _remoteDescSet) {
            await _pc!.addCandidate(cand);
          } else {
            _pendingRemote.add(cand); // queue until remote SDP is set
          }
        }
        break;
      case 'call_ringing':
        // The callee's device confirmed it's ringing — real ring, not a guess.
        if (isCaller && state == CallState.calling) {
          outgoing = CallOutgoing.ringing;
          _publish();
        }
        break;
      case 'call_delivered':
        // Server pushed a ring to the callee's phone (their app was closed). We
        // can't confirm it rang, so show "Ringing their phone…" — but never
        // downgrade a confirmed "ringing" back to this.
        if (isCaller &&
            state == CallState.calling &&
            outgoing != CallOutgoing.ringing) {
          outgoing = CallOutgoing.notified;
          _publish();
        }
        break;
      case 'call_unreachable':
        // Server says the friend is fully offline (no live app, no push token)
        // — the call never rang anywhere. End now with a clear reason instead
        // of ringing out the 45s timeout in silence.
        if (isCaller && state == CallState.calling) {
          _finish(CallEndReason.unreachable);
        }
        break;
      case 'call_decline':
        _finish(CallEndReason.declined);
        break;
      case 'call_busy':
        _finish(CallEndReason.busy);
        break;
      case 'call_cancel':
        _finish(CallEndReason.cancelled);
        break;
      case 'call_end':
        _finish(CallEndReason.hangup);
        break;
    }
  }

  // ── Controls ──────────────────────────────────────────────────────────────
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

  String get elapsedLabel {
    if (connectedAt == null) return '';
    final s = DateTime.now().difference(connectedAt!).inSeconds;
    final m = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$m:$ss';
  }

  // ── WebRTC plumbing ───────────────────────────────────────────────────────
  Future<void> _createPeer() async {
    _localStream = await navigator.mediaDevices
        .getUserMedia({'audio': true, 'video': false});
    final pc = await createPeerConnection(_iceConfig);
    _pc = pc;

    for (final track in _localStream!.getTracks()) {
      await pc.addTrack(track, _localStream!);
    }

    pc.onIceCandidate = (RTCIceCandidate candidate) {
      if (candidate.candidate == null) return;
      _signal({
        'type': 'call_ice',
        'candidate': {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      });
    };

    pc.onConnectionState = (RTCPeerConnectionState s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        if (state != CallState.connected) {
          state = CallState.connected;
          connectedAt = DateTime.now();
          _publish();
        }
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _finish(CallEndReason.failed);
      } else if (s ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        // Give ICE a moment to recover before declaring the call dead.
        Future.delayed(const Duration(seconds: 6), () {
          if (_pc == pc &&
              state == CallState.connected &&
              connectedAt != null) {
            _finish(CallEndReason.failed);
          }
        });
      }
    };
    // Remote audio plays automatically once the track arrives; nothing to wire.
  }

  Future<void> _drainPendingCandidates() async {
    for (final c in _pendingRemote) {
      try {
        await _pc?.addCandidate(c);
      } catch (_) {}
    }
    _pendingRemote.clear();
  }

  void _signal(Map<String, dynamic> data) {
    final to = peerId;
    if (to == null) return;
    sendSignal?.call({...data, 'to': to});
  }

  /// End the call for whatever [reason], tear down media, and reset to idle
  /// shortly after so screens can react to the `ended` state first.
  void _finish(CallEndReason reason) {
    if (state == CallState.idle) return;
    _ringTimeout?.cancel();
    cancelCallNotification(); // stop any ringing call notification
    endReason = reason;
    state = CallState.ended;
    _publish();
    _teardownMedia();
    _maybeLogCall();
    // NOTE: we stay in `ended` (not `idle`) so the call screen can show the
    // outcome — and, if the internet call couldn't connect, offer a phone
    // fallback. The screen calls reset() when it's dismissed. `ended` doesn't
    // count as active, so a fresh call can still start meanwhile.
  }

  // Post a call-log entry to the thread so both users see the call in their
  // history. Only the CALLER posts (single source of truth); the message is
  // delivered to the peer like any other, so it shows on both sides. Duration
  // is the connected length in seconds (0 = never connected → no answer/missed).
  void _maybeLogCall() {
    if (_callLogged || !isCaller) return;
    final to = peerId;
    if (to == null) return;
    _callLogged = true;
    final secs = connectedAt != null
        ? DateTime.now().difference(connectedAt!).inSeconds
        : 0;
    unawaited(
      ApiService()
          .sendMessage(to, '', messageType: 'call', mediaDuration: secs)
          .catchError((_) => null),
    );
  }

  /// Return to idle once the UI has finished showing the end state.
  void reset() {
    if (state == CallState.ended || state == CallState.idle) {
      state = CallState.idle;
      _reset();
      peerId = null;
      peerName = '';
      peerAvatar = null;
      fallbackPhone = null;
      isCaller = false;
      _publish();
    }
  }

  Future<void> _teardownMedia() async {
    try {
      for (final t in _localStream?.getTracks() ?? const []) {
        await t.stop();
      }
      await _localStream?.dispose();
    } catch (_) {}
    _localStream = null;
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    try {
      await Helper.setSpeakerphoneOn(false);
    } catch (_) {}
  }

  void _reset() {
    _ringTimeout?.cancel();
    _pendingOffer = null;
    _pendingRemote.clear();
    _remoteDescSet = false;
    muted = false;
    speakerOn = false;
    connectedAt = null;
    endReason = CallEndReason.none;
    outgoing = CallOutgoing.none;
    _callLogged = false;
  }

  int? _asInt(dynamic v) =>
      v is int ? v : int.tryParse(v?.toString() ?? '');
}
