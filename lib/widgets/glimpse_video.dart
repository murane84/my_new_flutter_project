import 'dart:async';
import 'dart:io' show File;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../services/media_store.dart';

/// A data-friendly video tile that plays from the DEVICE, never by live
/// streaming. Behaviour:
///
///  * Not on the device yet → a tidy poster placeholder with a play button
///    ("Tap to play") — nothing is downloaded, so scrolling past a video costs
///    nothing.
///  * Tap → downloads the clip once (cached via [MediaStore]) with a
///    "Downloading…" state, then plays it from the local file WITH sound.
///  * Once cached → a real poster frame, and when the tile lingers in view it
///    plays a SILENT glimpse (first ~quarter, looped twice) straight from the
///    device, then settles back to the poster.
///
/// On web (no device cache) it falls back to streaming on tap. Shared by Our
/// Space moments and chat so the experience is identical.
class GlimpseVideo extends StatefulWidget {
  const GlimpseVideo({
    super.key,
    required this.url,
    required this.headers,
    required this.accent,
    this.onFullscreen,
    this.borderRadius = 14,
    this.maxWidth,
    this.maxStageHeight = 300,
    this.aspectRatioFallback = 16 / 10,
    this.durationSecs,
    this.caption,
    this.posterUrl,
  });

  final String url;
  final Map<String, String> headers;
  final Color accent;
  final VoidCallback? onFullscreen;
  final double borderRadius;
  final double? maxWidth;
  // Hard ceiling on the video stage so a tall portrait clip stays a compact
  // bubble instead of a full-height strip.
  final double maxStageHeight;
  final double aspectRatioFallback;
  final int? durationSecs;
  // Optional overlaid caption; fades out while the clip is playing so it never
  // sits as noise over the moving video, and fades back when paused.
  final String? caption;
  // Optional server-generated poster (the true first frame) shown before the
  // clip is on the device and while a cached clip re-initialises on return.
  final String? posterUrl;

  @override
  State<GlimpseVideo> createState() => _GlimpseVideoState();
}

class _GlimpseVideoState extends State<GlimpseVideo> {
  VideoPlayerController? _c;
  File? _file; // local cached copy (native)
  late final Key _visKey = Key('glimpse_${identityHashCode(this)}');
  bool _checkedCache = false;
  bool _initing = false;
  bool _ready = false;
  bool _error = false;
  bool _downloading = false;
  bool _tapped = false; // the user tapped to play with sound
  bool _glimpsing = false;
  int _glimpseLoops = 0;
  bool _lastPlaying = false;
  Duration _posterPos = const Duration(milliseconds: 1200);
  Timer? _dwellTimer;
  double _frac = 0;

  static const double _glimpseFraction = 0.25;
  static const int _maxGlimpseLoops = 2;

  @override
  void initState() {
    super.initState();
    _checkCache();
  }

  @override
  void dispose() {
    _dwellTimer?.cancel();
    final c = _c;
    if (c != null) {
      c.removeListener(_tick);
      c.dispose();
    }
    super.dispose();
  }

  // If the clip is ALREADY on the device, load the poster (+ enable glimpse)
  // from it. Never downloads here — that only happens on an explicit tap.
  Future<void> _checkCache() async {
    if (_checkedCache || kIsWeb) return;
    _checkedCache = true;
    try {
      final f = await MediaStore.instance.cached(widget.url);
      if (f != null && mounted) {
        _file = f;
        await _ensureController();
      }
    } catch (_) {}
  }

  Future<void> _ensureController() async {
    if (_c != null || _initing || _error) return;
    if (!kIsWeb && _file == null) return; // native needs a local file first
    _initing = true;
    final c = (!kIsWeb && _file != null)
        ? VideoPlayerController.file(_file!)
        : VideoPlayerController.networkUrl(
            Uri.parse(widget.url),
            httpHeaders: widget.headers,
          );
    try {
      await c.initialize().timeout(const Duration(seconds: 25));
      if (!mounted) {
        c.dispose();
        return;
      }
      await c.setVolume(0);
      await c.setLooping(false);
      final durMs = c.value.duration.inMilliseconds;
      final posterMs =
          durMs > 0 ? (durMs * 0.1).clamp(300, 2000).round() : 1200;
      _posterPos = Duration(milliseconds: posterMs);
      await c.seekTo(_posterPos);
      c.addListener(_tick);
      if (!mounted) {
        c.dispose();
        return;
      }
      setState(() {
        _c = c;
        _ready = true;
        _initing = false;
      });
      if (_frac >= 0.8 && !_tapped) _maybeStartGlimpse();
    } catch (_) {
      _initing = false;
      try {
        c.dispose();
      } catch (_) {}
      if (mounted) setState(() => _error = true);
    }
  }

