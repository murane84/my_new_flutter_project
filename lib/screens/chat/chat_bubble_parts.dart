part of '../chat_page.dart';

// ─── Chat wallpaper background ───────────────────────────────────────────────

class _ChatWallpaper extends StatelessWidget {
  final bool isDark;
  final Color brand;
  const _ChatWallpaper({required this.isDark, required this.brand});

  @override
  Widget build(BuildContext context) {
    return Container(
      // Warm brand-neutral base — near-black on dark, soft warm off-white on
      // light — with a faint music-motif pattern painted over it.
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF141011) : const Color(0xFFF3ECEA),
      ),
      child: CustomPaint(
        painter: _WallpaperPainter(isDark: isDark, brand: brand),
        size: Size.infinite,
      ),
    );
  }
}

/// A faint, tiled music-motif wallpaper (notes, headphones, hearts, discs…) in
/// the brand colour — like WhatsApp's doodle background, tuned to Aluta. Only
/// repaints when the theme/brand changes, so it's effectively free after first
/// layout.
class _WallpaperPainter extends CustomPainter {
  final bool isDark;
  final Color brand;
  const _WallpaperPainter({required this.isDark, required this.brand});

  static const List<IconData> _icons = [
    Icons.music_note_rounded,
    Icons.headphones_rounded,
    Icons.favorite_rounded,
    Icons.album_rounded,
    Icons.graphic_eq_rounded,
    Icons.queue_music_rounded,
    Icons.radio_rounded,
    Icons.audiotrack_rounded,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    // Very low alpha keeps it a whisper behind the bubbles.
    final color =
        (isDark ? Colors.white : brand).withAlpha(isDark ? 12 : 15);
    const cell = 66.0;
    var i = 0;
    for (double y = 0; y < size.height + cell; y += cell) {
      final row = (y / cell).floor();
      final xOff = row.isEven ? 0.0 : cell / 2; // brick-lay for organic feel
      for (double x = xOff; x < size.width + cell; x += cell) {
        final icon = _icons[(i * 5 + row * 3) % _icons.length];
        final tilt = (((i * 7 + row * 11) % 7) - 3) * 0.16; // small varied tilt
        final glyphSize = 18.0 + ((i + row) % 3) * 5.0;
        _glyph(canvas, icon, Offset(x, y), glyphSize, color, tilt);
        i++;
      }
    }
  }

  void _glyph(Canvas canvas, IconData icon, Offset c, double glyphSize,
      Color color, double tilt) {
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: glyphSize,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(tilt);
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WallpaperPainter old) =>
      old.isDark != isDark || old.brand != brand;
}

// ─── Typing dot animation ────────────────────────────────────────────────────

class _Dot extends StatefulWidget {
  final int delay;
  const _Dot({required this.delay});

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _ctrl.repeat(reverse: true);
    });
    _anim = Tween<double>(begin: 0, end: -5).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(child: AnimatedBuilder(
      animation: _anim,
      builder: (ctx2, child2) => Transform.translate(
        offset: Offset(0, _anim.value),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            shape: BoxShape.circle,
          ),
        ),
      ),
    ));
  }
}

// ─── Action tile ─────────────────────────────────────────────────────────────

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final destructive = color != null;
    final tint = destructive ? scheme.error : scheme.primary;
    final textColor = destructive ? scheme.error : scheme.onSurface;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(
          children: [
            // Soft tinted chip behind the icon — matches the app's 3D chips.
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: isDark ? 0.16 : 0.10),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(
                    color: tint.withValues(alpha: isDark ? 0.28 : 0.20),
                    width: 1),
              ),
              child: Icon(icon, color: tint, size: 19),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: textColor,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single emoji reaction in the floating reaction pill. It gives a quick
/// press "pop" (scale down then release) so tapping a reaction feels tactile.
class _ReactionButton extends StatefulWidget {
  final String emoji;
  final VoidCallback onTap;
  const _ReactionButton({required this.emoji, required this.onTap});

  @override
  State<_ReactionButton> createState() => _ReactionButtonState();
}

class _ReactionButtonState extends State<_ReactionButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.72 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
          child: Text(widget.emoji, style: const TextStyle(fontSize: 24)),
        ),
      ),
    );
  }
}

