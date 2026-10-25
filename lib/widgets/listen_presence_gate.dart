import 'package:flutter/material.dart';

import '../screens/api_service.dart';
import '../services/online_watch.dart';
import '../utils/toast_helper.dart';

/// Before going live with Listen Together: is the partner actually here?
///  • online (or we can't tell) → true, start as usual;
///  • offline → a small sheet: "Notify me when she's online" (one-shot watch
///    that comes back with a Listen together button) or "Start anyway" (the
///    invite waits for her). Returns whether to start now.
Future<bool> listenTogetherGate(BuildContext context,
    {required int friendId, required String name}) async {
  final st = await ApiService().fetchFriendStatus(friendId);
  if (!context.mounted) return false;
  if (st.isEmpty || st['is_online'] == true) return true;
  final first = name.trim().split(RegExp(r'\s+')).first;
  final scheme = Theme.of(context).colorScheme;
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: scheme.surface,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(height: 18),
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primary.withValues(alpha: 0.12),
            ),
            child: Icon(Icons.headphones_rounded,
                color: scheme.primary, size: 28),
          ),
          const SizedBox(height: 12),
          Text('$first is offline right now',
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurface)),
          const SizedBox(height: 4),
          Text(
              "We'll tell you the moment $first is back — then one tap starts "
              'listening together.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, 'notify'),
            icon: const Icon(Icons.notifications_active_rounded, size: 18),
            label: Text('Notify me when $first is online'),
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16))),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'start'),
            child: Text('Start anyway — $first joins when back'),
          ),
        ]),
      ),
    ),
  );
  if (!context.mounted) return false;
  if (choice == 'notify') {
    final res = await OnlineWatchList.instance.watchForListen(friendId);
    if (!context.mounted) return false;
    if (res == 'online') {
      // Came online in the meantime — just go.
      OnlineWatchList.instance.clearListen(friendId);
      return true;
    }
    showToast(
        context,
        res == null
            ? "Couldn't set that up — try again"
            : "We'll ping you when $first is online 🎧",
        type: res == null ? ToastType.error : ToastType.success);
    return false;
  }
  return choice == 'start';
}