  void _tick() {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    if (_glimpsing && c.value.isPlaying) {
      final durMs = c.value.duration.inMilliseconds;
      final quarterMs =
          durMs > 0 ? (durMs * _glimpseFraction).round() : 4000;
      if (c.value.position.inMilliseconds >= quarterMs) {
        _glimpseLoops += 1;
        if (_glimpseLoops >= _maxGlimpseLoops) {
          _stopGlimpse();
        } else {
          c.seekTo(Duration.zero);
        }
      }
    }
    final p = c.value.isPlaying;
    final changed = p != _lastPlaying;
    if (changed) _lastPlaying = p;
    // Repaint for the scrubber + ticking time while the user is watching.
    if (mounted && (changed || _tapped)) setState(() {});
  }

  void _maybeStartGlimpse() {
    if (!_ready ||
        _tapped ||
        _glimpsing ||
        _glimpseLoops >= _maxGlimpseLoops) {
      return;
    }
    final c = _c;
    if (c == null) return;
    _glimpsing = true;
    c.setVolume(0);
    c.seekTo(Duration.zero);
    c.play();
    if (mounted) setState(() {});
  }

  void _stopGlimpse() {
    final c = _c;
    _glimpsing = false;
    if (c != null) {
      c.pause();
      c.seekTo(_posterPos);
    }
    if (mounted) setState(() {});
  }

  void _onVisibility(double frac) {
    _frac = frac;
    // Only ever glimpse something that's already on the device (or web stream
    // that's already initialised). Never kick off a download from scrolling.
    if (frac >= 0.8 &&
        _ready &&
        !_tapped &&
        !_glimpsing &&
        _glimpseLoops < _maxGlimpseLoops) {
      _dwellTimer?.cancel();
      _dwellTimer = Timer(const Duration(milliseconds: 450), () {
        if (mounted && _frac >= 0.8) _maybeStartGlimpse();
      });
    } else if (frac < 0.5) {
      _dwellTimer?.cancel();
      final c = _c;
      if (c != null && c.value.isPlaying) {
        if (!_tapped) {
          _glimpsing = false;
          c.pause();
          c.seekTo(_posterPos);
        } else {
          c.pause();
        }
        if (mounted) setState(() {});
      }
    }
  }

  Future<void> _playWithSound() async {
    final c = _c;
    if (c == null) return;
    _dwellTimer?.cancel();
    if (!_tapped) {
      _tapped = true;
      _glimpsing = false;
      await c.setVolume(1);
      await c.seekTo(Duration.zero);
      await c.play();
    } else if (c.value.isPlaying) {
      await c.pause();
    } else {
      // Replay from the start if we're sitting at the end.
      final pos = c.value.position;
      final dur = c.value.duration;
      if (dur > Duration.zero &&
          pos >= dur - const Duration(milliseconds: 250)) {
        await c.seekTo(Duration.zero);
      }
      await c.play();
    }
    if (mounted) setState(() {});
  }

