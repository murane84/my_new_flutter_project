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
    appBusy.count.addListener(_onBusy);
    _onBusy();
  }

  void _onBusy() {
    final busy = appBusy.count.value > 0;
    if (busy) {
      // Only reveal once the work has lasted past a brief window, so a fast op
      // doesn't flicker a spinner on screen.
      _delay ??= Timer(const Duration(milliseconds: 300), () {
        _delay = null;
        if (mounted && appBusy.count.value > 0 && !_show) {
          setState(() => _show = true);
        }
      });
    } else {
      _delay?.cancel();
      _delay = null;
      if (_show && mounted) setState(() => _show = false);
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    appBusy.count.removeListener(_onBusy);
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
    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        color: (isDark ? const Color(0xFF1C1B1F) : Colors.white)
            .withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.18),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: CircularProgressIndicator(
          strokeWidth: 2.6,
          valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
        ),
      ),
    );
  }
}
