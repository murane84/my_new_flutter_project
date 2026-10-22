import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/device_lean.dart';
import 'dart:math' as math;
import 'dart:ui' show FontFeature, PathMetric;
import 'dart:ui' as ui;
import 'package:intl/intl.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'dart:async';
import '../../services/heart_lock.dart';
import '../../widgets/glossy_heart.dart';
import '../../utils/readable.dart';

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
  // Every mood owns its colour — fixed, never the user's app/bubble theme —
  // so "with love" is always red, "missing you" always violet, and so on.
  final Color? color;
  final IconData icon;
  final List<String> prompts; // starters offered in the composer

  static const love = HeartMood(
      'love', 'Love', 'with love', 'With love',
      // Bright love red — fixed, never the theme accent (white words read on it).
      Color(0xFFF0142F),
      Icons.favorite_rounded, [
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

/// When a heart was sent, for the opened letter: "3:01 AM", "yesterday
/// 3:01 AM", "Fri 3:01 AM" or "12 Feb".
String heartSentLabel(DateTime when) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(when.year, when.month, when.day);
  final diff = today.difference(day).inDays;
  final t = DateFormat('h:mm a').format(when);
  if (diff <= 0) return t;
  if (diff == 1) return 'yesterday $t';
  if (diff < 7) return '${DateFormat('EEE').format(when)} $t';
  return DateFormat('d MMM').format(when);
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
///
/// In a GROUP the sender sees a count instead of a time ("2 of 3 opened",
/// "Opened by all") — who exactly is in Message info. [openCount] is how many
/// members opened it, [openTotal] how many could (null if unknown).
({IconData icon, String text, bool warm})? heartStatus({
  required bool isMe,
  DateTime? unlockAt,
  DateTime? openedAt,
  bool isGroup = false,
  int openCount = 0,
  int? openTotal,
}) {
  if (unlockAt != null && DateTime.now().isBefore(unlockAt)) {
    return (
      icon: Icons.hourglass_top_rounded,
      text: heartOpensLabel(unlockAt),
      warm: false,
    );
  }
  if (!isMe) return null;
  if (isGroup) {
    if (openCount <= 0) {
      return (
        icon: Icons.favorite_border_rounded,
        text: openTotal == null ? 'Not opened' : '0 of $openTotal opened',
        warm: false,
      );
    }
    if (openTotal != null && openCount >= openTotal) {
      return (icon: Icons.favorite_rounded, text: 'Opened by all', warm: true);
    }
    return (
      icon: Icons.favorite_rounded,
      text: openTotal == null
          ? '$openCount opened'
          : '$openCount of $openTotal opened',
      warm: true,
    );
  }
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
    this.onReply,
    this.onReact,
    this.onKeep,
    this.onSendBack,
    this.senderName,
  });

  /// Who sent it (first name) — shown on the opened letter.
  final String? senderName;

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

  /// Actions offered on the opened LETTER card (a long note opens there, not
  /// in the heart, so the bubble's long-press menu isn't reachable while
  /// reading). Null = not shown.
  final VoidCallback? onReply;
  final ValueChanged<String>? onReact;
  final VoidCallback? onKeep;

  /// "Send a heart back" — answer a heart with a heart (offered on the letter
  /// card of a RECEIVED heart).
  final VoidCallback? onSendBack;

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

  // Mouse hover tilt: where the pointer is over the heart, -1..1 on each
  // axis (0,0 = centre / not hovering). The heart turns subtly toward it and
  // its sheen slides with the light.
  final ValueNotifier<Offset> _tilt = ValueNotifier<Offset>(Offset.zero);

  void _tiltAt(Offset p) {
    if (_reduceMotion) return;
    const w = 160.0, h = 142.0;
    _tilt.value = Offset(
      ((p.dx / w) * 2 - 1).clamp(-1.0, 1.0),
      ((p.dy / h) * 2 - 1).clamp(-1.0, 1.0),
    );
  }

  // Touch: the heart presses in under the finger (same turn + light as the
  // mouse) while it's down, and eases back when it lifts or the touch turns
  // into a scroll.
  bool get _touchTilting => _touchAt != null;

  // Phone lean (accelerometer) while this heart is on screen.
  bool _leaning = false;
  void _setLeaning(bool on) {
    on = on && !_reduceMotion;
    if (on == _leaning) return;
    _leaning = on;
    on ? DeviceLean.instance.acquire() : DeviceLean.instance.release();
  }
  Offset? _touchAt;

  void _touchDown(PointerDownEvent e) {
    if (e.kind == PointerDeviceKind.mouse) return;
    _touchAt = e.position;
    _tiltAt(e.localPosition);
  }

  void _touchMove(PointerMoveEvent e) {
    if (!_touchTilting) return;
    if ((e.position - _touchAt!).distance > 14) {
      _touchEnd(); // it's a scroll, not a touch on the heart
    } else {
      _tiltAt(e.localPosition);
    }
  }

  void _touchEnd() {
    if (!_touchTilting) return;
    _touchAt = null;
    _tilt.value = Offset.zero;
  }

  Widget _tiltable(Widget Function(Offset light) build) {
    return MouseRegion(
      onHover: (e) => _tiltAt(e.localPosition),
      onExit: (_) => _tilt.value = Offset.zero,
      // Mouse / finger win while they're on the heart; otherwise it leans
      // gently with the phone.
      child: AnimatedBuilder(
        animation: Listenable.merge([_tilt, DeviceLean.instance.lean]),
        builder: (context, _) {
          final direct = _tilt.value;
          final target = direct != Offset.zero
              ? direct
              : (_leaning ? DeviceLean.instance.lean.value * 0.75 : Offset.zero);
          return TweenAnimationBuilder<Offset>(
          tween: Tween(end: target),
          duration: Duration(
              milliseconds: direct != Offset.zero
                  ? 160
                  : (target == Offset.zero ? 420 : 120)),
          curve: Curves.easeOutCubic,
          builder: (context, t, _) {
            const maxTurn = 0.16; // ~9°, subtle
            final m = Matrix4.identity()
              ..setEntry(3, 2, 0.0014)
              ..rotateX(t.dy * maxTurn)
              ..rotateY(-t.dx * maxTurn);
            return Transform(
              alignment: Alignment.center,
              transform: m,
              child: build(t),
            );
          },
          );
        },
      ),
    );
  }

  /// Open/close the in-heart note — also tells HeartLock, which keeps the
  /// window screenshot-proof while any note is open.
  void _setRevealed(bool v) {
    if (v == _revealedInHeart) return;
    setState(() => _revealedInHeart = v);
    v ? HeartLock.instance.noteOpened() : HeartLock.instance.noteClosed();
  }
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

  /// Stars are the "something new for you" signal: only on a RECEIVED heart
  /// I haven't opened yet. My own sent hearts never sparkle (their pill says
  /// whether it's been opened), and an opened heart rests.
  bool get _sparkle => _attract;

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
    _setRevealed(false);
    _syncBeat();
  }

  @override
  void dispose() {
    _setLeaning(false);
    _tilt.dispose();
    HeartLock.instance.relockEpoch.removeListener(_onRelockAll);
    _relock?.cancel();
    _hintTimer?.cancel();
    _tick?.cancel();
    _hold.dispose();
    _seal.dispose();
    if (_revealedInHeart) HeartLock.instance.noteClosed();
    _sleepTimer?.cancel();
    _burstTimer?.cancel();
    _scrollPos?.removeListener(_onScroll);
    _starFade.dispose();
    _stars.dispose();
    _beat.dispose();
    super.dispose();
  }

  // ── Hold-to-open ritual ────────────────────────────────────────────────────

  // Hold-to-open is the RECIPIENT's ritual. On my own sent hearts a hold
  // opens the message menu (Message info, delete…) like any bubble, and a
  // tap peeks at what I wrote.
  bool get _canHold =>
      !widget.isMe &&
      !_revealedInHeart &&
      !_sealedByTime &&
      !_awaitingNote &&
      !_opening;

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
    if (!widget.isMe && !HeartLock.instance.coachSeen) {
      unawaited(HeartLock.instance.markCoachSeen());
    }
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
          mood: _mood,
          from: widget.isMe ? 'you' : widget.senderName,
          sentAt: widget.sentAt,
          onReply: widget.onReply,
          onReact: widget.onReact,
          onKeep: widget.onKeep,
          onSendBack: widget.isMe ? null : widget.onSendBack);
    } else {
      _hold.value = 0;
      _setRevealed(true);
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
      _setRevealed(false);
      _syncBeat();
      return;
    }
    // My own heart → tap peeks. With a screen reader or reduced-motion on,
    // a plain tap also opens a received heart (holding can be hard).
    final a11y = MediaQuery.maybeOf(context)?.accessibleNavigation == true ||
        _reduceMotion;
    if ((widget.isMe || a11y) &&
        !_revealedInHeart &&
        !_sealedByTime &&
        !_awaitingNote &&
        !_opening) {
      unawaited(_peekOwn());
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

  /// Tap on my own heart: peek at it (behind the unlock when the lock is on).
  Future<void> _peekOwn() async {
    _opening = true;
    final ok = await HeartLock.instance.ensureUnlocked(
        widget.isMe ? 'Open your heart' : 'Open secret heart');
    if (!mounted) return;
    _opening = false;
    if (ok) {
      _open();
      _swallowTap = false; // no finger-lift tap follows a tap-open
    }
  }

  /// Re-seal a revealed in-heart note after a spell of no interaction.
  void _armRelock() {
    _relock?.cancel();
    _relock = Timer(HeartLock.idleRelock, () {
      if (!mounted || !_revealedInHeart) return;
      _setRevealed(false);
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
          _setLeaning(v);
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
        onPointerDown: (e) {
          _touchDown(e);
          _pointerDown(e);
        },
        onPointerMove: (e) {
          _touchMove(e);
          _pointerMove(e);
        },
        onPointerUp: (e) {
          _touchEnd();
          _pointerUp(e);
        },
        onPointerCancel: (_) {
          _touchEnd();
          _cancelHold(nudge: false);
        },
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
    // First heart this person ever receives: a one-time "hold to open" coach
    // under it (gone for good after the first open).
    final coach = !widget.isMe &&
        !HeartLock.instance.coachSeen &&
        !_revealedInHeart &&
        !_sealedByTime &&
        !_awaitingNote;
    final sealedLabel = _sealedByTime
        ? 'sealed, ${heartOpensLabel(widget.unlockAt!).toLowerCase()}'
        : null;
    final label = widget.isMe
        ? 'Your secret heart, ${_mood.label.toLowerCase()}. '
            '${sealedLabel ?? 'Tap to read it, hold for options.'}'
        : 'Secret heart, ${_mood.label.toLowerCase()}. '
            '${sealedLabel ?? (_revealedInHeart ? widget.text : 'Double-tap to open.')}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          widget.isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Semantics(
          label: label,
          button: true,
          excludeSemantics: true,
          onTap: _onTap,
          onLongPress: widget.onMenu == null
              ? null
              : () {
                  final box = context.findRenderObject() as RenderBox?;
                  final c = box == null
                      ? Offset.zero
                      : box.localToGlobal(box.size.center(Offset.zero));
                  widget.onMenu!(c);
                },
          child: heart,
        ),
        if (coach) _CoachChip(color: _accent),
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
    Widget beating(Offset light) => AnimatedBuilder(
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
          child: _heart(revealed, h, light),
        );
      },
    );
    if (_reduceMotion) return RepaintBoundary(child: beating(Offset.zero));
    final heart = _tiltable(beating);
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
          // Own layer: the beat / attract pulse repaints only the heart.
          RepaintBoundary(child: heart),
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

  Widget _heart(bool revealed, double hold, [Offset light = Offset.zero]) {
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
    final base =
        sealed ? Color.lerp(_accent, Colors.grey.shade700, 0.35)! : _accent;
    // The heart keeps its mood's own colour; its words take the matching
    // ink (white on deep moods, graphite / black on bright ones).
    final ink = readableOn(base);
    return SizedBox(
      key: _heartKey,
      width: 160,
      height: 142,
      child: CustomPaint(
        painter: _HeartPainter(base, light),
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
                        style: TextStyle(
                            color: ink,
                            fontSize: 13.5,
                            height: 1.2,
                            fontWeight: FontWeight.w600),
                      ),
                    )
                  : _cover(sealed, ink),
            ),
          ),
        ),
      ),
    );
  }

  Widget _cover(bool sealed, [Color ink = Colors.white]) {
    final white = ink.withValues(alpha: 0.95);
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
      line = _hint ? (widget.isMe ? 'tap to peek' : 'hold to open') : _mood.cover;
    }
    return Column(
      key: ValueKey('cover-$sealed-$_hint-$_awaitingNote'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: ink, size: 20),
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
          // One short affordance that always fits on one line inside the
          // heart. (Holding a sent heart for its menu is the same as every
          // bubble, so it doesn't need spelling out.)
          Text(widget.isMe ? 'tap to peek' : 'hold to open',
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.fade,
              style: TextStyle(
                  color: ink.withValues(alpha: 0.75),
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5)),
        ],
      ],
    );
  }
}

