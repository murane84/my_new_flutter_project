import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_prefs.dart';

/// How a section change animates (Circle's All · Status · Listening ·
/// Circle). The user picks it in Appearance; default = slide + wave.
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
        SectionTransitionStyle.wave => 'A sound-wave edge sweeps it in',
        SectionTransitionStyle.fade => 'Simplest — a soft fade',
        SectionTransitionStyle.equaliser => 'Rises in like equaliser bars',
        SectionTransitionStyle.slideWave =>
          'The slide, with a faint wave passing — Aluta default',
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
  static const SectionTransitionStyle defaultStyle =
      SectionTransitionStyle.slideWave;

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