  Future<void> _onTap() async {
    if (_error) {
      widget.onFullscreen?.call();
      return;
    }
    if (_ready && _c != null) {
      await _playWithSound();
      return;
    }
    if (_downloading || _initing) return;
    // Need to bring it onto the device first (web just streams).
    if (kIsWeb) {
      await _ensureController();
      await _playWithSound();
      return;
    }
    setState(() => _downloading = true);
    try {
      final f = await MediaStore.instance.getFile(widget.url, widget.headers);
      if (!mounted) return;
      if (f == null) {
        setState(() {
          _downloading = false;
          _error = true;
        });
        return;
      }
      _file = f;
      setState(() => _downloading = false);
      await _ensureController();
      await _playWithSound();
    } catch (_) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _error = true;
        });
      }
    }
  }

  String _fmt(Duration d) {
    final s = d.inSeconds;
    final m = s ~/ 60;
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$m:$ss';
  }

  Widget _blob(Color color, double size) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      );

  // Before the clip is ready: show the real poster frame (server thumbnail)
  // over a soft blur base, falling back to the blur alone if there's no poster
  // or it fails to load. This is what shows the TRUE first frame.
  Widget _notReadyBackdrop() {
    final poster = widget.posterUrl ?? '';
    if (poster.isEmpty) return _blurPlaceholder();
    return Stack(
      fit: StackFit.expand,
      children: [
        _blurPlaceholder(),
        Image.network(
          poster,
          headers: widget.headers,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          frameBuilder: (ctx, child, frame, wasSync) =>
              (frame == null && !wasSync)
                  ? const SizedBox.shrink()
                  : child,
        ),
      ],
    );
  }

  // A soft, out-of-focus poster used before a clip is downloaded (and briefly
  // while a cached clip re-initialises on return) — a gentle accent-tinted blur
  // instead of a flat black rectangle.
  Widget _blurPlaceholder() {
    final a = widget.accent;
    const base = Color(0xFF15131B);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(a.withValues(alpha: 0.30), base),
            base,
            Color.alphaBlend(
                a.withValues(alpha: 0.18), const Color(0xFF0C0B10)),
          ],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
              top: -24,
              left: -16,
              child: _blob(a.withValues(alpha: 0.45), 130)),
          Positioned(
              bottom: -30,
              right: -20,
              child: _blob(a.withValues(alpha: 0.30), 160)),
          Positioned(
              top: 28,
              right: 8,
              child: _blob(Colors.white.withValues(alpha: 0.06), 90)),
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 34, sigmaY: 34),
            child: const SizedBox.expand(),
          ),
        ],
      ),
    );
  }

  // The playback control bar shown once the user taps to watch: play/pause, a
  // ticking current time, a draggable progress slider, total time, fullscreen.
  Widget _controlBar(VideoPlayerController c) {
    final dur = c.value.duration;
    final pos = c.value.position;
    final totalMs =
        dur.inMilliseconds <= 0 ? 1.0 : dur.inMilliseconds.toDouble();
    final curMs = pos.inMilliseconds.toDouble().clamp(0.0, totalMs);
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 20, 6, 4),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xCC000000), Color(0x00000000)],
        ),
      ),
      child: Row(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _playWithSound,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(
                  c.value.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 26),
            ),
          ),
          Text(_fmt(pos),
              style: const TextStyle(color: Colors.white, fontSize: 10.5)),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2.5,
                activeTrackColor: widget.accent,
                inactiveTrackColor: Colors.white.withValues(alpha: 0.28),
                thumbColor: Colors.white,
                overlayColor: widget.accent.withValues(alpha: 0.2),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                min: 0,
                max: totalMs,
                value: curMs,
                onChanged: (v) {
                  c.seekTo(Duration(milliseconds: v.round()));
                  if (mounted) setState(() {});
                },
              ),
            ),
          ),
          Text(_fmt(dur),
              style: const TextStyle(color: Colors.white, fontSize: 10.5)),
          if (widget.onFullscreen != null)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onFullscreen,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.fullscreen_rounded,
                    color: Colors.white, size: 20),
              ),
            ),
        ],
      ),
    );
  }

  String? _durLabel() {
    final s = widget.durationSecs ?? 0;
    if (s <= 0) return null;
    final m = s ~/ 60, sx = s % 60;
    return '$m:${sx.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final ready = _ready && c != null && c.value.isInitialized;
    final ar = ready
        ? (c.value.aspectRatio == 0
            ? widget.aspectRatioFallback
            : c.value.aspectRatio)
        : widget.aspectRatioFallback;
    // Keep the card compact and always show the WHOLE frame. The stage ratio is
    // clamped to a sane band so a tall portrait clip can't blow the card up, and
    // the video is letterboxed inside it (BoxFit.contain) rather than cropped —
    // portrait or landscape, the full frame is visible on the black stage.
    final stageAr = ar.clamp(0.8, 16 / 9).toDouble();
    final playing = ready && c.value.isPlaying;
    final durLabel = _durLabel();

    Widget stack = VisibilityDetector(
      key: _visKey,
      onVisibilityChanged: (info) => _onVisibility(info.visibleFraction),
      child: GestureDetector(
        onTap: _onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: AspectRatio(
            aspectRatio: stageAr,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Letterbox base when playing; a soft out-of-focus poster
                // (not a flat black void) before the clip is on the device and
                // while an already-cached clip re-initialises on return.
                ready
                    ? const ColoredBox(color: Colors.black)
                    : _notReadyBackdrop(),
                if (ready)
                  Center(
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: SizedBox(
                        width: c.value.size.width > 0 ? c.value.size.width : 16,
                        height:
                            c.value.size.height > 0 ? c.value.size.height : 9,
                        child: VideoPlayer(c),
                      ),
                    ),
                  ),
                // Subtle video glyph on the placeholder (not yet on device).
                if (!ready && !_downloading && !_error)
                  Center(
                    child: Icon(Icons.movie_creation_outlined,
                        size: 34,
                        color: Colors.white.withValues(alpha: 0.18)),
                  ),
                if (_downloading)
                  const Center(
                    child: SizedBox(
                      width: 30,
                      height: 30,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white70),
                    ),
                  ),
                if (_error)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Video unavailable — tap to open',
                          textAlign: TextAlign.center,
                          style:
                              TextStyle(color: Colors.white70, fontSize: 12)),
                    ),
                  ),
                if (ready)
                  const Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 46,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [Colors.black54, Colors.transparent],
                          ),
                        ),
                      ),
                    ),
                  ),
                if ((widget.caption ?? '').trim().isNotEmpty)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 240),
                        curve: Curves.easeOut,
                        opacity: (_tapped || playing) ? 0.0 : 1.0,
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(14, 28, 14, 12),
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [Color(0xA6000000), Color(0x00000000)],
                            ),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.favorite_rounded,
                                  size: 13,
                                  color: Colors.white.withValues(alpha: 0.92)),
                              const SizedBox(height: 4),
                              Text(
                                widget.caption!.trim(),
                                textAlign: TextAlign.center,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w800,
                                  height: 1.25,
                                  shadows: [
                                    Shadow(
                                        color: Colors.black54,
                                        blurRadius: 6,
                                        offset: Offset(0, 1)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                // Centre play affordance — only on the poster (before the
                // user engages). Once tapped, the control bar owns play/pause.
                if (!_tapped &&
                    !_downloading &&
                    !_error &&
                    !_glimpsing &&
                    !playing)
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 54,
                          height: 54,
                          decoration: const BoxDecoration(
                              color: Colors.black45, shape: BoxShape.circle),
                          child: const Icon(Icons.play_arrow_rounded,
                              color: Colors.white, size: 32),
                        ),
                        if (!ready) ...[
                          const SizedBox(height: 8),
                          const Text('Tap to play',
                              style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ],
                    ),
                  ),
                if (ready && _tapped)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _controlBar(c),
                  ),
                if (_glimpsing)
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                          color: Colors.black45,
                          borderRadius: BorderRadius.circular(10)),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.volume_off_rounded,
                              size: 12, color: Colors.white),
                          SizedBox(width: 4),
                          Text('Preview',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ),
                if (durLabel != null && !_glimpsing && !_tapped)
                  Positioned(
                    left: 8,
                    bottom: 8,
                    child: Row(
                      children: [
                        const Icon(Icons.videocam_rounded,
                            size: 14, color: Colors.white70),
                        const SizedBox(width: 4),
                        Text(durLabel,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 11)),
                      ],
                    ),
                  ),
                if (widget.onFullscreen != null && !_tapped)
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: GestureDetector(
                      onTap: widget.onFullscreen,
                      child: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                            color: Colors.black38,
                            borderRadius: BorderRadius.circular(8)),
                        child: const Icon(Icons.fullscreen_rounded,
                            color: Colors.white, size: 18),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    stack = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: widget.maxWidth ?? double.infinity,
        maxHeight: widget.maxStageHeight,
      ),
      child: stack,
    );
    return stack;
  }
}