/// One-time "Hold to open" nudge under a person's first received heart: a
/// soft pill with a finger that presses down and up.
class _CoachChip extends StatefulWidget {
  const _CoachChip({required this.color});
  final Color color;
  @override
  State<_CoachChip> createState() => _CoachChipState();
}

class _CoachChipState extends State<_CoachChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1500))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(child: Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: widget.color.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _c,
              builder: (_, _) {
                // press (0–0.45) · hold · release
                final t = _c.value;
                final down = t < 0.15
                    ? t / 0.15
                    : (t < 0.6 ? 1.0 : (t < 0.75 ? (0.75 - t) / 0.15 : 0.0));
                return Transform.translate(
                  offset: Offset(0, 2.5 * down),
                  child: Transform.scale(
                    scale: 1 - 0.12 * down,
                    child: const Icon(Icons.touch_app_rounded,
                        size: 15, color: Colors.white),
                  ),
                );
              },
            ),
            const SizedBox(width: 6),
            const Text('Hold the heart to open it',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    ));
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
  _HeartPainter(this.accent, [this.light = Offset.zero]);
  final Color accent;

  /// Where the light leans (-1..1), from the hover tilt: the sheen and
  /// sparkle slide a little toward it.
  final Offset light;

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
    final lean = Offset(light.dx * w * 0.07, light.dy * h * 0.06);
    final hlCenter = Offset(w * 0.33, h * 0.22) + lean;
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
    final hl2 = Offset(w * 0.66, h * 0.26) + lean * 0.6;
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
      Offset(w * 0.3, h * 0.18) + lean,
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
  bool shouldRepaint(_HeartPainter old) =>
      old.accent != accent || old.light != light;
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
  String? from,
  DateTime? sentAt,
  VoidCallback? onReply,
  ValueChanged<String>? onReact,
  VoidCallback? onKeep,
  VoidCallback? onSendBack,
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
      from: from,
      sentAt: sentAt,
      onReply: onReply,
      onReact: onReact,
      onKeep: onKeep,
      onSendBack: onSendBack,
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
    this.from,
    this.sentAt,
    this.onReply,
    this.onReact,
    this.onKeep,
    this.onSendBack,
  });
  final Rect originRect;
  final String text;
  final Color accent;
  final HeartMood mood;
  final String? from;
  final DateTime? sentAt;
  final VoidCallback onClosed;
  final VoidCallback? onReply;
  final ValueChanged<String>? onReact;
  final VoidCallback? onKeep;
  final VoidCallback? onSendBack;

  @override
  State<_HeartGenie> createState() => _HeartGenieState();
}