// ─── Chat bubble with a WhatsApp-style beak/tail ─────────────────────────────
/// A rounded-rectangle bubble whose bottom-outer corner grows a small triangular
/// tail pointing toward the sender. Drawn as ONE continuous path so the fill,
/// border and shadow all follow the beak seamlessly (via [ShapeDecoration]).
///   • [tailOnRight] true  → tail at the bottom-right (my messages)
///   • [tailOnRight] false → tail at the bottom-left  (the friend's messages)
///   • [showTail] false    → a plain rounded rectangle (grouped messages)
class _BubbleBorder extends ShapeBorder {
  const _BubbleBorder({
    this.radius = 18,
    this.tailSize = 7,
    required this.tailOnRight,
    required this.showTail,
    this.side = BorderSide.none,
  });

  final double radius;
  final double tailSize;
  final bool tailOnRight;
  final bool showTail;
  final BorderSide side;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    final r = radius;
    final path = Path();

    if (!showTail) {
      // Reserve the same tail-side gutter the tailed (first) bubble uses, so a
      // grouped run lines up in a straight column instead of the tail-less
      // bubbles jutting out past the one with the beak.
      final body = tailOnRight
          ? Rect.fromLTRB(rect.left, rect.top, rect.right - tailSize, rect.bottom)
          : Rect.fromLTRB(rect.left + tailSize, rect.top, rect.right, rect.bottom);
      path.addRRect(RRect.fromRectAndRadius(body, Radius.circular(r)));
      return path;
    }

    final t = tailSize;
    final top = rect.top;
    final bottom = rect.bottom;

    if (tailOnRight) {
      // Body inset from the right by [t]; beak protrudes into that gap.
      final left = rect.left;
      final bodyR = rect.right - t;
      path.moveTo(left + r, top);
      path.lineTo(bodyR - r, top);
      path.arcToPoint(Offset(bodyR, top + r), radius: Radius.circular(r));
      path.lineTo(bodyR, bottom - t); // down the right edge to the beak base
      path.lineTo(rect.right, bottom); // out to the beak tip
      path.lineTo(bodyR, bottom); // back to the body's bottom-right
      path.lineTo(left + r, bottom);
      path.arcToPoint(Offset(left, bottom - r), radius: Radius.circular(r));
      path.lineTo(left, top + r);
      path.arcToPoint(Offset(left + r, top), radius: Radius.circular(r));
      path.close();
    } else {
      // Body inset from the left by [t]; beak protrudes into that gap.
      final right = rect.right;
      final bodyL = rect.left + t;
      path.moveTo(bodyL + r, top);
      path.lineTo(right - r, top);
      path.arcToPoint(Offset(right, top + r), radius: Radius.circular(r));
      path.lineTo(right, bottom - r);
      path.arcToPoint(Offset(right - r, bottom), radius: Radius.circular(r));
      path.lineTo(bodyL, bottom); // along the bottom to the body's bottom-left
      path.lineTo(rect.left, bottom); // out to the beak tip
      path.lineTo(bodyL, bottom - t); // back up to the body's left edge
      path.lineTo(bodyL, top + r);
      path.arcToPoint(Offset(bodyL + r, top), radius: Radius.circular(r));
      path.close();
    }
    return path;
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none) return;
    canvas.drawPath(
      getOuterPath(rect, textDirection: textDirection),
      side.toPaint(),
    );
  }

  @override
  ShapeBorder scale(double t) => _BubbleBorder(
        radius: radius * t,
        tailSize: tailSize * t,
        tailOnRight: tailOnRight,
        showTail: showTail,
        side: side.scale(t),
      );
}

// ─── Voice note player ───────────────────────────────────────────────────────
/// Plays a voice note from a remote URL on demand (lazy-loads on first tap so
/// the chat list stays light). Aluta waveform you can tap / drag to scrub, a
/// 1× · 1.5× · 2× speed pill (remembered across notes), and only one note
/// plays at a time. The bars are a stable per-note shape derived from the
/// URL — no amplitude data needs to travel with the message.
class _VoiceNotePlayer extends StatefulWidget {
  const _VoiceNotePlayer({
    required this.url,
    required this.durationMs,
    required this.accent,
    required this.onColor,
    this.onPlaying,
    this.autoPlaySoft = false,
  });

  final String url;
  final int durationMs;
  // A "voice hello": play once, softly, as soon as it's on screen.
  final bool autoPlaySoft;
  final Color accent;
  final Color onColor;
  // Playing / stopped — lets an opened heart letter hold its reseal countdown.
  final ValueChanged<bool>? onPlaying;

