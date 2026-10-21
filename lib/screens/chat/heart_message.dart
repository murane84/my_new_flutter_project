import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import 'dart:ui' show PathMetric;
import 'package:intl/intl.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'dart:async';
import '../../services/heart_lock.dart';

// ─── Secret hearts — the signature love note ────────────────────────────────
// A "secret heart" (message_type 'heart') arrives covered, beating softly. It
// is opened by a small ritual: HOLD it — the beat quickens, the phone pulses —
// and it blooms open (after the device unlock, when "Lock secret hearts" is
// on). Short notes reveal inside the heart; long ones bloom a "genie" letter.
//
// Extras (server-backed, see my_aluta_api/hearts.py):
//  • mood     — Love / Missing you / Sorry / Thank you / Proud of you: its own
//               colour, cover label and letter title.
//  • timed    — sealed until a chosen moment; the outline fills in as the
//               moment nears and the note is withheld by the server until then.
//  • receipt  — the sender sees "Opened 2:14 PM 💗" (and gets a ping).

/// The feeling a heart is sent with. `key` is what the server stores.
class HeartMood {
  const HeartMood(this.key, this.label, this.cover, this.title, this.color,
      this.icon, this.prompts);
  final String key;
  final String label; // chip in the composer
  final String cover; // small label on the covered heart
  final String title; // heading of the opened letter
  final Color? color; // null = the chat's accent
  final IconData icon;
  final List<String> prompts; // starters offered in the composer

  static const love = HeartMood(
      'love', 'Love', 'with love', 'With love', null, Icons.favorite_rounded, [
    'One thing I love about you is ',
    'I fell for you all over again when ',
    'Tonight I want to ',
  ]);
  static const miss = HeartMood('miss', 'Missing you', 'missing you',
      'Missing you', Color(0xFF6C63FF), Icons.nights_stay_rounded, [
    'I miss the way you ',
    'Right now I wish I was ',
    'The first thing we\'ll do when I see you: ',
  ]);
  static const sorry = HeartMood('sorry', 'Sorry', 'a soft sorry',
      'I\'m sorry', Color(0xFFE07A9A), Icons.healing_rounded, [
    'I\'m sorry for ',
    'I understand now that ',
    'Next time I promise to ',
  ]);
  static const thanks = HeartMood('thanks', 'Thank you', 'thank you',
      'Thank you', Color(0xFFE0A526), Icons.volunteer_activism_rounded, [
    'Thank you for ',
    'You made my day when ',
    'I don\'t say it enough, but ',
  ]);
  static const proud = HeartMood('proud', 'Proud of you', 'so proud',
      'Proud of you', Color(0xFF22A06B), Icons.emoji_events_rounded, [
    'I\'m so proud of you for ',
    'Watching you ',
    'One thing I admire about you is ',
  ]);

  static const all = [love, miss, sorry, thanks, proud];

  static HeartMood of(String? key) =>
      all.firstWhere((m) => m.key == key, orElse: () => love);
}

/// "Opens tonight 8:00 PM" / "Opens Fri 8:00 PM" / "Opens 12 Feb, 8:00 PM".
String heartOpensLabel(DateTime when, {String prefix = 'Opens '}) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(when.year, when.month, when.day);
  final diff = day.difference(today).inDays;
  final t = DateFormat('h:mm a').format(when);
  if (diff == 0) {
    return '$prefix${when.hour >= 17 ? 'tonight' : 'today'} $t';
  }
  if (diff == 1) return '${prefix}tomorrow $t';
  if (diff > 1 && diff < 7) return '$prefix${DateFormat('EEE').format(when)} $t';
  return '$prefix${DateFormat('d MMM').format(when)}, $t';
}

/// The heart's state line, for the pill under it: a timed heart's opening
/// time (both sides), or — for the sender — the opened receipt. Null when
/// there's nothing to say (a received, already-openable heart).
({IconData icon, String text, bool warm})? heartStatus({
  required bool isMe,
  DateTime? unlockAt,
  DateTime? openedAt,
}) {
  if (unlockAt != null && DateTime.now().isBefore(unlockAt)) {
    return (
      icon: Icons.hourglass_top_rounded,
      text: heartOpensLabel(unlockAt),
      warm: false,
    );
  }
  if (!isMe) return null;
  if (openedAt != null) {
    return (
      icon: Icons.favorite_rounded,
      text: 'Opened ${DateFormat('h:mm a').format(openedAt)}',
      warm: true,
    );
  }
  return (icon: Icons.favorite_border_rounded, text: 'Not opened', warm: false);
}

/// Compact countdown: "2d 4h", "3h 12m", "12m", "45s".
String _countdown(Duration d) {
  if (d.isNegative) return '0s';
  if (d.inDays > 0) return '${d.inDays}d ${d.inHours % 24}h';
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
  if (d.inMinutes > 0) return '${d.inMinutes}m';
  return '${d.inSeconds}s';
}

/// A "secret heart" message bubble (message_type == 'heart').
class HeartBubble extends StatefulWidget {
  const HeartBubble({
    super.key,
    required this.text,
    required this.isMe,
    required this.accent,
    this.bonded = false,
    this.heartKeySeed,
    this.onLoveBack,
    this.mood,
    this.sentAt,
    this.unlockAt,
    this.openedAt,
    this.justSent = false,
    this.onFirstOpen,
    this.onUnsealDue,
    this.onMenu,
    this.showStatus = true,
  });

