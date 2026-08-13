import 'package:flutter/material.dart';

import 'api_service.dart';

/// Manual "Add friend" — the discovery path for desktop/web users with no
/// phone-book to scan (and a quick add on mobile too). You look someone up by
/// their EXACT @username or full phone number and add them to your circle; you
/// can't browse strangers. Adding is instant and mutual.
Future<void> showAddFriendSheet(
  BuildContext context, {
  required VoidCallback onAdded,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _AddFriendSheet(onAdded: onAdded),
  );
}

class _AddFriendSheet extends StatefulWidget {
  final VoidCallback onAdded;
  const _AddFriendSheet({required this.onAdded});

  @override
  State<_AddFriendSheet> createState() => _AddFriendSheetState();
}

class _AddFriendSheetState extends State<_AddFriendSheet> {
  final TextEditingController _c = TextEditingController();
  bool _busy = false;
  bool _adding = false;
  bool _searched = false;
  Map<String, dynamic>? _user; // the matched user
  bool _isFriend = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _c.text.trim();
    if (q.isEmpty) {
      _snack('Enter a username or phone number');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _searched = true;
      _user = null;
    });
    final res = await ApiService().lookupUser(q);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _user = (res != null && res['user'] is Map)
          ? Map<String, dynamic>.from(res['user'] as Map)
          : null;
      _isFriend = res?['is_friend'] == true;
    });
  }

  Future<void> _add() async {
    final u = _user;
    if (u == null || _adding) return;
    final id = u['id'];
    if (id is! int) return;
    setState(() => _adding = true);
    final ok = await ApiService().addFriend(id);
    if (!mounted) return;
    setState(() => _adding = false);
    if (ok) {
      // Snack first (attaches to the app-level messenger so it survives the
      // sheet closing), then refresh the list and close.
      _snack('${u['username'] ?? 'Friend'} added to your circle');
      widget.onAdded();
      Navigator.pop(context);
    } else {
      _snack('Couldn’t add — check your connection and try again');
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      // Lift above the keyboard.
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 18,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.person_add_alt_1_rounded, color: scheme.primary),
              const SizedBox(width: 10),
              Text('Add a friend',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Enter their exact Aluta username or full phone number. Only people '
            'you look up here (or who are in your contacts) join your circle.',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _c,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: 'username or +255…',
              prefixIcon: const Icon(Icons.alternate_email_rounded),
              suffixIcon: IconButton(
                icon: const Icon(Icons.search_rounded),
                tooltip: 'Search',
                onPressed: _busy ? null : _search,
              ),
            ),
          ),
          const SizedBox(height: 16),
          _result(scheme),
        ],
      ),
    );
  }

  Widget _result(ColorScheme scheme) {
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (!_searched) return const SizedBox.shrink();
    final u = _user;
    if (u == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(Icons.search_off_rounded, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'No Aluta user with that username or number.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      );
    }
    final name = (u['username'] ?? 'Aluta user').toString();
    final phone = (u['phone'] ?? '').toString();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: scheme.primaryContainer,
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: TextStyle(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15)),
                if (phone.isNotEmpty)
                  Text(phone,
                      style: TextStyle(
                          fontSize: 12.5, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (_isFriend)
            Chip(
              avatar: Icon(Icons.check_rounded,
                  size: 16, color: scheme.primary),
              label: const Text('In your circle'),
              visualDensity: VisualDensity.compact,
            )
          else
            FilledButton(
              onPressed: _adding ? null : _add,
              style: FilledButton.styleFrom(
                  backgroundColor: scheme.primary,
                  foregroundColor: scheme.onPrimary),
              child: _adding
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Add'),
            ),
        ],
      ),
    );
  }
}
