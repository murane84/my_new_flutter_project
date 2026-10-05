import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// A video that NEVER shows a black box: it loads a real poster frame, and when
/// it lingers in view it plays a SILENT glimpse — the first ~quarter, looped
/// twice — then settles back to the poster (just like pausing your scroll on a
/// social feed). Tapping plays it for real, WITH sound; the fullscreen button
/// opens [onFullscreen]. Shared by Our Space moments AND chat so the behaviour
/// is identical everywhere.
///
/// The poster + glimpse are intentionally always-on (they ignore any future
/// "auto-download" media setting); only full, with-sound playback waits for a
/// tap.
class GlimpseVideo extends StatefulWidget {
  const GlimpseVideo({
    super.key,
    required this.url,
    required this.headers,
    required this.accent,
    this.onFullscreen,
    this.borderRadius = 14,
    this.maxWidth,
    this.aspectRatioFallback = 16 / 10,
    this.durationSecs,
  });

  final String url;
  final Map<String, String> headers;
  final Color accent;
  final VoidCallback? onFullscreen;
  final double borderRadius;
  final double? maxWidth;
  final double aspectRatioFallback;
  final int? durationSecs;

  @override
  State<GlimpseVideo> createState() => _GlimpseVideoState();
}

class _GlimpseVideoState extends State<GlimpseVideo> {
  VideoPlayerController? _c;
  // A stable, unique key for the visibility detector (per widget instance).
  late final Key _visKey = Key('glimpse_${identityHashCode(this)}');
  bool _initing = false;
  bool _ready = false;
  bool _error = false;
  bool _tapped = false; // the user tapped to play for real (with sound)
  bool _glimpsing = false;
  int _glimpseLoops = 0;
  bool _lastPlaying = false;
  Duration _posterPos = const Duration(milliseconds: 1200);
  Timer? _dwellTimer;
  double _frac = 0;

  // How much of the clip the silent glimpse plays, and how many times.
  static const double _glimpseFraction = 0.25;
  static const int _maxGlimpseLoops = 2;

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

  Future<void> _ensureController() async {
    if (_c != null || _initing || _error) return;
    _initing = true;
    final c = VideoPlayerController.networkUrl(
      Uri.parse(widget.url),
      httpHeaders: widget.headers,
    );
    try {
      await c.initialize();
      if (!mounted) {
        c.dispose();
        return;
      }
      await c.setVolume(0);
      await c.setLooping(false);
      // Poster = a representative early frame (frame 0 is often black/fade-in).
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
      // Already dwelling when it finished loading? Start the glimpse now.
      if (_frac >= 0.8) _maybeStartGlimpse();
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
    // Loop the first quarter while glimpsing; stop after _maxGlimpseLoops.
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
    // Repaint only when play/pause actually flips (not every frame).
    final p = c.value.isPlaying;
    if (p != _lastPlaying) {
      _lastPlaying = p;
      if (mounted) setState(() {});
    }
  }

  void _maybeStartGlimpse() {
    if (!_ready || _tapped || _glimpsing || _glimpseLoops >= _maxGlimpseLoops) {
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
    if (frac >= 0.5) {
      _ensureController();
    }
    if (frac >= 0.8 &&
        _ready &&
        !_tapped &&
        !_glimpsing &&
        _glimpseLoops < _maxGlimpseLoops) {
      // A short dwell so a fast scroll past doesn't trigger a glimpse.
      _dwellTimer?.cancel();
      _dwellTimer = Timer(const Duration(milliseconds: 450), () {
        if (mounted && _frac >= 0.8) _maybeStartGlimpse();
      });
    } else if (frac < 0.5) {
      _dwellTimer?.cancel();
      final c = _c;
      if (c != null && c.value.isPlaying) {
        if (!_tapped) {
          // Left the viewport mid-glimpse → settle back to the poster.
          _glimpsing = false;
          c.pause();
          c.seekTo(_posterPos);
        } else {
          // User's real playback pauses when it scrolls away.
          c.pause();
        }
        if (mounted) setState(() {});
      }
    }
  }

  Future<void> _onTap() async {
    if (_error) {
      widget.onFullscreen?.call();
      return;
    }
    if (_c == null || !_ready) await _ensureController();
    final c = _c;
    if (c == null) return;
    _dwellTimer?.cancel();
    if (!_tapped) {
      // First real tap: play from the start, WITH sound.
      _tapped = true;
      _glimpsing = false;
      await c.setVolume(1);
      await c.seekTo(Duration.zero);
      await c.play();
    } else if (c.value.isPlaying) {
      await c.pause();
    } else {
      await c.play();
    }
    if (mounted) setState(() {});
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
            aspectRatio: ar,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Colors.black),
                if (ready) VideoPlayer(c),
                if (!ready && !_error)
                  const Center(
                    child: SizedBox(
                      width: 30,
                      height: 30,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white54),
                    ),
                  ),
                if (_error)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text("Can't preview — tap to open",
                          textAlign: TextAlign.center,
                          style:
                              TextStyle(color: Colors.white70, fontSize: 12)),
                    ),
                  ),
                if (ready)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 46,
                    child: const IgnorePointer(
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
                // Center play affordance — on the poster / when paused.
                if (ready && !playing && !_glimpsing)
                  Center(
                    child: Container(
                      width: 54,
                      height: 54,
                      decoration: const BoxDecoration(
                          color: Colors.black38, shape: BoxShape.circle),
                      child: const Icon(Icons.play_arrow_rounded,
                          color: Colors.white, size: 32),
                    ),
                  ),
                // Silent-preview chip while glimpsing.
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
                if (durLabel != null && !_glimpsing)
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
                if (widget.onFullscreen != null)
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

    if (widget.maxWidth != null) {
      stack = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.maxWidth!),
        child: stack,
      );
    }
    return stack;
  }
}