  final String text;
  final bool isMe;
  final Color accent;
  final bool bonded;
  final String? heartKeySeed;

  /// Bonded-space gesture: double-tap the heart to "love back" (a reaction +
  /// haptic + a little rising-hearts burst). Null = gesture disabled.
  final VoidCallback? onLoveBack;

  /// Mood key ('love' | 'miss' | 'sorry' | 'thanks' | 'proud'); null = love.
  final String? mood;

  /// When it was sent (local time) — anchors a timed heart's fill-in.
  final DateTime? sentAt;

  /// Timed heart: sealed until this moment (local time). Null = open anytime.
  final DateTime? unlockAt;

  /// When the recipient first opened it (shown to the sender). Null = not yet.
  final DateTime? openedAt;

  /// Play the "sealed with a kiss" stamp once (the sender's fresh heart).
  final bool justSent;

  /// The recipient opened it for the first time → report the receipt.
  final VoidCallback? onFirstOpen;

  /// A timed heart's moment just passed but its note hasn't arrived yet →
  /// ask the server to unseal it.
  final VoidCallback? onUnsealDue;

  /// Open the message menu (long-press). Not offered on a covered heart —
  /// there, holding is the opening ritual; open it first, then long-press.
  final void Function(Offset globalPosition)? onMenu;

  /// Draw the receipt / opens-at line under the heart. The chat turns this
  /// off and merges it into the timestamp pill instead.
  final bool showStatus;

  /// A note longer than this (or spanning more than one line) opens the genie
  /// card instead of revealing inside the heart.
  static const int longThreshold = 42;

  /// How long you hold a covered heart to open it.
  static const Duration holdToOpen = Duration(milliseconds: 750);

  @override
  State<HeartBubble> createState() => _HeartBubbleState();
}

