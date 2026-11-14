import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../../services/contact_names.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../state/presence_state.dart';
import 'dart:io';
import '../../utils/net_image.dart';
import '../../services/media_store.dart';
import '../api_service.dart';
import '../token_helper.dart' show mediaAuthHeaders;
import 'story_models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../widgets/aluta_composer_field.dart';
import '../../utils/readable.dart';
import '../../utils/typing_guard.dart';
import '../../utils/anim_art.dart';
import '../../utils/emoji_field.dart'
    show inlineEmojiPicker, emojiFloats, showFloatingCard;
import '../gif_picker.dart';
import '../../widgets/story_ring.dart';
import 'story_fx.dart';
import '../../services/haptics.dart';
import '../../utils/toast_helper.dart';
import '../../utils/motion.dart';
import '../../utils/radii.dart';
import '../../utils/adaptive_sheet.dart';
import '../../utils/depth.dart';

/// Full-screen, tap-through story viewer (Instagram/WhatsApp style).
///
/// Plays every story in [groups] starting at [startGroup]: tap the right side
/// to advance, the left side to go back, hold to pause. A segmented progress
/// bar tracks each story (a fixed 5s for photos/music, the clip length for
/// video). Marks stories seen as they play; the author additionally sees a
/// "viewed by" count + list and can delete.
/// Bridges a status needs into the rest of Aluta — set by Home (which owns
/// presence, bonds and the music player) and read by the viewer.
class StoryHooks {
  StoryHooks._();

  /// An accepted bond with this author (Our Space partner)?
  static bool Function(int authorId)? isBonded;

  /// How close they are: 2 = my Harmony partner, 1 = a bond, 0 = circle.
  static int Function(int authorId)? closeness;

  /// Are they playing music right now (so "Tune in" can join it)?
  static bool Function(int authorId)? isPlayingNow;

  /// Ask to tune in to what they're playing.
  static void Function(
          BuildContext context, int authorId, String name, String? title)?
      tuneIn;

  /// Play this song from MY loaded songs. false = not in my songs.
  static bool Function(String title)? playOnMine;

  /// Open our chat and start Listen Together with this song.
  static void Function(BuildContext context, int authorId, String title)?
      listenTogether;

  /// My Harmony partner (for a duo status), or null.
  static ({int id, String name})? Function()? myPartner;

  /// Answer a status with a song from my player (sent to their chat).
  static Future<void> Function(BuildContext context, int authorId,
      String name, String about)? answerWithSong;
}

