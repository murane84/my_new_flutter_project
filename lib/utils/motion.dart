import 'package:flutter/animation.dart';

/// Aluta's ONE motion system: every button, sheet, chip and page moves to
/// the same few speeds, so the whole app shares one rhythm.
///
///  • [instant]    — taps, presses, tiny state flips (a tick, a check)
///  • [quick]      — chips, icons, small fades and colour changes
///  • [standard]   — most things that move: rows, panels, switches
///  • [emphasized] — something arriving that deserves a beat: sheets, cards
///  • [slow]       — big moves: whole sections, full panels
///
/// Curves: [enter] for things arriving (fast start, soft landing), [exit]
/// for things leaving (soft start, quick away), [move] for things changing
/// place on screen, [spring] for a playful little overshoot.
abstract final class Motion {
  static const Duration instant = Duration(milliseconds: 120);
  static const Duration quick = Duration(milliseconds: 180);
  static const Duration standard = Duration(milliseconds: 260);
  static const Duration emphasized = Duration(milliseconds: 360);
  static const Duration slow = Duration(milliseconds: 440);

  static const Curve enter = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;
  static const Curve move = Curves.easeInOutCubic;
  static const Curve spring = Curves.easeOutBack;
}