class _HeartBubbleState extends State<HeartBubble>
    with TickerProviderStateMixin {
  late final AnimationController _beat = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400));
  late final Animation<double> _scale = TweenSequence<double>([
    // lub-dub: two quick beats then rest.
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.07), weight: 8),
    TweenSequenceItem(tween: Tween(begin: 1.07, end: 1.0), weight: 10),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.05), weight: 7),
    TweenSequenceItem(tween: Tween(begin: 1.05, end: 1.0), weight: 10),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 55),
  ]).animate(_beat);

  // A slow continuous clock for the drifting star field around the heart.
  late final AnimationController _stars = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 7200));

  // Hold-to-open progress (0..1). Drives the swelling + quickening beat.
  late final AnimationController _hold =
      AnimationController(vsync: this, duration: HeartBubble.holdToOpen);

  // One-shot "sealed" stamp for a freshly sent heart.
  late final AnimationController _seal = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900));

  final GlobalKey _heartKey = GlobalKey();
  bool _revealedInHeart = false;
  bool _visible = false;
  // "Awake" = the heart was just scrolled into view / touched. Stars twinkle
  // only while awake; after [_awakeFor] of stillness they
  // fade out together and everything rests (no frozen half-drawn stars, no
  // battery spent on an idle screen). Scrolling or a touch wakes it again.
  static const Duration _awakeFor = Duration(seconds: 6);
  bool _awake = false;
  Timer? _sleepTimer;
  ScrollPosition? _scrollPos;
  late final AnimationController _starFade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
      reverseDuration: const Duration(milliseconds: 1100));
  bool _reduceMotion = false;
  bool _opening = false; // between hold-complete and the bloom (auth etc.)
  bool _hint = false; // "hold to open" nudge after a quick tap
  bool _reported = false;
  bool _unsealAsked = false;
  // The finger-lift that ends a successful hold also lands as a tap — swallow
  // it so the just-opened note doesn't instantly re-seal.
  bool _swallowTap = false;
  Offset? _downAt;
  int _hapticStep = 0;
  Timer? _relock;
  Timer? _hintTimer;
  Timer? _tick; // timed-heart countdown

  HeartMood get _mood => HeartMood.of(widget.mood);
  Color get _accent => _mood.color ?? widget.accent;

  bool get _sealedByTime =>
      widget.unlockAt != null && DateTime.now().isBefore(widget.unlockAt!);

  /// Due but the note hasn't come down yet (server unseal pending).
  bool get _awaitingNote =>
      widget.unlockAt != null && !_sealedByTime && widget.text.trim().isEmpty;

  bool get _isLong =>
      widget.text.trim().length > HeartBubble.longThreshold ||
      widget.text.contains('\n');

  @override
  void initState() {
    super.initState();
    _hold.addListener(_onHoldTick);
    _hold.addStatusListener((s) {
      if (s == AnimationStatus.completed) _onHoldComplete();
    });
    HeartLock.instance.relockEpoch.addListener(_onRelockAll);
    if (widget.justSent) {
      _seal.forward();
      HapticFeedback.lightImpact();
    } else {
      _seal.value = 1;
    }
    _syncTick();
  }

  @override
  void didUpdateWidget(HeartBubble old) {
    super.didUpdateWidget(old);
    if (old.openedAt != widget.openedAt) {
      _syncBeat();
      if (!_sparkle && _awake) _sleep();
    }
    if (old.unlockAt != widget.unlockAt || old.text != widget.text) {
      _unsealAsked = false;
      _syncTick();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    // Wake on every scroll of the chat list while this heart is on screen.
    final pos = Scrollable.maybeOf(context)?.position;
    if (pos != _scrollPos) {
      _scrollPos?.removeListener(_onScroll);
      _scrollPos = pos;
      _scrollPos?.addListener(_onScroll);
    }
    _syncBeat();
  }

  void _onScroll() {
    if (_visible) _wake();
  }

  /// Start (or extend) the awake window.
  void _wake() {
    if (!mounted || _reduceMotion || !_sparkle) return;
    _sleepTimer?.cancel();
    _sleepTimer = Timer(_awakeFor, _sleep);
    if (!_awake) {
      _awake = true;
      _starFade.forward();
      _syncBeat();
    }
  }

  /// Let the stars fade out and the beat settle; stop the clocks after.
  void _sleep() {
    if (!mounted) return;
    _awake = false;
    _syncBeat(); // stops the beat
    _starFade.reverse().whenComplete(() {
      if (mounted && !_awake) _syncBeat(); // then stops the star clock
    });
  }

  /// Should the heart call for attention? Only a RECEIVED heart nobody has
  /// opened yet. Once it's been opened (here or on another of my devices),
  /// and on the sender's own hearts, it rests — no beat.
  bool get _attract =>
      !widget.isMe && widget.openedAt == null && !_reported;

  /// Stars only dress a heart that hasn't been opened yet (on either side:
  /// my unopened received heart, or one I sent they haven't opened).
  bool get _sparkle => widget.openedAt == null && !_reported;

  Timer? _burstTimer;
  static const Duration _burstEvery = Duration(seconds: 9);

  /// Two lub-dubs, then rest — a "knock" rather than a constant throb.
  Future<void> _burst() async {
    if (!mounted || _beat.isAnimating) return;
    for (var i = 0; i < 2; i++) {
      if (!mounted || !_shouldBeat) return;
      await _beat.forward(from: 0);
    }
    if (mounted) _beat.value = 0;
  }

  bool get _shouldBeat =>
      _visible && _attract && !_reduceMotion && !_revealedInHeart &&
      !_sealedByTime && !_awaitingNote;

  void _syncBeat() {
    if (_shouldBeat) {
      if (_burstTimer == null) {
        unawaited(_burst()); // knock as soon as it's seen
        _burstTimer = Timer.periodic(_burstEvery, (_) => _burst());
      }
    } else {
      _burstTimer?.cancel();
      _burstTimer = null;
      if (_beat.isAnimating) {
        // Finish the current beat gently instead of snapping to rest.
        _beat
            .animateTo(1.0,
                duration: Duration(
                    milliseconds:
                        ((1 - _beat.value) * 1400).round().clamp(0, 1400)))
            .whenComplete(() {
          if (mounted) _beat.value = 0;
        });
      }
    }
    // The star clock keeps running while the field is (fading) visible.
    final starsOn =
        _visible && !_reduceMotion && (_awake || _starFade.value > 0);
    if (starsOn) {
      if (!_stars.isAnimating) _stars.repeat();
    } else if (_stars.isAnimating) {
      _stars.stop();
    }
  }

  /// Timed hearts: refresh the countdown (every second in the last minute,
  /// otherwise every 20s) and ask for the note once the moment passes.
  void _syncTick() {
    _tick?.cancel();
    if (widget.unlockAt == null) return;
    if (_awaitingNote) {
      if (!_unsealAsked) {
        _unsealAsked = true;
        // Let the server's own unseal loop win the race first.
        _tick = Timer(const Duration(seconds: 2), () {
          widget.onUnsealDue?.call();
          // Keep retrying gently until the note lands.
          _tick = Timer.periodic(const Duration(seconds: 15), (_) {
            if (!mounted || !_awaitingNote) {
              _tick?.cancel();
              return;
            }
            widget.onUnsealDue?.call();
          });
        });
      }
      return;
    }
    if (!_sealedByTime) return;
    final left = widget.unlockAt!.difference(DateTime.now());
    final every = left.inSeconds <= 60
        ? const Duration(seconds: 1)
        : const Duration(seconds: 20);
    _tick = Timer(every < left ? every : left + const Duration(milliseconds: 50),
        () {
      if (!mounted) return;
      final wasSealed = _sealedByTime;
      setState(() {});
      if (!wasSealed) {
        // The moment arrived: a little heartbeat to say "it's ready".
        _heartbeatHaptic();
      }
      _syncBeat();
      _syncTick();
    });
  }

  void _onRelockAll() {
    if (!mounted || !_revealedInHeart) return;
    _relock?.cancel();
    setState(() => _revealedInHeart = false);
    _syncBeat();
  }

  @override
  void dispose() {
    HeartLock.instance.relockEpoch.removeListener(_onRelockAll);
    _relock?.cancel();
    _hintTimer?.cancel();
    _tick?.cancel();
    _hold.dispose();
    _seal.dispose();
    _sleepTimer?.cancel();
    _burstTimer?.cancel();
    _scrollPos?.removeListener(_onScroll);
    _starFade.dispose();
    _stars.dispose();
    _beat.dispose();
    super.dispose();
  }

  // ── Hold-to-open ritual ────────────────────────────────────────────────────

  bool get _canHold =>
      !_revealedInHeart && !_sealedByTime && !_awaitingNote && !_opening;

  void _pointerDown(PointerDownEvent e) {
    _swallowTap = false;
    _wake();
    if (!_canHold) return;
    _downAt = e.position;
    _hapticStep = 0;
    _hold.forward(from: 0);
  }

  void _pointerMove(PointerMoveEvent e) {
    if (_downAt == null) return;
    // Scrolling the chat isn't a hold.
    if ((e.position - _downAt!).distance > 14) _cancelHold(nudge: false);
  }

  void _pointerUp(PointerUpEvent e) {
    if (_downAt == null) return;
    final nudge = _hold.value < 0.5;
    _cancelHold(nudge: nudge);
  }

  void _cancelHold({required bool nudge}) {
    _downAt = null;
    if (_hold.status == AnimationStatus.completed) return;
    _hold.animateBack(0,
        duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    if (nudge) {
      _hintTimer?.cancel();
      setState(() => _hint = true);
      _hintTimer = Timer(const Duration(milliseconds: 1800), () {
        if (mounted) setState(() => _hint = false);
      });
    }
  }

  // Haptic ticks that quicken as you hold — the heart racing.
  void _onHoldTick() {
    if (_reduceMotion || _downAt == null) return;
    const steps = [0.0, 0.35, 0.6, 0.8, 0.93];
    while (_hapticStep < steps.length && _hold.value >= steps[_hapticStep]) {
      HapticFeedback.selectionClick();
      _hapticStep++;
    }
  }

  Future<void> _onHoldComplete() async {
    _downAt = null;
    _opening = true;
    final ok = await HeartLock.instance.ensureUnlocked();
    if (!mounted) return;
    _opening = false;
    if (!ok) {
      _hold.animateBack(0, duration: const Duration(milliseconds: 260));
      return;
    }
    _open();
  }

  void _open() {
    _swallowTap = true;
    _heartbeatHaptic();
    if (!widget.isMe && !_reported) {
      _reported = true;
      widget.onFirstOpen?.call();
    }
    _syncBeat(); // opened → stop calling for attention
    if (!_sparkle && _awake) _sleep(); // …and let the stars fade away
    if (_isLong) {
      final box = _heartKey.currentContext?.findRenderObject() as RenderBox?;
      Rect origin;
      if (box != null && box.hasSize) {
        origin = box.localToGlobal(Offset.zero) & box.size;
      } else {
        origin = Rect.zero;
      }
      _hold.animateBack(0, duration: const Duration(milliseconds: 300));
      showHeartGenie(context,
          originRect: origin,
          text: widget.text,
          accent: _accent,
          mood: _mood);
    } else {
      _hold.value = 0;
      setState(() => _revealedInHeart = true);
      _syncBeat();
      _armRelock();
    }
  }

  void _onTap() {
    if (_swallowTap) {
      _swallowTap = false;
      return;
    }
    // A tap on an already-open in-heart note re-seals it (manual lock).
    if (_revealedInHeart && !_isLong) {
      _relock?.cancel();
      setState(() => _revealedInHeart = false);
      _syncBeat();
      return;
    }
    if (_sealedByTime || _awaitingNote) {
      HapticFeedback.selectionClick();
      _hintTimer?.cancel();
      setState(() => _hint = true);
      _hintTimer = Timer(const Duration(milliseconds: 2200), () {
        if (mounted) setState(() => _hint = false);
      });
    }
  }

  /// Re-seal a revealed in-heart note after a spell of no interaction.
  void _armRelock() {
    _relock?.cancel();
    _relock = Timer(HeartLock.idleRelock, () {
      if (!mounted || !_revealedInHeart) return;
      setState(() => _revealedInHeart = false);
      _syncBeat();
    });
  }

  /// A soft "lub-dub" you feel. No-op without a vibrator (desktop).
  Future<void> _heartbeatHaptic() async {
    if (_reduceMotion) return;
    HapticFeedback.mediumImpact();
    await Future.delayed(const Duration(milliseconds: 150));
    HapticFeedback.lightImpact();
  }

  void _loveBack() {
    HapticFeedback.mediumImpact();
    final box = _heartKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      _showLoveBurst(
          context, box.localToGlobal(Offset.zero) & box.size, _accent);
    }
    widget.onLoveBack?.call();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final revealed = _revealedInHeart && !_isLong;
    final heart = VisibilityDetector(
      key: Key('heart-${widget.heartKeySeed ?? widget.text.hashCode}'),
      onVisibilityChanged: (info) {
        final v = info.visibleFraction > 0.15;
        if (v != _visible) {
          _visible = v;
          if (!mounted) return;
          if (v) {
            _wake(); // scrolled into view → stars + beat
          } else {
            _sleepTimer?.cancel();
            _awake = false;
            _starFade.value = 0;
            _syncBeat();
          }
        }
      },
      child: Listener(
        onPointerDown: _pointerDown,
        onPointerMove: _pointerMove,
        onPointerUp: _pointerUp,
        onPointerCancel: (_) => _cancelHold(nudge: false),
        child: GestureDetector(
          onTap: _onTap,
          onLongPressStart: (_canHold || widget.onMenu == null)
              ? null
              : (d) => widget.onMenu!(d.globalPosition),
          onDoubleTap:
              (widget.onLoveBack == null || !revealed) ? null : _loveBack,
          child: _withStars(revealed),
        ),
      ),
    );
    final status = widget.showStatus ? _statusLine() : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          widget.isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        heart,
        if (status != null)
          Padding(
            padding: const EdgeInsets.only(top: 2, left: 10, right: 10),
            child: status,
          ),
      ],
    );
  }

  /// The small line under the heart: the sender's receipt, or a timed
  /// heart's opening time for the recipient.
  Widget? _statusLine() {
    final scheme = Theme.of(context).colorScheme;
    String? text;
    IconData? icon;
    Color color = scheme.onSurfaceVariant;
    if (_sealedByTime) {
      text = heartOpensLabel(widget.unlockAt!);
      icon = Icons.hourglass_top_rounded;
    } else if (widget.isMe) {
      if (widget.openedAt != null) {
        text = 'Opened ${DateFormat('h:mm a').format(widget.openedAt!)}';
        icon = Icons.favorite_rounded;
        color = _accent;
      } else {
        text = 'Not opened yet';
        icon = Icons.favorite_border_rounded;
      }
    }
    if (text == null) return null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: color),
        const SizedBox(width: 4),
        Text(text,
            style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: color,
                letterSpacing: 0.2)),
      ],
    );
  }

  Widget _withStars(bool revealed) {
    final heart = AnimatedBuilder(
      animation: Listenable.merge([_scale, _hold, _seal]),
      builder: (context, _) {
        // Hold: the heart swells and races; seal: it lands with a bounce.
        final h = Curves.easeIn.transform(_hold.value);
        final racing = _hold.value > 0
            ? 1.0 + 0.10 * h + 0.03 * math.sin(_hold.value * math.pi * 14)
            : (revealed || _sealedByTime ? 1.0 : _scale.value);
        final stamp = Curves.elasticOut.transform(_seal.value.clamp(0.0, 1.0));
        final s = racing * (0.35 + 0.65 * stamp);
        return Transform.scale(
          scale: s,
          child: _heart(revealed, h),
        );
      },
    );
    if (_reduceMotion) return heart;
    return SizedBox(
      width: 160,
      height: 142,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: FadeTransition(
                  opacity: _starFade,
                  child: AnimatedBuilder(
                    animation: _stars,
                    builder: (context, _) => CustomPaint(
                      painter: _StarsPainter(_stars.value, _accent),
                    ),
                  ),
                ),
              ),
            ),
          ),
          heart,
          // "Sealed with a kiss" stamp on a freshly sent heart.
          if (widget.justSent)
            IgnorePointer(
              child: AnimatedBuilder(
                animation: _seal,
                builder: (context, _) {
                  final t = _seal.value;
                  if (t >= 1) return const SizedBox.shrink();
                  final o = t < 0.2 ? t / 0.2 : (1 - t) / 0.8;
                  return Opacity(
                    opacity: o.clamp(0.0, 1.0),
                    child: Transform.scale(
                      scale: 0.6 + 1.1 * t,
                      child: Container(
                        width: 150,
                        height: 150,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: _accent.withValues(alpha: 0.55),
                              width: 2),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _heart(bool revealed, double hold) {
    final sealed = _sealedByTime;
    double? progress;
    if (sealed && widget.sentAt != null) {
      final total =
          widget.unlockAt!.difference(widget.sentAt!).inSeconds.toDouble();
      final done =
          DateTime.now().difference(widget.sentAt!).inSeconds.toDouble();
      progress = total <= 0 ? 1.0 : (done / total).clamp(0.0, 1.0);
    }
    // A sealed heart sits a little dimmer, as if waiting.
    final base = sealed ? Color.lerp(_accent, Colors.grey.shade700, 0.35)! : _accent;
    return SizedBox(
      key: _heartKey,
      width: 160,
      height: 142,
      child: CustomPaint(
        painter: _HeartPainter(base),
        foregroundPainter: (sealed && progress != null)
            ? _HeartRingPainter(progress, Color.lerp(_accent, Colors.white, 0.45)!)
            : (hold > 0
                ? _HeartRingPainter(hold, Colors.white.withValues(alpha: 0.9))
                : null),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 30, 20, 34),
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              transitionBuilder: (c, a) => FadeTransition(
                  opacity: a,
                  child: ScaleTransition(
                      scale: Tween(begin: 0.85, end: 1.0).animate(a),
                      child: c)),
              child: revealed
                  ? SingleChildScrollView(
                      key: const ValueKey('open'),
                      child: Text(
                        widget.text,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13.5,
                            height: 1.2,
                            fontWeight: FontWeight.w600),
                      ),
                    )
                  : _cover(sealed),
            ),
          ),
        ),
      ),
    );
  }

  Widget _cover(bool sealed) {
    final white = Colors.white.withValues(alpha: 0.95);
    final String line;
    final IconData icon;
    if (sealed) {
      icon = Icons.hourglass_top_rounded;
      line = _hint
          ? heartOpensLabel(widget.unlockAt!, prefix: '')
          : 'opens in ${_countdown(widget.unlockAt!.difference(DateTime.now()))}';
    } else if (_awaitingNote) {
      icon = Icons.auto_awesome_rounded;
      line = 'opening…';
    } else {
      icon = _hint ? Icons.touch_app_rounded : _mood.icon;
      line = _hint ? 'hold to open' : _mood.cover;
    }
    return Column(
      key: ValueKey('cover-$sealed-$_hint-$_awaitingNote'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.white, size: 20),
        const SizedBox(height: 4),
        Text(
          line,
          textAlign: TextAlign.center,
          style: TextStyle(
              color: white,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3),
        ),
        if (!sealed && !_awaitingNote && !_hint) ...[
          const SizedBox(height: 2),
          Text('hold to open',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 9,
                  letterSpacing: 0.4)),
        ],
      ],
    );
  }
}

