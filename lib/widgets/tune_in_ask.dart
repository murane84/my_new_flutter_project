import 'package:flutter/material.dart';

import '../services/tune_in.dart';
import '../utils/toast_helper.dart';
import 'net_gate.dart';
import 'person_avatar.dart';

/// Tap "Tune in" on a friend who's listening: ASK to join their song (they
/// keep their rhythm; you join right where they are). A small waiting card
/// shows until they answer — it closes itself when they accept (their invite
/// opens the session for you), decline, or time out. Cancel stops the ask.
Future<void> askToTuneIn(
  BuildContext context, {
  required int friendId,
  required String name,
  String? avatar,
  String? title,
}) async {
  final svc = TuneInService.instance;
  // A weak connection would only stutter — check before asking.
  if (!await ensureListenTogetherNet(context,
      host: false,
      peerName: name,
      retry: () => askToTuneIn(context,
          friendId: friendId, name: name, avatar: avatar, title: title))) {
    return;
  }
  if (!context.mounted) return;
  if (!svc.request(friendId, title: title)) {
    showToast(context, 'Still connecting — try again in a moment',
        type: ToastType.info);
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    // No theme outline — the sheet draws its own card.
    shape: const RoundedRectangleBorder(),
    elevation: 0,
    barrierColor: Colors.black.withValues(alpha: 0.25),
    builder: (_) => _TuneInWaiting(
        friendId: friendId, name: name, avatar: avatar, title: title),
  );
  // Closed by hand while still waiting → that's a cancel.
  if (svc.pending.value == friendId && svc.accepted.value != friendId) {
    svc.cancel();
  }
}

class _TuneInWaiting extends StatefulWidget {
  const _TuneInWaiting(
      {required this.friendId, required this.name, this.avatar, this.title});
  final int friendId;
  final String name;
  final String? avatar;
  final String? title;

  @override
  State<_TuneInWaiting> createState() => _TuneInWaitingState();
}

class _TuneInWaitingState extends State<_TuneInWaiting> {
  final _svc = TuneInService.instance;

  @override
  void initState() {
    super.initState();
    _svc.pending.addListener(_onChange);
    _svc.accepted.addListener(_onChange);
    _svc.pushedTo.addListener(_onChange);
  }

  @override
  void dispose() {
    _svc.pending.removeListener(_onChange);
    _svc.accepted.removeListener(_onChange);
    _svc.pushedTo.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    // No longer waiting on this friend (joined / declined / timed out).
    if (_svc.pending.value != widget.friendId) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final yes = _svc.accepted.value == widget.friendId;
    final song = (widget.title ?? '').trim();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              decoration: BoxDecoration(
                color: isDark
                    ? Color.alphaBlend(
                        Colors.white.withValues(alpha: 0.05), scheme.surface)
                    : scheme.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                    color: scheme.primary
                        .withValues(alpha: isDark ? 0.30 : 0.18)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.14),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Stack(
                        alignment: Alignment.center,
                        children: [
                          SizedBox(
                            width: 50,
                            height: 50,
                            child: yes
                                ? null
                                : CircularProgressIndicator(
                                    strokeWidth: 2.4,
                                    color: scheme.primary),
                          ),
                          PersonAvatar(
                              name: widget.name,
                              avatar: widget.avatar,
                              radius: 20),
                        ],
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                yes
                                    ? '${widget.name} let you in'
                                    : 'Asking ${widget.name}…',
                                style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15,
                                    color: scheme.onSurface)),
                            const SizedBox(height: 2),
                            Text(
                                yes
                                    ? 'Joining their song…'
                                    : (_svc.pushedTo.value == widget.friendId
                                        ? 'Sent to their phone — waiting for them'
                                        : 'You\'ll join their song right where they are'),
                                style: TextStyle(
                                    fontSize: 12,
                                    color: scheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (song.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 9),
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.graphic_eq_rounded,
                              size: 16, color: scheme.primary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(song,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: scheme.onSurface)),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  if (!yes)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () {
                          _svc.cancel();
                        },
                        child: const Text('Cancel'),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
