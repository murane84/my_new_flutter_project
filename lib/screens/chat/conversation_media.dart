import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../utils/net_image.dart' show authNetworkImageProvider;

/// One shared photo/video in the Media tab.
class MediaItem {
  final String messageId;
  final String thumbUrl; // full image, or video poster (…/thumb)
  final Map<String, String> headers;
  final bool isVideo;
  final String monthLabel; // "October 2026" — gallery section
  final String dayLabel; // "21 Oct" — stamp on the tile
  final String dateLabel; // "21 Oct 2026"
  const MediaItem({
    required this.messageId,
    required this.thumbUrl,
    required this.headers,
    required this.isVideo,
    this.monthLabel = '',
    this.dayLabel = '',
    this.dateLabel = '',
  });
}

/// One song shared in the conversation — the "songs we shared" shelf.
class SongItem {
  final String messageId;
  final String title;
  final String sender; // "You" or their name
  final bool mine;
  final String dateLabel;
  const SongItem({
    required this.messageId,
    required this.title,
    required this.sender,
    required this.mine,
    required this.dateLabel,
  });
}

/// One link found in a text message.
class LinkItem {
  final String messageId;
  final String url;
  final String snippet; // the surrounding message text
  final String dateLabel;
  const LinkItem({
    required this.messageId,
    required this.url,
    required this.snippet,
    required this.dateLabel,
  });
}

/// One shared document / file.
class DocItem {
  final String messageId;
  final String name;
  final String sizeLabel;
  final IconData icon;
  final String dateLabel;
  const DocItem({
    required this.messageId,
    required this.name,
    required this.sizeLabel,
    required this.icon,
    required this.dateLabel,
  });
}

/// A per-conversation "Media, links & docs" browser. Pure discovery: tapping an
/// item (except a link) pops with its message id so the chat can jump to it —
/// so playback / saving reuses the thread's own handling. Links open directly.
class ConversationMediaScreen extends StatefulWidget {
  final String title;
  final List<MediaItem> media;
  final List<LinkItem> links;
  final List<DocItem> docs;
  final List<SongItem> songs;

  const ConversationMediaScreen({
    super.key,
    required this.title,
    required this.media,
    required this.links,
    required this.docs,
    this.songs = const [],
    this.onJump,
    this.onClose,
    this.onOpenMedia,
    this.songPlayer,
    this.onSwipedAway,
  });

  /// Called instead of [onClose] when a swipe has already carried the panel
  /// off screen (so the host removes it without animating it again).
  final VoidCallback? onSwipedAway;

  /// Open media item [index] (of [media]) in the chat's viewer. Without it a
  /// tap jumps to the message.
  final ValueChanged<int>? onOpenMedia;

  /// A ready player for a shared song (by message id), or null to fall back
  /// to a plain row that jumps to the message.
  final Widget? Function(String messageId)? songPlayer;

  /// Inline mode (inside the chat panel): tapping an item calls [onJump]
  /// with its message id and the back button calls [onClose]. Without them
  /// the screen behaves as a pushed page and pops with the id.
  final ValueChanged<String>? onJump;
  final VoidCallback? onClose;

  @override
  State<ConversationMediaScreen> createState() =>
      _ConversationMediaScreenState();
}