/// Traces the heart's outline up to [progress] — the hold-to-open ring, or a
/// timed heart filling in as its moment approaches.
class _HeartRingPainter extends CustomPainter {
  _HeartRingPainter(this.progress, this.color);
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final path = _HeartPainter.heartPath(size);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = color;
    for (final PathMetric m in path.computeMetrics()) {
      canvas.drawPath(m.extractPath(0, m.length * progress.clamp(0.0, 1.0)),
          paint);
    }
  }

  @override
  bool shouldRepaint(_HeartRingPainter old) =>
      old.progress != progress || old.color != color;
}

class _HeartPainter extends CustomPainter {
  _HeartPainter(this.accent);
  final Color accent;

  static Path heartPath(Size s) {
    final w = s.width, h = s.height;
    final path = Path();
    path.moveTo(0.5 * w, 0.34 * h);
    path.cubicTo(0.16 * w, -0.05 * h, -0.28 * w, 0.36 * h, 0.5 * w, 0.95 * h);
    path.cubicTo(1.28 * w, 0.36 * h, 0.84 * w, -0.05 * h, 0.5 * w, 0.34 * h);
    path.close();
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = heartPath(size);
    final rect = Offset.zero & size;
    final w = size.width, h = size.height;

    // 1) Soft coloured glow behind the heart — premium lift off the wallpaper.
    canvas.drawPath(
      path,
      Paint()
        ..color = accent.withValues(alpha: 0.38)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
    // 2) Grounding contact shadow.
    canvas.drawShadow(path.shift(const Offset(0, 6)), Colors.black87, 10, false);

    // 3) Volume: radial gradient lit from the upper-left so the lobes read as
    //    rounded, with a deep shaded bottom tip.
    final base = RadialGradient(
      center: const Alignment(-0.35, -0.62),
      radius: 1.25,
      colors: [
        Color.lerp(accent, Colors.white, 0.72)!,
        Color.lerp(accent, Colors.white, 0.28)!,
        accent,
        Color.lerp(accent, Colors.black, 0.4)!,
        Color.lerp(accent, Colors.black, 0.68)!,
      ],
      stops: const [0.0, 0.22, 0.52, 0.8, 1.0],
    );
    canvas.drawPath(path, Paint()..shader = base.createShader(rect));

    // 4) Inside-the-heart shading: clip to the heart, then sculpt the volume.
    canvas.save();
    canvas.clipPath(path);
    // 4a) Deep core shadow pooled at the bottom tip → real sense of mass.
    final tip = Offset(w * 0.5, h * 0.82);
    canvas.drawCircle(
      tip,
      w * 0.6,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.black.withValues(alpha: 0.42),
            Colors.black.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromCircle(center: tip, radius: w * 0.6)),
    );
    // 4b) Gentle overall bottom darken for grounding.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.center,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.26)],
        ).createShader(rect),
    );
    // 4c) Big soft specular sheen on the upper-left lobe.
    final hlCenter = Offset(w * 0.33, h * 0.22);
    canvas.drawCircle(
      hlCenter,
      w * 0.32,
      Paint()
        ..shader = RadialGradient(colors: [
          Colors.white.withValues(alpha: 0.6),
          Colors.white.withValues(alpha: 0.0),
        ]).createShader(Rect.fromCircle(center: hlCenter, radius: w * 0.32))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );
    // 4d) Secondary smaller glossy catch on the right lobe → both bumps lit.
    final hl2 = Offset(w * 0.66, h * 0.26);
    canvas.drawCircle(
      hl2,
      w * 0.17,
      Paint()
        ..shader = RadialGradient(colors: [
          Colors.white.withValues(alpha: 0.32),
          Colors.white.withValues(alpha: 0.0),
        ]).createShader(Rect.fromCircle(center: hl2, radius: w * 0.17))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    // 4e) Crisp hotspot sparkle on the main lobe.
    canvas.drawCircle(
      Offset(w * 0.3, h * 0.18),
      w * 0.05,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.85)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    canvas.restore();

    // 5) Bright rim light along the edge (top-left catches the light).
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.5),
            Colors.white.withValues(alpha: 0.05),
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_HeartPainter old) => old.accent != accent;
}

