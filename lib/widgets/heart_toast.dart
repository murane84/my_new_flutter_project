import 'dart:async';

import 'package:flutter/material.dart';

import 'glossy_heart.dart';

/// The "Neema opened your secret heart" moment — a small glossy pill that
/// drops in at the TOP of the screen (so an open keyboard never hides it),
/// gives one heartbeat, and slips away. Compact on desktop too (max 380 px),
/// instead of a full-width snackbar. Tap to dismiss.
void showHeartOpenedToast(BuildContext context, String who) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late OverlayEntry entry;
  var removed = false;
  void remove() {
    if (removed) return;
    removed = true;
    try {
      entry.remove();
    } catch (_) {}
  }

  entry = OverlayEntry(builder: (_) => _HeartToast(who: who, onDone: remove));
  overlay.insert(entry);
}

class _HeartToast extends StatefulWidget {
  const _HeartToast({required this.who, required this.onDone});
  final String who;
  final VoidCallback onDone;

  @override
  State<_HeartToast> createState() => _HeartToastState();
}

class _HeartToastState extends State<_HeartToast>
    with TickerProviderStateMixin {
  late final AnimationController _in = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 360));
  late final AnimationController _beat = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 700));
  // lub (big) – dub (smaller) – rest.
  late final Animation<double> _lubDub = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.2), weight: 20),
    TweenSequenceItem(tween: Tween(begin: 1.2, end: 1.0), weight: 15),
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.12), weight: 15),
    TweenSequenceItem(tween: Tween(begin: 1.12, end: 1.0), weight: 20),
    TweenSequenceItem(tween: ConstantTween(1.0), weight: 30),
  ]).animate(CurvedAnimation(parent: _beat, curve: Curves.easeInOut));
  Timer? _hold;

  @override
  void initState() {
    super.initState();
    _in.forward().then((_) {
      if (mounted) _beat.forward();
    });
    _hold = Timer(const Duration(milliseconds: 3800), _close);
  }

  Future<void> _close() async {
    _hold?.cancel();
    if (!mounted) return;
    await _in.reverse();
    widget.onDone();
  }

  @override
  void dispose() {
    _hold?.cancel();
    _in.dispose();
    _beat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final accent = scheme.primary;
    final top = MediaQuery.of(context).padding.top + 12;
    final curve = CurvedAnimation(parent: _in, curve: Curves.easeOutBack);
    return Positioned(
      top: top,
      left: 16,
      right: 16,
      child: Center(
        child: FadeTransition(
          opacity: _in,
          child: AnimatedBuilder(
            animation: curve,
            builder: (_, child) => Transform.translate(
                offset: Offset(0, -18 * (1 - curve.value)), child: child),
            child: Material(
              color: Colors.transparent,
              child: GestureDetector(
                onTap: _close,
                onVerticalDragEnd: (_) => _close(),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(12, 10, 18, 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(28),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color.alphaBlend(
                              accent.withValues(alpha: dark ? 0.22 : 0.10),
                              scheme.surface),
                          Color.alphaBlend(
                              accent.withValues(alpha: dark ? 0.32 : 0.18),
                              scheme.surfaceContainerHighest),
                        ],
                      ),
                      border: Border.all(
                          color: accent.withValues(alpha: 0.35)),
                      boxShadow: [
                        BoxShadow(
                          color: accent.withValues(alpha: 0.30),
                          blurRadius: 22,
                          offset: const Offset(0, 8),
                          spreadRadius: -4,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // One soft lub-dub as it lands.
                        ScaleTransition(
                          scale: _lubDub,
                          child: GlossyHeart(size: 26, color: accent),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text.rich(
                            TextSpan(children: [
                              TextSpan(
                                  text: widget.who,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800)),
                              const TextSpan(
                                  text: ' opened your secret heart 💗'),
                            ]),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13.5, color: scheme.onSurface),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