/// The shared-element tag of an author's story photo (tray bubble ⇄ the
/// viewer's header).
String storyHeroTag(int authorId) => 'story-avatar-$authorId';

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
    this.startStoryId,
  });

  /// Open on this exact story (e.g. tapped from a status quote in a chat)
  /// instead of the first unseen one.
  final String? startStoryId;

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
  // The timer waits for the content: while a status's photo / video / art is
  // still downloading, a spinner shows and the bar holds at zero. Stale loads
  // (the user already tapped on) are dropped by the generation counter.
  bool _loading = false;
  // A sticker / song art that didn't finish within its wait: the timer then
  // starts the moment the image's first frame is actually painted.
  bool _awaitArt = false;
  // This status's own copy of its GIF, so it always plays from frame 0.
  ImageProvider? _artProvider;
  int _gen = 0;
  File? _photoFile;

  // Reply to someone else's status — it lands in your DM with them, quoting
  // the status. Typing pauses the story; leaving the field resumes it.
  final TextEditingController _replyCtrl = TextEditingController();
  final FocusNode _replyFocus = FocusNode();
  bool _replySending = false;
  bool _replyEmoji = false; // full emoji panel open inside the reply card
  // An emoji card / GIF picker is open over the status: the reply box loses
  // focus to it, which used to RESUME the timer — so the status ran on (and
  // skipped ahead) while you were still choosing. Nothing resumes while set.
  bool _overlayOpen = false;

  // Reactions floating up over the status, and an occasion's confetti.
  final List<({int key, String emoji, double x, double size, int delayMs})>
      _floaters = [];
  int _fxKey = 0;
  bool _confetti = false;
  bool _duoBusy = false;
  // The on-device copy lookup for the photo on screen — made once per
  // status, not on every rebuild (reactions / pause rebuild a lot).
  Future<File?>? _photoFuture;
  String? _photoFutureFor;

  StoryGroup get _group => widget.groups[_g];
  StoryItem get _story => _group.stories[_s];

  @override
  void initState() {
    super.initState();
    _g = widget.startGroup.clamp(0, widget.groups.length - 1);
    _replyFocus.addListener(_onReplyFocus);
    _replyCtrl.addListener(_onReplyText);
    // Open directly on the first UNSEEN story so the viewer doesn't dump the
    // user on old, already-watched ones (they can still swipe back) — or
    // on the exact story asked for.
    final want = widget.startStoryId;
    final at = want == null
        ? -1
        : widget.groups[_g].stories.indexWhere((s) => s.id == want);
    _s = at >= 0 ? at : _firstUnseen(widget.groups[_g]);
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

  void _onReplyFocus() {
    if (_replyFocus.hasFocus) {
      _pause();
      _replyEmoji = false; // the keyboard takes over from the emoji panel
    } else if (_replyCtrl.text.trim().isEmpty &&
        !_replySending &&
        !_replyEmoji) {
      _resume();
    }
    if (mounted) setState(() {});
  }

  void _toggleReplyEmoji() {
    // Desktop: the same floating emoji card as everywhere else.
    if (emojiFloats(context)) {
      _pause();
      _overlayOpen = true;
      showFloatingCard<void>(context,
              width: 380,
              height: 300,
              builder: (c) => inlineEmojiPicker(c, _replyCtrl))
          .then((_) {
        _overlayOpen = false;
        if (mounted && _replyCtrl.text.trim().isEmpty && !_replyFocus.hasFocus) {
          _resume();
        }
      });
      return;
    }
    final opening = !_replyEmoji;
    setState(() => _replyEmoji = opening);
    if (opening) {
      _replyFocus.unfocus();
      _pause();
    } else {
      // ⌨: straight back to typing the reply (one tap, as in the chat).
      _replyFocus.requestFocus();
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    }
  }

  /// Reply with a GIF / sticker (same picker as the chat).
  Future<void> _replyWithSticker() async {
    _pause();
    _overlayOpen = true;
    final url = await showAdaptiveSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1B1B1F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl)),
      ),
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.6,
          child: GifPicker(
            onSelected: (gif) => Navigator.pop(ctx, gif.fullUrl),
          ),
        ),
      ),
    );
    _overlayOpen = false;
    if (!mounted) return;
    if (url == null || url.isEmpty) {
      _resume();
      return;
    }
    await _sendReply(gifUrl: url);
  }

  void _onReplyText() {
    if (mounted) setState(() {});
  }

  /// A one-line quote of the status, so the DM shows what was answered.
  String _statusQuote(StoryItem it) {
    String clip(String t) {
      final one = t.trim().replaceAll(RegExp(r'\s+'), ' ');
      return one.length > 60 ? '${one.substring(0, 57)}…' : one;
    }
    final cap = clip(it.caption ?? '');
    String withCap(String head) => cap.isEmpty ? head : '$head: $cap';
    switch (it.kind) {
      case 'video':
        return withCap('🎬 Status');
      case 'music':
        final t = clip(it.musicTitle ?? '');
        final a = clip(it.musicArtist ?? '');
        return t.isEmpty
            ? withCap('🎵 Status')
            : '🎵 Status: $t${a.isEmpty ? '' : ' — $a'}';
      case 'text':
        return cap.isEmpty ? '💬 Status' : '💬 Status: $cap';
      case 'sticker':
        return withCap('✨ Status');
      default:
        return withCap('📷 Status');
    }
  }

  Future<void> _sendReply({String? quick, String? gifUrl}) async {
    final text = gifUrl != null ? '' : (quick ?? _replyCtrl.text).trim();
    if ((text.isEmpty && gifUrl == null) || _replySending) return;
    final item = _story;
    final to = _group.authorId;
    setState(() => _replySending = true);
    final content = '> ${_statusQuote(item)}\n\n$text';
    // See it go: the reaction floats up over their status (and an occasion
    // gets its confetti).
    if (quick != null) _floatUp(quick);
    if (_occasionOf(item) != null && (quick != null || text.isNotEmpty)) {
      setState(() => _confetti = true);
    }
    // A quick reaction also shows beside my name in their "Viewed by".
    if (quick != null) ApiService().reactToStory(item.id, quick);
    final sent = gifUrl != null
        ? await ApiService().sendMessage(to, content,
            messageType: 'image',
            mediaUrl: gifUrl,
            mediaName: 'sticker.gif',
            mediaMime: 'image/gif')
        : await ApiService().sendMessage(to, content);
    if (!mounted) return;
    setState(() => _replySending = false);
    final name = _displayName();
    if (sent != null) {
      if (gifUrl == null && quick == null) _replyCtrl.clear();
      _replyFocus.unfocus();
      _replyEmoji = false;
      Haptics.lightImpact();
      // Aluta's own toast (not a grey system bar), and a short beat before
      // the status moves on — so you see it landed.
      showToast(context, 'Sent to ${name.isEmpty ? 'them' : name} 💞',
          type: ToastType.success);
      _pause();
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (mounted && !_replyFocus.hasFocus && !_overlayOpen) _resume();
      });
    } else {
      showToast(context, 'Couldn’t send — check your connection',
          type: ToastType.error);
    }
  }

  /// One glossy card holding the whole reply: quick reactions (and ＋ for
  /// every emoji), then the composer with emoji · GIF/sticker · send — so it
  /// reads as YOUR reply, not part of their status.
  Widget _replyBar() {
    const quick = ['❤️', '😍', '😂', '😮', '😢', '🔥', '👏', '🙏'];
    final scheme = Theme.of(context).colorScheme;
    final hasText = _replyCtrl.text.trim().isNotEmpty;
    final name = _displayName();
    Widget tool(IconData icon, String tip, VoidCallback onTap,
            {bool active = false}) =>
        IconButton(
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          onPressed: onTap,
          icon: Icon(icon,
              color: active ? scheme.primary : Colors.white.withValues(alpha: 0.8)),
        );
    // Swallow taps so they don't page the story.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (_) {},
      onLongPressStart: (_) {},
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Container(
            margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.xxl),
              // Glossy dark glass: a lit top edge fading into a deep base.
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.alphaBlend(Colors.white.withValues(alpha: 0.14),
                      const Color(0xE61C1A1F)),
                  const Color(0xF0141216),
                ],
              ),
              border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.45),
                  blurRadius: Depth.lg,
                  offset: const Offset(0, 8),
                ),
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.12),
                  blurRadius: Depth.lg,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Quick reactions — one tap sends.
                SizedBox(
                  height: 44,
                  child: Row(
                    children: [
                      Expanded(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            for (final e in quick)
                              Flexible(
                                child: InkResponse(
                                  radius: 24,
                                  onTap: _replySending
                                      ? null
                                      : () => _sendReply(quick: e),
                                  child: Padding(
                                    padding: const EdgeInsets.all(3),
                                    child: FittedBox(
                                      child: Text(e,
                                          style:
                                              const TextStyle(fontSize: 26)),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      tool(
                          _replyEmoji
                              ? Icons.expand_more_rounded
                              : Icons.add_reaction_outlined,
                          _replyEmoji ? 'Hide emoji' : 'All emoji',
                          _toggleReplyEmoji,
                          active: _replyEmoji),
                    ],
                  ),
                ),
                Divider(
                    height: 10,
                    color: Colors.white.withValues(alpha: 0.10)),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: AlutaComposerField(
                        controller: _replyCtrl,
                        focusNode: _replyFocus,
                        hint: name.isEmpty ? 'Reply…' : 'Reply to $name…',
                        maxLines: 3,
                        dark: true,
                        sendOnAction: true,
                        onSubmit: _sendReply,
                        leading: tool(
                            _replyEmoji
                                ? Icons.keyboard_rounded
                                : Icons.emoji_emotions_outlined,
                            _replyEmoji ? 'Keyboard' : 'Emoji',
                            () {
                          if (_replyEmoji) {
                            _toggleReplyEmoji();
                            _replyFocus.requestFocus();
                          } else {
                            _toggleReplyEmoji();
                          }
                        }, active: _replyEmoji),
                        trailing: tool(Icons.gif_box_outlined,
                            'GIF / sticker', _replyWithSticker),
                      ),
                    ),
                    AnimatedSize(
                      duration: Motion.quick,
                      curve: Curves.easeOutCubic,
                      child: hasText || _replySending
                          ? Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: Material(
                                color: scheme.primary,
                                shape: const CircleBorder(),
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: _replySending ? null : _sendReply,
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: _replySending
                                        ? SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: readableOn(
                                                    scheme.primary)))
                                        : Icon(Icons.send_rounded,
                                            size: 20,
                                            color: scheme.onPrimary),
                                  ),
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
                // Every emoji, inside the same card.
                AnimatedSize(
                  duration: Motion.standard,
                  curve: Curves.easeOutCubic,
                  child: _replyEmoji
                      ? Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(Radii.xl),
                            child: SizedBox(
                              height: 260,
                              child: inlineEmojiPicker(context, _replyCtrl),
                            ),
                          ),
                        )
                      : const SizedBox(width: double.infinity),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _replyFocus.removeListener(_onReplyFocus);
    _replyCtrl.removeListener(_onReplyText);
    _replyFocus.dispose();
    _replyCtrl.dispose();
    _progress.dispose();
    _disposeVideo();
    _song?.dispose();
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
    final gen = ++_gen;
    _photoFile = null;
    _loading = false;
    _awaitArt = false;
    _artProvider = null;
    _progress.duration = _photoDuration;
    _stopSong();

    // Mark seen (not for my own stories — the backend ignores self-views).
    final item = _story;
    if (!_group.isMe && !item.viewed) {
      item.viewed = true;
      _group.hasUnseen = _group.stories.any((s) => !s.viewed);
      ApiService().markStoryViewed(item.id);
    }

    // A song moment plays under it (and the status lasts as long).
    if (!item.isVideo && (item.songUrl ?? '').isNotEmpty) {
      _playSong(item, gen).ignore();
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
      // Cache-first: play the on-device copy when the status was pre-downloaded
      // (photos always; videos on Wi-Fi per the user's setting) — instant and
      // offline. Otherwise stream from the network.
      File? cachedVid;
      if (!kIsWeb) {
        try {
          cachedVid = await MediaStore.instance.cached(url);
        } catch (_) {}
      }
      final ctrl = cachedVid != null
          ? VideoPlayerController.file(cachedVid)
          : VideoPlayerController.networkUrl(uri, httpHeaders: hdrs);
      _video = ctrl;
      if (mounted) setState(() => _loading = true);
      try {
        await ctrl.initialize().timeout(const Duration(seconds: 25));
        if (!mounted || _video != ctrl || gen != _gen) return;
        _loading = false;
        _barTick = ctrl;
        ctrl.addListener(_onVideoTick);
        if (!_paused) await ctrl.play();
        if (mounted) setState(() {});
      } catch (_) {
        // Video couldn't play here (e.g. Windows desktop has no video_player
        // backend) — show a fallback card on a timed advance so we don't stall.
        if (!mounted || gen != _gen) return;
        _loading = false;
        _videoError = true;
        _barTick = _progress;
        if (!_paused) _progress.forward(from: 0);
        setState(() {});
      }
    } else {
      // Photo / music / sticker: fetch and decode what it shows FIRST, so
      // the 5s timer only starts once the status is actually on screen.
      final needsLoad = (item.mediaUrl != null && !item.isText) ||
          ((item.musicArtUrl ?? '').isNotEmpty);
      if (needsLoad) {
        setState(() => _loading = true);
        final ready = await _prepareStill(item);
        if (!mounted || gen != _gen) return;
        final hasArt = (item.musicArtUrl ?? '').startsWith('http');
        if (!ready && hasArt && (item.isSticker || item.isMusic)) {
          // Slow GIF: keep the spinner and the bar at zero; the image's first
          // painted frame starts the timer (see _artImage). Hard cap so a
          // dead link can't hold the viewer forever.
          _awaitArt = true;
          setState(() {});
          Future.delayed(const Duration(seconds: 20), () => _artReady(gen));
          _prefetchNext();
          return;
        }
        _loading = false;
        // A GIF / sticker: show it from frame 0 and start the bar on its
        // first painted frame, so bar and animation run together.
        final art = item.musicArtUrl;
        if ((item.isSticker || item.isMusic) &&
            art != null &&
            AnimArt.loopOf(art) != null) {
          _artProvider = AnimArt.freshImage(art);
          if (_artProvider != null) {
            _awaitArt = true;
            setState(() {});
            Future.delayed(const Duration(seconds: 4), () => _artReady(gen));
            _prefetchNext();
            return;
          }
        }
      }
      _syncToArt(item);
      _barTick = _progress;
      if (!_paused) _progress.forward(from: 0);
      setState(() {});
    }
    _prefetchNext();
  }

  /// A GIF / sticker (or animated song art) runs the status for whole loops
  /// of its animation — the bar finishes with the GIF, not mid-way.
  void _syncToArt(StoryItem item) {
    if (!(item.isSticker || item.isMusic)) return;
    final art = item.musicArtUrl;
    if (art == null || !art.startsWith('http')) return;
    _progress.duration = AnimArt.storyLength(AnimArt.loopOf(art));
  }

  /// While this status plays, quietly download the next one's photo and warm
  /// upcoming stickers / song art, so the following taps usually open
  /// instantly (videos stream; text needs none).
  void _prefetchNext() {
    StoryItem? next;
    if (_s < _group.stories.length - 1) {
      next = _group.stories[_s + 1];
    } else if (_g < widget.groups.length - 1) {
      final g = widget.groups[_g + 1];
      if (g.stories.isNotEmpty) next = g.stories[_firstUnseen(g)];
    }
    // Stickers and song art: warm every one left in this person's statuses
    // plus the next one, so GIFs are usually decoded before they're reached
    // (the image cache drops duplicates).
    final warm = <StoryItem>[
      for (var i = _s + 1; i < _group.stories.length; i++) _group.stories[i],
      ?next,
    ];
    for (final it in warm) {
      final art = it.musicArtUrl;
      if (art != null && art.startsWith('http') && mounted) {
        // Bytes once (also tells us the GIF's loop length), then decode.
        AnimArt.load(art).then((b) {
          if (!mounted) return;
          precacheImage(b != null ? MemoryImage(b) : NetworkImage(art),
                  context)
              .ignore();
        }).ignore();
      }
    }
    // Photos go through the on-device cache (native only).
    if (kIsWeb || next == null || !next.isPhoto || next.mediaUrl == null) {
      return;
    }
    final url = _absUrl(next.mediaUrl!);
    MediaStore.instance.getFile(url, mediaAuthHeaders(url)).ignore();
  }

  /// Downloads (cache-first) and decodes the image a still status shows.
  /// Never throws; gives up after a timeout so a dead link can't stall the
  /// viewer (the content then falls back to its normal loading/error view).
  Future<bool> _prepareStill(StoryItem item) async {
    try {
      if (item.mediaUrl != null && !item.isMusic && !item.isSticker) {
        final url = _absUrl(item.mediaUrl!);
        final headers = mediaAuthHeaders(url);
        if (!kIsWeb) {
          final f = await MediaStore.instance
              .getFile(url, headers)
              .timeout(const Duration(seconds: 20));
          if (f != null) {
            if (!mounted) return false;
            await precacheImage(FileImage(f), context);
            _photoFile = f;
            return true;
          }
        }
        if (!mounted) return false;
        await precacheImage(authNetworkImageProvider(url, headers), context)
            .timeout(const Duration(seconds: 20));
        return true;
      }
      final art = item.musicArtUrl;
      if (art != null && art.isNotEmpty) {
        if (!mounted) return false;
        // Stickers are often multi-MB GIFs — allow them as long as a video.
        // Fetch the bytes ourselves (shared with the on-screen image) so the
        // GIF's own loop length can drive the timer.
        final b = await AnimArt.load(art);
        if (!mounted) return false;
        await precacheImage(b != null ? MemoryImage(b) : NetworkImage(art),
                context)
            .timeout(const Duration(seconds: 25));
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Starts the timer for a status that was waiting on its sticker / art.
  void _artReady(int gen) {
    if (!mounted || gen != _gen || !_awaitArt) return;
    _awaitArt = false;
    _loading = false;
    _syncToArt(_story);
    _barTick = _progress;
    if (!_paused) _progress.forward(from: 0);
    setState(() {});
  }

  /// Sticker / song art that reports its first painted frame, so a status
  /// still waiting on it ([_awaitArt]) starts its timer exactly then.
  /// The GIF also freezes while the status is paused (hold / Space), so it
  /// never drifts ahead of the bar.
  Widget _artImage(String art) => TickerMode(
        enabled: !_paused,
        child: Image(
          // Same bytes the timer measured (falls back to the network).
          image: _artProvider ??
              (AnimArt.bytesOf(art) != null
                  ? MemoryImage(AnimArt.bytesOf(art)!)
                  : NetworkImage(art)),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          frameBuilder: (ctx, child, frame, sync) {
            if (frame != null && _awaitArt) {
              final g = _gen;
              WidgetsBinding.instance
                  .addPostFrameCallback((_) => _artReady(g));
            }
            return child;
          },
        ),
      );

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
    if (_songOn) _song?.pause();
    if (mounted) setState(() {}); // freeze the GIF too
  }

  void _resume() {
    if (!_paused || _overlayOpen) return;
    _paused = false;
    if (mounted) setState(() {}); // GIF resumes with the bar
    // Still loading / waiting for the GIF's first frame: that starts the
    // timer when it's ready.
    if (_loading || _awaitArt) return;
    if (_video != null) {
      _video!.play();
    } else {
      _progress.forward();
    }
    if (_songOn) _song?.play();
  }

  // ── Song moment: a photo / text status with a song under it ───────────────
  ja.AudioPlayer? _song;
  bool _songOn = false;
  bool _songMuted = false;
  static const Duration _songMoment = Duration(seconds: 15);

  void _stopSong() {
    if (!_songOn) return;
    _songOn = false;
    _song?.stop();
  }

  /// Start the status's song at its moment; the status lasts as long as it.
  Future<void> _playSong(StoryItem item, int gen) async {
    final rel = item.songUrl;
    if (rel == null || rel.isEmpty) return;
    _progress.duration = _songMoment;
    final url = _absUrl(rel);
    final headers = mediaAuthHeaders(url);
    // Web <audio> can't send headers: the token rides as ?token= instead.
    var uri = Uri.parse(url);
    var hdrs = headers;
    if (kIsWeb) {
      final auth = headers['Authorization'] ?? '';
      final tok = auth.startsWith('Bearer ') ? auth.substring(7).trim() : '';
      if (tok.isNotEmpty) {
        uri = Uri.parse('$url${url.contains('?') ? '&' : '?'}'
            'token=${Uri.encodeQueryComponent(tok)}');
      }
      hdrs = const {};
    }
    try {
      final p = _song ??= ja.AudioPlayer();
      await p.setVolume(_songMuted ? 0 : 1);
      await p.setAudioSource(ja.AudioSource.uri(uri, headers: hdrs));
      if (!mounted || gen != _gen) return;
      if (item.songStartMs > 0) {
        await p.seek(Duration(milliseconds: item.songStartMs));
      }
      if (!mounted || gen != _gen) return;
      _songOn = true;
      if (mounted) setState(() {}); // the pill's record starts spinning
      // Never await play(): its future completes when the clip ENDS.
      if (!_paused) p.play();
    } catch (_) {}
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
    // ‹ › arrows between this person's statuses — only when they posted more
    // than one, and only toward a status that exists. (← → / Space / Esc
    // work on a keyboard too.)
    final many = _group.stories.length > 1;
    final canPrev = many && _s > 0;
    final canNext = many && _s < _group.stories.length - 1;
    final wide = MediaQuery.sizeOf(context).width >= 700;
    // Room for the people rail (and it's worth it: someone else posted too).
    final rail = MediaQuery.sizeOf(context).width >= 1100 &&
        widget.groups.length > 1;
    Widget arrow(IconData icon, String tip, VoidCallback onTap) => Tooltip(
          message: tip,
          child: Material(
            color: Colors.black.withValues(alpha: 0.38),
            shape: CircleBorder(
                side: BorderSide(color: Colors.white.withValues(alpha: 0.22))),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Padding(
                padding: EdgeInsets.all(wide ? 10 : 6),
                child: Icon(icon, color: Colors.white, size: wide ? 30 : 24),
              ),
            ),
          ),
        );
    // Typing-safe: while the reply box has focus, Space / arrows type and
    // move the cursor instead of pausing / skipping the story.
    return TypingSafeShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowRight): _next,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): _prev,
        const SingleActivator(LogicalKeyboardKey.escape): () {
          // Esc in the reply box just leaves the box; otherwise closes.
          if (_replyFocus.hasFocus || isTypingInTextField()) {
            FocusManager.instance.primaryFocus?.unfocus();
          } else {
            _close();
          }
        },
        const SingleActivator(LogicalKeyboardKey.space): () {
          _paused ? _resume() : _pause();
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
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
            if (_loading)
              const Center(
                child: SizedBox(
                  width: 34,
                  height: 34,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2.6),
                ),
              ),
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
                  if ((item.songTitle ?? '').trim().isNotEmpty)
                    _songPill(item),
                  // Paused (holding, typing, a picker open): say so.
                  AnimatedOpacity(
                    opacity: _paused && !_loading ? 1 : 0,
                    duration: Motion.quick,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(Radii.lg),
                        ),
                        child: const Text('⏸  Paused',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                  const Spacer(),
                  // Text stories already show the caption as the full-screen
                  // content, so skip the bottom caption bar for them.
                  if (!item.isText && (item.caption ?? '').isNotEmpty)
                    _captionBar(item),
                  // (Mine too: the song chip; the rest are for friends.)
                  _storyActions(item),
                  if (_group.isMe) _authorFooter(item) else _replyBar(),
                  const SizedBox(height: 12),
                ],
              ),
            ),
            if (canPrev)
              Positioned(
                left: wide ? 16 : 6,
                top: 0,
                bottom: 0,
                child: Center(
                    child: arrow(Icons.chevron_left_rounded, 'Previous status',
                        _prev)),
              ),
            if (canNext)
              Positioned(
                right: rail ? 250 : (wide ? 16 : 6),
                top: 0,
                bottom: 0,
                child: Center(
                    child: arrow(Icons.chevron_right_rounded, 'Next status', _next)),
              ),
            if (rail)
              Positioned(right: 0, top: 0, bottom: 0, child: _upNextRail()),
            // Reactions floating up, and an occasion's confetti.
            for (final f in _floaters)
              Positioned.fill(
                child: IgnorePointer(
                  child: RisingReaction(
                    key: ValueKey('fx${f.key}'),
                    emoji: f.emoji,
                    x: f.x,
                    size: f.size,
                    delay: Duration(milliseconds: f.delayMs),
                    onDone: () {
                      if (mounted) {
                        setState(() => _floaters.removeWhere((e) => e.key == f.key));
                      }
                    },
                  ),
                ),
              ),
            if (_confetti)
              Positioned.fill(
                child: IgnorePointer(
                  child: ConfettiBurst(
                    colors: [
                      Theme.of(context).colorScheme.primary,
                      const Color(0xFFFFD166),
                      const Color(0xFFFF8AA0),
                      const Color(0xFF7BDFF2),
                      Colors.white,
                    ],
                    onDone: () {
                      if (mounted) setState(() => _confetti = false);
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
        ),
      ),
    );
  }

  Widget _content(StoryItem item) {
    if (item.isText) return _textContent(item);
    if (item.isSticker) return _stickerContent(item);
    if (item.isMusic) return _musicContent(item);
    if (item.isVideo) {
      final v = _video;
      if (v != null && v.value.isInitialized) {
        return Stack(fit: StackFit.expand, children: [
          _ambient(_thumbOf(item)),
          Center(
            child: AspectRatio(
              aspectRatio:
                  v.value.aspectRatio == 0 ? 9 / 16 : v.value.aspectRatio,
              child: VideoPlayer(v),
            ),
          ),
        ]);
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
      if (_loading) return const SizedBox.shrink(); // the spinner covers it
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    // Photo — cache-first: show the on-device copy (from prefetch or a prior
    // view) instantly and offline; otherwise fetch (and cache) from the network.
    if (item.mediaUrl != null) {
      final url = _absUrl(item.mediaUrl!);
      final headers = mediaAuthHeaders(url);
      if (_loading) return const SizedBox.shrink(); // the spinner covers it
      final ready = _photoFile;
      if (ready != null) {
        final img = FileImage(ready);
        return Stack(fit: StackFit.expand, children: [
          _ambient(img),
          Center(child: Image(image: img, fit: BoxFit.contain)),
        ]);
      }
      if (kIsWeb) {
        return Stack(fit: StackFit.expand, children: [
          _ambient(authNetworkImageProvider(url, headers)),
          Center(
            child: authNetworkImage(
                url: url, headers: headers, fit: BoxFit.contain),
          ),
        ]);
      }
      if (_photoFutureFor != url) {
        _photoFutureFor = url;
        _photoFuture = MediaStore.instance.getFile(url, headers);
      }
      return FutureBuilder<File?>(
        future: _photoFuture,
        builder: (ctx, snap) {
          final f = snap.data;
          return Stack(fit: StackFit.expand, children: [
            _ambient(f != null
                ? FileImage(f)
                : authNetworkImageProvider(url, headers)),
            Center(
              child: f != null
                  ? Image.file(f, fit: BoxFit.contain)
                  : authNetworkImage(
                      url: url, headers: headers, fit: BoxFit.contain),
            ),
          ]);
        },
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

  /// Legible foreground "ink" for a stored background ("hex1,hex2" or "#hex"):
  /// near-black on light backgrounds (warm white / cream), white on dark ones.
  Color _inkFor(String? bg) {
    final cs = <Color>[];
    if (bg != null) {
      for (final part in bg.split(',')) {
        final c = _parseHex(part.trim());
        if (c != null) cs.add(c);
      }
    }
    if (cs.isEmpty) return Colors.white;
    final l = cs.map((c) => c.computeLuminance()).reduce((a, b) => a + b) /
        cs.length;
    return l > 0.55 ? const Color(0xFF15171C) : Colors.white;
  }

  Widget _textContent(StoryItem item) {
    final ink = _inkFor(item.background);
    final text = item.caption ?? '';
    final n = text.trim().length;
    // Auto-fit to match the composer: short = big & bold, long = smaller.
    final fontSize = n <= 24
        ? 36.0
        : n <= 60
            ? 30.0
            : n <= 140
                ? 24.0
                : 19.0;
    final onDark = ink == Colors.white;
    return Container(
      decoration: _bgDecoration(
          item.background, const [Color(0xFF5B2C83), Color(0xFF1D1040)]),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(28),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: ink,
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          height: 1.25,
          shadows: [
            Shadow(
              color:
                  (onDark ? Colors.black : Colors.white).withValues(alpha: 0.26),
              blurRadius: Depth.md,
            ),
          ],
        ),
      ),
    );
  }

  /// A GIF / sticker status: the animated art fills the screen over the
  /// chosen colour background, with an optional caption beneath it.
  Widget _stickerContent(StoryItem item) {
    final art = item.musicArtUrl;
    final hasArt = art != null && art.startsWith('http');
    final ink = _inkFor(item.background);
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: _bgDecoration(
              item.background, const [Color(0xFF2B2140), Color(0xFF120A20)]),
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 260,
                height: 260,
                child: hasArt
                    ? _artImage(art)
                    : Icon(Icons.gif_box_rounded, color: ink, size: 96),
              ),
              if ((item.caption ?? '').isNotEmpty) ...[
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    item.caption!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: ink,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _musicContent(StoryItem item) {
    final art = item.musicArtUrl;
    final hasArt = art != null && art.startsWith('http');
    final ink = _inkFor(item.background);
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
                    ? _artImage(art)
                    : Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(Radii.xl),
                          color: ink.withValues(alpha: 0.12),
                        ),
                        child: Icon(Icons.music_note_rounded,
                            color: ink, size: 72),
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
                  style: TextStyle(
                      color: ink,
                      fontSize: 20,
                      fontWeight: FontWeight.bold),
                ),
              ),
              if ((item.musicArtist ?? '').isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  item.musicArtist!,
                  style: TextStyle(
                      color: ink.withValues(alpha: 0.8), fontSize: 15),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.graphic_eq_rounded,
                      color: ink.withValues(alpha: 0.7), size: 18),
                  const SizedBox(width: 6),
                  Text('Now playing',
                      style: TextStyle(
                          color: ink.withValues(alpha: 0.7),
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
          // Same photo as the status bubble I tapped: it flies here on open
          // and back to the bubble of whoever I'm on when I close.
          Hero(
            tag: storyHeroTag(_group.authorId),
            child: CircleAvatar(
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
                    // My own status: how long it has left.
                    _group.isMe && _story.expiresAt != null
                        ? '${_ago(when)} · ${_left(_story.expiresAt!)}'
                        : _postedLine(when, _story.expiresAt),
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

  /// Nudge a silent viewer: an emoji or sticker straight to their DM,
  /// quoting the status they watched — so the poster can start the
  /// conversation instead of waiting for a comment.
  Future<bool> _nudgeViewer(StoryViewer v, StoryItem item,
      {String? emoji, String? gifUrl}) async {
    // The DM shows it as a quote: a warm "caught you" + which status.
    final content = '> 👀 Caught you on my status\n> ${_statusQuote(item)}'
        '\n\n${emoji ?? ''}';
    final sent = gifUrl != null
        ? await ApiService().sendMessage(v.userId, content,
            messageType: 'image',
            mediaUrl: gifUrl,
            mediaName: 'sticker.gif',
            mediaMime: 'image/gif')
        : await ApiService().sendMessage(v.userId, content);
    return sent != null;
  }

  Future<String?> _pickSticker(BuildContext ctx) => showAdaptiveSheet<String>(
        context: ctx,
        isScrollControlled: true,
        backgroundColor: const Color(0xFF1B1B1F),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl)),
        ),
        builder: (sctx) => SafeArea(
          child: SizedBox(
            height: MediaQuery.of(sctx).size.height * 0.6,
            child: GifPicker(
              onSelected: (gif) => Navigator.pop(sctx, gif.fullUrl),
            ),
          ),
        ),
      );

  Future<void> _showViewers(StoryItem item) async {
    _pause();
    final raw = await ApiService().fetchStoryViewers(item.id);
    if (!mounted) return;
    final viewers = raw
        .map(StoryViewer.fromJson)
        .where((v) => v.userId != widget.myUserId)
        .toList();
    // My person first, with a 💞 — the view that matters most.
    bool mine(StoryViewer v) => (StoryHooks.closeness?.call(v.userId) ?? 0) == 2;
    viewers.sort((a, b) => (mine(b) ? 1 : 0) - (mine(a) ? 1 : 0));
    // Per viewer: null = idle, '…' = sending, else what was sent. One nudge
    // per viewer per status — remembered on this device, so nobody gets a
    // second wave for the same status.
    final sentTo = <int, String>{};
    final prefKey = 'story_nudged_v1_${item.id}';
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      for (final e in prefs.getStringList(prefKey) ?? const <String>[]) {
        final i = e.indexOf(':');
        if (i > 0) sentTo[int.tryParse(e.substring(0, i)) ?? -1] = e.substring(i + 1);
      }
    } catch (_) {}
    if (!mounted) return;
    void remember() {
      try {
        prefs?.setStringList(prefKey, [
          for (final e in sentTo.entries)
            if (e.value != '…') '${e.key}:${e.value}'
        ]);
      } catch (_) {}
    }
    // Nudges that fit what they watched.
    final nudges = switch (item.kind) {
      'music' => const ['🎧', '🎶', '❤️', '👋'],
      'text' => const ['🤗', '❤️', '💭', '👋', '🙏'],
      'video' => const ['😂', '🔥', '😮', '❤️', '👋'],
      'sticker' => const ['😂', '😉', '❤️', '👋'],
      _ => const ['😍', '❤️', '😊', '🔥', '👋'],
    };
    await showAdaptiveSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: const Color(0xFF1B1B1F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl)),
      ),
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSheet) {
          Future<void> send(StoryViewer v,
              {String? emoji, String? gifUrl}) async {
            setSheet(() => sentTo[v.userId] = '…');
            final ok =
                await _nudgeViewer(v, item, emoji: emoji, gifUrl: gifUrl);
            if (!ctx.mounted) return;
            setSheet(() {
              if (ok) {
                sentTo[v.userId] = emoji ?? 'sticker';
              } else {
                sentTo.remove(v.userId);
              }
            });
            if (ok) remember();
            if (!ok) {
              showToast(ctx, 'Couldn’t send — check your connection',
                  type: ToastType.error);
            }
          }

          // Who's here right now: they're the ones a nudge reaches warm
          // (a reply comes soon) — they lead the list, lit green.
          return Consumer(builder: (ctx, ref, _) {
          final presence = ref.watch(presenceProvider);
          final shown = [...viewers]..sort((a, b) {
              final oa = presence.isOnline(a.userId) ? 0 : 1;
              final ob = presence.isOnline(b.userId) ? 0 : 1;
              return oa.compareTo(ob);
            });
          final onlineN =
              viewers.where((v) => presence.isOnline(v.userId)).length;
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.7),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
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
                              if (viewers.isNotEmpty)
                                Text(
                                    onlineN > 0
                                        ? '$onlineN online now — nudge them while they’re here'
                                        : 'No one’s online right now — a nudge waits in your DM',
                                    style: TextStyle(
                                        color: onlineN > 0
                                            ? const Color(0xFF7BE0A0)
                                            : Colors.white
                                                .withValues(alpha: 0.6),
                                        fontSize: 12)),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          icon: const Icon(Icons.close_rounded,
                              color: Colors.white70),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 12),
                      itemCount: shown.length,
                      itemBuilder: (_, i) {
                        final v = shown[i];
                        final on = presence.isOnline(v.userId);
                        final av = (v.avatarUrl ?? '').isNotEmpty
                            ? _absUrl(v.avatarUrl!)
                            : null;
                        final name = _viewerName(v);
                        final state = sentTo[v.userId];
                        final when = v.viewedAt;
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 4),
                          child: Row(
                            children: [
                              Stack(clipBehavior: Clip.none, children: [
                                CircleAvatar(
                                  radius: 20,
                                  backgroundColor: Colors.white24,
                                  backgroundImage: av != null
                                      ? authNetworkImageProvider(
                                          av, mediaAuthHeaders(av))
                                      : null,
                                  child: av == null
                                      ? Text(
                                          name.isNotEmpty
                                              ? name[0].toUpperCase()
                                              : '?',
                                          style: const TextStyle(
                                              color: Colors.white))
                                      : null,
                                ),
                                if (on)
                                  Positioned(
                                    right: -1,
                                    bottom: -1,
                                    child: Container(
                                      width: 12,
                                      height: 12,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF22C55E),
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                            color: const Color(0xFF1C1B1F),
                                            width: 2),
                                      ),
                                    ),
                                  ),
                              ]),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                        '${mine(v) ? '💞 ' : ''}'
                                        '${(v.reaction ?? '').isEmpty ? name : '$name  ${v.reaction}'}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w600)),
                                    if (on || when != null)
                                      Text(
                                          [
                                            if (on) 'online now',
                                            if (when != null)
                                              'viewed ${_ago(when)}',
                                          ].join(' · '),
                                          style: TextStyle(
                                              color: on
                                                  ? const Color(0xFF7BE0A0)
                                                  : Colors.white
                                                      .withValues(alpha: 0.55),
                                              fontSize: 11.5)),
                                  ],
                                ),
                              ),
                              // The nudge strip: tap an emoji, or ✨ for a
                              // sticker. Once sent, it shows what went.
                              AnimatedSwitcher(
                                duration: Motion.standard,
                                child: state == null
                                    ? Opacity(
                                        key: const ValueKey('nudge'),
                                        // Offline → still possible, just
                                        // quieter: it waits in the DM.
                                        opacity: on ? 1 : 0.55,
                                        child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 4, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.white
                                              .withValues(alpha: 0.07),
                                          borderRadius:
                                              BorderRadius.circular(Radii.xl),
                                          border: Border.all(
                                              color: Colors.white
                                                  .withValues(alpha: 0.12)),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            for (final e in nudges)
                                              InkResponse(
                                                radius: 18,
                                                // On a music status 🎧 asks
                                                // them to listen together.
                                                onTap: () => send(v,
                                                    emoji: e == '🎧'
                                                        ? '🎧 Listen together?'
                                                        : e),
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.all(4),
                                                  child: Text(e,
                                                      style: const TextStyle(
                                                          fontSize: 19)),
                                                ),
                                              ),
                                            IconButton(
                                              tooltip: 'Send a sticker',
                                              visualDensity:
                                                  VisualDensity.compact,
                                              icon: const Icon(
                                                  Icons.gif_box_outlined,
                                                  color: Colors.white70,
                                                  size: 20),
                                              onPressed: () async {
                                                final url =
                                                    await _pickSticker(ctx);
                                                if (url != null &&
                                                    url.isNotEmpty) {
                                                  await send(v, gifUrl: url);
                                                }
                                              },
                                            ),
                                          ],
                                        ),
                                      ))
                                    : Row(
                                        key: ValueKey('sent-$state'),
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (state == '…')
                                            const SizedBox(
                                                width: 16,
                                                height: 16,
                                                child:
                                                    CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color: Colors.white70))
                                          else ...[
                                            Text(
                                                state == 'sticker'
                                                    ? '✨'
                                                    : state.characters.first,
                                                style: const TextStyle(
                                                    fontSize: 16)),
                                            const SizedBox(width: 6),
                                            Text('Sent',
                                                style: TextStyle(
                                                    color: Colors.white
                                                        .withValues(
                                                            alpha: 0.75),
                                                    fontWeight:
                                                        FontWeight.w600)),
                                            const SizedBox(width: 2),
                                            Icon(Icons.check_rounded,
                                                size: 16,
                                                color: Colors.white
                                                    .withValues(alpha: 0.75)),
                                          ],
                                        ],
                                      ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
          });
        });
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

  /// "5h left" / "40m left" for my own status.
  /// A friend's status: "Posted 7:12 AM · fades in 19h".
  String _postedLine(DateTime when, DateTime? expires) {
    final at = MaterialLocalizations.of(context)
        .formatTimeOfDay(TimeOfDay.fromDateTime(when.toLocal()));
    final today = DateUtils.isSameDay(when.toLocal(), DateTime.now());
    final head = today ? 'Posted $at' : 'Posted yesterday, $at';
    if (expires == null) return head;
    final d = expires.difference(DateTime.now());
    if (d.isNegative) return head;
    final left = d.inMinutes < 60 ? '${d.inMinutes}m' : '${d.inHours}h';
    return '$head · fades in $left';
  }

  String _left(DateTime expires) {
    final d = expires.difference(DateTime.now());
    if (d.inMinutes < 1) return 'ending';
    if (d.inMinutes < 60) return '${d.inMinutes}m left';
    return '${d.inHours}h left';
  }

  /// A friend's status, made actionable (Aluta, not a picture):
  ///  • music → 🎧 Tune in (they're playing now) and ▶ Play on mine;
  ///  • my bonded partner → 💞 Keep (pins it in our Space before it fades).
  Widget _storyActions(StoryItem item) {
    final author = _group.authorId;
    final name = _displayName();
    final title = (item.musicTitle ?? '').trim();
    final music = item.isMusic && title.isNotEmpty;
    final mine = _group.isMe;
    final live = !mine &&
        music &&
        (StoryHooks.isPlayingNow?.call(author) ?? false);
    final bonded = !mine && (StoryHooks.isBonded?.call(author) ?? false);
    final keepable = item.isMusic ||
        item.isSticker ||
        ((item.isPhoto || item.isVideo) && item.mediaUrl != null) ||
        (item.isText && (item.caption ?? '').trim().isNotEmpty);
    final occasion = _occasionOf(item);
    final partner = !mine &&
        StoryHooks.myPartner?.call()?.id == author;
    final chips = <Widget>[
      // An occasion in the caption → answer it with a song (and confetti).
      if (!mine && occasion != null && StoryHooks.answerWithSong != null)
        _actionChip(
            switch (occasion) {
              'birthday' => '🎂',
              'anniversary' => '💍',
              'wedding' => '💒',
              _ => '🎓',
            },
            switch (occasion) {
              'birthday' => 'Send a birthday song',
              'anniversary' => 'Send an anniversary song',
              'wedding' => 'Bless them with a song',
              _ => 'Celebrate with a song',
            }, () async {
          _pause();
          setState(() => _confetti = true);
          await StoryHooks.answerWithSong!(context, author, name,
              occasion == 'birthday' ? 'your birthday 🎂' : _statusLabel(item));
          if (mounted) _resume();
        }),
      if (live && StoryHooks.tuneIn != null)
        _actionChip('🎧', 'Tune in', () {
          _pause();
          StoryHooks.tuneIn!(context, author, name, title);
        }),
      // Not on web: its player has no loaded-file paths to match.
      if (!mine && music && StoryHooks.playOnMine != null && !kIsWeb)
        _actionChip('▶', 'Play on mine', () {
          final ok = StoryHooks.playOnMine!(title);
          showToast(
              context,
              ok
                  ? 'Playing “$title” 🎶'
                  : '“$title” isn’t in your loaded songs yet',
              type: ok ? ToastType.success : ToastType.info);
        }),
      // A music status → listen to it together, in sync.
      if (music && StoryHooks.listenTogether != null && !_group.isMe)
        _actionChip('🎧', 'Listen together', () {
          _pause();
          StoryHooks.listenTogether!(context, author, title);
        }),
      // Answer any status with a song ("this reminds me of…").
      if (!_group.isMe && occasion == null && StoryHooks.answerWithSong != null)
        _actionChip('🎵', 'Answer with a song', () async {
          _pause();
          await StoryHooks.answerWithSong!(
              context, author, name, _statusLabel(item));
          if (mounted) _resume();
        }),
      // My person's photo → send my half back for a duo.
      if (partner && item.isPhoto && item.mediaUrl != null)
        _actionChip('📸', _duoBusy ? 'Sending…' : 'Start a duo',
            () => _startDuo(item)),
      if (bonded && keepable)
        _actionChip('💞', partner ? 'Add to our moments' : 'Keep', () async {
          _pause();
          final err = await ApiService().keepStoryInSpace(item.id);
          if (!mounted) return;
          if (err == null) _floatUp('💞');
          showToast(
              context,
              err ??
                  (partner
                      ? 'Added to your moments together 💞'
                      : 'Kept in your Space 💞'),
              type: err == null ? ToastType.success : ToastType.error);
          Future.delayed(const Duration(milliseconds: 900), () {
            if (mounted) _resume();
          });
        }),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 6,
        children: chips,
      ),
    );
  }

  /// "📷 your photo status" / "🎵 your “Song” status" — what a song answers.
  String _statusLabel(StoryItem item) {
    if (item.isMusic) return 'your “${item.musicTitle ?? 'song'}” status';
    if (item.isVideo) return 'your video status';
    if (item.isText) {
      final t = (item.caption ?? '').trim();
      return t.isEmpty
          ? 'your status'
          : 'your status “${t.length > 40 ? '${t.substring(0, 39)}…' : t}”';
    }
    return 'your photo status';
  }

  Widget _actionChip(String emoji, String label, VoidCallback onTap) {
    return Material(
      color: Colors.white.withValues(alpha: 0.16),
      shape: StadiumBorder(
          side: BorderSide(color: Colors.white.withValues(alpha: 0.28))),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: () {
          Haptics.selectionClick();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text('$emoji  $label',
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5)),
        ),
      ),
    );
  }

  // ── Moments: reactions you see, occasions, the song, duo, up next ────────

  void _floatUp(String emoji) {
    final r = math.Random();
    setState(() {
      for (var i = 0; i < 3; i++) {
        _floaters.add((
          key: ++_fxKey,
          emoji: emoji,
          x: 0.5 + (r.nextDouble() - 0.5) * 0.3,
          size: i == 0 ? 52.0 : 30.0 + r.nextDouble() * 8,
          delayMs: i * 140,
        ));
      }
    });
  }

  /// A birthday / anniversary / wedding / graduation in the caption.
  String? _occasionOf(StoryItem item) {
    final c = (item.caption ?? '').toLowerCase();
    if (c.isEmpty) return null;
    if (RegExp(r'birthday|b-?day|siku ya kuzaliwa|kuzaliwa|🎂').hasMatch(c)) {
      return 'birthday';
    }
    if (RegExp(r'anniversary|kumbukumbu ya ndoa|miaka \d+ ya').hasMatch(c)) {
      return 'anniversary';
    }
    if (RegExp(r'wedding|harusi|married|ndoa yetu|💍|💒').hasMatch(c)) {
      return 'wedding';
    }
    if (RegExp(r'graduat|mahafali|🎓').hasMatch(c)) return 'graduation';
    return null;
  }

  String _nameOf(StoryGroup g) {
    final phone = (g.phone ?? '').trim();
    if (phone.isNotEmpty) {
      final saved = ContactNames.instance.nameFor(phone);
      if (saved != null && saved.isNotEmpty) return saved;
    }
    return g.isMe
        ? 'Your story'
        : (g.username.isNotEmpty ? g.username : 'Friend');
  }

  void _jumpToGroup(int i) {
    if (i == _g || i < 0 || i >= widget.groups.length) return;
    Haptics.selectionClick();
    setState(() {
      _g = i;
      _s = _firstUnseen(widget.groups[i]);
    });
    _startStory();
  }

  /// The status itself, softly blurred to fill the screen behind it — so a
  /// portrait photo on a wide window sits in its own colours, not black bars.
  Widget _ambient(ImageProvider? p) {
    if (p == null) return const SizedBox.shrink();
    return Positioned.fill(
      child: RepaintBoundary(
        child: Stack(fit: StackFit.expand, children: [
          ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 40, sigmaY: 40),
            child: Image(image: p, fit: BoxFit.cover, gaplessPlayback: true),
          ),
          ColoredBox(color: Colors.black.withValues(alpha: 0.5)),
        ]),
      ),
    );
  }

  ImageProvider? _thumbOf(StoryItem item) {
    final t = item.thumb;
    if (t == null || !t.startsWith('data:')) return null;
    try {
      return MemoryImage(UriData.parse(t).contentAsBytes());
    } catch (_) {
      return null;
    }
  }

  /// The status's song as a small player under the name: a record that
  /// spins while it plays, the title, mute — tap for Listen together.
  Widget _songPill(StoryItem item) {
    final title = (item.songTitle ?? '').trim();
    final scheme = Theme.of(context).colorScheme;
    final playing = _songOn && !_paused && !_songMuted;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (_) {},
      onLongPressStart: (_) {},
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Material(
            color: Colors.black.withValues(alpha: 0.42),
            shape: StadiumBorder(
                side: BorderSide(color: Colors.white.withValues(alpha: 0.22))),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () => _songMenu(item),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 5, 4, 5),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  SpinningDisc(
                      spinning: playing, size: 28, accent: scheme.primary),
                  const SizedBox(width: 9),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 240),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 13)),
                        Text(
                            _songMuted
                                ? 'Muted · tap for more'
                                : _group.isMe
                                    ? 'Your song moment'
                                    : 'Their song moment · tap for more',
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                                fontSize: 11)),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: _songMuted ? 'Unmute' : 'Mute',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                        _songMuted
                            ? Icons.volume_off_rounded
                            : Icons.volume_up_rounded,
                        color: Colors.white,
                        size: 20),
                    onPressed: () {
                      Haptics.selectionClick();
                      setState(() => _songMuted = !_songMuted);
                      _song?.setVolume(_songMuted ? 0 : 1);
                    },
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _songMenu(StoryItem item) async {
    final title = (item.songTitle ?? '').trim();
    final author = _group.authorId;
    final mine = _group.isMe;
    _pause();
    _overlayOpen = true;
    final pick = await showAdaptiveSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1B1B1F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl)),
      ),
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: SpinningDisc(
                spinning: false,
                size: 34,
                accent: Theme.of(c).colorScheme.primary),
            title: Text(title,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w800)),
            subtitle: Text('A song moment from ${_displayName()}',
                style: const TextStyle(color: Colors.white60)),
          ),
          const Divider(color: Colors.white12, height: 1),
          if (!mine && StoryHooks.listenTogether != null)
            ListTile(
              leading: const Icon(Icons.headphones_rounded, color: Colors.white),
              title: const Text('Listen together',
                  style: TextStyle(color: Colors.white)),
              subtitle: const Text('The whole song, in sync, in your chat',
                  style: TextStyle(color: Colors.white60)),
              onTap: () => Navigator.pop(c, 'together'),
            ),
          if (StoryHooks.playOnMine != null && !kIsWeb)
            ListTile(
              leading: const Icon(Icons.play_circle_rounded, color: Colors.white),
              title: const Text('Play the whole song on mine',
                  style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(c, 'mine'),
            ),
          ListTile(
            leading: Icon(
                _songMuted ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                color: Colors.white),
            title: Text(_songMuted ? 'Unmute' : 'Mute',
                style: const TextStyle(color: Colors.white)),
            onTap: () => Navigator.pop(c, 'mute'),
          ),
          const SizedBox(height: 6),
        ]),
      ),
    );
    _overlayOpen = false;
    if (!mounted) return;
    switch (pick) {
      case 'together':
        StoryHooks.listenTogether!(context, author, title);
        return; // the chat takes over; the status stays paused
      case 'mine':
        final ok = StoryHooks.playOnMine!(title);
        showToast(
            context,
            ok
                ? 'Playing “$title” 🎶'
                : '“$title” isn’t in your loaded songs yet',
            type: ok ? ToastType.success : ToastType.info);
      case 'mute':
        setState(() => _songMuted = !_songMuted);
        _song?.setVolume(_songMuted ? 0 : 1);
    }
    _resume();
  }

  /// My person's photo status → send my half back; it becomes a duo when
  /// they add it (the same "Add your half" flow as a duo from Create).
  Future<void> _startDuo(StoryItem item) async {
    if (_duoBusy) return;
    final partner = StoryHooks.myPartner?.call();
    if (partner == null) return;
    _pause();
    _overlayOpen = true;
    XFile? x;
    try {
      x = await ImagePicker()
          .pickImage(source: ImageSource.gallery, imageQuality: 88);
    } catch (_) {}
    _overlayOpen = false;
    if (!mounted) return;
    if (x == null) {
      _resume();
      return;
    }
    setState(() => _duoBusy = true);
    final bytes = await x.readAsBytes();
    final mime = x.mimeType ?? 'image/jpeg';
    final up = await ApiService()
        .uploadMedia(bytes: bytes, filename: x.name, mime: mime);
    final sent = up == null || up['url'] == null
        ? null
        : await ApiService().sendMessage(partner.id,
            '> ${_statusQuote(item)}\n\n📸 Duo — add your half 💞',
            messageType: 'image',
            mediaUrl: up['url'].toString(),
            mediaName: (up['name'] ?? x.name).toString(),
            mediaMime: (up['mime'] ?? mime).toString(),
            mediaSize: (up['size'] as num?)?.toInt() ?? bytes.length,
            meta: jsonEncode({'duo': 1}));
    if (!mounted) return;
    setState(() => _duoBusy = false);
    final first = _displayName().split(RegExp(r'\s+')).first;
    if (sent == null) {
      showToast(context, 'Couldn’t send it — try again',
          type: ToastType.error);
    } else {
      _floatUp('💞');
      showToast(context, 'Sent to $first — a duo goes live when they add theirs',
          type: ToastType.success);
    }
    _resume();
  }

  /// Wide windows: everyone else's statuses down the right, rings and all,
  /// so you can move between people without closing.
  Widget _upNextRail() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 220,
      margin: const EdgeInsets.fromLTRB(0, 70, 14, 20),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(Radii.xl),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (_) {},
        onLongPressStart: (_) {},
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text('STATUS',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.4)),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: widget.groups.length,
                itemBuilder: (_, i) {
                  final g = widget.groups[i];
                  final now = i == _g;
                  final unseen = g.stories.where((s) => !s.viewed).length;
                  final av = (g.avatarUrl ?? '').isNotEmpty
                      ? _absUrl(g.avatarUrl!)
                      : null;
                  return InkWell(
                    onTap: () => _jumpToGroup(i),
                    child: Container(
                      color: now
                          ? scheme.primary.withValues(alpha: 0.18)
                          : Colors.transparent,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 7),
                      child: Row(children: [
                        SizedBox(
                          width: 44,
                          height: 44,
                          child: CustomPaint(
                            painter: StoryRingPainter(
                              seen: [for (final s in g.stories) s.viewed],
                              colors: [
                                scheme.primary,
                                const Color(0xFFFF8AA0),
                                scheme.primary
                              ],
                              seenColor: Colors.white24,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: CircleAvatar(
                                backgroundColor: Colors.white12,
                                backgroundImage: av != null
                                    ? authNetworkImageProvider(
                                        av, mediaAuthHeaders(av))
                                    : null,
                                child: av == null
                                    ? Text(_nameOf(g).isEmpty
                                        ? '?'
                                        : _nameOf(g)[0].toUpperCase(),
                                        style: const TextStyle(
                                            color: Colors.white))
                                    : null,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_nameOf(g),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: now || unseen > 0
                                          ? FontWeight.w800
                                          : FontWeight.w500,
                                      fontSize: 13.5)),
                              Text(
                                  now
                                      ? 'Watching now'
                                      : unseen > 0
                                          ? '$unseen new'
                                          : 'Seen',
                                  style: TextStyle(
                                      color: now
                                          ? const Color(0xFFFF8AA0)
                                          : Colors.white54,
                                      fontSize: 11.5)),
                            ],
                          ),
                        ),
                      ]),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}
