import 'package:flutter/material.dart';
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
  });

  @override
  State<ConversationMediaScreen> createState() =>
      _ConversationMediaScreenState();
}

class _ConversationMediaScreenState extends State<ConversationMediaScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _jump(String messageId) => Navigator.of(context).pop(messageId);

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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
      message: m.dateLabel.isEmpty ? 'Show in chat' : '${m.dateLabel} · show in chat',
      child: GestureDetector(
        onTap: () => _jump(m.messageId),
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
