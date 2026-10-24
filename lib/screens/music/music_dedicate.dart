part of '../music_controls.dart';

// "Dedicate this song ❤" (the hero card's row of the people you chat with
// most) and the loading ring that sweeps around the record while a song —
// or the app — is busy, instead of a loader sitting on top of the title.

/// A thin glowing comet that circles the record while [active]. Fades in and
/// out; holds still when the system asks for reduced motion.
class _DiscLoadRing extends StatefulWidget {
  const _DiscLoadRing({
    required this.active,
    required this.side,
    required this.accent,
  });

  final bool active;
  final double side;
  final Color accent;

  @override
  State<_DiscLoadRing> createState() => _DiscLoadRingState();
}

class _DiscLoadRingState extends State<_DiscLoadRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400));

  // Shown only once busy lasts a moment: the blip of buffering on a seek
  // (or an A-B loop jump) never flashes the ring.
  bool _shown = false;
  Timer? _wait;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _DiscLoadRing old) {
    super.didUpdateWidget(old);
    if (old.active != widget.active) _sync();
  }

  void _sync() {
    _wait?.cancel();
    if (widget.active) {
      _wait = Timer(const Duration(milliseconds: 350), () {
        if (!mounted) return;
        setState(() => _shown = true);
        _spin.repeat();
      });
    } else if (_shown) {
      _shown = false; // build follows (initState / didUpdateWidget)
      // Let the fade-out finish before parking it.
      _wait = Timer(const Duration(milliseconds: 260), () {
        if (mounted && !_shown) _spin.stop();
      });
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: _shown ? 1 : 0,
        duration: const Duration(milliseconds: 240),
        child: SizedBox(
          width: widget.side,
          height: widget.side,
          child: AnimatedBuilder(
            animation: _spin,
            builder: (_, _) => CustomPaint(
              painter: _LoadRingPainter(
                  turn: still ? 0.12 : _spin.value, accent: widget.accent),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadRingPainter extends CustomPainter {
  _LoadRingPainter({required this.turn, required this.accent});
  final double turn;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 3;
    final rect = Rect.fromCircle(center: c, radius: r);
    const sweep = 1.9; // radians of tail
    final start = turn * 2 * pi - pi / 2;
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(start);
    canvas.translate(-c.dx, -c.dy);
    final tail = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [accent.withValues(alpha: 0), accent],
        stops: const [0.0, sweep / (2 * pi)],
      ).createShader(rect);
    canvas.drawArc(rect, 0, sweep, false, tail);
    // The glowing head.
    final head = Offset(c.dx + r * cos(sweep), c.dy + r * sin(sweep));
    canvas.drawCircle(
        head,
        6,
        Paint()
          ..color = accent.withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
    canvas.drawCircle(head, 3, Paint()..color = Colors.white);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LoadRingPainter old) =>
      old.turn != turn || old.accent != accent;
}

/// Confirm + optional note, then send the playing song to [friend] as a love
/// heart (the song sealed inside, like "Dedicate a song" in chat).
class _DedicateSheet extends StatefulWidget {
  const _DedicateSheet({
    required this.friend,
    required this.name,
    required this.avatarUrl,
    required this.path,
    required this.title,
    required this.artist,
    required this.durationMs,
    required this.accent,
  });

  final Map<String, dynamic> friend;
  final String name;
  final String? avatarUrl;
  final String path;
  final String title;
  final String artist;
  final int? durationMs;
  final Color accent;

  @override
  State<_DedicateSheet> createState() => _DedicateSheetState();
}

class _DedicateSheetState extends State<_DedicateSheet> {
  static const int _maxBytes = 40 * 1024 * 1024; // same cap as chat hearts
  final _note = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  String _mime(String ext) => switch (ext) {
        'mp3' => 'audio/mpeg',
        'm4a' || 'mp4' => 'audio/mp4',
        'aac' => 'audio/aac',
        'ogg' || 'opus' => 'audio/ogg',
        'wav' => 'audio/wav',
        'flac' => 'audio/flac',
        _ => 'audio/mpeg',
      };

  Future<void> _send() async {
    if (_sending) return;
    final id = (widget.friend['id'] as num?)?.toInt();
    if (id == null) return;
    setState(() => _sending = true);
    try {
      final file = File(widget.path);
      final len = await file.length();
      if (len > _maxBytes) {
        if (mounted) {
          showToast(context, 'That song is too big for a heart (max 40 MB)',
              type: ToastType.error);
          setState(() => _sending = false);
        }
        return;
      }
      final bytes = await file.readAsBytes();
      final base = widget.path.replaceAll('\\', '/').split('/').last;
      final ext = base.contains('.') ? base.split('.').last.toLowerCase() : 'mp3';
      final a = widget.artist.trim();
      final shown =
          (a.isEmpty || a == '<unknown>') ? widget.title : '$a - ${widget.title}';
      final safe = shown.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();
      final name = '$safe.$ext';
      final mime = _mime(ext);
      final api = ApiService();
      final up = await api.uploadMedia(bytes: bytes, filename: name, mime: mime);
      if (up == null || up['url'] == null) throw Exception('upload failed');
      final note = _note.text.trim();
      final sent = await api.sendMessage(
        id,
        note.isEmpty ? 'This song is for you ❤' : note,
        messageType: 'heart',
        heartMood: 'love',
        mediaUrl: up['url'].toString(),
        mediaName: (up['name'] ?? name).toString(),
        mediaMime: (up['mime'] ?? mime).toString(),
        mediaSize: (up['size'] as num?)?.toInt() ?? len,
        mediaDuration: widget.durationMs,
      );
      if (sent == null) throw Exception('send failed');
      if (mounted) {
        Navigator.pop(context);
        showToast(context, 'Dedicated to ${widget.name} ❤',
            type: ToastType.success);
      }
    } catch (_) {
      if (mounted) {
        showToast(context, 'Couldn’t send — check your connection',
            type: ToastType.error);
        setState(() => _sending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = widget.accent;
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.onSurface.withAlpha(40),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Stack(
                clipBehavior: Clip.none,
                children: [
                  InitialsAvatar(
                      name: widget.name, radius: 30, imageUrl: widget.avatarUrl),
                  Positioned(
                    right: -4,
                    bottom: -2,
                    child: Icon(Icons.favorite_rounded, color: accent, size: 22),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text('Dedicate to ${widget.name}',
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(
                widget.artist.trim().isEmpty
                    ? widget.title
                    : '${widget.title} — ${widget.artist}',
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onSurface.withAlpha(170)),
              ),
              const SizedBox(height: 6),
              Text('Arrives as a heart with the song inside',
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurface.withAlpha(130))),
              const SizedBox(height: 16),
              TextField(
                controller: _note,
                maxLength: 140,
                enabled: !_sending,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Add a few words (optional)',
                  counterText: '',
                  filled: true,
                  fillColor: accent.withAlpha(18),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: readableOn(accent),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24)),
                  ),
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: readableOn(accent)))
                      : const Icon(Icons.favorite_rounded),
                  label: Text(_sending ? 'Sending…' : 'Send with love'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A previous / next song name under the wide Now Playing record: hover
/// lifts it into the accent, click skips to that song.
class _PeekName extends StatefulWidget {
  const _PeekName({
    required this.child,
    required this.onTap,
    required this.alignEnd,
    required this.accent,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool alignEnd;
  final Color accent;

  @override
  State<_PeekName> createState() => _PeekNameState();
}

class _PeekNameState extends State<_PeekName> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.onTap != null;
    return Align(
      alignment: widget.alignEnd ? Alignment.topRight : Alignment.topLeft,
      child: MouseRegion(
        cursor: on ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: on && _hover
                  ? widget.accent.withValues(alpha: 0.10)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}


/// A slow, gentle scale "breath" while [active] (A-B looping). Still when the
/// system asks for reduced motion.
class _Breathe extends StatefulWidget {
  const _Breathe({required this.active, required this.child});
  final bool active;
  final Widget child;

  @override
  State<_Breathe> createState() => _BreatheState();
}

class _BreatheState extends State<_Breathe>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1800));

  @override
  void initState() {
    super.initState();
    if (widget.active) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _Breathe old) {
    super.didUpdateWidget(old);
    if (widget.active && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.active && _c.isAnimating) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still || !widget.active) return widget.child;
    return ScaleTransition(
      scale: Tween(begin: 1.0, end: 1.04)
          .animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
      child: widget.child,
    );
  }
}
