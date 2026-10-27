import 'package:flutter/material.dart';

/// The "this song is playing" mark used in every playlist / queue: four
/// small bars that gently dance (the web queue's look, now shared by the
/// Android / Windows playlist, Up next and Listen Together queues).
/// [scale] 1.0 = 3 px bars up to 19 px tall (for a ~42 px disc).
class PlayingBars extends StatefulWidget {
  const PlayingBars({super.key, required this.color, this.scale = 1.0});
  final Color color;
  final double scale;

  @override
  State<PlayingBars> createState() => _PlayingBarsState();
}

class _PlayingBarsState extends State<PlayingBars>
    with SingleTickerProviderStateMixin {
  static const int _n = 4;
  static const List<double> _phase = [0.0, 0.55, 0.25, 0.8];
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  // Triangle wave 0..1.
  double _wave(double x) {
    x = x - x.floorToDouble();
    return x < 0.5 ? x * 2 : (1 - x) * 2;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.scale;
    return RepaintBoundary(
      child: SizedBox(
        height: 19 * s,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (int i = 0; i < _n; i++) ...[
                Container(
                  width: 3 * s,
                  height: (6.0 + _wave(_c.value + _phase[i]) * 13.0) * s,
                  decoration: BoxDecoration(
                    color: widget.color,
                    borderRadius: BorderRadius.circular(2 * s),
                  ),
                ),
                if (i < _n - 1) SizedBox(width: 2.5 * s),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
