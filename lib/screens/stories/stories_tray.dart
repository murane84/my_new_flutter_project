import 'package:flutter/material.dart';

import '../../services/contact_names.dart';
import '../../utils/net_image.dart';
import '../token_helper.dart' show mediaAuthHeaders;
import 'create_story_sheet.dart';
import 'story_models.dart';
import 'story_viewer.dart';
import '../../utils/readable.dart';
import '../../services/story_mute.dart';

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
  // Compact = smaller rings/tiles, for a pinned strip where vertical room is
  // precious (e.g. the desktop Circle column). Default is the full-size tray.
  final bool compact;
  // Grid = the "Status" full view: every circle laid out in a vertical grid
  // that fills the whole column / screen, split into New · Viewed · Muted,
  // instead of the one-row strip. The caller gives it a bounded height.
  final bool grid;
  // Grid only: the groups were narrowed by a search (empty = "no match",
  // not "nobody posted").
  final bool searching;
  // Grid only: lets the host glide it back to the top.
  final ScrollController? controller;

  const StoriesTray({
    super.key,
    required this.apiBase,
    required this.myUserId,
    required this.myName,
    required this.myAvatarUrl,
    required this.groups,
    required this.onReload,
    this.compact = false,
    this.grid = false,
    this.searching = false,
    this.controller,
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

  /// Closest first, like everywhere in Aluta: my Harmony partner right
  /// after me, then my bonds, then everyone else (newest first, as the
  /// server sends them); muted friends wait at the end.
  List<StoryGroup> get _friendGroups {
    final list = widget.groups.where((g) => !g.isMe).toList();
    int rank(StoryGroup g) {
      if (StoryMute.instance.isMuted(g.authorId)) return 3;
      final c = StoryHooks.closeness?.call(g.authorId) ?? 0;
      return c == 2 ? 0 : (c == 1 ? 1 : 2);
    }

    final order = {for (var i = 0; i < list.length; i++) list[i]: i};
    list.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : order[a]!.compareTo(order[b]!);
    });
    return list;
  }

  /// Long-press a friend's status → mute / unmute it.
  Future<void> _muteSheet(StoryGroup g) async {
    final name = _nameFor(g);
    final muted = StoryMute.instance.isMuted(g.authorId);
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          ListTile(
            leading: Icon(muted
                ? Icons.notifications_active_outlined
                : Icons.notifications_off_outlined),
            title: Text(muted
                ? 'Unmute $name’s status'
                : 'Mute $name’s status'),
            subtitle: Text(muted
                ? 'Their new statuses light up again'
                : 'Moves to the end, never shows as new · still friends'),
            onTap: () => Navigator.pop(ctx, true),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (ok != true) return;
    await StoryMute.instance.toggle(g.authorId);
    await widget.onReload();
    if (mounted) setState(() {});
  }

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
    if (widget.grid) return _buildGrid(context);
    final friends = _friendGroups;
    final compact = widget.compact;
    final ringSize = compact ? 50.0 : 66.0;
    final avatarRadius = compact ? 22.0 : 30.0;
    final tileWidth = compact ? 58.0 : 74.0;
    final labelSize = compact ? 10.0 : 11.0;
    final badgeSize = compact ? 18.0 : 22.0;
    final trayHeight = compact ? 82.0 : 104.0;
    return Container(
      height: trayHeight,
      margin: const EdgeInsets.only(bottom: 4),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: compact ? 4 : 6),
        itemCount: friends.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (_, i) {
          if (i == 0) {
            return _myTile(
                ringSize, avatarRadius, tileWidth, labelSize, badgeSize);
          }
          final g = friends[i - 1];
          final idx = friends.indexOf(g);
          return _friendTile(g, () => _openViewer(friends, idx), ringSize,
              avatarRadius, tileWidth, labelSize, badgeSize);
        },
      ),
    );
  }

  /// The full Status view: "Your story" first, then the circle split into
  /// New (unseen) · Viewed · Muted — each a grid that fills the width, the
  /// whole thing scrolling in the height it's given. The viewer still walks
  /// the full closest-first order, so swiping on carries through sections.
  Widget _buildGrid(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final friends = _friendGroups;
    final fresh = <StoryGroup>[];
    final seen = <StoryGroup>[];
    final muted = <StoryGroup>[];
    for (final g in friends) {
      if (StoryMute.instance.isMuted(g.authorId)) {
        muted.add(g);
      } else if (g.hasUnseen) {
        fresh.add(g);
      } else {
        seen.add(g);
      }
    }
    const ringSize = 66.0, avatarRadius = 30.0, tileWidth = 80.0;
    const labelSize = 11.0, badgeSize = 22.0;
    const delegate = SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 96,
      mainAxisExtent: 98,
      crossAxisSpacing: 4,
      mainAxisSpacing: 6,
    );
    Widget label(String text, int n) => Padding(
          padding: const EdgeInsets.fromLTRB(6, 14, 6, 8),
          child: Row(children: [
            Text(text.toUpperCase(),
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                    color: scheme.onSurfaceVariant)),
            const SizedBox(width: 6),
            Text('· $n',
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    color: scheme.primary)),
            const SizedBox(width: 10),
            Expanded(
                child: Container(
                    height: 1, color: scheme.outlineVariant.withAlpha(70))),
          ]),
        );
    List<Widget> section(String title, List<StoryGroup> list) {
      if (list.isEmpty) return const [];
      return [
        SliverToBoxAdapter(child: label(title, list.length)),
        SliverGrid(
          gridDelegate: delegate,
          delegate: SliverChildBuilderDelegate(
            (_, i) {
              final g = list[i];
              return Center(
                child: _friendTile(
                    g,
                    () => _openViewer(friends, friends.indexOf(g)),
                    ringSize,
                    avatarRadius,
                    tileWidth,
                    labelSize,
                    badgeSize),
              );
            },
            childCount: list.length,
          ),
        ),
      ];
    }

    return CustomScrollView(
      key: const PageStorageKey<String>('stories-grid'),
      controller: widget.controller,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
          sliver: SliverToBoxAdapter(
            child: Align(
              alignment: Alignment.centerLeft,
              child: _myTile(
                  ringSize, avatarRadius, tileWidth, labelSize, badgeSize),
            ),
          ),
        ),
        ...section('New', fresh),
        ...section('Viewed', seen),
        ...section('Muted', muted),
        if (friends.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 28, 16, 0),
              child: Column(children: [
                Icon(Icons.auto_stories_rounded,
                    size: 34, color: scheme.onSurfaceVariant.withAlpha(150)),
                const SizedBox(height: 10),
                Text(
                    widget.searching
                        ? 'No status matches that name'
                        : 'No status from your circle yet',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface)),
                const SizedBox(height: 4),
                if (!widget.searching)
                  Text('Share a moment or the song you\'re on — yours shows first.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12.5, color: scheme.onSurfaceVariant)),
              ]),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    );
  }

  Widget _myTile(double ringSize, double avatarRadius, double tileWidth,
      double labelSize, double badgeSize) {
    final mine = _myGroup;
    final avatar =
        (widget.myAvatarUrl ?? '').isNotEmpty ? _absUrl(widget.myAvatarUrl!) : null;
    return _TileScaffold(
      label: 'Your story',
      width: tileWidth,
      labelSize: labelSize,
      onTap: () {
        if (mine != null) {
          _openViewer([mine], 0);
        } else {
          _addStory();
        }
      },
      ring: _Ring(
        size: ringSize,
        // My own ring: coloured if I have a live story, else a neutral dashed
        // "add" look.
        state: mine != null ? _RingState.own : _RingState.none,
        badge: GestureDetector(
          onTap: _addStory,
          child: Container(
            width: badgeSize,
            height: badgeSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Theme.of(context).colorScheme.primary,
              border: Border.all(
                  color: Theme.of(context).colorScheme.surface, width: 2),
            ),
            child: Icon(Icons.add,
                color: readableOn(Theme.of(context).colorScheme.primary), size: badgeSize * 0.68),
          ),
        ),
        child: _avatarCircle(avatar, widget.myName, avatarRadius),
      ),
    );
  }

  Widget _friendTile(StoryGroup g, VoidCallback onTap, double ringSize,
      double avatarRadius, double tileWidth, double labelSize,
      double badgeSize) {
    final avatar =
        (g.avatarUrl ?? '').isNotEmpty ? _absUrl(g.avatarUrl!) : null;
    final muted = StoryMute.instance.isMuted(g.authorId);
    // My Harmony partner: the warm theme → rose → gold ring and a 💞.
    final partner =
        !muted && (StoryHooks.closeness?.call(g.authorId) ?? 0) == 2;
    final tile = _TileScaffold(
      label: _nameFor(g),
      width: tileWidth,
      labelSize: labelSize,
      onTap: onTap,
      onLongPress: () => _muteSheet(g),
      ring: _Ring(
        size: ringSize,
        state: muted
            ? _RingState.none
            : partner
                ? (g.hasUnseen ? _RingState.partner : _RingState.partnerSeen)
                : (g.hasUnseen ? _RingState.unseen : _RingState.seen),
        badge: partner
            ? Text('💞', style: TextStyle(fontSize: badgeSize * 0.7))
            : null,
        child: _avatarCircle(avatar, _nameFor(g), avatarRadius),
      ),
    );
    return muted ? Opacity(opacity: 0.5, child: tile) : tile;
  }

  Widget _avatarCircle(String? avatar, String name, double radius) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: Colors.grey.shade400,
      backgroundImage: avatar != null
          ? authNetworkImageProvider(avatar, mediaAuthHeaders(avatar),
              cacheSize: 160)
          : null,
      child: avatar == null
          ? Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: radius * 0.73,
                  fontWeight: FontWeight.bold),
            )
          : null,
    );
  }
}

class _TileScaffold extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget ring;
  final double width;
  final double labelSize;

  const _TileScaffold({
    required this.label,
    required this.onTap,
    required this.ring,
    this.onLongPress,
    this.width = 74,
    this.labelSize = 11,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ring,
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: labelSize),
            ),
          ],
        ),
      ),
    );
  }
}

enum _RingState { unseen, seen, own, none, partner, partnerSeen }

class _Ring extends StatelessWidget {
  final _RingState state;
  final Widget child;
  final Widget? badge;
  final double size;

  const _Ring(
      {required this.state, required this.child, this.badge, this.size = 66});

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
      case _RingState.partner:
        // My Harmony partner's new status: warm theme → rose → gold.
        gradient = SweepGradient(colors: [
          scheme.primary,
          const Color(0xFFFF5C8A),
          const Color(0xFFF2A541),
          scheme.primary,
        ]);
        break;
      case _RingState.partnerSeen:
        solid = const Color(0xFFFF5C8A).withValues(alpha: 0.45);
        break;
    }
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
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
