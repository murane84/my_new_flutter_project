import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/call_service.dart';
import '../utils/app_config.dart';
import 'token_helper.dart' show mediaAuthHeaders;

/// Full-screen UI for the single active Aluta voice call. It simply reflects
/// [CallService]'s state — ring / calling / connected / ended — and drives the
/// accept/decline/mute/speaker/hang-up controls. Pops itself when the call
/// returns to idle.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
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
    _call.addListener(_onCallChanged);
    // Refresh once a second so the call timer counts up.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _call.state == CallState.connected) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _endTimer?.cancel();
    _call.removeListener(_onCallChanged);
    super.dispose();
  }

  void _onCallChanged() {
    if (!mounted) return;
    final s = _call.state;
    if (s == CallState.idle) {
      _dismiss();
    } else if (s == CallState.ended && !_showFallback) {
      // Clean end (no phone-fallback prompt) → auto-close shortly.
      _endTimer?.cancel();
      _endTimer = Timer(const Duration(milliseconds: 1600), _dismiss);
    }
    setState(() {});
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

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF1A1012),
        body: Container(
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
                  _avatar(),
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
          ? CachedNetworkImage(
              imageUrl: url,
              httpHeaders: mediaAuthHeaders(url),
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => _initial(initial),
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
        return 'Calling…';
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
    switch (_call.endReason) {
      case CallEndReason.declined:
        return 'Call declined';
      case CallEndReason.busy:
        return '${_call.peerName} is on another call';
      case CallEndReason.unanswered:
        return 'No answer';
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

    // Ended → outcome + (for the caller who couldn't get through) a phone
    // fallback, honouring "call out of Aluta when not reachable".
    if (_call.state == CallState.ended) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_showFallback) ...[
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
            const SizedBox(height: 12),
          ],
          TextButton(
            onPressed: _dismiss,
            child: const Text('Close',
                style: TextStyle(color: Colors.white70, fontSize: 16)),
          ),
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
