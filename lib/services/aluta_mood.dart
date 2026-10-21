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

  /// A barely-there wash over chat wallpapers so the room follows the day:
  /// warm at dawn/morning, clear by afternoon, golden at evening, deep
  /// blue at night. Transparent = no wash.
  static Color wallpaperWash({required bool isDark}) => switch (moment) {
        AlutaMoment.dawn => const Color(0xFFFFB74D).withValues(alpha: 0.05),
        AlutaMoment.morning => const Color(0xFFFFE0B2).withValues(alpha: 0.05),
        AlutaMoment.afternoon => const Color(0x00000000),
        AlutaMoment.evening => const Color(0xFFFF8A65).withValues(alpha: 0.045),
        AlutaMoment.night => const Color(0xFF1A237E)
            .withValues(alpha: isDark ? 0.06 : 0.07),
      };

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
          'Umeamka mapema$you 🌅',
          'A quiet morning with Aluta$you',
          'Asubuhi njema$you',
        ]);
        break;
      case AlutaMoment.morning:
        lines.addAll([
          'Good morning$you',
          'Morning tea and music$you? ☕',
          'Habari za asubuhi$you',
          'Chai na muziki$you? ☕',
          'Fresh day, fresh tunes$you',
          'Siku njema$you ☀️',
        ]);
        break;
      case AlutaMoment.afternoon:
        lines.addAll([
          'Good afternoon$you',
          'Lunch break with Aluta$you? 🍲',
          'Habari za mchana$you',
          'Mchana mwema$you',
          'Afternoon catch-up$you',
          'Pumzika kidogo$you 🍲',
        ]);
        break;
      case AlutaMoment.evening:
        lines.addAll([
          'Good evening$you',
          'Nice evening$you 🌇',
          'Habari za jioni$you',
          'Jioni njema$you 🌇',
          'Wind down with your circle$you',
          'Karibu nyumbani$you',
        ]);
        break;
      case AlutaMoment.night:
        lines.addAll([
          'Late night tunes$you? 🌙',
          'Still up$you?',
          'Usiku mwema$you',
          'Bado uko macho$you? 🌙',
          'A calm night in$you',
          'Usiku wa utulivu$you',
        ]);
        break;
    }
    if (wd == DateTime.friday) {
      lines.addAll(['Happy Friday$you 🎉', 'Ijumaa njema$you 🎉']);
    }
    if (wd == DateTime.sunday) {
      lines.addAll(['Slow Sunday$you', 'Jumapili njema$you']);
    }
    if (n.isNotEmpty) lines.addAll(['Welcome back$you', 'Karibu tena$you']);
    return _pick('greet', lines);
  }

  /// The first stage line under the greeting while the app warms up.
  static String wakeLine({bool firstRun = false}) {
    if (firstRun) return 'Setting up your Aluta…';
    switch (moment) {
      case AlutaMoment.dawn:
      case AlutaMoment.morning:
        return _pick('wake', ['Opening the curtains…', 'Brewing your feed…', 'Tunaamka…', 'Waking up…']);
      case AlutaMoment.afternoon:
        return _pick('wake', ['Catching you up…', 'Gathering your circle…', 'Tunakuletea habari…', 'Warming up…']);
      case AlutaMoment.evening:
        return _pick('wake', ['Lighting the lamps…', 'Gathering your circle…', 'Tunawaita wapendwa…', 'Settling in…']);
      case AlutaMoment.night:
        return _pick('wake', ['Tiptoeing in…', 'Quietly catching up…', 'Taratibu…', 'Dimming the lights…']);
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
        return _pick('wait', ['One sip and we\'re there…', 'Getting things ready…', 'Subiri kidogo…', 'Almost there…']);
      case AlutaMoment.afternoon:
        return _pick('wait', ['Just a moment…', 'Catching up…', 'Karibu tunamaliza…', 'Almost there…']);
      case AlutaMoment.evening:
        return _pick('wait', ['Bringing your circle in…', 'Just a moment…', 'Kidogo tu…', 'Almost there…']);
      case AlutaMoment.night:
        return _pick('wait', ['Quietly loading…', 'Just a moment…', 'Polepole…', 'Almost there…']);
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
        'Mtandao uko polepole — bado tunajaribu',
        'Still here, still loading…',
      ]);

  // ── Welcome-back after a long time away ─────────────────────────────────
  /// [fromPartner] unread from the bonded partner; [others] unread from
  /// everyone else across [chats] conversations.
  static String awaySummary({
    required String me,
    String partner = '',
    int fromPartner = 0,
    int others = 0,
    int chats = 0,
  }) {
    final you = me.isEmpty ? '' : ', $me';
    String n(int c, String one, String many) => '$c ${c == 1 ? one : many}';
    if (partner.isNotEmpty && fromPartner > 0) {
      final m = n(fromPartner, 'message', 'messages');
      return _pick('away_p', [
        '$partner sent you $m while you were away 💌',
        '$partner amekutumia ujumbe $fromPartner ukiwa mbali 💌',
        'Welcome back$you — $partner left you $m 💞',
      ]);
    }
    if (others > 0) {
      return _pick('away_o', [
        'Welcome back$you — ${n(others, 'new message', 'new messages')}'
            '${chats > 1 ? ' in $chats chats' : ''}',
        'Karibu tena$you — ujumbe mpya $others unakusubiri',
        'Your circle missed you$you · ${n(others, 'new message', 'new messages')}',
      ]);
    }
    if (partner.isNotEmpty) {
      return _pick('away_q', [
        'Karibu tena$you — say hi to $partner? 👋',
        'All quiet$you. $partner might love a hello 💞',
        'Welcome back$you — send $partner a little heart?',
      ]);
    }
    return '';
  }

  // ── Welcome-back while music plays ───────────────────────────────────────
  /// Headline when the user comes back to Aluta with a song still playing.
  /// [partner] = first name of the bonded partner (may be empty);
  /// [partnerListening] = they're playing music right now too.
  static String musicWelcome({
    required String me,
    required String track,
    String partner = '',
    bool partnerListening = false,
  }) {
    final you = me.isEmpty ? '' : ', $me';
    final song = track.trim().isEmpty ? 'your song' : '“${track.trim()}”';
    if (partner.isNotEmpty && partnerListening) {
      return _pick('mw_both', [
        '$partner is listening too 🎧 — tune in together?',
        '$partner yuko kwenye muziki pia 🎧 — msikilize pamoja?',
        'You and $partner, both in the music right now 💞',
      ]);
    }
    final lines = <String>[
      'Still vibing to $song$you? 🎶',
      'Bado unaburudika na $song$you? 🎶',
      '$song sounds better shared$you',
    ];
    if (partner.isNotEmpty) {
      lines.addAll([
        'Share $song with $partner? 💞',
        'Msikilize $song pamoja na $partner? 💞',
        '$partner would love this one 🎧',
      ]);
    }
    switch (moment) {
      case AlutaMoment.dawn:
      case AlutaMoment.morning:
        lines.add('Morning soundtrack on$you ☕');
        lines.add('Muziki wa asubuhi$you ☀️');
        break;
      case AlutaMoment.afternoon:
        lines.add('Music with your lunch$you? 🍲');
        break;
      case AlutaMoment.evening:
        lines.add('Evening tunes$you 🌇');
        lines.add('Burudani ya jioni$you 🌇');
        break;
      case AlutaMoment.night:
        lines.add('Late night listening$you 🌙');
        lines.add('Muziki wa usiku$you 🌙');
        break;
    }
    return _pick('mw', lines);
  }
}
