import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/group_call_service.dart';
import '../services/contact_names.dart';
import '../state/group_call_state.dart';

/// Full-screen UI for the single active Aluta GROUP voice call. Reflects
/// [GroupCallService] — ringing (incoming) / active — and drives accept /
/// decline / mute / speaker / leave. Pops itself when the call goes idle.
class GroupCallScreen extends ConsumerStatefulWidget {
  const GroupCallScreen({super.key});

  @override
  ConsumerState<GroupCallScreen> createState() => _GroupCallScreenState();
}

class _GroupCallScreenState extends ConsumerState<GroupCallScreen> {
  final GroupCallService _call = GroupCallService.instance;
  bool _closing = false;

  void _dismiss() {
    if (_closing) return;
    _closing = true;
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  // Prefer the user's phonebook-saved name over the raw username.
  String _display(GroupParticipant p) {
    final ph = (p.phone ?? '').trim();
    if (ph.isNotEmpty) {
      final saved = ContactNames.instance.nameFor(ph);
      if (saved != null && saved.isNotEmpty) return saved;
    }
    return p.name.isNotEmpty ? p.name : 'Member';
  }

  @override
  Widget build(BuildContext context) {
    final snap = ref.watch(groupCallProvider);
    ref.listen<GroupCallSnapshot>(groupCallProvider, (prev, next) {
      if (next.phase == GroupCallPhase.idle) _dismiss();
    });

    final ringing = snap.phase == GroupCallPhase.ringing;
    final peers = _call.participants.values.toList();

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF12131A),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF1E2340), Color(0xFF0C0D14)],
            ),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const Spacer(flex: 2),
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withAlpha(28),
                      border:
                          Border.all(color: Colors.white.withAlpha(40), width: 2),
                    ),
                    child: const Icon(Icons.groups_rounded,
                        color: Colors.white, size: 46),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _call.title.isEmpty ? 'Group call' : _call.title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w700),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    ringing
                        ? (_call.incomingCaller.isEmpty
                            ? 'Incoming group call'
                            : '${_call.incomingCaller} started a group call')
                        : peers.isEmpty
                            ? 'Waiting for others to join…'
                            : '${peers.length + 1} in call',
                    style: TextStyle(
                        color: Colors.white.withAlpha(180), fontSize: 15),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  if (!ringing)
                    Expanded(
                      flex: 5,
                      child: SingleChildScrollView(
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 18,
                          runSpacing: 18,
                          children: [
                            for (final p in peers) _peerChip(p),
                          ],
                        ),
                      ),
                    )
                  else
                    const Spacer(flex: 3),
                  _controls(ringing),
                  const SizedBox(height: 30),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _peerChip(GroupParticipant p) {
    final name = _display(p);
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return SizedBox(
      width: 84,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 32,
            backgroundColor: Colors.white.withAlpha(30),
            child: Text(initial,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 8),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _controls(bool ringing) {
    if (ringing) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _bigButton(
            icon: Icons.call_end_rounded,
            color: const Color(0xFFE53935),
            label: 'Decline',
            onTap: () => _call.leave(),
          ),
          _bigButton(
            icon: Icons.call_rounded,
            color: const Color(0xFF43A047),
            label: 'Join',
            onTap: () => _call.accept(),
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _smallToggle(
              icon: _call.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
              active: _call.muted,
              label: 'Mute',
              onTap: () => setState(_call.toggleMute),
            ),
            _smallToggle(
              icon: _call.speakerOn
                  ? Icons.volume_up_rounded
                  : Icons.hearing_rounded,
              active: _call.speakerOn,
              label: 'Speaker',
              onTap: () async {
                await _call.toggleSpeaker();
                if (mounted) setState(() {});
              },
            ),
          ],
        ),
        const SizedBox(height: 26),
        _bigButton(
          icon: Icons.call_end_rounded,
          color: const Color(0xFFE53935),
          label: 'Leave',
          onTap: () => _call.leave(),
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
            width: 66,
            height: 66,
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
    required VoidCallback onTap,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? Colors.white : Colors.white.withAlpha(30),
            ),
            child: Icon(icon, color: active ? Colors.black : Colors.white, size: 26),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white70)),
      ],
    );
  }
}