class _HeartGenieState extends State<_HeartGenie>
    with TickerProviderStateMixin {
  // Drains from full to empty over the idle window — the visible reseal.
  late final AnimationController _drain =
      AnimationController(vsync: this, duration: HeartLock.idleRelock);
  // The spotlight's soft lub-dub around the heart the letter came from.
  late final AnimationController _beat = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still) {
      _beat.stop();
    } else if (!_beat.isAnimating) {
      _beat.repeat();
    }
  }

  static double _lubDub(double t) {
    double bump(double a, double b) {
      if (t < a || t > b) return 0;
      return math.sin((t - a) / (b - a) * math.pi);
    }
    return bump(0.0, 0.18) + 0.7 * bump(0.18, 0.38);
  }
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
    HeartLock.instance.relockEpoch.addListener(_closeNow);
    HeartLock.instance.noteOpened(); // screenshot-proof while the letter is up
  }

  void _armIdle() {
    _idle?.cancel();
    _idle = Timer(HeartLock.idleRelock, _close);
    _drain.forward(from: 0);
  }

  /// App backgrounded: no frames are drawn while paused, so an animated
  /// close wouldn't finish before the app-switcher snapshot — close at once.
  void _closeNow() {
    if (_closing) return;
    _closing = true;
    _idle?.cancel();
    _c.value = 0;
    widget.onClosed();
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
    HeartLock.instance.noteClosed();
    HeartLock.instance.relockEpoch.removeListener(_closeNow);
    _idle?.cancel();
    _drain.dispose();
    _beat.dispose();
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
              // The dark backdrop keeps a soft, gently beating opening around
              // the heart this letter came from — you always see which heart
              // you're reading, and the letter folds back into that spot.
              Positioned.fill(
                child: GestureDetector(
                  onTap: _close,
                  child: RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: _beat,
                      builder: (context, _) => CustomPaint(
                        painter: _SpotlightScrim(
                          hole: widget.originRect.shortestSide >= 24
                              ? widget.originRect
                              : null,
                          alpha: 0.6 * fade,
                          pulse: _lubDub(_beat.value),
                          accent: widget.accent,
                        ),
                      ),
                    ),
                  ),
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

  // Act right away (don't wait on the fold-back animation — if it never
  // completes, the action would never run), then fold the card away.
  Future<void> _after(VoidCallback fn) async {
    HapticFeedback.selectionClick();
    fn();
    await _close();
  }

  /// Quick loving reactions — one soft row right under the words.
  Widget _reactions() {
    const reactions = ['❤️', '😍', '🥹', '😘', '🙏'];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final e in reactions)
            InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _after(() => widget.onReact!(e)),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Text(e, style: const TextStyle(fontSize: 21)),
              ),
            ),
        ],
      ),
    );
  }

  /// One action row: Reply · ♥ Send a heart back · Keepsake. The heart is
  /// the clear main action; on a narrow card the side two become round icon
  /// buttons.
  Widget _actionRow(bool narrow) {
    final white = Colors.white.withValues(alpha: 0.92);
    final a = widget.accent;
    Widget side(IconData icon, String label, VoidCallback onTap) {
      final child = narrow
          ? Padding(
              padding: const EdgeInsets.all(10),
              child: Icon(icon, size: 18, color: white),
            )
          : Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 15, color: white),
                  const SizedBox(width: 6),
                  Text(label,
                      style: TextStyle(
                          color: white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            );
      return Tooltip(
        message: label,
        child: Material(
          color: Colors.white.withValues(alpha: 0.10),
          shape: narrow
              ? CircleBorder(
                  side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.18)))
              : StadiumBorder(
                  side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.18))),
          child: InkWell(
            customBorder:
                narrow ? const CircleBorder() : const StadiumBorder(),
            onTap: onTap,
            child: child,
          ),
        ),
      );
    }

    final main = widget.onSendBack == null
        ? null
        : DecoratedBox(
            // Raised, lit key — same 3D language as the rest of Aluta.
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.lerp(a, Colors.white, 0.34)!,
                  Color.lerp(a, Colors.white, 0.12)!,
                  a,
                ],
              ),
              border:
                  Border.all(color: Colors.white.withValues(alpha: 0.35)),
              boxShadow: [
                BoxShadow(
                  color: a.withValues(alpha: 0.45),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () => _after(widget.onSendBack!),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.favorite_rounded,
                          size: 17, color: readableOn(a)),
                      const SizedBox(width: 7),
                      Text('Send a heart back',
                          style: TextStyle(
                              color: readableOn(a),
                              fontSize: 13.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.2)),
                    ],
                  ),
                ),
              ),
            ),
          );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.onReply != null) ...[
          side(Icons.reply_rounded, 'Reply', () => _after(widget.onReply!)),
          const SizedBox(width: 10),
        ],
        ?main,
        if (widget.onKeep != null) ...[
          const SizedBox(width: 10),
          side(Icons.auto_awesome_rounded, 'Keepsake',
              () => _after(widget.onKeep!)),
        ],
      ],
    );
  }

  /// "✨ Listen to understand\n…" → a title line and the body.
  static (String?, String) _split(String t) {
    final i = t.indexOf('\n');
    if (i > 0 && i <= 64) {
      final head = t.substring(0, i).trim();
      final body = t.substring(i + 1).trim();
      if (head.isNotEmpty && body.isNotEmpty) return (head, body);
    }
    return (null, t.trim());
  }

  String _byline() {
    final parts = <String>[];
    final from = widget.from?.trim();
    if (from != null && from.isNotEmpty) parts.add('from $from');
    final at = widget.sentAt;
    if (at != null) parts.add(heartSentLabel(at));
    return parts.join(' · ');
  }

  Widget _card(BuildContext context, double words) {
    final size = MediaQuery.of(context).size;
    final a = widget.accent;
    final width = (size.width * 0.84).clamp(260.0, 430.0);
    final narrow = width < 360;
    final (title, body) = _split(widget.text);
    final byline = _byline();
    final soft = Color.lerp(a, Colors.white, 0.62)!;
    final hasActions = widget.onReply != null ||
        widget.onKeep != null ||
        widget.onSendBack != null;
    return Material(
      color: Colors.transparent,
      child: Container(
        width: width,
        constraints: BoxConstraints(maxHeight: size.height * 0.7),
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
                  bottom: 14, right: 10, child: _CardMotifs(flip: true)),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header: glossy heart medallion + who / when.
                    Container(
                      width: 48,
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.10),
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.20)),
                      ),
                      child: widget.mood.icon == Icons.favorite_rounded
                          ? Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: GlossyHeart(
                                  size: 26,
                                  color: Color.lerp(a, Colors.white, 0.18)!),
                            )
                          : Icon(widget.mood.icon, size: 22, color: soft),
                    ),
                    const SizedBox(height: 9),
                    Text.rich(
                      TextSpan(children: [
                        TextSpan(
                          text: widget.mood.title,
                          style: TextStyle(
                            color: soft,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.4,
                          ),
                        ),
                        if (byline.isNotEmpty)
                          TextSpan(
                            text: '  ·  $byline',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.62),
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0.2,
                            ),
                          ),
                      ]),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 16),
                    // The words — calm and readable; long notes scroll.
                    Flexible(
                      child: Opacity(
                        opacity: words,
                        child: Transform.translate(
                          offset: Offset(0, (1 - words) * 10),
                          child: SingleChildScrollView(
                            child: Column(
                              children: [
                                if (title != null) ...[
                                  Text(
                                    title,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 17.5,
                                      height: 1.3,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                ],
                                SizedBox(
                                  width: double.infinity,
                                  child: Text(
                                    body,
                                    textAlign: body.length > 160
                                        ? TextAlign.start
                                        : TextAlign.center,
                                    style: TextStyle(
                                      color:
                                          Colors.white.withValues(alpha: 0.90),
                                      fontSize: title == null ? 16.5 : 15.5,
                                      height: 1.55,
                                      fontWeight: FontWeight.w400,
                                      letterSpacing: 0.1,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (widget.onReact != null) ...[
                      const SizedBox(height: 16),
                      _reactions(),
                    ],
                    if (hasActions) ...[
                      const SizedBox(height: 14),
                      _actionRow(narrow),
                    ],
                    const SizedBox(height: 14),
                    // The visible reseal: a countdown that restarts on touch.
                    AnimatedBuilder(
                      animation: _drain,
                      builder: (context, _) {
                        final left = HeartLock.idleRelock.inSeconds *
                            (1 - _drain.value);
                        final secs = left.ceil();
                        final label =
                            '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}';
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.lock_clock_rounded,
                                size: 11,
                                color: Colors.white.withValues(alpha: 0.6)),
                            const SizedBox(width: 5),
                            Text(
                              'reseals in $label · tap outside to close',
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.62),
                                  fontSize: 10.5,
                                  letterSpacing: 0.3,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures()
                                  ]),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
              // Drain line along the bottom edge.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 3,
                child: AnimatedBuilder(
                  animation: _drain,
                  builder: (context, _) => Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: (1 - _drain.value).clamp(0.0, 1.0),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [
                            Color.lerp(a, Colors.white, 0.35)!,
                            a,
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The letter's backdrop: a dark scrim with a soft lit opening around the
/// source heart, plus a faint accent glow that beats.
class _SpotlightScrim extends CustomPainter {
  _SpotlightScrim({
    required this.hole,
    required this.alpha,
    required this.pulse,
    required this.accent,
  });

  final Rect? hole;
  final double alpha, pulse;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final full = Offset.zero & size;
    final dark = Colors.black.withValues(alpha: alpha.clamp(0.0, 1.0));
    final h = hole;
    if (h == null) {
      canvas.drawRect(full, Paint()..color = dark);
      return;
    }
    final c = h.center;
    final r = h.longestSide * 0.58 * (1 + 0.05 * pulse);
    canvas.drawRect(
      full,
      Paint()
        ..shader = ui.Gradient.radial(
          c,
          r * 1.9,
          [Colors.transparent, Colors.transparent, dark],
          const [0.0, 0.5, 1.0],
        ),
    );
    // A soft beating halo ring around the heart (not over it).
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..color = accent.withValues(
            alpha: (alpha / 0.6) * (0.18 + 0.20 * pulse))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );
  }

  @override
  bool shouldRepaint(_SpotlightScrim o) =>
      o.hole != hole ||
      o.alpha != alpha ||
      o.pulse != pulse ||
      o.accent != accent;
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
