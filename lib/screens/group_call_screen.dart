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
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Refresh once a second so the "MM:SS" elapsed label keeps counting.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _dismiss() {
    if (_closing) return;
    _closing = true;
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  /// Close the call screen but STAY in the call — home shows a "return to call"
  /// banner. Distinct from Leave (which tears the call down).
  void _minimize() {
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

    // While connected, show a live MM:SS timer; before anyone connects, the
    // "waiting" line; when ringing, the incoming-call line.
    final elapsed = _call.elapsedLabel;
    final String statusLine = ringing
        ? (_call.incomingCaller.isEmpty
            ? 'Incoming group call'
            : '${_call.incomingCaller} started a group call')
        : peers.isEmpty
            ? (elapsed.isEmpty
                ? 'Waiting for others to join…'
                : '$elapsed · waiting for others…')
            : (elapsed.isEmpty
                ? '${peers.length + 1} in call'
                : '$elapsed · ${peers.length + 1} in call');

    return PopScope(
      // Back gesture / button MINIMIZES the call (keeps it running) rather than
      // blocking. The call only ends via the Leave button.
      canPop: true,
      child: Scaffold(
        backgroundColor: const Color(0xFF12131A),
        body: Container(
          // Fill the whole screen (see call_screen.dart) so narrow states like
          // "ringing" never let the container shrink-wrap and paint a strip.
          width: double.infinity,
          height: double.infinity,
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
                  // Top bar: a minimize chevron so the user can drop back to
                  // chat while staying connected (hidden during the ring).
                  SizedBox(
                    height: 44,
                    child: ringing
                        ? null
                        : Align(
                            alignment: Alignment.centerLeft,
                            child: IconButton(
                              tooltip: 'Minimize',
                              icon: const Icon(Icons.keyboard_arrow_down_rounded,
                                  color: Colors.white, size: 30),
                              onPressed: _minimize,
                            ),
                          ),
                  ),
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
                    statusLine,
                    style: TextStyle(
                        color: Colors.white.withAlpha(180), fontSize: 15),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  if (!ringing)
                    Expanded(
                      flex: 5,
                      // Adaptive, scrollable grid of members — glows the tile of
                      // whoever is talking. Scrolls when the group is large.
                      child: ValueListenableBuilder<Set<int>>(
                        valueListenable: _call.speakingIds,
                        builder: (context, speaking, _) {
                          if (peers.isEmpty) return const SizedBox.shrink();
                          return GridView.builder(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            physics: const AlwaysScrollableScrollPhysics(),
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 112,
                              mainAxisExtent: 116,
                              crossAxisSpacing: 6,
                              mainAxisSpacing: 10,
                            ),
                            itemCount: peers.length,
                            itemBuilder: (_, i) {
                              final p = peers[i];
                              return _peerTile(p, speaking.contains(p.id));
                            },
                          );
                        },
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

  Widget _peerTile(GroupParticipant p, bool talking) {
    final name = _display(p);
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    const green = Color(0xFF34D058);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Glowing ring while this member is talking.
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: talking ? green : Colors.white.withAlpha(28),
              width: talking ? 3 : 1.5,
            ),
            boxShadow: talking
                ? [
                    BoxShadow(
                      color: green.withAlpha(150),
                      blurRadius: 16,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: CircleAvatar(
            radius: 30,
            backgroundColor: Colors.white.withAlpha(28),
            child: Text(initial,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: talking ? green : Colors.white70,
            fontSize: 12,
            fontWeight: talking ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ],
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
