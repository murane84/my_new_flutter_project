import 'package:flutter/material.dart';

import '../screens/api_service.dart';
import '../utils/toast_helper.dart';

/// The people *I* blocked (never who blocked me — that's not knowable).
///
/// One place for the whole app: the chat swaps its composer for an
/// "Unblock" bar, the profile card and the chat menu offer Block / Unblock,
/// Settings → Privacy lists them, and Home refreshes the circle the moment
/// it changes (their status, listening and presence disappear at once).
class BlockList extends ChangeNotifier {
  BlockList._();
  static final BlockList instance = BlockList._();

  final Map<int, Map<String, dynamic>> _blocked = {};
  int? _myId;

  bool isBlocked(int id) => _blocked.containsKey(id);

  /// Bumps on each block / unblock I make (not on a plain reload), so
  /// listeners can refetch only when something actually changed.
  int get version => _version;
  int _version = 0;
  List<Map<String, dynamic>> get people => _blocked.values.toList();
  int get count => _blocked.length;
  int? get myId => _myId;

  /// Fetch my block list (call once "me" is known, and on refresh).
  Future<void> load(int myId) async {
    _myId = myId;
    final rows = await ApiService().getBlockedUsers(myId);
    _blocked
      ..clear()
      ..addEntries(rows
          .where((r) => r['id'] is num)
          .map((r) => MapEntry((r['id'] as num).toInt(), r)));
    notifyListeners();
  }

  Future<void> refresh() async {
    final me = _myId;
    if (me != null) await load(me);
  }

  /// Block or unblock [id], with a short confirm that says what happens.
  /// Returns the new state (true = blocked), or null if cancelled / failed.
  Future<bool?> toggle(BuildContext context, int id, String name,
      {Map<String, dynamic>? person}) async {
    final blocking = !isBlocked(id);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(blocking ? 'Block $name?' : 'Unblock $name?'),
        content: Text(blocking
            ? "They won't be told. Messages, calls, status, listening and "
                'Listen Together stop both ways until you unblock. Your '
                'chat history stays.'
            : 'You can message, call and see each other again.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: blocking
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(dctx).colorScheme.error,
                    foregroundColor: Theme.of(dctx).colorScheme.onError)
                : null,
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(blocking ? 'Block' : 'Unblock'),
          ),
        ],
      ),
    );
    if (ok != true) return null;
    try {
      final now = await ApiService().toggleBlock(id);
      if (now) {
        _blocked[id] = person ?? {'id': id, 'username': name};
      } else {
        _blocked.remove(id);
      }
      _version++;
      notifyListeners();
      if (context.mounted) {
        showToast(context, now ? '$name blocked' : '$name unblocked',
            type: ToastType.success);
      }
      return now;
    } catch (_) {
      if (context.mounted) {
        showToast(context, 'Could not change that — try again.',
            type: ToastType.error);
      }
      return null;
    }
  }
}
