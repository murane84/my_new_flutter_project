import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../utils/prefs_now.dart';
import 'account_prefs.dart';
import 'plan_limits.dart';

/// The app's text style (Appearance → Text style). [aluta] — today's font —
/// is the default; the others are bundled, so they work offline and on web.
enum AlutaFont { aluta, harmony, soft, easyRead }

extension AlutaFontInfo on AlutaFont {
  String get title => switch (this) {
        AlutaFont.aluta => 'Aluta',
        AlutaFont.harmony => 'Harmony',
        AlutaFont.soft => 'Soft',
        AlutaFont.easyRead => 'Easy read',
      };

  String get blurb => switch (this) {
        AlutaFont.aluta => 'Today’s font — the default',
        AlutaFont.harmony =>
          'Aluta’s own: a calm book serif, easy on the eyes in messages, '
              'heart dots in headings',
        AlutaFont.soft => 'Rounded and warm',
        AlutaFont.easyRead =>
          'Made so letters never mix up (I l 1 · O 0) — kind to tired eyes',
      };

  /// The family for body text (null = the platform default).
  String? family(Brightness b) => switch (this) {
        AlutaFont.aluta => null,
        // Light text on dark reads thinner → a hair heavier cut.
        AlutaFont.harmony =>
          b == Brightness.dark ? 'HarmonyDark' : 'Harmony',
        AlutaFont.soft => 'Nunito',
        AlutaFont.easyRead => 'AtkinsonHyperlegible',
      };

  /// Big headings: Harmony Display (heart dots) for Harmony.
  String? headingFamily(Brightness b) =>
      this == AlutaFont.harmony ? 'HarmonyDisplay' : family(b);

  /// A Together perk.
  bool get paid => this == AlutaFont.harmony;
}

class TextStylePref {
  TextStylePref._();
  static final TextStylePref instance = TextStylePref._();

  static const String key = 'text_style_v1';

  /// What I picked (kept even while my plan can't show it).
  final ValueNotifier<AlutaFont> chosen =
      ValueNotifier<AlutaFont>(AlutaFont.aluta);

  /// What the app paints: Harmony only while my plan includes it — after a
  /// lapse it goes back to Aluta and comes back by itself on renewal.
  final ValueNotifier<AlutaFont> shown =
      ValueNotifier<AlutaFont>(AlutaFont.aluta);

  bool _started = false;

  bool get hasHarmony => PlanLimits.instance.of('harmony_font', 0) != 0;

  void start() {
    if (_started) return;
    _started = true;
    _read();
    PlanLimits.instance.changed.addListener(refresh);
    AccountPrefs.onRestore(_read);
    _registerLicences();
  }

  void _read() {
    final raw = prefsNow?.getString(key);
    chosen.value = AlutaFont.values.firstWhere((f) => f.name == raw,
        orElse: () => AlutaFont.aluta);
    refresh();
  }

  void refresh() {
    final c = chosen.value;
    shown.value = (c.paid && !hasHarmony) ? AlutaFont.aluta : c;
  }

  Future<void> choose(AlutaFont f) async {
    chosen.value = f;
    try {
      await prefsNow?.setString(key, f.name);
    } catch (_) {}
    AccountPrefs.touch();
    refresh();
  }

  /// [t] with the chosen family for body text and, for Harmony, Harmony
  /// Display on the big heading roles. Emoji fallback is kept (it rides on
  /// fontFamilyFallback, which apply() leaves alone).
  static ThemeData apply(ThemeData t, AlutaFont f) {
    final b = t.brightness;
    final body = f.family(b);
    if (body == null) return t;
    final head = f.headingFamily(b);
    TextTheme theme(TextTheme x) {
      final o = x.apply(fontFamily: body);
      if (head == body) return o;
      TextStyle? h(TextStyle? s) => s?.copyWith(fontFamily: head);
      return o.copyWith(
        displayLarge: h(o.displayLarge),
        displayMedium: h(o.displayMedium),
        displaySmall: h(o.displaySmall),
        headlineLarge: h(o.headlineLarge),
        headlineMedium: h(o.headlineMedium),
        headlineSmall: h(o.headlineSmall),
        titleLarge: h(o.titleLarge),
      );
    }

    return t.copyWith(
      textTheme: theme(t.textTheme),
      primaryTextTheme: theme(t.primaryTextTheme),
      appBarTheme: t.appBarTheme.copyWith(
        titleTextStyle:
            t.appBarTheme.titleTextStyle?.copyWith(fontFamily: head),
      ),
    );
  }

  static void _registerLicences() {
    Stream<LicenseEntry> one(String pkg, String asset) async* {
      try {
        final text = await rootBundle.loadString(asset);
        yield LicenseEntryWithLineBreaks([pkg], text);
      } catch (_) {}
    }

    LicenseRegistry.addLicense(() => one(
        'Harmony font (based on Lora by The Lora Project Authors)',
        'assets/fonts/OFL-Harmony.txt'));
    LicenseRegistry.addLicense(
        () => one('Nunito font', 'assets/fonts/OFL-Nunito.txt'));
    LicenseRegistry.addLicense(() => one(
        'Atkinson Hyperlegible font',
        'assets/fonts/OFL-AtkinsonHyperlegible.txt'));
  }
}
