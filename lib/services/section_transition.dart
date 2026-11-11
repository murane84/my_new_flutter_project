import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_prefs.dart';

/// How a section change animates (Circle's All · Status · Listening ·
/// Circle). The user picks it in Appearance; default = the waveform wipe.
enum SectionTransitionStyle {
  slide,
  depth,
  ripple,
  wave,
  fade,
  equaliser,
  slideWave,
  cube,
}

extension SectionTransitionInfo on SectionTransitionStyle {
  String get label => switch (this) {
        SectionTransitionStyle.slide => 'Side slide',
        SectionTransitionStyle.depth => 'Depth stack',
        SectionTransitionStyle.ripple => 'Ripple from the button',
        SectionTransitionStyle.wave => 'Waveform wipe',
        SectionTransitionStyle.fade => 'Fade-through',
        SectionTransitionStyle.equaliser => 'Equaliser bars',
        SectionTransitionStyle.slideWave => 'Slide + wave',
        SectionTransitionStyle.cube => '3D turn',
      };

  String get blurb => switch (this) {
        SectionTransitionStyle.slide => 'Calm, slides in from its side',
        SectionTransitionStyle.depth => 'Sinks back, the next rises in front',
        SectionTransitionStyle.ripple => 'Spreads out from the button you tap',
        SectionTransitionStyle.wave =>
          'A sound-wave edge sweeps it in — Aluta default',
        SectionTransitionStyle.fade => 'Simplest — a soft fade',
        SectionTransitionStyle.equaliser => 'Rises in like equaliser bars',
        SectionTransitionStyle.slideWave =>
          'The slide, with a faint wave passing',
        SectionTransitionStyle.cube => 'Turns like a cube face',
      };
}

class SectionTransition {
  SectionTransition._() {
    _load();
    AccountPrefs.onRestore(_load);
  }
  static final SectionTransition instance = SectionTransition._();

  static const _k = 'section_transition_v1';
  // The waveform wipe: Aluta's music identity, follows the finger on a
  // swipe, and hands over with no overlap. (A choice someone made stays.)
  static const SectionTransitionStyle defaultStyle =
      SectionTransitionStyle.wave;

  /// The picker's order: the default first, the rest as listed.
  static List<SectionTransitionStyle> get pickerOrder => [
        defaultStyle,
        for (final s in SectionTransitionStyle.values)
          if (s != defaultStyle) s,
      ];

  final ValueNotifier<SectionTransitionStyle> style =
      ValueNotifier<SectionTransitionStyle>(defaultStyle);

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final name = p.getString(_k);
      style.value = SectionTransitionStyle.values
              .where((s) => s.name == name)
              .firstOrNull ??
          defaultStyle;
    } catch (_) {}
  }

  Future<void> set(SectionTransitionStyle s) async {
    style.value = s;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_k, s.name);
      AccountPrefs.touch();
    } catch (_) {}
  }
}