  @override
  State<_VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<_VoiceNotePlayer> {
  static const _speeds = [1.0, 1.5, 2.0];
  // Shared: the next note keeps your speed, and every pill on screen follows.
  static final ValueNotifier<double> _speedN = ValueNotifier<double>(1.0);
  double get _speed => _speedN.value;
  void _onSpeed() {
    if (mounted) setState(() {});
  }
  static _VoiceNotePlayerState? _active; // one note at a time
  // Voice hellos already auto-played this run (scrolling away and back
  // rebuilds the bubble — it must not play again).
  static final Set<String> _autoPlayed = {};

  final ja.AudioPlayer _player = ja.AudioPlayer();
  bool _prepared = false;
  bool _loading = false;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  double? _dragFrac;
  late final List<double> _bars = _shape(widget.url, 34);
  StreamSubscription? _posSub;
  StreamSubscription? _stateSub;

  /// Deterministic, speech-like bar heights (0.18..1) seeded by the URL.
  static List<double> _shape(String seed, int n) {
    var h = 0x811C9DC5;
    for (final c in seed.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0x7FFFFFFF;
    }
    final out = <double>[];
    var prev = 0.5;
    for (var i = 0; i < n; i++) {
      h = (h * 1103515245 + 12345) & 0x7FFFFFFF;
      final r = (h % 1000) / 1000.0;
      // Smooth towards the new sample + a gentle phrase envelope.
      final env = 0.55 + 0.45 * math.sin(math.pi * (i + 0.5) / n);
      prev = prev * 0.45 + r * 0.55;
      out.add((0.18 + 0.82 * prev * env).clamp(0.18, 1.0));
    }
    return out;
  }

  @override
  void initState() {
    super.initState();
    _dur = Duration(milliseconds: widget.durationMs);
    _speedN.addListener(_onSpeed);
    _posSub = _player.positionStream.listen((p) {
      if (mounted && _dragFrac == null) setState(() => _pos = p);
    });
    _stateSub = _player.playerStateStream.listen((s) {
      if (!mounted) return;
      if (s.processingState == ja.ProcessingState.completed) {
        _player.pause();
        _player.seek(Duration.zero);
      }
      widget.onPlaying?.call(s.playing &&
          s.processingState != ja.ProcessingState.completed);
      setState(() {});
    });
    if (widget.autoPlaySoft && _autoPlayed.add(widget.url)) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted || !await _prepare() || !mounted) return;
        final other = _active;
        if (other != null && !identical(other, this) && other.mounted) {
          other._player.pause();
        }
        _active = this;
        await _player.setVolume(0.55);
        // Never await play(): its future completes when the clip ENDS.
        _player.play();
      });
    }
  }

  @override
  void dispose() {
    widget.onPlaying?.call(false); // a letter mid-countdown resumes
    _speedN.removeListener(_onSpeed);
    if (identical(_active, this)) _active = null;
    _posSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  // One shared load, so a tap followed by a quick drag doesn't start two
  // setUrl calls (the first would throw "Loading interrupted").
  Future<bool>? _prepFut;
  Future<bool> _prepare() => _prepFut ??= _doPrepare();

  Future<bool> _doPrepare() async {
    if (_prepared) return true;
    setState(() => _loading = true);
    try {
      final d = await _player.setUrl(widget.url,
          headers: mediaAuthHeaders(widget.url));
      if (!mounted) return false;
      if (d != null) _dur = d;
      await _player.setSpeed(_speed);
      _prepared = true;
    } catch (_) {
      _prepFut = null; // let a later tap retry
      if (mounted) setState(() => _loading = false);
      return false;
    }
    if (!mounted) return false;
    setState(() => _loading = false);
    return true;
  }

  Future<void> _toggle() async {
    if (!await _prepare() || !mounted) return;
    if (_player.playing) {
      await _player.pause();
    } else {
      if (_player.processingState == ja.ProcessingState.completed) {
        await _player.seek(Duration.zero);
      }
      final other = _active;
      if (other != null && !identical(other, this) && other.mounted) {
        other._player.pause();
      }
      _active = this;
      if (_player.speed != _speed) await _player.setSpeed(_speed);
      if (_player.volume != 1.0) await _player.setVolume(1.0); // after a soft hello
      await _player.play();
    }
  }

  Future<void> _cycleSpeed() async {
    HapticFeedback.selectionClick();
    final i = _speeds.indexOf(_speed);
    final next = _speeds[(i + 1) % _speeds.length];
    _speedN.value = next;
    if (_prepared) await _player.setSpeed(next);
  }

  int get _totalMs =>
      _dur.inMilliseconds > 0 ? _dur.inMilliseconds : widget.durationMs;

  Future<void> _seekFrac(double f) async {
    final total = _totalMs;
    if (total <= 0) return;
    if (!await _prepare() || !mounted) return;
    final to = Duration(milliseconds: (total * f.clamp(0.0, 1.0)).round());
    setState(() => _pos = to);
    await _player.seek(to);
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _speedLabel(double v) =>
      v == v.roundToDouble() ? '${v.toInt()}×' : '$v×';

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final playing = _player.playing;
    final total = _totalMs;
    final frac = _dragFrac ??
        (total > 0 ? (_pos.inMilliseconds / total).clamp(0.0, 1.0) : 0.0);
    final started = playing || _pos > Duration.zero || _dragFrac != null;
    final label = _dragFrac != null
        ? Duration(milliseconds: (total * _dragFrac!).round())
        : started
            ? _pos
            : _dur;
    return RepaintBoundary(child: SizedBox(
      width: 232,
      child: Row(
        children: [
          GestureDetector(
            onTap: _toggle,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: playing
                    ? widget.accent
                    : widget.accent.withAlpha(isDark ? 48 : 30),
                shape: BoxShape.circle,
                border: Border.all(
                    color: widget.accent.withAlpha(isDark ? 90 : 70),
                    width: 1),
              ),
              child: _loading
                  ? Padding(
                      padding: const EdgeInsets.all(10),
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: widget.accent),
                    )
                  : Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: playing
                          ? Colors.white
                          : (isDark ? const Color(0xFFFF8A93) : widget.accent),
                      size: 20),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LayoutBuilder(builder: (ctx, c) {
                  double fx(Offset local) =>
                      (local.dx / c.maxWidth).clamp(0.0, 1.0);
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (d) => _seekFrac(fx(d.localPosition)),
                    onHorizontalDragStart: (d) =>
                        setState(() => _dragFrac = fx(d.localPosition)),
                    onHorizontalDragUpdate: (d) =>
                        setState(() => _dragFrac = fx(d.localPosition)),
                    onHorizontalDragEnd: (_) {
                      final f = _dragFrac;
                      setState(() => _dragFrac = null);
                      if (f != null) _seekFrac(f);
                    },
                    onHorizontalDragCancel: () =>
                        setState(() => _dragFrac = null),
                    child: SizedBox(
                      height: 26,
                      width: c.maxWidth,
                      child: CustomPaint(
                        painter: _WavePainter(
                          bars: _bars,
                          frac: frac,
                          played: widget.accent,
                          idle: widget.onColor.withAlpha(isDark ? 70 : 60),
                          knob: _dragFrac != null || started,
                        ),
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Icon(Icons.mic_rounded,
                        size: 12, color: widget.onColor.withAlpha(150)),
                    const SizedBox(width: 3),
                    Text(_fmt(label),
                        style: TextStyle(
                            fontSize: 10.5,
                            fontFeatures: const [
                              ui.FontFeature.tabularFigures()
                            ],
                            color: widget.onColor.withAlpha(165))),
                    const Spacer(),
                    // Speed pill — tap to cycle 1× · 1.5× · 2×.
                    GestureDetector(
                      onTap: _cycleSpeed,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: _speed == 1.0
                              ? widget.onColor.withAlpha(22)
                              : widget.accent.withAlpha(isDark ? 70 : 40),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(_speedLabel(_speed),
                            style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                color: _speed == 1.0
                                    ? widget.onColor.withAlpha(170)
                                    : (isDark
                                        ? const Color(0xFFFF8A93)
                                        : widget.accent))),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ));
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.bars,
    required this.frac,
    required this.played,
    required this.idle,
    required this.knob,
  });

  final List<double> bars;
  final double frac;
  final Color played;
  final Color idle;
  final bool knob;

  @override
  void paint(Canvas canvas, Size size) {
    final n = bars.length;
    final slot = size.width / n;
    final w = (slot * 0.56).clamp(1.5, 3.2);
    final mid = size.height / 2;
    final p = Paint()..strokeCap = StrokeCap.round;
    for (var i = 0; i < n; i++) {
      final x = slot * (i + 0.5);
      final h = (size.height - 4) * bars[i];
      p
        ..color = (x / size.width) <= frac ? played : idle
        ..strokeWidth = w;
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), p);
    }
    if (knob) {
      final kx = (size.width * frac).clamp(3.0, size.width - 3.0);
      canvas.drawCircle(
          Offset(kx, mid), 5, Paint()..color = played.withAlpha(60));
      canvas.drawCircle(Offset(kx, mid), 3.4, Paint()..color = played);
    }
  }

  @override
  bool shouldRepaint(_WavePainter o) =>
      o.frac != frac || o.played != played || o.idle != idle || o.knob != knob;
}

// ─── Shared-song bubble ──────────────────────────────────────────────────────
/// Renders a song shared into the chat. Shared songs are EPHEMERAL: the sender
/// uploads the audio only long enough for the recipient to cache it locally,
/// after which the server purges its copy (see [SongCache] and the attachments
/// router). This widget therefore:
///   • plays from the on-device cache whenever it exists (both ends);
///   • on the RECIPIENT side, downloads → caches → acks the server on first
///     appearance (within the 7-day window), which triggers the server purge;
///   • falls back to streaming from the server only while the bytes still live
///     there, and shows "No longer available" if they're gone and we never
///     cached them.
class _SongBubble extends StatefulWidget {
  const _SongBubble({
    required this.assetId,
    required this.url,
    required this.title,
    required this.fileName,
    required this.mime,
    required this.isMe,
    required this.accent,
    required this.onColor,
    this.onDownload,
    this.onPlaying,
  });

  final String? assetId;
  final String url;
  final String title;
  final String? fileName;
  final String? mime;
  final bool isMe;
  final Color accent;
  final Color onColor;
  // Save the song out to the device's own storage (Files / Music) — handled by
  // the chat page, which reads from the local cache (server copy may be purged).
  // Null = saving isn't offered (a heart whose sender kept it view-only).
  final VoidCallback? onDownload;
  // Playing / stopped — lets an opened heart letter hold its reseal countdown.
  final ValueChanged<bool>? onPlaying;

  @override
  State<_SongBubble> createState() => _SongBubbleState();
}

class _SongBubbleState extends State<_SongBubble> {
  final ja.AudioPlayer _player = ja.AudioPlayer();
  bool _prepared = false;
  bool _loading = false;
  bool _unavailable = false;
  bool _dragging = false;
  double _dragFrac = 0;
  String? _localPath;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  StreamSubscription? _posSub;
  StreamSubscription? _durSub;
  StreamSubscription? _stateSub;

  @override
  void initState() {
    super.initState();
    _posSub = _player.positionStream.listen((p) {
      if (mounted && !_dragging) setState(() => _pos = p);
    });
    // Duration can arrive after setFilePath/setUrl returns null (streamed or
    // some codecs), so keep the slider's total in sync as the player learns it.
    _durSub = _player.durationStream.listen((d) {
      if (mounted && d != null) setState(() => _dur = d);
    });
    _stateSub = _player.playerStateStream.listen((s) {
      if (!mounted) return;
      if (s.processingState == ja.ProcessingState.completed) {
        _player.pause();
        _player.seek(Duration.zero);
      }
      widget.onPlaying?.call(s.playing &&
          s.processingState != ja.ProcessingState.completed);
      setState(() {});
    });
    _prime();
  }

  /// Resolve a local copy. The recipient downloads + caches + acks while the
  /// server still holds the bytes; the sender relies on the copy it seeded at
  /// send time and never fetches from the server here.
  Future<void> _prime() async {
    final id = widget.assetId;
    if (id == null) return;
    var path = await SongCache.cachedPath(id,
        filename: widget.fileName, mime: widget.mime);
    if (path == null && !widget.isMe) {
      path = await SongCache.ensureCached(
        id,
        widget.url,
        mediaAuthHeaders(widget.url),
        filename: widget.fileName,
        mime: widget.mime,
      );
      if (path != null && !SongCache.hasAcked(id)) {
        SongCache.markAcked(id);
        unawaited(ApiService().ackAttachmentCached(id));
      }
    }
    if (mounted && path != null) setState(() => _localPath = path);
  }

  @override
  void dispose() {
    widget.onPlaying?.call(false); // a letter mid-countdown resumes
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  /// Load the audio (cache-first) without starting playback — used when the
  /// user drags the slider before pressing play.
  Future<bool> _ensureLoaded() async {
    if (_prepared) return true;
    setState(() => _loading = true);
    try {
      final id = widget.assetId;
      var path = _localPath;
      if (path == null && id != null) {
        path = await SongCache.cachedPath(id,
            filename: widget.fileName, mime: widget.mime);
      }
      if (path == null && !widget.isMe && id != null) {
        path = await SongCache.ensureCached(
          id,
          widget.url,
          mediaAuthHeaders(widget.url),
          filename: widget.fileName,
          mime: widget.mime,
        );
        if (path != null && !SongCache.hasAcked(id)) {
          SongCache.markAcked(id);
          unawaited(ApiService().ackAttachmentCached(id));
        }
      }
      Duration? d;
      if (path != null) {
        _localPath = path;
        d = await _player.setFilePath(path);
      } else {
        d = await _player.setUrl(widget.url,
            headers: mediaAuthHeaders(widget.url));
      }
      if (d != null && mounted) _dur = d;
      _prepared = true;
      if (mounted) setState(() => _loading = false);
      return true;
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _unavailable = true;
        });
      }
      return false;
    }
  }

  Future<void> _toggle() async {
    if (_unavailable) return;
    if (!await _ensureLoaded()) return;
    if (_player.playing) {
      await _player.pause();
    } else {
      if (_player.processingState == ja.ProcessingState.completed) {
        await _player.seek(Duration.zero);
      }
      await _player.play();
    }
  }

  // Seek to a fraction of the track, loading it first if the user drags before
  // pressing play.
  Future<void> _seekToFraction(double frac) async {
    if (_unavailable) return;
    if (!await _ensureLoaded()) return;
    final total = _dur;
    if (total <= Duration.zero) return;
    final target = total * frac.clamp(0.0, 1.0);
    await _player.seek(target);
    if (mounted) setState(() => _pos = target);
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final playing = _player.playing;
    final total = _dur.inMilliseconds;
    final liveFrac =
        total > 0 ? (_pos.inMilliseconds / total).clamp(0.0, 1.0) : 0.0;
    final frac = _dragging ? _dragFrac : liveFrac;
    // Seekable whenever the song isn't gone — dragging before the first play
    // loads it, then jumps to the dropped position.
    final canSeek = !_unavailable;
    // "Title — Artist" → two lines; a bare title stays one line.
    final parts = widget.title.split(' — ');
    final line1 = parts.first;
    final line2 = parts.length > 1 ? parts.sublist(1).join(' — ') : null;
    final shownPos =
        _dragging ? Duration(milliseconds: (total * _dragFrac).round()) : _pos;
    return RepaintBoundary(child: SizedBox(
      width: 248,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Title row: play/pause · title/artist · download ──────────────
          Row(
            children: [
              GestureDetector(
                onTap: _toggle,
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: widget.accent.withAlpha(isDark ? 48 : 30),
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: widget.accent.withAlpha(isDark ? 90 : 70),
                        width: 1),
                  ),
                  child: _loading
                      ? Padding(
                          padding: const EdgeInsets.all(11),
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: widget.accent),
                        )
                      : Icon(
                          _unavailable
                              ? Icons.music_off_rounded
                              : (playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded),
                          color:
                              isDark ? const Color(0xFFFF8A93) : widget.accent,
                          size: 22),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.music_note_rounded,
                            size: 13, color: widget.onColor.withAlpha(170)),
                        const SizedBox(width: 3),
                        Expanded(
                          child: Text(line1,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: widget.onColor)),
                        ),
                      ],
                    ),
                    if (line2 != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 16, top: 1),
                        child: Text(line2,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11.5,
                                color: widget.onColor.withAlpha(165))),
                      ),
                  ],
                ),
              ),
              // Save the song to the device's own storage.
              if (widget.onDownload != null)
              Tooltip(
                message: 'Save to device',
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 34, minHeight: 34),
                  icon: Icon(Icons.download_rounded,
                      size: 20, color: widget.onColor.withAlpha(190)),
                  onPressed: widget.onDownload,
                ),
              ),
            ],
          ),
          if (_unavailable)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 2),
              child: Row(
                children: [
                  Icon(Icons.cloud_off_rounded,
                      size: 12, color: widget.onColor.withAlpha(150)),
                  const SizedBox(width: 4),
                  Text('No longer on server — cache expired',
                      style: TextStyle(
                          fontSize: 10.5,
                          fontStyle: FontStyle.italic,
                          color: widget.onColor.withAlpha(150))),
                ],
              ),
            )
          else ...[
            // ── Seek slider ────────────────────────────────────────────────
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: widget.accent,
                inactiveTrackColor: widget.onColor.withAlpha(45),
                thumbColor: widget.accent,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                value: frac,
                onChangeStart: canSeek
                    ? (v) => setState(() {
                          _dragging = true;
                          _dragFrac = v;
                        })
                    : null,
                onChanged: canSeek
                    ? (v) => setState(() => _dragFrac = v)
                    : null,
                onChangeEnd: canSeek
                    ? (v) {
                        setState(() => _dragging = false);
                        _seekToFraction(v);
                      }
                    : null,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    total > 0 ? _fmt(shownPos) : 'Tap to play',
                    style: TextStyle(
                        fontSize: 10, color: widget.onColor.withAlpha(160)),
                  ),
                  Text(
                    total > 0 ? _fmt(_dur) : '',
                    style: TextStyle(
                        fontSize: 10, color: widget.onColor.withAlpha(160)),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    ));
  }
}

