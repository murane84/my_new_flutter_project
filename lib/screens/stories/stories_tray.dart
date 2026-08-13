import 'package:flutter/material.dart';

import '../../services/contact_names.dart';
import '../../utils/net_image.dart';
import '../token_helper.dart' show mediaAuthHeaders;
import 'create_story_sheet.dart';
import 'story_models.dart';
import 'story_viewer.dart';

/// Horizontal "stories" strip shown at the top of the Messages list. Owns its
/// own data: it fetches the friends-only feed and reloads after posting or
/// viewing (so seen-state and new posts appear). A leading "Your story" tile
/// adds a story; friend tiles open the full-screen viewer.
class StoriesTray extends StatefulWidget {
  final String apiBase;
  final int? myUserId;
  final String myName;
  final String? myAvatarUrl;
  final List<StoryGroup> groups;
  final Future<void> Function() onReload;

  const StoriesTray({
    super.key,
    required this.apiBase,
    required this.myUserId,
    required this.myName,
    required this.myAvatarUrl,
    required this.groups,
    required this.onReload,
  });

  @override
  State<StoriesTray> createState() => _StoriesTrayState();
}

class _StoriesTrayState extends State<StoriesTray> {
  StoryGroup? get _myGroup {
    for (final g in widget.groups) {
      if (g.isMe) return g;
    }
    return null;
  }

  List<StoryGroup> get _friendGroups =>
      widget.groups.where((g) => !g.isMe).toList();

  String _absUrl(String rel) =>
      rel.startsWith('http') ? rel : '${widget.apiBase}$rel';

  String _nameFor(StoryGroup g) {
    final phone = (g.phone ?? '').trim();
    if (phone.isNotEmpty) {
      final saved = ContactNames.instance.nameFor(phone);
      if (saved != null && saved.isNotEmpty) return saved;
    }
    return g.username.isNotEmpty ? g.username : 'Friend';
  }

  Future<void> _openViewer(List<StoryGroup> groups, int startGroup) async {
    if (groups.isEmpty) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => StoryViewerScreen(
          groups: groups,
          startGroup: startGroup,
          apiBase: widget.apiBase,
          myUserId: widget.myUserId,
        ),
      ),
    );
    // Returning from the viewer: seen-state may have changed (or my story was
    // deleted). Ask home to refresh so the tray + friend-tile rings update.
    await widget.onReload();
  }

  Future<void> _addStory() async {
    await showCreateStorySheet(
      context,
      apiBase: widget.apiBase,
      onPosted: widget.onReload,
    );
  }

  @override
  Widget build(BuildContext context) {
    final friends = _friendGroups;
    return Container(
      height: 104,
      margin: const EdgeInsets.only(bottom: 4),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        itemCount: friends.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (_, i) {
          if (i == 0) return _myTile();
          final g = friends[i - 1];
          final idx = friends.indexOf(g);
          return _friendTile(g, () => _openViewer(friends, idx));
        },
      ),
    );
  }

  Widget _myTile() {
    final mine = _myGroup;
    final avatar =
        (widget.myAvatarUrl ?? '').isNotEmpty ? _absUrl(widget.myAvatarUrl!) : null;
    return _TileScaffold(
      label: 'Your story',
      onTap: () {
        if (mine != null) {
          _openViewer([mine], 0);
        } else {
          _addStory();
        }
      },
      ring: _Ring(
        // My own ring: coloured if I have a live story, else a neutral dashed
        // "add" look.
        state: mine != null ? _RingState.own : _RingState.none,
        badge: GestureDetector(
          onTap: _addStory,
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Theme.of(context).colorScheme.primary,
              border: Border.all(
                  color: Theme.of(context).colorScheme.surface, width: 2),
            ),
            child: const Icon(Icons.add, color: Colors.white, size: 15),
          ),
        ),
        child: _avatarCircle(avatar, widget.myName),
      ),
    );
  }

  Widget _friendTile(StoryGroup g, VoidCallback onTap) {
    final avatar =
        (g.avatarUrl ?? '').isNotEmpty ? _absUrl(g.avatarUrl!) : null;
    return _TileScaffold(
      label: _nameFor(g),
      onTap: onTap,
      ring: _Ring(
        state: g.hasUnseen ? _RingState.unseen : _RingState.seen,
        child: _avatarCircle(avatar, _nameFor(g)),
      ),
    );
  }

  Widget _avatarCircle(String? avatar, String name) {
    return CircleAvatar(
      radius: 30,
      backgroundColor: Colors.grey.shade400,
      backgroundImage: avatar != null
          ? authNetworkImageProvider(avatar, mediaAuthHeaders(avatar),
              cacheSize: 160)
          : null,
      child: avatar == null
          ? Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold),
            )
          : null,
    );
  }
}

class _TileScaffold extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final Widget ring;

  const _TileScaffold({
    required this.label,
    required this.onTap,
    required this.ring,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 74,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ring,
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

enum _RingState { unseen, seen, own, none }

class _Ring extends StatelessWidget {
  final _RingState state;
  final Widget child;
  final Widget? badge;

  const _Ring({required this.state, required this.child, this.badge});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Gradient? gradient;
    Color? solid;
    switch (state) {
      case _RingState.unseen:
        gradient = const LinearGradient(
          colors: [Color(0xFFF9A825), Color(0xFFE91E63), Color(0xFF7B1FA2)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        );
        break;
      case _RingState.own:
        solid = scheme.primary;
        break;
      case _RingState.seen:
        solid = Colors.grey.shade400;
        break;
      case _RingState.none:
        solid = Colors.grey.shade300;
        break;
    }
    return SizedBox(
      width: 66,
      height: 66,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 66,
            height: 66,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: gradient,
              color: gradient == null ? solid : null,
            ),
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(context).colorScheme.surface,
              ),
              child: child,
            ),
          ),
          if (badge != null)
            Positioned(bottom: -2, right: -2, child: badge!),
        ],
      ),
    );
  }
}
