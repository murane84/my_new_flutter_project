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
    return AnimatedBuilder(
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
    );
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
    final c = color ?? Theme.of(context).colorScheme.onSurface;
    return ListTile(
      leading: Icon(icon, color: c, size: 22),
      title: Text(label, style: TextStyle(color: c)),
      dense: true,
      onTap: onTap,
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
      path.addRRect(RRect.fromRectAndRadius(rect, Radius.circular(r)));
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
/// the chat list stays light). Shows a play/pause button, a progress bar and
/// the elapsed / total time.
class _VoiceNotePlayer extends StatefulWidget {
  const _VoiceNotePlayer({
    required this.url,
    required this.durationMs,
    required this.accent,
    required this.onColor,
  });

  final String url;
  final int durationMs;
  final Color accent;
  final Color onColor;

  @override
  State<_VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<_VoiceNotePlayer> {
  final ja.AudioPlayer _player = ja.AudioPlayer();
  bool _prepared = false;
  bool _loading = false;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  StreamSubscription? _posSub;
  StreamSubscription? _stateSub;

  @override
  void initState() {
    super.initState();
    _dur = Duration(milliseconds: widget.durationMs);
    _posSub = _player.positionStream.listen((p) {
      if (mounted) setState(() => _pos = p);
    });
    _stateSub = _player.playerStateStream.listen((s) {
      if (!mounted) return;
      if (s.processingState == ja.ProcessingState.completed) {
        _player.pause();
        _player.seek(Duration.zero);
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (!_prepared) {
      setState(() => _loading = true);
      try {
        final d = await _player.setUrl(widget.url,
            headers: mediaAuthHeaders(widget.url));
        if (d != null && mounted) _dur = d;
        _prepared = true;
      } catch (_) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      if (mounted) setState(() => _loading = false);
    }
    if (_player.playing) {
      await _player.pause();
    } else {
      if (_player.processingState == ja.ProcessingState.completed) {
        await _player.seek(Duration.zero);
      }
      await _player.play();
    }
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
    final total =
        _dur.inMilliseconds > 0 ? _dur.inMilliseconds : widget.durationMs;
    final frac =
        total > 0 ? (_pos.inMilliseconds / total).clamp(0.0, 1.0) : 0.0;
    final label = (playing || _pos > Duration.zero) ? _pos : _dur;
    return SizedBox(
      width: 216,
      child: Row(
        children: [
          GestureDetector(
            onTap: _toggle,
            child: Container(
              width: 38,
              height: 38,
              // Soft brand tint (like the composer mic) so it complements the
              // solid-red Send/FAB instead of competing with it.
              decoration: BoxDecoration(
                color: widget.accent.withAlpha(isDark ? 48 : 30),
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
                  : Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: isDark ? const Color(0xFFFF8A93) : widget.accent,
                      size: 20),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: widget.onColor.withAlpha(45),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    FractionallySizedBox(
                      widthFactor: frac == 0 ? 0.001 : frac,
                      child: Container(
                        height: 4,
                        decoration: BoxDecoration(
                          color: widget.accent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Icon(Icons.mic_rounded,
                        size: 12, color: widget.onColor.withAlpha(150)),
                    const SizedBox(width: 3),
                    Text(_fmt(label),
                        style: TextStyle(
                            fontSize: 10.5,
                            color: widget.onColor.withAlpha(165))),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
  final bool isMe;

  const _SwipeToReply({
    required this.child,
    required this.onReply,
    required this.isMe,
  });

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply>
    with SingleTickerProviderStateMixin {
  static const double _maxDrag = 72;
  static const double _trigger = 50;

  late final AnimationController _spring;
  Animation<double>? _springAnim;
  double _dx = 0;
  bool _armed = false;

  @override
  void initState() {
    super.initState();
    _spring = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    )..addListener(() {
        if (_springAnim != null) setState(() => _dx = _springAnim!.value);
      });
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  void _settle() {
    _springAnim = Tween<double>(begin: _dx, end: 0).animate(
      CurvedAnimation(parent: _spring, curve: Curves.easeOutCubic),
    );
    _spring
      ..reset()
      ..forward();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final progress = (_dx / _trigger).clamp(0.0, 1.0);

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: (d) {
        // Reply is a rightward pull only; resist and cap the travel.
        final next = (_dx + d.delta.dx).clamp(0.0, _maxDrag);
        if (!_armed && next >= _trigger) {
          _armed = true;
          HapticFeedback.selectionClick();
        } else if (_armed && next < _trigger) {
          _armed = false;
        }
        setState(() => _dx = next);
      },
      onHorizontalDragEnd: (_) {
        if (_dx >= _trigger) widget.onReply();
        _armed = false;
        _settle();
      },
      onHorizontalDragCancel: () {
        _armed = false;
        _settle();
      },
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          Positioned(
            left: 14,
            child: Opacity(
              opacity: progress,
              child: Transform.scale(
                scale: 0.5 + 0.5 * progress,
                child: Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: scheme.primary.withAlpha(30),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.reply_rounded,
                      size: 18, color: scheme.primary),
                ),
              ),
            ),
          ),
          Transform.translate(
            offset: Offset(_dx, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}
