import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'aluta_mood.dart';

/// How a song makes you feel — the answer to the on-repeat card.
enum SongFeel {
  love('😍', 'In love', 'love'),
  missing('🥹', 'Missing someone', 'missing'),
  hyped('💪', 'Hyped', 'hyped'),
  calm('😌', 'Calm', 'calm'),
  hurting('💔', 'Hurting', 'hurting');

  const SongFeel(this.emoji, this.label, this.key);
  final String emoji;
  final String label;
  final String key;

  static SongFeel? of(String? k) {
    for (final f in values) {
      if (f.key == k) return f;
    }
    return null;
  }
}

/// A nudge the app would like to show (home decides when it's welcome).
class SongNudge {
  const SongNudge(this.kind, this.title,
      {this.artist = '', this.feel, required this.day});
  final String kind; // 'repeat' · 'missing' · 'ours'
  final String title;
  final String artist;
  final SongFeel? feel;
  final String day; // yyyymmdd it was queued (stale ones get replaced)
}

/// Aluta learns, on this device only, what you listen to and how it makes
/// you feel — so it can nudge you toward the people a song is really about.
///
/// Guardrails (by design):
///  • at most ONE music nudge per day (the weekly recap has its own slot);
///  • a nudge ignored twice for a song never comes back for that song;
///  • a "Music nudges" switch turns it all off (Moments & nudges);
///  • nothing leaves the phone — no server, no analytics.
class SongInsights {
  SongInsights._();
  static final SongInsights instance = SongInsights._();

  static const _prefsKey = 'song_insights_v1';
  static const _enabledKey = 'music_nudges_on';