/// A gentle field of tiny twinkling stars drifting down around the heart.
class _StarsPainter extends CustomPainter {
  _StarsPainter(this.t, this.accent);
  final double t; // 0..1 loop phase
  final Color accent;

  static const int _count = 13;

  double _hash(int i) {
    final x = math.sin(i * 12.9898) * 43758.5453;
    return x - x.floorToDouble();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final tint = Color.lerp(Colors.white, accent, 0.2)!;
    const tau = math.pi * 2;
    for (int i = 0; i < _count; i++) {
      final fx = _hash(i * 2 + 1);
      final speed = 0.45 + _hash(i * 7 + 3) * 0.75;
      final phase = _hash(i * 5 + 2);
      final scale = 0.6 + _hash(i * 3 + 4) * 1.0;
      final fy = (phase + t * speed) % 1.0;
      final x = fx * w + math.sin((t * speed + phase) * tau) * 3.0;
      final y = fy * h;
      // fade in/out at the top and bottom edges
      final edge = (fy < 0.12
              ? fy / 0.12
              : (fy > 0.88 ? (1 - fy) / 0.12 : 1.0))
          .clamp(0.0, 1.0);
      // twinkle
      final tw = 0.3 + 0.7 * (0.5 + 0.5 * math.sin((t * speed * 3 + phase) * tau));
      final a = (0.9 * edge * tw).clamp(0.0, 1.0);
      if (a <= 0.02) continue;
      final r = 1.1 * scale;
      final color = tint.withValues(alpha: a);
      // soft glow
      canvas.drawCircle(
        Offset(x, y),
        r * 2.4,
        Paint()
          ..color = tint.withValues(alpha: a * 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      );
      // four-point sparkle cross
      final p = Paint()
        ..color = color
        ..strokeCap = StrokeCap.round
        ..strokeWidth = r * 0.7;
      final arm = r * 2.2;
      canvas.drawLine(Offset(x - arm, y), Offset(x + arm, y), p);
      canvas.drawLine(Offset(x, y - arm), Offset(x, y + arm), p);
      // bright core
      canvas.drawCircle(
          Offset(x, y), r * 0.7, Paint()..color = Colors.white.withValues(alpha: a));
    }
  }

  @override
  bool shouldRepaint(_StarsPainter old) => old.t != t || old.accent != accent;
}

/// Bloom a decorated "genie" letter out of the heart at [originRect], with the
/// note scrolling independently. Dismisses (collapsing back into the heart) on
/// tap-outside, swipe, back, idle, or the app going to the background.
void showHeartGenie(
  BuildContext context, {
  required Rect originRect,
  required String text,
  required Color accent,
  HeartMood mood = HeartMood.love,
}) {
  // A see-through route (not a bare overlay) so the system Back button
  // reaches the card's PopScope and folds it back into the heart.
  final nav = Navigator.of(context);
  nav.push(PageRouteBuilder<void>(
    opaque: false,
    barrierDismissible: false,
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    pageBuilder: (ctx, _, _) => _HeartGenie(
      originRect: originRect,
      text: text,
      accent: accent,
      mood: mood,
      onClosed: () {
        if (nav.mounted && nav.canPop()) nav.pop();
      },
    ),
  ));
}

class _HeartGenie extends StatefulWidget {
  const _HeartGenie({
    required this.originRect,
    required this.text,
    required this.accent,
    required this.mood,
    required this.onClosed,
  });
  final Rect originRect;
  final String text;
  final Color accent;
  final HeartMood mood;
  final VoidCallback onClosed;