class _ConversationMediaScreenState extends State<ConversationMediaScreen>
    with TickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);

  // Swipe to dismiss (inline): finger moving right → left. The panel
  // follows it to the left — from the right edge, or by pulling past the
  // last tab — and closes past a third of the width (or on a quick flick);
  // otherwise it springs back. [_dragX] is ≤ 0.
  double _dragX = 0;
  double _width = 1;
  late final AnimationController _settle =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 220))
        ..addListener(() {
          if (_settleTween != null) {
            setState(() => _dragX = _settleTween!.evaluate(_settle));
          }
        });
  Tween<double>? _settleTween;
  bool _closing = false;

  void _dragBy(double dx) {
    if (_closing) return;
    _settle.stop();
    setState(() => _dragX = (_dragX + dx).clamp(-_width, 0.0));
  }

  void _dragEnd(double velocity) {
    if (_closing || _dragX == 0) return;
    final close = -_dragX > _width * 0.33 || velocity < -700;
    _closing = close;
    _settleTween = Tween(begin: _dragX, end: close ? -_width : 0.0);
    _settle.forward(from: 0).whenComplete(() {
      if (close) (widget.onSwipedAway ?? widget.onClose)?.call();
    });
  }

  @override
  void dispose() {
    _settle.dispose();
    _tabs.dispose();
    super.dispose();
  }

  void _jump(String messageId) {
    final j = widget.onJump;
    if (j != null) {
      j(messageId);
    } else {
      Navigator.of(context).pop(messageId);
    }
  }

  Future<void> _openLink(String url) async {
    try {
      final uri = Uri.parse(url);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Could not open link')));
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not open link')));
      }
    }
  }

  // Phones cap big counts so the four tabs always fit.
  static String _n(int n, bool fit) => fit && n > 99 ? '99+' : '$n';

  TabBar _tabBar(ColorScheme scheme, {bool inline = false, bool fit = false}) =>
      TabBar(
        controller: _tabs,
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        indicatorColor: scheme.primary,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: inline
            ? Colors.transparent
            : scheme.outlineVariant.withValues(alpha: 0.4),
        labelPadding: fit
            ? const EdgeInsets.symmetric(horizontal: 2)
            : (inline ? const EdgeInsets.symmetric(horizontal: 12) : null),
        isScrollable: !fit,
        tabAlignment: fit ? TabAlignment.fill : TabAlignment.start,
        labelStyle: TextStyle(
            fontWeight: FontWeight.w700, fontSize: fit ? 12.5 : 13),
        unselectedLabelStyle: TextStyle(
            fontWeight: FontWeight.w500, fontSize: fit ? 12.5 : 13),
        tabs: [
          Tab(text: 'Songs (${_n(widget.songs.length, fit)})'),
          Tab(text: 'Media (${_n(widget.media.length, fit)})'),
          Tab(text: 'Links (${_n(widget.links.length, fit)})'),
          Tab(text: 'Docs (${_n(widget.docs.length, fit)})'),
        ],
      );

  // Inside the chat panel: the conversation header stays above and the
  // composer below; this is a surface over the thread with its own slim bar.
  Widget _inline(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final total = widget.songs.length +
        widget.media.length +
        widget.links.length +
        widget.docs.length;
    final panel = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            widget.onClose?.call(),
      },
      child: Focus(
        autofocus: true,
        child: Material(
          color: isDark
              ? Color.alphaBlend(
                  Colors.white.withValues(alpha: 0.03), scheme.surface)
              : scheme.surface,
          child: Column(
            children: [
              // One slim row: back + the tabs. The conversation header above
              // already names the chat, so no second title here.
              Container(
                padding: const EdgeInsets.only(left: 2, right: 6),
                decoration: BoxDecoration(
                  border: Border(
                      bottom: BorderSide(
                          color: scheme.outlineVariant.withValues(alpha: 0.4))),
                ),
                child: LayoutBuilder(builder: (context, c) {
                  // Phones: the four tabs share the row evenly (no
                  // scrolling, no hidden first tab); the total sits at the
                  // end as a raised badge so it can't read as a fifth tab.
                  final narrow = c.maxWidth < 560;
                  return Row(
                  children: [
                    IconButton(
                      tooltip: 'Back to chat',
                      visualDensity: VisualDensity.compact,
                      onPressed: widget.onClose,
                      icon: const Icon(Icons.arrow_back_rounded, size: 20),
                    ),
                    Expanded(
                      child: Tooltip(
                        message: total == 0
                            ? 'Nothing shared yet'
                            : '$total shared · tap one to find it in the chat',
                        child: _tabBar(scheme, inline: true, fit: narrow),
                      ),
                    ),
                    // The total as a small raised 3D badge — a lit pink
                    // key, clearly not a flat tab label. Phones show just
                    // the heart + number.
                    Tooltip(
                      message: '$total shared in this chat',
                      child: Container(
                        margin: const EdgeInsets.only(left: 6, right: 4),
                        padding: EdgeInsets.symmetric(
                            horizontal: narrow ? 7 : 9, vertical: 4),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Color.lerp(scheme.primary, Colors.white, 0.30)!,
                              scheme.primary,
                              Color.lerp(scheme.primary, Colors.black, 0.18)!,
                            ],
                            stops: const [0.0, 0.55, 1.0],
                          ),
                          border: Border.all(
                              width: 0.8,
                              color: Colors.white.withValues(alpha: 0.38)),
                          boxShadow: [
                            BoxShadow(
                              color: scheme.primary.withValues(alpha: 0.35),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.favorite_rounded,
                                size: 11, color: Colors.white),
                            const SizedBox(width: 4),
                            Text(
                              narrow ? '$total' : '$total shared',
                              style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
                }),
              ),
              Expanded(
                // Pulling left past the last tab = swipe to dismiss.
                child: NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n.depth != 0 || n.metrics.axis != Axis.horizontal) {
                      return false;
                    }
                    if (n is OverscrollNotification &&
                        n.overscroll > 0 &&
                        n.dragDetails != null &&
                        _tabs.index == _tabs.length - 1) {
                      _dragBy(-n.overscroll);
                    } else if (n is ScrollEndNotification && _dragX < 0) {
                      _dragEnd(n.dragDetails?.primaryVelocity ?? 0);
                    }
                    return false;
                  },
                  child: TabBarView(
                    controller: _tabs,
                    children: [
                      _songsTab(scheme),
                      _mediaTab(scheme),
                      _linksTab(scheme),
                      _docsTab(scheme),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return LayoutBuilder(builder: (context, c) {
      _width = c.maxWidth.isFinite && c.maxWidth > 0 ? c.maxWidth : 1;
      final p = (-_dragX / _width).clamp(0.0, 1.0);
      return Stack(
        children: [
          Positioned.fill(
            child: Transform.translate(
              offset: Offset(_dragX, 0),
              child: Opacity(opacity: 1 - 0.5 * p, child: panel),
            ),
          ),
          // Right-edge swipe (works on every tab, and on iOS where pages
          // bounce instead of overscrolling).
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 20,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragUpdate: (d) => _dragBy(d.delta.dx),
              onHorizontalDragEnd: (d) => _dragEnd(d.primaryVelocity ?? 0),
              onHorizontalDragCancel: () => _dragEnd(0),
            ),
          ),
        ],
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (widget.onClose != null) return _inline(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        bottom: TabBar(
          controller: _tabs,
          labelColor: scheme.primary,
          indicatorColor: scheme.primary,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(text: 'Songs (${widget.songs.length})'),
            Tab(text: 'Media (${widget.media.length})'),
            Tab(text: 'Links (${widget.links.length})'),
            Tab(text: 'Docs (${widget.docs.length})'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _songsTab(scheme),
          _mediaTab(scheme),
          _linksTab(scheme),
          _docsTab(scheme),
        ],
      ),
    );
  }

  Widget _empty(ColorScheme scheme, IconData icon, String text) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: scheme.onSurfaceVariant.withAlpha(120)),
            const SizedBox(height: 12),
            Text(text,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
          ],
        ),
      );

  Widget _mediaTab(ColorScheme scheme) {
    if (widget.media.isEmpty) {
      return _empty(scheme, Icons.photo_library_outlined,
          'No photos or videos shared yet');
    }
    // Month sections (newest first, as the items arrive), each a 3-up grid
    // under a small accent header — the gallery reads like a timeline.
    final sections = <(String, List<MediaItem>)>[];
    for (final m in widget.media) {
      if (sections.isEmpty || sections.last.$1 != m.monthLabel) {
        sections.add((m.monthLabel, <MediaItem>[]));
      }
      sections.last.$2.add(m);
    }
    return CustomScrollView(
      slivers: [
        for (final sec in sections) ...[
          if (sec.$1.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
                child: Row(
                  children: [
                    Container(
                      width: 3,
                      height: 14,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(sec.$1,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface)),
                    const SizedBox(width: 6),
                    Text('${sec.$2.length}',
                        style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 150,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
              ),
              delegate: SliverChildBuilderDelegate(
                (_, i) => _mediaCell(scheme, sec.$2[i]),
                childCount: sec.$2.length,
              ),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    );
  }

  Widget _mediaCell(ColorScheme scheme, MediaItem m) {
    return Tooltip(
      message: widget.onOpenMedia != null
          ? (m.dateLabel.isEmpty ? 'Open' : '${m.dateLabel} · open')
          : (m.dateLabel.isEmpty
              ? 'Show in chat'
              : '${m.dateLabel} · show in chat'),
      child: GestureDetector(
        onTap: () {
          final open = widget.onOpenMedia;
          if (open != null) {
            open(widget.media.indexOf(m));
          } else {
            _jump(m.messageId);
          }
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image(
                image: authNetworkImageProvider(m.thumbUrl, m.headers),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                  color: scheme.surfaceContainerHighest,
                  child: Icon(Icons.broken_image_outlined,
                      color: scheme.onSurfaceVariant),
                ),
              ),
              if (m.isVideo)
                const Center(
                  child: Icon(Icons.play_circle_fill_rounded,
                      color: Colors.white, size: 34),
                ),
              // Day stamp, bottom-left, on a soft scrim.
              if (m.dayLabel.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(6, 10, 6, 4),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black54],
                      ),
                    ),
                    child: Text(m.dayLabel,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _linksTab(ColorScheme scheme) {
    if (widget.links.isEmpty) {
      return _empty(scheme, Icons.link_rounded, 'No links shared yet');
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: widget.links.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final l = widget.links[i];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: scheme.primaryContainer,
            child: Icon(Icons.link_rounded, color: scheme.onPrimaryContainer),
          ),
          title: Text(l.url,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.primary, fontSize: 13.5)),
          subtitle: Text(
            l.snippet.isEmpty ? l.dateLabel : l.snippet,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
          trailing: IconButton(
            tooltip: 'Go to message',
            icon: const Icon(Icons.subdirectory_arrow_right_rounded, size: 20),
            onPressed: () => _jump(l.messageId),
          ),
          onTap: () => _openLink(l.url),
        );
      },
    );
  }

  /// Our soundtrack: every song either of us sent, newest first, with who
  /// sent it — tap to go back to that moment in the chat.
  // A song that plays right here: who shared it and when, the player, and a
  // way back to it in the chat.
  Widget _songCard(ColorScheme scheme, SongItem s, Widget player) {
    final isDark = scheme.brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 8),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.05)
            : scheme.primary.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  [s.mine ? 'You shared' : '${s.sender} shared', s.dateLabel]
                      .where((e) => e.isNotEmpty)
                      .join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: 'Show in chat',
                visualDensity: VisualDensity.compact,
                onPressed: () => _jump(s.messageId),
                icon: Icon(Icons.forum_outlined,
                    size: 18, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: player,
          ),
        ],
      ),
    );
  }

  Widget _songsTab(ColorScheme scheme) {
    if (widget.songs.isEmpty) {
      return _empty(scheme, Icons.library_music_outlined,
          'No songs shared yet — your soundtrack starts here');
    }
    final mine = widget.songs.where((s) => s.mine).length;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Row(children: [
            Icon(Icons.favorite_rounded, size: 15, color: scheme.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '${widget.songs.length} songs shared · $mine from you, '
                '${widget.songs.length - mine} to you',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant),
              ),
            ),
          ]),
        ),
        for (final s in widget.songs)
          if (widget.songPlayer?.call(s.messageId) case final player?)
            _songCard(scheme, s, player)
          else
          ListTile(
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [
                  Color.lerp(scheme.primary, Colors.white, 0.25)!,
                  scheme.primary,
                ]),
              ),
              child: const Icon(Icons.music_note_rounded,
                  color: Colors.white, size: 20),
            ),
            title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [s.mine ? 'You shared' : '${s.sender} shared', s.dateLabel]
                  .where((e) => e.isNotEmpty)
                  .join(' · '),
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
            trailing: Icon(Icons.chevron_right_rounded,
                color: scheme.onSurfaceVariant),
            onTap: () => _jump(s.messageId),
          ),
      ],
    );
  }

  Widget _docsTab(ColorScheme scheme) {
    if (widget.docs.isEmpty) {
      return _empty(scheme, Icons.insert_drive_file_outlined,
          'No documents shared yet');
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: widget.docs.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final d = widget.docs[i];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: scheme.primaryContainer,
            child: Icon(d.icon, color: scheme.onPrimaryContainer),
          ),
          title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [d.sizeLabel, d.dateLabel].where((s) => s.isNotEmpty).join(' · '),
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
          onTap: () => _jump(d.messageId),
        );
      },
    );
  }
}