  /// ON by default; mirrored live so the settings switches can flip it.
  final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);

  /// Set when a nudge is due; the home page shows it and clears it.
  final ValueNotifier<SongNudge?> pending = ValueNotifier<SongNudge?>(null);

  /// Ticks when a feeling changes (the player strip listens).
  final ValueNotifier<int> feelsRev = ValueNotifier<int>(0);

  // key → {t: title, a: artist, d: {yyyymmdd: plays}, m: {moment: plays},
  //        f: feel, fAt: epoch-ms, ig: ignores, ours: bool}
  Map<String, Map<String, dynamic>> _songs = {};
  String? _lastNudgeDay;
  String? _lastRecapWeek;
  Map<String, int> _together = {}; // yyyymmdd → live sessions started
  Future<void>? _loading;

  static String _day(DateTime d) =>
      '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
  static String get _today => _day(DateTime.now());

  /// ISO-ish week id (year + week-of-year) for the Sunday recap.
  static String _weekId(DateTime d) {
    final jan1 = DateTime(d.year, 1, 1);
    final w = ((d.difference(jan1).inDays + jan1.weekday - 1) / 7).floor();
    return '${d.year}-w$w';
  }

  static String _keyOf(String title) {
    final k = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{M}\p{N}]+', unicode: true), ' ')
        .trim();
    return k.isEmpty ? title.trim().toLowerCase() : k;
  }

  /// One shared load — every caller awaits the same read, so nobody works
  /// on (or saves over) an empty memory.
  Future<void> load() => _loading ??= _doLoad();

  Future<void> _doLoad() async {
    try {
      final p = await SharedPreferences.getInstance();
      enabled.value = p.getBool(_enabledKey) ?? true;
      final raw = p.getString(_prefsKey);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      _songs = ((j['s'] as Map?) ?? {}).map((k, v) =>
          MapEntry(k.toString(), Map<String, dynamic>.from(v as Map)));
      _lastNudgeDay = j['ln'] as String?;
      _lastRecapWeek = j['lr'] as String?;
      _together = ((j['tg'] as Map?) ?? {})
          .map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      // Keep it small: drop day buckets older than ~10 weeks.
      final cutoff = _day(DateTime.now().subtract(const Duration(days: 70)));
      for (final s in _songs.values) {
        final d = (s['d'] as Map?)?.cast<String, dynamic>();
        d?.removeWhere((k, _) => k.compareTo(cutoff) < 0);
      }
      _together.removeWhere((k, _) => k.compareTo(cutoff) < 0);
      final p = await SharedPreferences.getInstance();
      await p.setString(
          _prefsKey,
          jsonEncode({
            's': _songs,
            'ln': _lastNudgeDay,
            'lr': _lastRecapWeek,
            'tg': _together,
          }));
    } catch (_) {}
  }

  Future<void> setEnabled(bool on) async {
    enabled.value = on;
    if (!on) pending.value = null;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_enabledKey, on);
    } catch (_) {}
  }

  Map<String, dynamic> _song(String title, String artist) {
    final k = _keyOf(title);
    final s = _songs.putIfAbsent(k, () => {'t': title, 'a': artist});
    if (artist.isNotEmpty) s['a'] = artist;
    return s;
  }

  int _playsOn(Map<String, dynamic> s, String day) =>
      ((s['d'] as Map?)?[day] as num?)?.toInt() ?? 0;

  int _playsSince(Map<String, dynamic> s, DateTime since) {
    final cut = _day(since);
    var n = 0;
    ((s['d'] as Map?) ?? {}).forEach((k, v) {
      if (k.toString().compareTo(cut) >= 0) n += (v as num).toInt();
    });
    return n;
  }

  bool get _nudgedToday => _lastNudgeDay == _today;

  /// Called by the player each time a track starts.
  Future<void> recordPlay(String title, {String artist = ''}) async {
    final t = title.trim();
    if (t.isEmpty) return;
    await load();
    final s = _song(t, artist.trim());
    final d = Map<String, dynamic>.from((s['d'] as Map?) ?? {});
    d[_today] = ((d[_today] as num?)?.toInt() ?? 0) + 1;
    s['d'] = d;
    final m = Map<String, dynamic>.from((s['m'] as Map?) ?? {});
    final mk = AlutaMood.moment.name;
    m[mk] = ((m[mk] as num?)?.toInt() ?? 0) + 1;
    s['m'] = m;
    _maybeQueue(s);
    await _save();
  }

  void _maybeQueue(Map<String, dynamic> s) {
    if (!enabled.value || _nudgedToday) return;
    final pend = pending.value;
    if (pend != null && pend.day == _today) return; // today's is waiting
    if (((s['ig'] as num?)?.toInt() ?? 0) >= 2) return; // ignored twice
    final title = s['t'].toString();
    final artist = (s['a'] ?? '').toString();
    final feel = SongFeel.of(s['f'] as String?);
    final today = _playsOn(s, _today);
    final now = DateTime.now();
    int ago(String k) => now
        .difference(DateTime.fromMillisecondsSinceEpoch(
            (s[k] as num?)?.toInt() ?? 0))
        .inDays;
    // 5) Your song for weeks, felt with love → make it part of "us".
    if ((feel == SongFeel.love || feel == SongFeel.missing) &&
        s['ours'] != true &&
        _playsSince(s, now.subtract(const Duration(days: 30))) >= 10) {
      pending.value =
          SongNudge('ours', title, artist: artist, feel: feel, day: _today);
      return;
    }
    // 7) A "missing someone" song COMING BACK after a gap → a heart.
    final playedYesterday =
        _playsOn(s, _day(now.subtract(const Duration(days: 1)))) > 0;
    if (feel == SongFeel.missing &&
        today == 1 &&
        !playedYesterday &&
        ago('nAt') >= 7 &&
        ago('fAt') >= 2) {
      pending.value =
          SongNudge('missing', title, artist: artist, feel: feel, day: _today);
      return;
    }
    // 1) On repeat today (3+) and we haven't asked how it feels lately.
    final askedAt = (s['fAt'] as num?)?.toInt() ?? 0;
    final askedRecently = DateTime.now()
            .difference(DateTime.fromMillisecondsSinceEpoch(askedAt))
            .inDays <
        14;
    if (today >= 3 && !askedRecently) {
      pending.value =
          SongNudge('repeat', title, artist: artist, feel: feel, day: _today);
    }
  }

  /// The home page showed [n] — that spends today's nudge.
  void markShown(SongNudge n) {
    _lastNudgeDay = _today;
    _songs[_keyOf(n.title)]?['nAt'] = DateTime.now().millisecondsSinceEpoch;
    if (identical(pending.value, n)) pending.value = null;
    _save();
  }

  /// Closed without any action.
  void markIgnored(String title) {
    final s = _songs[_keyOf(title)];
    if (s == null) return;
    s['ig'] = ((s['ig'] as num?)?.toInt() ?? 0) + 1;
    _save();
  }

  void markActed(String title) {
    final s = _songs[_keyOf(title)];
    if (s == null) return;
    s['ig'] = 0;
    _save();
  }

  void setFeel(String title, SongFeel f) {
    final s = _song(title, '');
    s['f'] = f.key;
    s['fAt'] = DateTime.now().millisecondsSinceEpoch;
    s['ig'] = 0;
    feelsRev.value++;
    _save();
  }

  void markOurs(String title) {
    _song(title, '')['ours'] = true;
    _save();
  }

  /// The feeling I tagged most recently (any song) — tunes Glow's daily card.
  SongFeel? get lastFeel {
    var at = 0;
    SongFeel? f;
    for (final s in _songs.values) {
      final t = (s['fAt'] as num?)?.toInt() ?? 0;
      if (t > at && s['f'] != null) {
        at = t;
        f = SongFeel.of(s['f'] as String?);
      }
    }
    return f;
  }

  SongFeel? feelOf(String title) =>
      SongFeel.of(_songs[_keyOf(title)]?['f'] as String?);

  /// Songs I tagged calm (in the order first tagged).
  List<String> get calmSongs => [
        for (final s in _songs.values)
          if (s['f'] == SongFeel.calm.key) s['t'].toString(),
      ];

  /// My most-played song in this part of the day (needs a few plays).
  String? topForMoment(AlutaMoment m) {
    String? best;
    var n = 2;
    for (final s in _songs.values) {
      final c = ((s['m'] as Map?)?[m.name] as num?)?.toInt() ?? 0;
      if (c > n) {
        n = c;
        best = s['t'].toString();
      }
    }
    return best;
  }

  /// Listen Together started (counts toward the weekly recap).
  void recordTogether() {
    _together[_today] = (_together[_today] ?? 0) + 1;
    _save();
  }

  /// Sunday evening, once a week: top 3 songs, the feeling, together count.
  ({List<String> top, SongFeel? feel, int together})? weeklyRecapDue() {
    final now = DateTime.now();
    if (!enabled.value) return null;
    if (now.weekday != DateTime.sunday || now.hour < 18) return null;
    final wk = _weekId(now);
    if (_lastRecapWeek == wk) return null;
    final since = now.subtract(const Duration(days: 6));
    final ranked = _songs.values
        .map((s) => (s, _playsSince(s, since)))
        .where((e) => e.$2 > 0)
        .toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    if (ranked.isEmpty) return null;
    final feels = <SongFeel, int>{};
    for (final e in ranked.take(10)) {
      final f = SongFeel.of(e.$1['f'] as String?);
      if (f != null) feels[f] = (feels[f] ?? 0) + e.$2;
    }
    SongFeel? feel;
    var fn = 0;
    feels.forEach((f, c) {
      if (c > fn) {
        fn = c;
        feel = f;
      }
    });
    final cut = _day(since);
    var together = 0;
    _together.forEach((k, v) {
      if (k.compareTo(cut) >= 0) together += v;
    });
    return (
      top: [for (final e in ranked.take(3)) e.$1['t'].toString()],
      feel: feel,
      together: together,
    );
  }

  void markRecapShown() {
    _lastRecapWeek = _weekId(DateTime.now());
    _save();
  }
}

/// What the music surfaces can ask the app to do with a song — registered by
/// the home page (which knows your partner, chats and Spaces), used by the
/// nudge cards AND the player's feel strip, so music and chat move together.
class SongBridge {
  SongBridge._();
  static final SongBridge instance = SongBridge._();

  /// First name of the bonded partner, or null.
  String? Function()? partnerName;

  /// Open the partner's chat; [text] pre-fills it, [heart] seals it.
  void Function({String? text, bool heart, String? mood})? messagePartner;

  /// Open Our Space (where Listen Together lives).
  VoidCallback? listenTogether;

  /// Share the song playing now to a chat (picker).
  VoidCallback? shareCurrent;

  /// Whether this player can share its track (the web player can't yet).
  bool Function()? canShare;

  /// Same number on both partners' phones (from the two user ids) — lets
  /// Glow pick one shared "For you two" card a day without a server.
  int? Function()? pairSeed;

  /// Add a song to Our Playlist with the partner.
  Future<bool> Function(String title, String artist)? addToOurs;
}
