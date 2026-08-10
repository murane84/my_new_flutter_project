import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api_service.dart';
import 'token_helper.dart' show mediaAuthHeaders;
import '../services/contact_names.dart';
import '../utils/net_image.dart';
import '../utils/time_utils.dart';
import '../utils/toast_helper.dart';

/// A read-only profile card for ANOTHER user (a friend or a group member).
/// Opens from a tap on their name/avatar. Shows the photo, the name (their saved
/// phonebook name if you have their number, otherwise their app username), the
/// phone number (copyable), online/last-seen, and an optional Call action.
///
/// If [userId] is given, the sheet FETCHES that user's live details
/// (/users/{id}/status → phone + is_online + last_seen) on open, so it shows the
/// current profile even when the caller only had a partial record. Any values
/// passed in are used immediately as a first paint while the fetch resolves.
Future<void> showUserProfile(
  BuildContext context, {
  required String username,
  int? userId,
  String? phone,
  String? avatarUrl, // full URL (already resolved)
  bool isOnline = false,
  String? statusLine, // e.g. "Online" / "Last seen …"
  VoidCallback? onCall,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _UserProfileSheet(
      username: username,
      userId: userId,
      phone: phone,
      avatarUrl: avatarUrl,
      isOnline: isOnline,
      statusLine: statusLine,
      onCall: onCall,
    ),
  );
}

class _UserProfileSheet extends StatefulWidget {
  final String username;
  final int? userId;
  final String? phone;
  final String? avatarUrl;
  final bool isOnline;
  final String? statusLine;
  final VoidCallback? onCall;

  const _UserProfileSheet({
    required this.username,
    this.userId,
    this.phone,
    this.avatarUrl,
    this.isOnline = false,
    this.statusLine,
    this.onCall,
  });

  @override
  State<_UserProfileSheet> createState() => _UserProfileSheetState();
}

class _UserProfileSheetState extends State<_UserProfileSheet> {
  late String? _phone = widget.phone;
  late bool _isOnline = widget.isOnline;
  late String? _statusLine = widget.statusLine;
  bool _fetching = false;

  @override
  void initState() {
    super.initState();
    _fetchLive();
  }

  /// Pull the user's live status (online, last-seen) + phone from the server so
  /// the sheet reflects the current profile, not a possibly-stale hand-off.
  Future<void> _fetchLive() async {
    final id = widget.userId;
    if (id == null) return;
    setState(() => _fetching = true);
    try {
      final st = await ApiService().fetchFriendStatus(id);
      if (!mounted) return;
      final fp = (st['phone'] as String?)?.trim();
      final online = st['is_online'] == true;
      final lastSeen = (st['last_seen'] as String?)?.trim();
      setState(() {
        if (fp != null && fp.isNotEmpty) _phone = fp;
        _isOnline = online;
        if (online) {
          _statusLine = 'Online';
        } else if (lastSeen != null && lastSeen.isNotEmpty) {
          _statusLine = 'Last seen ${formatLastSeen(lastSeen)}';
        }
        _fetching = false;
      });
    } catch (_) {
      if (mounted) setState(() => _fetching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ph = (_phone ?? '').trim();
    final saved = ph.isNotEmpty ? ContactNames.instance.nameFor(ph) : null;
    final inPhonebook = saved != null && saved.isNotEmpty;
    final title = inPhonebook ? saved : widget.username;
    final initial = title.isNotEmpty ? title[0].toUpperCase() : '?';
    final avatarUrl = widget.avatarUrl;
    final hasAvatar = (avatarUrl ?? '').isNotEmpty;
    final status = (_statusLine ?? '').trim();

    return Container(
      margin: const EdgeInsets.all(10),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: scheme.primary.withAlpha(120)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 3,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Avatar
            CircleAvatar(
              radius: 46,
              backgroundColor: scheme.primaryContainer,
              backgroundImage: hasAvatar
                  ? authNetworkImageProvider(
                      avatarUrl!, mediaAuthHeaders(avatarUrl!))
                  : null,
              child: hasAvatar
                  ? null
                  : Text(initial,
                      style: TextStyle(
                          fontSize: 34,
                          fontWeight: FontWeight.w700,
                          color: scheme.onPrimaryContainer)),
            ),
            const SizedBox(height: 12),
            Text(title,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface)),
            // Show the app username as a secondary line when it differs from the
            // saved contact name (so you still know who it is in the app).
            if (inPhonebook &&
                widget.username.isNotEmpty &&
                widget.username != saved) ...[
              const SizedBox(height: 2),
              Text('~ ${widget.username}',
                  style: TextStyle(
                      fontSize: 12.5, color: scheme.onSurfaceVariant)),
            ],
            if (status.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(status,
                  style: TextStyle(
                      fontSize: 12,
                      color: _isOnline
                          ? Colors.green
                          : scheme.onSurfaceVariant)),
            ],
            const SizedBox(height: 18),
            // Phone row
            if (ph.isNotEmpty)
              Container(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withAlpha(120),
                  borderRadius: BorderRadius.circular(14),
                ),
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                child: Row(
                  children: [
                    Icon(Icons.phone_rounded,
                        size: 18, color: scheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Phone',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant)),
                          const SizedBox(height: 1),
                          Text(ph,
                              style: const TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copy',
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: ph));
                        showToast(context, 'Number copied');
                      },
                    ),
                  ],
                ),
              )
            else if (_fetching)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Text('Loading details…',
                      style: TextStyle(
                          fontSize: 12.5, color: scheme.onSurfaceVariant)),
                ],
              )
            else
              Text('No phone number shared',
                  style: TextStyle(
                      fontSize: 12.5, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.maybePop(context),
                    child: const Text('Close'),
                  ),
                ),
                if (widget.onCall != null) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.maybePop(context);
                        widget.onCall!();
                      },
                      icon: const Icon(Icons.call_rounded, size: 18),
                      label: const Text('Call'),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