/// WhatsApp-style swipe-to-reply. The bubble follows the finger to the right,
/// a reply glyph fades and scales in from the left edge, a single haptic fires
/// when the trigger distance is crossed, and on release the bubble springs
/// smoothly back to rest (instead of the old snap/on-off behaviour). If the
/// pull passed the trigger, [onReply] is invoked.
class _SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback onReply;
  // Swipe LEFT → forward. Null = left pull doesn't arm (unsent, heart,
  // deleted, call/live logs).
  final VoidCallback? onForward;
  final bool isMe;

  const _SwipeToReply({
    required this.child,
    required this.onReply,
    required this.isMe,
    this.onForward,
  });

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply>
    with SingleTickerProviderStateMixin {
  // Travel limit + where the reply arms. The finger's raw pull is mapped
  // through a rubber-band curve, so it starts 1:1 and gets heavier near the
  // limit instead of hitting a hard stop.
  // WhatsApp-light: arms early, with a tick, so even a short thumb flick
  // on a tiny emoji bubble is enough.
  static const double _maxDrag = 76;
  static const double _trigger = 46;

  // Unbounded so a spring can overshoot zero a hair on release (that tiny
  // settle is what makes it feel physical, not scripted).
  late final AnimationController _spring =
      AnimationController.unbounded(vsync: this)
        ..addListener(() => setState(() => _dx = _spring.value));
  double _raw = 0; // finger travel
  double _dx = 0; // rendered travel (rubber-banded)
  bool _armed = false;

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  double _band(double raw) =>
      raw.sign * _maxDrag * (1 - math.exp(-raw.abs() / (_maxDrag * 0.9)));

  void _settle(double velocity) {
    _raw = 0;
    _spring.value = _dx;
    _spring.animateWith(SpringSimulation(
      const SpringDescription(mass: 1, stiffness: 420, damping: 24),
      _dx,
      0,
      velocity / 4,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final left = _dx < 0; // pulling toward forward
    final progress = (_dx.abs() / _trigger).clamp(0.0, 1.0);
    final t = Curves.easeOut.transform(progress);

    // 3D: the bubble slides, tips back a little on its vertical axis (as if
    // hinged on the far edge) and leans down a touch — a card being pulled.
    final m = Matrix4.identity()
      ..setEntry(3, 2, 0.0013) // perspective
      ..translateByDouble(_dx, 0, 0, 1)
      ..rotateY(-0.16 * t * (widget.isMe ? -1 : 1) * (left ? -1 : 1))
      ..scaleByDouble(1 - 0.03 * t, 1 - 0.03 * t, 1, 1);

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // Swipe-to-reply is a finger gesture. A mouse drag is left alone so it
      // can select text in the bubble (desktop/web); mouse users reply from
      // the hover chevron or the right-click menu.
      supportedDevices: const {
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.unknown,
      },
      onHorizontalDragStart: (_) {
        _spring.stop();
        _raw = _dx; // grab it mid-settle smoothly
      },
      onHorizontalDragUpdate: (d) {
        // Right = reply; left = forward (only when offered).
        final minRaw = widget.onForward == null ? 0.0 : -400.0;
        _raw = (_raw + d.delta.dx).clamp(minRaw, 400.0);
        final next = _band(_raw);
        if (!_armed && next.abs() >= _trigger) {
          _armed = true;
          HapticFeedback.mediumImpact();
        } else if (_armed && next.abs() < _trigger - 6) {
          _armed = false; // a little hysteresis so it doesn't flicker
          HapticFeedback.selectionClick();
        }
        setState(() => _dx = next);
      },
      onHorizontalDragEnd: (d) {
        if (_armed) {
          if (_dx < 0) {
            HapticFeedback.selectionClick();
            widget.onForward?.call();
          } else {
            widget.onReply();
          }
        }
        _armed = false;
        _settle(d.primaryVelocity ?? 0);
      },
      onHorizontalDragCancel: () {
        _armed = false;
        _settle(0);
      },
      child: Stack(
        alignment: Alignment.centerLeft,
        clipBehavior: Clip.none,
        children: [
          // The reply badge rises with the pull, spins into place and pops
          // (solid fill) the moment the reply is armed.
          Positioned(
            left: left ? null : 12,
            right: left ? 12 : null,
            child: Opacity(
              opacity: t,
              child: Transform.rotate(
                angle: (1 - t) * -0.9,
                child: AnimatedScale(
                  scale: _armed ? 1.18 : (0.55 + 0.45 * t),
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutBack,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: _armed
                          ? scheme.primary
                          : scheme.primary.withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                      boxShadow: _armed
                          ? [
                              BoxShadow(
                                color: scheme.primary.withValues(alpha: 0.4),
                                blurRadius: 10,
                                offset: const Offset(0, 3),
                              ),
                            ]
                          : null,
                    ),
                    child: Icon(
                        left ? Icons.forward_rounded : Icons.reply_rounded,
                        size: 18,
                        color: _armed ? Colors.white : scheme.primary),
                  ),
                ),
              ),
            ),
          ),
          Transform(
            transform: m,
            alignment: (widget.isMe != left)
                ? Alignment.centerLeft
                : Alignment.centerRight,
            child: widget.child,
          ),
        ],
      ),
    );
  }
}


