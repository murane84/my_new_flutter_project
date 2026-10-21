import 'dart:async';
import 'package:flutter/material.dart';
import '../services/app_busy.dart';

/// A global, app-wide busy indicator: a small centred spinner that appears
/// whenever a background task (see [appBusy]) runs beyond a brief moment, so the
/// app never looks idle-but-ready while it is actually still working.
///
/// Non-blocking (taps pass straight through) and delayed, so quick (<~300ms)
/// tasks never flash it. Mounted once, app-wide, from MaterialApp.builder.
class BusyOverlay extends StatefulWidget {
  const BusyOverlay({super.key, required this.child});
  final Widget child;

  @override
  State<BusyOverlay> createState() => _BusyOverlayState();
}

class _BusyOverlayState extends State<BusyOverlay> {
  bool _show = false;
  Timer? _delay;

  @override
  void initState() {
    super.initState();
    appBusy.major.addListener(_onBusy);
    splashOnScreen.addListener(_onBusy);
    _onBusy();
  }

  void _onBusy() {
    final busy = appBusy.major.value > 0 && splashOnScreen.value == 0;
    if (busy) {
      // Only reveal once the work has lasted past a brief window, so a fast op
      // doesn't flicker a spinner on screen.
      _delay ??= Timer(const Duration(milliseconds: 300), () {
        _delay = null;
        if (mounted &&
            appBusy.major.value > 0 &&
            splashOnScreen.value == 0 &&
            !_show) {
          setState(() => _show = true);
        }
      });
    } else {
      _delay?.cancel();
      _delay = null;
      // Deferred: this can fire from a splash's initState/dispose (mid-build).
      if (_show) {
        Future.microtask(() {
          if (mounted && _show) setState(() => _show = false);
        });
      }
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    appBusy.major.removeListener(_onBusy);
    splashOnScreen.removeListener(_onBusy);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_show)
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: const Duration(milliseconds: 160),
                  builder: (context, t, child) =>
                      Opacity(opacity: t, child: child),
                  child: _card(context),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _card(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Branded "big moment" loader (back online, opening the app): the Aluta
    // mark sits still in the middle while a brand ring sweeps around it.
    return Container(
      width: 68,
      height: 68,
      decoration: BoxDecoration(
        color: (isDark ? const Color(0xFF1C1B1F) : Colors.white)
            .withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: scheme.primary.withValues(alpha: isDark ? 0.25 : 0.12)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.18),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 50,
            height: 50,
            child: CircularProgressIndicator(
              strokeWidth: 2.6,
              strokeCap: StrokeCap.round,
              backgroundColor: scheme.primary.withValues(alpha: 0.12),
              valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
            ),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(9),
            child: Image.asset(
              'assets/images/logo.png',
              width: 30,
              height: 30,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => Icon(Icons.favorite_rounded,
                  size: 18, color: scheme.primary),
            ),
          ),
        ],
      ),
    );
  }
}
