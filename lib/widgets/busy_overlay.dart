import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/aluta_mood.dart';
import '../services/app_busy.dart';
import 'aluta_loader.dart';
import '../utils/motion.dart';
import '../utils/radii.dart';

/// A global, app-wide busy indicator — the Aluta logo loader, centred, when a
/// MAJOR background task (see [appBusy.runMajor]) runs beyond a brief moment.
///
/// It has moods rather than one mechanical spin: each appearance picks a
/// style for the time of day ([AlutaMood.loaderStyle]). It never flashes —
/// it waits ~300ms to appear and, once up, stays at least ~450ms — rises in
/// softly, and on finishing closes its ring with a little heart before
/// fading. A wait earns a caption after ~2s (what's happening, or a mood
/// line).
///
/// A SLOW network never holds the middle of the screen: past ~6s (or at once
/// for a reconnect) the loader steps aside — one slim pill at the top edge for
/// a couple of seconds, then nothing while the work carries on in the
/// background. It stays quiet for the rest of that slow spell (retries and
/// flaps don't bring it back) until the app has been idle ~10s.
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

  // Slow-network spell: once the loader stepped aside, stay out of the way
  // until things have been calm for a while.
  bool _quiet = false;
  Timer? _calmTimer, _pillTimer, _reconnectTimer;
  String? _pill; // the slim top-edge hint, or null
  bool _pillUp = false;

  static bool _isReconnect(String? label) =>
      (label ?? '').toLowerCase().contains('reconnect');

  bool get _busy => appBusy.major.value > 0 &&
      splashOnScreen.value == 0 &&
      menusOnScreen.value == 0 &&
      discHostsBusy.value == 0;

  @override
  void initState() {
    super.initState();
    appBusy.major.addListener(_onBusy);
    appBusy.majorLabel.addListener(_onLabel);
    splashOnScreen.addListener(_onBusy);
    menusOnScreen.addListener(_onBusy);
    discHostsBusy.addListener(_onBusy);
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

  /// One slim hint at the top edge, ~2.5 s, then gone. Taps pass through.
  void _flashPill(String text) {
    _pillTimer?.cancel();
    setState(() {
      _pill = text;
      _pillUp = true;
    });
    _pillTimer = Timer(const Duration(milliseconds: 2500), () {
      if (!mounted) return;
      setState(() => _pillUp = false);
      _pillTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) setState(() => _pill = null);
      });
    });
  }

  /// The loader steps aside: hide it (no heart — the work isn't done), one
  /// top-edge hint, then quiet for the rest of this slow spell.
  void _stepAside() {
    if (!mounted) return;
    _quiet = true;
    _delay?.cancel();
    _delay = null;
    _capTimer?.cancel();
    _slowTimer?.cancel();
    _hideTimer?.cancel();
    if (_phase != _Phase.hidden) {
      setState(() => _visible = false);
      _hideTimer = Timer(const Duration(milliseconds: 220), () {
        if (mounted && _quiet) {
          setState(() {
            _phase = _Phase.hidden;
            _caption = null;
          });
        }
      });
    }
    _flashPill(AlutaMood.slowCaption());
  }

  void _onBusy() {
    if (_busy) {
      _calmTimer?.cancel();
      _calmTimer = null;
      if (_quiet) return; // already stepped aside this spell
      if (_isReconnect(appBusy.majorLabel.value) && _phase == _Phase.hidden) {
        // Reconnecting never takes the middle of the screen: a quick one
        // finishes unseen; a slow one gets the top-edge hint, once.
        _reconnectTimer ??= Timer(const Duration(seconds: 2), () {
          _reconnectTimer = null;
          if (mounted && _busy && !_quiet) _stepAside();
        });
        return;
      }
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
        _slowTimer = Timer(const Duration(seconds: 6), () {
          if (mounted && _phase == _Phase.shown && _busy) _stepAside();
        });
      });
    } else {
      _delay?.cancel();
      _delay = null;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      if (_quiet) {
        // Calm for ~10 s in a row → the spell is over.
        _calmTimer ??= Timer(const Duration(seconds: 10), () {
          _calmTimer = null;
          _quiet = false;
        });
        return;
      }
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
    for (final t in [
      _delay,
      _capTimer,
      _slowTimer,
      _hideTimer,
      _calmTimer,
      _pillTimer,
      _reconnectTimer,
    ]) {
      t?.cancel();
    }
    appBusy.major.removeListener(_onBusy);
    appBusy.majorLabel.removeListener(_onLabel);
    splashOnScreen.removeListener(_onBusy);
    menusOnScreen.removeListener(_onBusy);
    discHostsBusy.removeListener(_onBusy);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Stack(
      children: [
        widget.child,
        if (_pill != null)
          Positioned(
            top: top + 8,
            left: 16,
            right: 16,
            child: IgnorePointer(
              child: Center(
                child: AnimatedSlide(
                  offset: _pillUp ? Offset.zero : const Offset(0, -0.6),
                  duration: Motion.standard,
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    opacity: _pillUp ? 1 : 0,
                    duration: Motion.standard,
                    child: Material(
                      type: MaterialType.transparency,
                      child: _captionPill(context, _pill!),
                    ),
                  ),
                ),
              ),
            ),
          ),
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
                        duration: Motion.standard,
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
      borderRadius: BorderRadius.circular(Radii.lg),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 260),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: isDark
              ? Colors.black.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.7),
          child: AnimatedSwitcher(
            duration: Motion.standard,
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
