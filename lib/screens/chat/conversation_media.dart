import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../utils/net_image.dart' show authNetworkImageProvider;

/// One shared photo/video in the Media tab.
class MediaItem {
  final String messageId;
  final String thumbUrl; // full image, or video poster (…/thumb)
  final Map<String, String> headers;
  final bool isVideo;
  const MediaItem({
    required this.messageId,
    required this.thumbUrl,
    required this.headers,
    required this.isVideo,
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

  const ConversationMediaScreen({
    super.key,
    required this.title,
    required this.media,
    required this.links,
    required this.docs,
  });

  @override
  State<ConversationMediaScreen> createState() =>
      _ConversationMediaScreenState();
}

class _ConversationMediaScreenState extends State<ConversationMediaScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

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
          tabs: [
            Tab(text: 'Media (${widget.media.length})'),
            Tab(text: 'Links (${widget.links.length})'),
            Tab(text: 'Docs (${widget.docs.length})'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
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
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
      ),
      itemCount: widget.media.length,
      itemBuilder: (_, i) {
        final m = widget.media[i];
        return GestureDetector(
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
              ],
            ),
          ),
        );
      },
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
