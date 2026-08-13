import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../services/contact_names.dart';
import '../../utils/net_image.dart';
import '../api_service.dart';
import '../token_helper.dart' show mediaAuthHeaders;
import 'story_models.dart';

/// Full-screen, tap-through story viewer (Instagram/WhatsApp style).
///
/// Plays every story in [groups] starting at [startGroup]: tap the right side
/// to advance, the left side to go back, hold to pause. A segmented progress
/// bar tracks each story (a fixed 5s for photos/music, the clip length for
/// video). Marks stories seen as they play; the author additionally sees a
/// "viewed by" count + list and can delete.
class StoryViewerScreen extends StatefulWidget {
  final List<StoryGroup> groups;
  final int startGroup;
  final String apiBase;
  final int? myUserId;

  const StoryViewerScreen({
    super.key,
    required this.groups,
    required this.startGroup,
    required this.apiBase,
    required this.myUserId,
  });

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen>
    with SingleTickerProviderStateMixin {
  static const Duration _photoDuration = Duration(seconds: 5);

  late int _g; // current group index
  int _s = 0; // current story index within the group

  late final AnimationController _progress;
  VideoPlayerController? _video;
  Listenable? _barTick; // drives the top progress bar (photo timer or video)
  bool _paused = false;
  bool _deleting = false;
  bool _videoError = false; // clip couldn't play here (e.g. desktop)

  StoryGroup get _group => widget.groups[_g];
  StoryItem get _story => _group.stories[_s];

  @override
  void initState() {
    super.initState();
    _g = widget.startGroup.clamp(0, widget.groups.length - 1);
    // Open directly on the first UNSEEN story so the viewer doesn't dump the
    // user on old, already-watched ones (they can still swipe back).
    _s = _firstUnseen(widget.groups[_g]);
    _progress = AnimationController(vsync: this, duration: _photoDuration)
      ..addStatusListener((st) {
        if (st == AnimationStatus.completed) _next();
      });
    WidgetsBinding.instance.addPostFrameCallback((_) => _startStory());
  }

  /// Index of the first not-yet-seen story in [g], or 0 when every story is
  /// already seen (then the group just replays from the start).
  int _firstUnseen(StoryGroup g) {
    for (var i = 0; i < g.stories.length; i++) {
      if (!g.stories[i].viewed) return i;
    }
    return 0;
  }

  @override
  void dispose() {
    _progress.dispose();
    _disposeVideo();
    super.dispose();
  }

  void _disposeVideo() {
    _video?.removeListener(_onVideoTick);
    _video?.dispose();
    _video = null;
  }

  String _absUrl(String rel) =>
      rel.startsWith('http') ? rel : '${widget.apiBase}$rel';

  Future<void> _startStory() async {
    _progress.stop();
    _progress.reset();
    _disposeVideo();
    _paused = false;
    _videoError = false;

    // Mark seen (not for my own stories — the backend ignores self-views).
    final item = _story;
    if (!_group.isMe && !item.viewed) {
      item.viewed = true;
      _group.hasUnseen = _group.stories.any((s) => !s.viewed);
      ApiService().markStoryViewed(item.id);
    }

    if (item.isVideo && item.mediaUrl != null) {
      final url = _absUrl(item.mediaUrl!);
      final headers = mediaAuthHeaders(url);
      // On WEB the browser <video> can't send an Authorization header, so move
      // the bearer token into a ?token= query param (the backend accepts it via
      // get_current_user_flexible). Native keeps sending the header.
      final Uri uri;
      final Map<String, String> hdrs;
      if (kIsWeb) {
        final auth = headers['Authorization'] ?? '';
        final tok = auth.startsWith('Bearer ') ? auth.substring(7).trim() : '';
        if (tok.isEmpty) {
          uri = Uri.parse(url);
        } else {
          final sep = url.contains('?') ? '&' : '?';
          uri = Uri.parse('$url${sep}token=${Uri.encodeQueryComponent(tok)}');
        }
        hdrs = const {};
      } else {
        uri = Uri.parse(url);
        hdrs = headers;
      }
      final ctrl = VideoPlayerController.networkUrl(uri, httpHeaders: hdrs);
      _video = ctrl;
      try {
        await ctrl.initialize();
        if (!mounted || _video != ctrl) return;
        _barTick = ctrl;
        ctrl.addListener(_onVideoTick);
        await ctrl.play();
        setState(() {});
      } catch (_) {
        // Video couldn't play here (e.g. Windows desktop has no video_player
        // backend) — show a fallback card on a timed advance so we don't stall.
        if (!mounted) return;
        _videoError = true;
        _barTick = _progress;
        _progress.forward(from: 0);
        setState(() {});
      }
    } else {
      _barTick = _progress;
      _progress.forward(from: 0);
      setState(() {});
    }
  }

  void _onVideoTick() {
    final v = _video;
    if (v == null || !v.value.isInitialized) return;
    final dur = v.value.duration;
    final pos = v.value.position;
    if (dur > Duration.zero && pos >= dur - const Duration(milliseconds: 120)) {
      _next();
    } else if (mounted) {
      setState(() {}); // advance the top bar
    }
  }

  void _next() {
    if (_s < _group.stories.length - 1) {
      setState(() => _s++);
      _startStory();
    } else if (_g < widget.groups.length - 1) {
      // Advancing to the next author → start on their first unseen story too.
      setState(() {
        _g++;
        _s = _firstUnseen(widget.groups[_g]);
      });
      _startStory();
    } else {
      _close();
    }
  }

  void _prev() {
    if (_s > 0) {
      setState(() => _s--);
      _startStory();
    } else if (_g > 0) {
      setState(() {
        _g--;
        _s = widget.groups[_g].stories.length - 1;
      });
      _startStory();
    } else {
      _startStory(); // replay first
    }
  }

  void _close() {
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  void _pause() {
    if (_paused) return;
    _paused = true;
    _progress.stop();
    _video?.pause();
  }

  void _resume() {
    if (!_paused) return;
    _paused = false;
    if (_video != null) {
      _video!.play();
    } else {
      _progress.forward();
    }
  }

  double _activeFraction() {
    final item = _story;
    if (item.isVideo && _video != null && _video!.value.isInitialized) {
      final dur = _video!.value.duration.inMilliseconds;
      if (dur <= 0) return 0;
      return (_video!.value.position.inMilliseconds / dur).clamp(0.0, 1.0);
    }
    return _progress.value;
  }

  String _displayName() {
    final phone = (_group.phone ?? '').trim();
    if (phone.isNotEmpty) {
      final saved = ContactNames.instance.nameFor(phone);
      if (saved != null && saved.isNotEmpty) return saved;
    }
    return _group.isMe
        ? 'Your story'
        : (_group.username.isNotEmpty ? _group.username : 'Friend');
  }

  @override
  Widget build(BuildContext context) {
    final item = _story;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapUp: (d) {
          final w = MediaQuery.of(context).size.width;
          if (d.globalPosition.dx < w * 0.33) {
            _prev();
          } else {
            _next();
          }
        },
        onLongPressStart: (_) => _pause(),
        onLongPressEnd: (_) => _resume(),
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) > 300) _close();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            _content(item),
            // Dark gradient top + bottom for legible chrome.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xAA000000), Color(0x00000000), Color(0x00000000), Color(0x99000000)],
                  stops: [0.0, 0.18, 0.72, 1.0],
                ),
              ),
            ),
            SafeArea(
              child: Column(
                children: [
                  _progressBars(),
                  _topBar(),
                  const Spacer(),
                  // Text stories already show the caption as the full-screen
                  // content, so skip the bottom caption bar for them.
                  if (!item.isText && (item.caption ?? '').isNotEmpty)
                    _captionBar(item),
                  if (_group.isMe) _authorFooter(item),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(StoryItem item) {
    if (item.isText) return _textContent(item);
    if (item.isMusic) return _musicContent(item);
    if (item.isVideo) {
      final v = _video;
      if (v != null && v.value.isInitialized) {
        return Center(
          child: AspectRatio(
            aspectRatio: v.value.aspectRatio == 0 ? 9 / 16 : v.value.aspectRatio,
            child: VideoPlayer(v),
          ),
        );
      }
      if (_videoError) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.movie_rounded, color: Colors.white54, size: 84),
              const SizedBox(height: 12),
              Text('Video story',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.8))),
              if ((item.caption ?? '').isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('Playback not supported here',
                      style: TextStyle(color: Colors.white38, fontSize: 12)),
                ),
            ],
          ),
        );
      }
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    // Photo
    if (item.mediaUrl != null) {
      final url = _absUrl(item.mediaUrl!);
      return Center(
        child: authNetworkImage(
          url: url,
          headers: mediaAuthHeaders(url),
          fit: BoxFit.contain,
        ),
      );
    }
    return const SizedBox.shrink();
  }

  static Color? _parseHex(String? h) {
    if (h == null || !h.startsWith('#')) return null;
    final v = int.tryParse(h.substring(1), radix: 16);
    return v == null ? null : Color(v);
  }

  /// Story background: "hex1,hex2" → gradient, a single "#hex" → solid colour,
  /// null/invalid → the [fallback] gradient.
  BoxDecoration _bgDecoration(String? bg, List<Color> fallback) {
    if (bg != null && bg.contains(',')) {
      final cs = bg.split(',').map(_parseHex).whereType<Color>().toList();
      if (cs.length >= 2) {
        return BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [cs[0], cs[1]],
          ),
        );
      }
    }
    final one = _parseHex(bg);
    if (one != null) return BoxDecoration(color: one);
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: fallback,
      ),
    );
  }

  Widget _textContent(StoryItem item) {
    return Container(
      decoration: _bgDecoration(
          item.background, const [Color(0xFF5B2C83), Color(0xFF1D1040)]),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(28),
      child: Text(
        item.caption ?? '',
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 26,
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
      ),
    );
  }

  Widget _musicContent(StoryItem item) {
    final art = item.musicArtUrl;
    final hasArt = art != null && art.startsWith('http');
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: _bgDecoration(
              item.background, const [Color(0xFF5B2C83), Color(0xFF1D1040)]),
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // A chosen GIF/sticker animates (Image.network); otherwise a note.
              SizedBox(
                width: 180,
                height: 180,
                child: hasArt
                    ? Image.network(art, fit: BoxFit.contain)
                    : Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          color: Colors.white.withValues(alpha: 0.12),
                        ),
                        child: const Icon(Icons.music_note_rounded,
                            color: Colors.white, size: 72),
                      ),
              ),
              const SizedBox(height: 22),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  item.musicTitle ?? 'Now playing',
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold),
                ),
              ),
              if ((item.musicArtist ?? '').isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  item.musicArtist!,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8), fontSize: 15),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.graphic_eq_rounded,
                      color: Colors.white.withValues(alpha: 0.7), size: 18),
                  const SizedBox(width: 6),
                  Text('Now playing',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 12)),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _progressBars() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
      child: Row(
        children: List.generate(_group.stories.length, (i) {
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: AnimatedBuilder(
                animation: _barTick ?? _progress,
                builder: (_, _) {
                  double value;
                  if (i < _s) {
                    value = 1;
                  } else if (i > _s) {
                    value = 0;
                  } else {
                    value = _activeFraction();
                  }
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: value,
                      minHeight: 3,
                      backgroundColor: Colors.white.withValues(alpha: 0.3),
                      valueColor:
                          const AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  );
                },
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _topBar() {
    final avatar =
        (_group.avatarUrl ?? '').isNotEmpty ? _absUrl(_group.avatarUrl!) : null;
    final when = _story.createdAt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 0),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: Colors.white24,
            backgroundImage: avatar != null
                ? authNetworkImageProvider(avatar, mediaAuthHeaders(avatar))
                : null,
            child: avatar == null
                ? Text(
                    _displayName().isNotEmpty
                        ? _displayName()[0].toUpperCase()
                        : '?',
                    style: const TextStyle(color: Colors.white))
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _displayName(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600),
                ),
                if (when != null)
                  Text(
                    _ago(when),
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 11),
                  ),
              ],
            ),
          ),
          if (_group.isMe)
            IconButton(
              tooltip: 'Delete story',
              icon: _deleting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.delete_outline_rounded,
                      color: Colors.white),
              onPressed: _deleting ? null : _confirmDelete,
            ),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close_rounded, color: Colors.white),
            onPressed: _close,
          ),
        ],
      ),
    );
  }

  Widget _captionBar(StoryItem item) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Text(
        item.caption!,
        textAlign: TextAlign.center,
        style: const TextStyle(
            color: Colors.white, fontSize: 16, height: 1.3),
      ),
    );
  }

  Widget _authorFooter(StoryItem item) {
    return InkWell(
      onTap: () => _showViewers(item),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.remove_red_eye_rounded,
                color: Colors.white, size: 18),
            const SizedBox(width: 6),
            Text(
              item.viewCount == 1 ? '1 view' : '${item.viewCount} views',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.keyboard_arrow_up_rounded,
                color: Colors.white70, size: 18),
          ],
        ),
      ),
    );
  }

  Future<void> _showViewers(StoryItem item) async {
    _pause();
    final raw = await ApiService().fetchStoryViewers(item.id);
    if (!mounted) return;
    final viewers = raw.map(StoryViewer.fromJson).toList();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1B1F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  viewers.isEmpty
                      ? 'No views yet'
                      : 'Viewed by ${viewers.length}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15),
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: viewers.length,
                    itemBuilder: (_, i) {
                      final v = viewers[i];
                      final av = (v.avatarUrl ?? '').isNotEmpty
                          ? _absUrl(v.avatarUrl!)
                          : null;
                      final name = _viewerName(v);
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.white24,
                          backgroundImage: av != null
                              ? authNetworkImageProvider(
                                  av, mediaAuthHeaders(av))
                              : null,
                          child: av == null
                              ? Text(
                                  name.isNotEmpty ? name[0].toUpperCase() : '?',
                                  style: const TextStyle(color: Colors.white))
                              : null,
                        ),
                        title: Text(name,
                            style: const TextStyle(color: Colors.white)),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (mounted) _resume();
  }

  String _viewerName(StoryViewer v) {
    final phone = (v.phone ?? '').trim();
    if (phone.isNotEmpty) {
      final saved = ContactNames.instance.nameFor(phone);
      if (saved != null && saved.isNotEmpty) return saved;
    }
    return v.username.isNotEmpty ? v.username : 'Someone';
  }

  Future<void> _confirmDelete() async {
    _pause();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete story?'),
        content: const Text('This story will be removed for everyone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) {
      if (mounted) _resume();
      return;
    }
    setState(() => _deleting = true);
    final item = _story;
    final done = await ApiService().deleteStory(item.id);
    if (!mounted) return;
    setState(() => _deleting = false);
    if (!done) {
      _resume();
      return;
    }
    // Drop it locally and advance / close.
    _group.stories.removeWhere((s) => s.id == item.id);
    if (_group.stories.isEmpty) {
      _close();
    } else {
      setState(() => _s = _s.clamp(0, _group.stories.length - 1));
      _startStory();
    }
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}
