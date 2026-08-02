import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'dart:async';
import 'user_profile_page.dart';
import 'user.dart';
import 'api_service.dart';
import 'token_helper.dart';
import 'home_page.dart';
import '../utils/avatar_widget.dart';
import '../utils/snackbar_helper.dart';

class FriendsListScreen extends StatefulWidget {
  static const routeName = '/friends';
  const FriendsListScreen({super.key});

  @override
  FriendsListScreenState createState() => FriendsListScreenState();
}

class FriendsListScreenState extends State<FriendsListScreen> {
  List<User> _friends = [];
  bool _isLoading = true;
  int? _currentUserId;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _initialize();
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _loadFriends(quiet: true);
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final userData = await ApiService().getUserData();
      _currentUserId = userData['id'] as int?;
    } catch (_) {}
    await _loadFriends();
  }

  Future<void> _loadFriends({bool quiet = false}) async {
    try {
      final token = await getToken();
      if (token == null || token.isEmpty) return;

      final users = await ApiService().getFriendsWithUnreadCounts();
      if (!mounted) return;
      setState(() {
        _friends = users;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _formatTimestamp(String raw) {
    if (raw.isEmpty) return '';
    try {
      final dt = DateTime.parse(raw).toLocal();
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inMinutes < 1) return 'now';
      if (diff.inHours < 1) return '${diff.inMinutes}m';
      if (diff.inDays < 1) return DateFormat('h:mm a').format(dt);
      if (diff.inDays < 7) return DateFormat('EEE').format(dt);
      return DateFormat('d MMM').format(dt);
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textColor = scheme.onSurface;

    return Scaffold(
      appBar: AppBar(title: const Text('Messages')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _friends.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.chat_bubble_outline,
                          size: 56, color: scheme.outlineVariant),
                      const SizedBox(height: 12),
                      Text(
                        'No conversations yet',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadFriends,
                  child: ListView.separated(
                    itemCount: _friends.length,
                    separatorBuilder: (ctx, i) => Divider(
                      height: 1,
                      indent: 76,
                      color: scheme.outlineVariant.withAlpha(80),
                    ),
                    itemBuilder: (_, i) => _buildFriendTile(_friends[i], textColor, scheme),
                  ),
                ),
    );
  }

  Widget _buildFriendTile(User user, Color textColor, ColorScheme scheme) {
    final isYouLastSender = user.lastSenderId == _currentUserId;
    final hasUnread = !isYouLastSender && user.unreadCount > 0;

    return InkWell(
      onTap: () async {
        Navigator.popUntil(context, (r) => r.isFirst);
        await Future.delayed(const Duration(milliseconds: 100));
        if (!mounted) return;
        HomePage.of(context)?.openChat(user.toMap());
        _loadFriends(quiet: true);
      },
      onLongPress: () => showModalBottomSheet(
        context: context,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => FriendOptionsSheet(
          user: user,
          onRefresh: () => _loadFriends(),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            InitialsAvatar(
              name: user.username,
              radius: 26,
              isOnline: user.isOnline,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (user.isMuted)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Icon(
                            Icons.notifications_off_outlined,
                            size: 14,
                            color: textColor.withAlpha(120),
                          ),
                        ),
                      Expanded(
                        child: Text(
                          user.username,
                          style: TextStyle(
                            color: textColor,
                            fontWeight: hasUnread
                                ? FontWeight.bold
                                : FontWeight.w500,
                            fontSize: 15,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (isYouLastSender)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Icon(
                            user.lastMessageRead == true
                                ? Icons.done_all
                                : user.lastMessageDelivered == true
                                    ? Icons.done_all
                                    : Icons.done,
                            size: 14,
                            color: user.lastMessageRead == true
                                ? Colors.blue
                                : textColor.withAlpha(120),
                          ),
                        ),
                      Expanded(
                        child: Text(
                          user.lastMessage,
                          style: TextStyle(
                            color: hasUnread
                                ? textColor.withAlpha(200)
                                : textColor.withAlpha(120),
                            fontSize: 13,
                            fontWeight: hasUnread
                                ? FontWeight.w500
                                : FontWeight.normal,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _formatTimestamp(user.lastTimestamp),
                  style: TextStyle(
                    color: hasUnread
                        ? scheme.primary
                        : textColor.withAlpha(110),
                    fontSize: 11.5,
                    fontWeight:
                        hasUnread ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
                if (hasUnread) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      user.unreadCount > 99 ? '99+' : '${user.unreadCount}',
                      style: TextStyle(
                        color: scheme.onPrimary,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
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

class FriendOptionsSheet extends StatelessWidget {
  final User user;
  final VoidCallback onRefresh;

  const FriendOptionsSheet({
    super.key,
    required this.user,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: const Text('View Profile'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => UserProfilePage(user: user),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.notifications_off_outlined),
              title: Text(user.isMuted ? 'Unmute' : 'Mute Notifications'),
              onTap: () async {
                Navigator.pop(context);
                try {
                  final muted = await ApiService().toggleMute(user.id!);
                  onRefresh();
                  if (context.mounted) {
                    showInfoSnackBar(
                      context,
                      muted ? '${user.username} muted' : '${user.username} unmuted',
                    );
                  }
                } catch (_) {
                  if (context.mounted) {
                    showErrorSnackBar(context, 'Failed to update mute status');
                  }
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text(
                'Delete Chat',
                style: TextStyle(color: Colors.red),
              ),
              onTap: () async {
                Navigator.pop(context);
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Delete Chat'),
                    content: Text(
                      'Delete your chat with ${user.username}? This cannot be undone.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text(
                          'Delete',
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  try {
                    await ApiService().deleteChatWith(user.id!);
                    onRefresh();
                    if (context.mounted) {
                      showSuccessSnackBar(context, 'Chat deleted');
                    }
                  } catch (_) {
                    if (context.mounted) {
                      showErrorSnackBar(context, 'Failed to delete chat');
                    }
                  }
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.block),
              title: const Text('Block / Unblock'),
              onTap: () async {
                Navigator.pop(context);
                try {
                  final blocked = await ApiService().toggleBlock(user.id!);
                  onRefresh();
                  if (context.mounted) {
                    showInfoSnackBar(
                      context,
                      blocked
                          ? '${user.username} blocked'
                          : '${user.username} unblocked',
                    );
                  }
                } catch (_) {
                  if (context.mounted) {
                    showErrorSnackBar(context, 'Failed to update block status');
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}
