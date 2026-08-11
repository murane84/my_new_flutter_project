import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/call_service.dart';
import '../state/call_state.dart';
import '../utils/app_config.dart';
import '../utils/net_image.dart';
import 'token_helper.dart' show mediaAuthHeaders;

/// Full-screen UI for the single active Aluta voice call. It simply reflects
/// [CallService]'s state — ring / calling / connected / ended — and drives the
/// accept/decline/mute/speaker/hang-up controls. Pops itself when the call
/// returns to idle.
class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({super.key});

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
  final CallService _call = CallService.instance;
  Timer? _tick;
  Timer? _endTimer;
  bool _closing = false;
  String _base = '';

  @override
  void initState() {
    super.initState();
    AppConfig.baseUrl.then((b) {
      if (mounted) setState(() => _base = b);
    });
    // Refresh once a second so the call timer counts up.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _call.state == CallState.connected) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _endTimer?.cancel();
    super.dispose();
  }

  // Reacts to call-state transitions (was the _call.addListener callback). Only
  // the side-effects live here now; the rebuild is handled by ref.watch below.
  void _onCallStateChanged(CallState s) {
    if (!mounted) return;
    if (s == CallState.idle) {
      _dismiss();
    } else if (s == CallState.ended && !_showFallback) {
      // Clean end (no phone-fallback prompt) → auto-close shortly. Kept short so
      // the "Call ended" state reads as a brief flash before the fade-out.
      _endTimer?.cancel();
      _endTimer = Timer(const Duration(milliseconds: 1300), _dismiss);
    }
  }

  void _dismiss() {
    if (_closing) return;
    _closing = true;
    _call.reset();
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  String? _avatarUrl() {
    final a = _call.peerAvatar;
    if (a == null || a.isEmpty) return null;
    if (a.startsWith('http')) return a;
    return '$_base$a';
  }

  Future<void> _callOnPhone() async {
    final phone = _call.fallbackPhone?.trim() ?? '';
    _dismiss();
    if (phone.isEmpty) return;
    try {
      await launchUrl(Uri(scheme: 'tel', path: phone));
    } catch (_) {}
  }

  bool get _showFallback =>
      _call.state == CallState.ended &&
      _call.isCaller &&
      _isUnreachable &&
      (_call.fallbackPhone?.trim().isNotEmpty ?? false);

  bool get _ended => _call.state == CallState.ended;

  @override
  Widget build(BuildContext context) {
    // Rebuild whenever the call state/mute/speaker changes (was _call's
    // ChangeNotifier). ref.listen handles the one-off transitions (dismiss on
    // idle, auto-close on end) that the old listener also did.
    ref.watch(callProvider);
    ref.listen<CallSnapshot>(callProvider, (prev, next) {
      _onCallStateChanged(next.state);
    });
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF1A1012),
        body: Container(
          // Fill the whole screen. Without these, the Container shrink-wraps to
          // its content width — and in the "Call ended" state (no full-width
          // controls row) that made the gradient cover only a narrow strip,
          // leaving the rest black (the "screen dividing" on hang-up).
          width: double.infinity,
          height: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF3A1A1F), Color(0xFF120B0D)],
            ),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const Spacer(flex: 2),
                  // Dim the avatar once the call has ended for a calm wind-down.
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 300),
                    opacity: _ended ? 0.55 : 1,
                    child: _avatar(),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    _call.peerName.isEmpty ? 'Aluta call' : _call.peerName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _statusText(),
                    style: TextStyle(
                      color: Colors.white.withAlpha(180),
                      fontSize: 15,
                    ),
                  ),
                  const Spacer(flex: 3),
                  _controls(),
                  const SizedBox(height: 30),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _avatar() {
    final url = _avatarUrl();
    final initial =
        _call.peerName.isNotEmpty ? _call.peerName[0].toUpperCase() : '?';
    return Container(
      width: 128,
      height: 128,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withAlpha(30),
        border: Border.all(color: Colors.white.withAlpha(40), width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: url != null
          // Use the cross-platform loader: on WEB it moves the token into the
          // URL (?token=) since a browser <img> can't send the auth header —
          // that's why Windows/Android showed the photo but web fell back to
          // the initial.
          ? authNetworkImage(
              url: url,
              headers: mediaAuthHeaders(url),
              width: 128,
              height: 128,
              fit: BoxFit.cover,
              placeholder: (_) => _initial(initial),
              error: (_) => _initial(initial),
            )
          : _initial(initial),
    );
  }

  Widget _initial(String initial) => Center(
        child: Text(
          initial,
          style: const TextStyle(
              color: Colors.white, fontSize: 52, fontWeight: FontWeight.bold),
        ),
      );

  String _statusText() {
    switch (_call.state) {
      case CallState.calling:
        // Be honest about what's actually happening on the other end.
        switch (_call.outgoing) {
          case CallOutgoing.ringing:
            return 'Ringing…';
          case CallOutgoing.notified:
            return 'Ringing their phone…';
          case CallOutgoing.dialing:
          case CallOutgoing.none:
            return 'Calling…';
        }
      case CallState.ringing:
        return 'Incoming Aluta call';
      case CallState.connecting:
        return 'Connecting…';
      case CallState.connected:
        return _call.elapsedLabel;
      case CallState.ended:
        return _endedText();
      case CallState.idle:
        return '';
    }
  }

  String _endedText() {
    final name = _call.peerName.isEmpty ? 'They' : _call.peerName;
    switch (_call.endReason) {
      case CallEndReason.declined:
        return 'Call declined';
      case CallEndReason.busy:
        return '${_call.peerName} is on another call';
      case CallEndReason.unanswered:
        return 'No answer';
      case CallEndReason.unreachable:
        return '$name can’t be reached — offline';
      case CallEndReason.failed:
        return 'Couldn’t connect';
      case CallEndReason.cancelled:
        return 'Call cancelled';
      case CallEndReason.hangup:
      case CallEndReason.none:
        return 'Call ended';
    }
  }

  bool get _isUnreachable =>
      _call.endReason == CallEndReason.unanswered ||
      _call.endReason == CallEndReason.busy ||
      _call.endReason == CallEndReason.failed ||
      _call.endReason == CallEndReason.unreachable ||
      _call.endReason == CallEndReason.declined;

  Widget _controls() {
    // Incoming, not yet answered → Decline / Accept.
    if (_call.state == CallState.ringing) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _bigButton(
            icon: Icons.call_end_rounded,
            color: const Color(0xFFE53935),
            label: 'Decline',
            onTap: _call.declineCall,
          ),
          _bigButton(
            icon: Icons.call_rounded,
            color: const Color(0xFF43A047),
            label: 'Accept',
            onTap: _call.acceptCall,
          ),
        ],
      );
    }

    // Ended → a calm, balanced wind-down: a dim (non-interactive) end marker
    // sits where the hang-up button was — instead of the controls abruptly
    // collapsing to a bare "Close" link — then the screen fades itself out.
    // For a caller who couldn't get through, offer the phone fallback + Close.
    if (_call.state == CallState.ended) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(28),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.call_end_rounded,
                color: Colors.white70, size: 30),
          ),
          if (_showFallback) ...[
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF43A047),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _callOnPhone,
                icon: const Icon(Icons.phone_rounded),
                label: const Text('Call on phone instead'),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _dismiss,
              child: const Text('Close',
                  style: TextStyle(color: Colors.white70, fontSize: 16)),
            ),
          ],
        ],
      );
    }

    // Calling / connecting / connected → mute · speaker · hang up.
    final live = _call.state == CallState.connected;
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _smallToggle(
              icon: _call.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
              active: _call.muted,
              label: 'Mute',
              onTap: live ? _call.toggleMute : null,
            ),
            _smallToggle(
              icon: _call.speakerOn
                  ? Icons.volume_up_rounded
                  : Icons.hearing_rounded,
              active: _call.speakerOn,
              label: 'Speaker',
              onTap: _call.toggleSpeaker,
            ),
          ],
        ),
        const SizedBox(height: 30),
        _bigButton(
          icon: Icons.call_end_rounded,
          color: const Color(0xFFE53935),
          label: 'Hang up',
          onTap: _call.hangUp,
        ),
      ],
    );
  }

  Widget _bigButton({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 30),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white70)),
      ],
    );
  }

  Widget _smallToggle({
    required IconData icon,
    required bool active,
    required String label,
    VoidCallback? onTap,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? Colors.white : Colors.white.withAlpha(30),
            ),
            child: Icon(icon,
                color: active ? Colors.black : Colors.white,
                size: 26),
          ),
        ),
        const SizedBox(height: 8),
        Text(label,
            style: TextStyle(color: Colors.white.withAlpha(onTap == null ? 90 : 180))),
      ],
    );
  }
}
