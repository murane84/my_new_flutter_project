import 'dart:math' as math;

/// Aluta's mood of the moment — so the welcome, the loader and its captions
/// feel like the app noticed the time of day, not like a machine repeating
/// itself. Everything here is local and cheap: the clock, the weekday and a
/// little randomness that never picks the same line twice in a row.

enum AlutaMoment { dawn, morning, afternoon, evening, night }

/// How the logo loader moves this time.
enum LoaderStyle { heartbeat, ripple, breathe, orbit }

class AlutaMood {
  AlutaMood._();

  static final math.Random _rng = math.Random();
  static final Map<String, String> _lastLine = {};
  static LoaderStyle? _lastStyle;

  static AlutaMoment momentAt([DateTime? at]) {
    final h = (at ?? DateTime.now()).hour;
    if (h >= 5 && h < 8) return AlutaMoment.dawn;
    if (h >= 8 && h < 12) return AlutaMoment.morning;
    if (h >= 12 && h < 17) return AlutaMoment.afternoon;
    if (h >= 17 && h < 21) return AlutaMoment.evening;
    return AlutaMoment.night;
  }

  static AlutaMoment get moment => momentAt();

  /// Pick from [options] without repeating the last pick for [slot].
  static String _pick(String slot, List<String> options) {
    if (options.isEmpty) return '';
    if (options.length == 1) return options.first;
    final last = _lastLine[slot];
    String s;
    var guard = 0;
    do {
      s = options[_rng.nextInt(options.length)];
    } while (s == last && ++guard < 6);
    _lastLine[slot] = s;
    return s;
  }

  /// The welcome line, e.g. on the preload screen. [first] may be empty.
  static String greeting(String first) {
    final n = first.trim();
    final you = n.isEmpty ? '' : ', $n';
    final now = DateTime.now();
    final wd = now.weekday;
    final lines = <String>[];
    switch (momentAt(now)) {
      case AlutaMoment.dawn:
        lines.addAll([
          'Up with the sun$you',
          'Early start$you? ☀️',
          'Habari za asubuhi$you',
          'A quiet morning with Aluta$you',
        ]);
        break;
      case AlutaMoment.morning:
        lines.addAll([
          'Good morning$you',
          'Morning tea and music$you? ☕',
          'Habari za asubuhi$you',
          'Fresh day, fresh tunes$you',
        ]);
        break;
      case AlutaMoment.afternoon:
        lines.addAll([
          'Good afternoon$you',
          'Lunch break with Aluta$you? 🍲',
          'Habari za mchana$you',
          'Afternoon catch-up$you',
        ]);
        break;
      case AlutaMoment.evening:
        lines.addAll([
          'Good evening$you',
          'Nice evening$you 🌇',
          'Habari za jioni$you',
          'Wind down with your circle$you',
        ]);
        break;
      case AlutaMoment.night:
        lines.addAll([
          'Late night tunes$you? 🌙',
          'Still up$you?',
          'Usiku mwema$you',
          'A calm night in$you',
        ]);
        break;
    }
    if (wd == DateTime.friday) lines.add('Happy Friday$you 🎉');
    if (wd == DateTime.sunday) lines.add('Slow Sunday$you');
    if (n.isNotEmpty) lines.add('Welcome back$you');
    return _pick('greet', lines);
  }

  /// The first stage line under the greeting while the app warms up.
  static String wakeLine({bool firstRun = false}) {
    if (firstRun) return 'Setting up your Aluta…';
    switch (moment) {
      case AlutaMoment.dawn:
      case AlutaMoment.morning:
        return _pick('wake', ['Opening the curtains…', 'Brewing your feed…', 'Waking up…']);
      case AlutaMoment.afternoon:
        return _pick('wake', ['Catching you up…', 'Gathering your circle…', 'Warming up…']);
      case AlutaMoment.evening:
        return _pick('wake', ['Lighting the lamps…', 'Gathering your circle…', 'Settling in…']);
      case AlutaMoment.night:
        return _pick('wake', ['Tiptoeing in…', 'Quietly catching up…', 'Dimming the lights…']);
    }
  }

  /// A loader style suited to the moment, never the same twice running.
  static LoaderStyle loaderStyle() {
    final m = moment;
    final pool = switch (m) {
      AlutaMoment.dawn => [LoaderStyle.breathe, LoaderStyle.heartbeat, LoaderStyle.orbit],
      AlutaMoment.morning => [LoaderStyle.orbit, LoaderStyle.heartbeat, LoaderStyle.ripple],
      AlutaMoment.afternoon => [LoaderStyle.orbit, LoaderStyle.ripple, LoaderStyle.heartbeat],
      AlutaMoment.evening => [LoaderStyle.ripple, LoaderStyle.heartbeat, LoaderStyle.breathe],
      AlutaMoment.night => [LoaderStyle.breathe, LoaderStyle.heartbeat],
    };
    LoaderStyle s;
    var guard = 0;
    do {
      s = pool[_rng.nextInt(pool.length)];
    } while (s == _lastStyle && pool.length > 1 && ++guard < 6);
    _lastStyle = s;
    return s;
  }

  /// Caption shown under the loader once a wait passes ~2s. [label] is what
  /// the app is doing (e.g. "Reconnecting"), when the caller gave one.
  static String waitCaption(String? label) {
    if (label != null && label.trim().isNotEmpty) return label.trim();
    switch (moment) {
      case AlutaMoment.dawn:
      case AlutaMoment.morning:
        return _pick('wait', ['One sip and we\'re there…', 'Getting things ready…', 'Almost there…']);
      case AlutaMoment.afternoon:
        return _pick('wait', ['Just a moment…', 'Catching up…', 'Almost there…']);
      case AlutaMoment.evening:
        return _pick('wait', ['Bringing your circle in…', 'Just a moment…', 'Almost there…']);
      case AlutaMoment.night:
        return _pick('wait', ['Quietly loading…', 'Just a moment…', 'Almost there…']);
    }
  }

  /// The first-message nudge in an empty chat: (button label, text it types).
  /// Deterministic per moment, so it never flickers on rebuild.
  static (String, String) opener() => switch (moment) {
        AlutaMoment.dawn ||
        AlutaMoment.morning =>
          ('Say good morning', 'Good morning ☀️'),
        AlutaMoment.afternoon => ('Say hi', 'Hi 👋'),
        AlutaMoment.evening => ('Say good evening', 'Good evening 🌇'),
        AlutaMoment.night => ('Say hey', 'Hey, still up? 🌙'),
      };

  /// After ~8s — gentle, honest about the network.
  static String slowCaption() => _pick('slow', [
        'Still working — your connection seems slow',
        'Hang on, the network is taking its time',
        'Still here, still loading…',
      ]);
}
