import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/aluta_mood.dart';
import '../services/app_busy.dart';
import 'aluta_loader.dart';

/// A global, app-wide busy indicator — the Aluta logo loader, centred, when a
/// MAJOR background task (see [appBusy.runMajor]) runs beyond a brief moment.
///
/// It has moods rather than one mechanical spin: each appearance picks a
/// style for the time of day ([AlutaMood.loaderStyle]). It never flashes —
/// it waits ~300ms to appear and, once up, stays at least ~450ms — rises in
/// softly, and on finishing closes its ring with a little heart before
/// fading. A long wait earns a caption (what's happening, or a mood line
/// after ~2s; an honest "slow connection" line after ~8s).
///
/// Non-blocking (taps pass straight through). Mounted once, app-wide, from
/// MaterialApp.builder; hidden while a full-screen splash is up.
class BusyOverlay extends StatefulWidget {
  const BusyOverlay({super.key, required this.child});
  final Widget child;

  @override
  State<BusyOverlay> createState() => _BusyOverlayState();
}

enum _Phase { hidden, shown, closing }

class _BusyOverlayState extends State<BusyOverlay> {
  _Phase _phase = _Phase.hidden;
  bool _visible = false; // drives the fade/scale (lags _phase on the way out)
  LoaderStyle _style = LoaderStyle.heartbeat;
  String? _caption;
  DateTime _shownAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _delay, _capTimer, _slowTimer, _hideTimer;

  bool get _busy => appBusy.major.value > 0 &&
      splashOnScreen.value == 0 &&
      menusOnScreen.value == 0;

  @override
  void initState() {
    super.initState();
    appBusy.major.addListener(_onBusy);
    appBusy.majorLabel.addListener(_onLabel);
    splashOnScreen.addListener(_onBusy);
    menusOnScreen.addListener(_onBusy);
    _onBusy();
  }

  // Deferred: busy changes can fire from a splash's initState/dispose.
  void _set(VoidCallback fn) => Future.microtask(() {
        if (mounted) setState(fn);
      });

  void _onLabel() {
    if (_caption != null && _slowTimer?.isActive == true) {
      _set(() => _caption = AlutaMood.waitCaption(appBusy.majorLabel.value));
    }
  }

  void _onBusy() {
    if (_busy) {
      _hideTimer?.cancel();
      if (_phase == _Phase.closing) {
        // Work resumed while saying goodbye → simply stay.
        _set(() {
          _phase = _Phase.shown;
          _visible = true;
        });
        return;
      }
      if (_phase == _Phase.shown) return;
      _delay ??= Timer(const Duration(milliseconds: 300), () {
        _delay = null;
        if (!mounted || !_busy || _phase != _Phase.hidden) return;
        _style = AlutaMood.loaderStyle();
        _shownAt = DateTime.now();
        setState(() {
          _phase = _Phase.shown;
          _visible = true;
          _caption = null;
        });
        _capTimer = Timer(const Duration(seconds: 2), () {
          if (mounted && _phase == _Phase.shown) {
            setState(() => _caption =
                AlutaMood.waitCaption(appBusy.majorLabel.value));
          }
        });
        _slowTimer = Timer(const Duration(seconds: 8), () {
          if (mounted && _phase == _Phase.shown) {
            setState(() => _caption = AlutaMood.slowCaption());
          }
        });
      });
    } else {
      _delay?.cancel();
      _delay = null;
      if (_phase != _Phase.shown) return;
      final left = const Duration(milliseconds: 450) -
          DateTime.now().difference(_shownAt);
      _hideTimer?.cancel();
      _hideTimer = Timer(left.isNegative ? Duration.zero : left, _close);
    }
  }

  void _close() {
    if (!mounted || _busy || _phase != _Phase.shown) return;
    _capTimer?.cancel();
    _slowTimer?.cancel();
    setState(() => _phase = _Phase.closing); // ring closes + heart pops
    _hideTimer = Timer(const Duration(milliseconds: 380), () {
      if (!mounted || _phase != _Phase.closing) return;
      setState(() => _visible = false); // fade out
      _hideTimer = Timer(const Duration(milliseconds: 220), () {
        if (mounted && _phase == _Phase.closing) {
          setState(() {
            _phase = _Phase.hidden;
            _caption = null;
          });
        }
      });
    });
  }

  @override
  void dispose() {
    for (final t in [_delay, _capTimer, _slowTimer, _hideTimer]) {
      t?.cancel();
    }
    appBusy.major.removeListener(_onBusy);
    appBusy.majorLabel.removeListener(_onLabel);
    splashOnScreen.removeListener(_onBusy);
    menusOnScreen.removeListener(_onBusy);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_phase != _Phase.hidden)
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: TweenAnimationBuilder<double>(
                  // Rise in (scale + fade) on show; fade out on goodbye.
                  tween: Tween(begin: 0.0, end: _visible ? 1.0 : 0.0),
                  duration: Duration(milliseconds: _visible ? 260 : 220),
                  curve: _visible ? Curves.easeOutBack : Curves.easeIn,
                  builder: (context, t, child) => Opacity(
                    opacity: t.clamp(0.0, 1.0),
                    child: Transform.scale(
                        scale: 0.85 + 0.15 * t, child: child),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AlutaLoader(
                        style: _style,
                        completing: _phase == _Phase.closing,
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        child: _caption == null
                            ? const SizedBox(width: 1)
                            : Padding(
                                padding: const EdgeInsets.only(top: 6),
                                // Above the Navigator: give text a Material.
                                child: Material(
                                  type: MaterialType.transparency,
                                  child: _captionPill(context, _caption!),
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _captionPill(BuildContext context, String text) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 260),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: isDark
              ? Colors.black.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.7),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            child: Text(
              text,
              key: ValueKey(text),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                decoration: TextDecoration.none,
                color: (isDark ? Colors.white : const Color(0xFF2B2829))
                    .withValues(alpha: 0.78),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