  @override
  State<_HeartGenie> createState() => _HeartGenieState();
}

class _HeartGenieState extends State<_HeartGenie>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 420))
    ..forward();
  double _dragDy = 0;
  Timer? _idle;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _armIdle();
    HeartLock.instance.relockEpoch.addListener(_close);
  }

  void _armIdle() {
    _idle?.cancel();
    _idle = Timer(HeartLock.idleRelock, _close);
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _idle?.cancel();
    await _c.reverse();
    if (mounted) widget.onClosed();
  }

  @override
  void dispose() {
    HeartLock.instance.relockEpoch.removeListener(_close);
    _idle?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final oc = widget.originRect.center;
    final alignX = size.width == 0 ? 0.0 : (oc.dx / size.width) * 2 - 1;
    final alignY = size.height == 0 ? 0.0 : (oc.dy / size.height) * 2 - 1;
    final origin = Alignment(alignX.clamp(-1.0, 1.0), alignY.clamp(-1.0, 1.0));

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = Curves.easeOutBack.transform(_c.value.clamp(0.0, 1.0));
          final fade = _c.value.clamp(0.0, 1.0);
          // The letter's words drift in just after the card lands.
          final words =
              Curves.easeOut.transform(((_c.value - 0.45) / 0.55).clamp(0.0, 1.0));
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: _close,
                  child: Container(
                      color: Colors.black.withValues(alpha: 0.6 * fade)),
                ),
              ),
              Center(
                child: Transform.translate(
                  offset: Offset(0, _dragDy),
                  child: Transform.scale(
                    scale: (0.2 + 0.8 * t).clamp(0.0, 1.0),
                    alignment: origin,
                    child: Opacity(
                      opacity: fade,
                      child: GestureDetector(
                        onVerticalDragUpdate: (d) =>
                            setState(() => _dragDy += d.delta.dy),
                        onVerticalDragEnd: (d) {
                          if (_dragDy.abs() > 90 ||
                              (d.primaryVelocity ?? 0).abs() > 700) {
                            _close();
                          } else {
                            setState(() => _dragDy = 0);
                          }
                        },
                        child: Listener(
                          onPointerDown: (_) => _armIdle(),
                          onPointerMove: (_) => _armIdle(),
                          child: _card(context, words),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _card(BuildContext context, double words) {
    final size = MediaQuery.of(context).size;
    final a = widget.accent;
    return Material(
      color: Colors.transparent,
      child: Container(
        width: (size.width * 0.84).clamp(260.0, 430.0),
        constraints: BoxConstraints(maxHeight: size.height * 0.66),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.lerp(a, Colors.black, 0.66)!,
              Color.lerp(a, Colors.black, 0.88)!,
            ],
          ),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          boxShadow: [
            BoxShadow(
              color: a.withValues(alpha: 0.34),
              blurRadius: 44,
              spreadRadius: -8,
              offset: const Offset(0, 20),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 22,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: Stack(
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 110,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [a.withValues(alpha: 0.34), Colors.transparent],
                    ),
                  ),
                ),
              ),
              const Positioned(top: 8, left: 10, child: _CardMotifs(flip: false)),
              const Positioned(
                  bottom: 8, right: 10, child: _CardMotifs(flip: true)),
              Padding(
                padding: const EdgeInsets.fromLTRB(26, 24, 26, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(11),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.12),
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.22)),
                      ),
                      child: Icon(widget.mood.icon,
                          size: 22, color: Color.lerp(a, Colors.white, 0.5)),
                    ),
                    const SizedBox(height: 10),
                    // The letter's heading, by mood.
                    Text(
                      widget.mood.title,
                      style: TextStyle(
                        color: Color.lerp(a, Colors.white, 0.62),
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.6,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: 36,
                      height: 1.5,
                      color: Colors.white.withValues(alpha: 0.18),
                    ),
                    const SizedBox(height: 14),
                    Flexible(
                      child: Opacity(
                        opacity: words,
                        child: Transform.translate(
                          offset: Offset(0, (1 - words) * 10),
                          child: SingleChildScrollView(
                            child: Text(
                              widget.text,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.96),
                                fontSize: 17,
                                height: 1.55,
                                fontWeight: FontWeight.w500,
                                fontStyle: FontStyle.italic,
                                letterSpacing: 0.2,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.lock_clock_rounded,
                            size: 11,
                            color: Colors.white.withValues(alpha: 0.5)),
                        const SizedBox(width: 5),
                        Text(
                          'reseals by itself · tap outside to close',
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.55),
                              fontSize: 10.5,
                              letterSpacing: 0.4),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Faint corner motifs for the genie card — a tiny scatter of hearts, music
/// notes and sparkles echoing the chat wallpaper.
class _CardMotifs extends StatelessWidget {
  const _CardMotifs({required this.flip});
  final bool flip;

  @override
  Widget build(BuildContext context) {
    final c = Colors.white.withValues(alpha: 0.10);
    final items = flip
        ? const [Icons.music_note_rounded, Icons.favorite_rounded, Icons.auto_awesome_rounded]
        : const [Icons.favorite_rounded, Icons.music_note_rounded, Icons.auto_awesome_rounded];
    return IgnorePointer(
      child: SizedBox(
        width: 76,
        height: 64,
        child: Stack(
          children: [
            Positioned(left: 6, top: 8, child: Icon(items[0], size: 20, color: c)),
            Positioned(left: 40, top: 2, child: Icon(items[1], size: 13, color: c)),
            Positioned(left: 20, top: 34, child: Icon(items[2], size: 15, color: c)),
          ],
        ),
      ),
    );
  }
}

/// A brief burst of little hearts rising + fading from [origin] — the reward
/// for a bonded "love back" double-tap. Self-removing after the animation.
void _showLoveBurst(BuildContext context, Rect origin, Color accent) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _LoveBurst(
      origin: origin,
      accent: accent,
      onDone: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
}

class _LoveBurst extends StatefulWidget {
  const _LoveBurst({
    required this.origin,
    required this.accent,
    required this.onDone,
  });
  final Rect origin;
  final Color accent;
  final VoidCallback onDone;

  @override
  State<_LoveBurst> createState() => _LoveBurstState();
}

class _LoveBurstState extends State<_LoveBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100))
    ..forward().whenComplete(widget.onDone);

  // Per-heart jitter: horizontal drift, size, delay.
  static const _n = 7;
  final List<double> _dx = List.generate(_n, (i) => (i - _n / 2) * 9.0);
  final List<double> _size = List.generate(_n, (i) => 14.0 + (i % 3) * 6.0);
  final List<double> _delay = List.generate(_n, (i) => (i % 4) * 0.08);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cx = widget.origin.center.dx;
    final top = widget.origin.top;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final hearts = <Widget>[];
          for (var i = 0; i < _n; i++) {
            final t = ((_c.value - _delay[i]) / (1 - _delay[i])).clamp(0.0, 1.0);
            if (t <= 0) continue;
            final rise = 70.0 * t;
            final opacity = (t < 0.15 ? t / 0.15 : (1 - t)).clamp(0.0, 1.0);
            hearts.add(Positioned(
              left: cx + _dx[i] * t,
              top: top - rise,
              child: Opacity(
                opacity: opacity,
                child: Transform.scale(
                  scale: 0.6 + 0.6 * t,
                  child: Icon(Icons.favorite_rounded,
                      size: _size[i], color: widget.accent),
                ),
              ),
            ));
          }
          return Stack(children: hearts);
        },
      ),
    );
  }
}
