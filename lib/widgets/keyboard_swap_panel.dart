import 'dart:async';

import 'package:flutter/material.dart';

import '../utils/motion.dart';
import '../utils/prefs_now.dart';

/// An emoji panel that TRADES PLACES with the keyboard (as the chat's does):
///  • it takes the keyboard's own height (learned by the chat, kept across
///    launches), so swapping one for the other never moves what's above;
///  • while the keyboard drops (😊) or rises (⌨), it shows only the part the
///    keyboard doesn't cover, frame by frame — no jump, no gap;
///  • on ⌨ it stays until the keyboard has risen into its place (or gives
///    way after a moment if none rises).
/// Phones only; desktop uses the floating emoji card.
class KeyboardSwapPanel extends StatefulWidget {
  const KeyboardSwapPanel(
      {super.key, required this.open, required this.builder});

  final bool open;

  /// Builds the panel at its full [height].
  final Widget Function(double height) builder;

  @override
  State<KeyboardSwapPanel> createState() => _KeyboardSwapPanelState();
}

class _KeyboardSwapPanelState extends State<KeyboardSwapPanel>
    with WidgetsBindingObserver {
  bool _closing = false;
  Timer? _giveWay;

  double get _full =>
      (prefsNow?.getDouble('kb_height_v1') ?? 300).clamp(260.0, 420.0);

  double _inset() {
    final v = View.of(context);
    return v.viewInsets.bottom / v.devicePixelRatio;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _giveWay?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(KeyboardSwapPanel old) {
    super.didUpdateWidget(old);
    if (old.open && !widget.open) {
      _closing = true;
      _giveWay?.cancel();
      _giveWay = Timer(const Duration(milliseconds: 900), _finish);
    } else if (!old.open && widget.open) {
      _closing = false;
      _giveWay?.cancel();
    }
  }

  void _finish() {
    _giveWay?.cancel();
    if (mounted && _closing) setState(() => _closing = false);
  }

  @override
  void didChangeMetrics() {
    if (!mounted || !(widget.open || _closing)) return;
    if (_closing && _inset() >= _full - 2) {
      _finish(); // the keyboard now fills the panel's place
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final showing = widget.open || _closing;
    final full = _full;
    final inset = _inset();
    final h = showing ? (full - inset).clamp(0.0, full) : 0.0;
    return AnimatedContainer(
      duration: inset > 0 ? Duration.zero : Motion.standard,
      curve: Motion.enter,
      height: h,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topCenter,
          minHeight: full,
          maxHeight: full,
          child: showing ? widget.builder(full) : const SizedBox.shrink(),
        ),
      ),
    );
  }
}