// ─── Stable image box ────────────────────────────────────────────────────────
/// A chat photo / GIF / sticker in a FIXED, whole-pixel box. A plain Image
/// with no width/height re-lays-out its parents on every animation frame (and
/// jumps from the loader size to the image size), which made animated GIF
/// bubbles shimmer. Here the aspect ratio is read once from the first frame
/// (and remembered per URL, so scrolling back never jumps), the box is
/// sized from it and then never changes; frames only repaint, inside their
/// own RepaintBoundary.
class _StableImage extends StatefulWidget {
  const _StableImage({
    super.key,
    required this.sizeKey,
    required this.provider,
    required this.loader,
    required this.broken,
  });

  final String sizeKey;
  final ImageProvider provider;
  final Widget Function() loader;
  final Widget Function() broken;

  static final Map<String, double> _aspects = {};

  @override
  State<_StableImage> createState() => _StableImageState();
}

class _StableImageState extends State<_StableImage> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  bool _failed = false;

  double? get _aspect => _StableImage._aspects[widget.sizeKey];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(_StableImage old) {
    super.didUpdateWidget(old);
    if (old.provider != widget.provider) {
      _failed = false; // e.g. the network try failed, the local copy arrived
      _resolve();
    }
  }

  void _resolve() {
    if (_aspect != null) return; // the Image itself does the loading
    final s = widget.provider.resolve(createLocalImageConfiguration(context));
    if (s.key == _stream?.key) return;
    _unlisten();
    _listener = ImageStreamListener((info, _) {
      final w = info.image.width, h = info.image.height;
      if (w > 0 && h > 0) _StableImage._aspects[widget.sizeKey] = w / h;
      _unlisten();
      if (mounted) setState(() {});
    }, onError: (_, _) {
      _unlisten();
      if (mounted) setState(() => _failed = true);
    });
    _stream = s..addListener(_listener!);
  }

  void _unlisten() {
    final l = _listener;
    if (l != null) _stream?.removeListener(l);
    _listener = null;
  }

  @override
  void dispose() {
    _unlisten();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.broken();
    final a = _aspect;
    if (a == null) return widget.loader();
    // Fit 240×300, keep at least 120×80 (cover crops the rest); whole pixels.
    var w = 240.0, h = w / a;
    if (h > 300) {
      h = 300;
      w = h * a;
    }
    w = w.clamp(120.0, 240.0).roundToDouble();
    h = h.clamp(80.0, 300.0).roundToDouble();
    return SizedBox(
      width: w,
      height: h,
      child: RepaintBoundary(
        child: Image(
          image: widget.provider,
          width: w,
          height: h,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) => widget.broken(),
        ),
      ),
    );
  }
}
