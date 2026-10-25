import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'aluta_mood.dart';
import 'account_prefs.dart';
import '../screens/api_service.dart';

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
  final String kind; // 'repeat' · 'missing' · 'ours' · 'back' · 'streak' · 'night'
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
///  • it's YOUR listening history: backed up to your own account (so a
///    reinstall or a new phone keeps your weeks), merged across devices,
///    never used for analytics. Your bonded partner sees only your top
///    titles, and only while you share your listening with them.
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
  String? _lastNightWeek; // week the "late-night song" card was shown
  String? _lastMonthCard; // yyyymm the "Our soundtrack" card was shown
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
  Future<void> load() {
    if (_loading == null) {
      // Nudges on/off came back from the account → re-read just that.
      AccountPrefs.onRestore(() async {
        final p = await SharedPreferences.getInstance();
        enabled.value = p.getBool(_enabledKey) ?? true;
      });
    }
    return _loading ??= _doLoad();
  }

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
      _lastNightWeek = j['lnw'] as String?;
      _lastMonthCard = j['lmc'] as String?;
      _together = ((j['tg'] as Map?) ?? {})
          .map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
    } catch (_) {}
  }

  Map<String, dynamic> _snapshot() => {
        's': _songs,
        'ln': _lastNudgeDay,
        'lr': _lastRecapWeek,
        'lnw': _lastNightWeek,
        'lmc': _lastMonthCard,
        'tg': _together,
      };

  // ── Account backup (merge, never overwrite) ────────────────────────────────
  // The history lives in the user's account (user_settings 'song_insights'),
  // so a reinstall / update / new phone keeps every week. Devices MERGE: per
  // song per day the higher count wins, the newer feeling wins, "ours" sticks
  // — so two phones never erase each other's plays.
  static const _settingKey = 'song_insights';
  Timer? _push;
  bool _synced = false;

  static Map<String, dynamic> _m(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  static int _n(Object? v) => (v as num?)?.toInt() ?? 0;

  static Map<String, dynamic> _maxMap(Object? a, Object? b) {
    final out = _m(a);
    _m(b).forEach((k, v) {
      if (_n(v) > _n(out[k])) out[k] = _n(v);
    });
    return out;
  }

  static Map<String, dynamic> _mergeSong(
      Map<String, dynamic> a, Map<String, dynamic> b) {
    final out = Map<String, dynamic>.from(a);
    if ((out['t'] ?? '').toString().isEmpty) out['t'] = b['t'];
    if ((out['a'] ?? '').toString().isEmpty && b['a'] != null) {
      out['a'] = b['a'];
    }
    out['d'] = _maxMap(a['d'], b['d']);
    out['m'] = _maxMap(a['m'], b['m']);
    final dm = _m(a['dm']);
    _m(b['dm']).forEach((day, v) => dm[day] = _maxMap(dm[day], v));
    out['dm'] = dm;
    if (_n(b['fAt']) > _n(a['fAt']) && b['f'] != null) {
      out['f'] = b['f'];
      out['fAt'] = b['fAt'];
    }
    if (b['ours'] == true) out['ours'] = true;
    for (final k in const ['ig', 'nAt', 'bAt', 'sAt']) {
      if (_n(b[k]) > _n(out[k])) out[k] = _n(b[k]);
    }
    return out;
  }

  static String? _maxStr(String? a, Object? b) {
    final bs = b?.toString();
    if (bs == null || bs.isEmpty) return a;
    if (a == null || bs.compareTo(a) > 0) return bs;
    return a;
  }

  /// Merge the account copy in, then upload the union. Call after sign-in
  /// (unawaited); safe to call again.
  Future<void> syncWithAccount() async {
    try {
      await load();
      final remote = await ApiService().getSetting(_settingKey);
      if (remote == null) return; // offline — next launch
      final d = remote.data;
      if (d is Map) {
        final rs = _m(d['s']);
        rs.forEach((k, v) {
          final theirs = _m(v);
          final mine = _songs[k];
          _songs[k] = mine == null ? theirs : _mergeSong(mine, theirs);
        });
        _maxMap(_together, d['tg']).forEach((k, v) => _together[k] = _n(v));
        _lastNudgeDay = _maxStr(_lastNudgeDay, d['ln']);
        _lastRecapWeek = _maxStr(_lastRecapWeek, d['lr']);
        _lastNightWeek = _maxStr(_lastNightWeek, d['lnw']);
        _lastMonthCard = _maxStr(_lastMonthCard, d['lmc']);
        feelsRev.value++;
      }
      _synced = true;
      await _save(); // writes locally and uploads the merged copy
    } catch (_) {}
  }

  void _schedulePush() {
    if (!_synced) return; // merge first, so a fresh install never uploads emptiness
    _push?.cancel();
    _push = Timer(const Duration(seconds: 8), () async {
      try {
        await ApiService().putSetting(_settingKey,
            DateTime.now().millisecondsSinceEpoch, _snapshot());
      } catch (_) {}
    });
  }

  Future<void> _save() async {
    try {
      // Keep it small: drop day buckets older than ~10 weeks.
      final cutoff = _day(DateTime.now().subtract(const Duration(days: 70)));
      // Time-of-day buckets only need the last two weeks.
      final cut14 = _day(DateTime.now().subtract(const Duration(days: 14)));
      for (final s in _songs.values) {
        final d = (s['d'] as Map?)?.cast<String, dynamic>();
        d?.removeWhere((k, _) => k.compareTo(cutoff) < 0);
        final dm = (s['dm'] as Map?)?.cast<String, dynamic>();
        dm?.removeWhere((k, _) => k.compareTo(cut14) < 0);
      }
      _together.removeWhere((k, _) => k.compareTo(cutoff) < 0);
      final p = await SharedPreferences.getInstance();
      await p.setString(_prefsKey, jsonEncode(_snapshot()));
    } catch (_) {}
    _schedulePush();
  }

  Future<void> setEnabled(bool on) async {
    enabled.value = on;
    if (!on) pending.value = null;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_enabledKey, on);
    } catch (_) {}
    AccountPrefs.touch();
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
    // Days since I last played it (before today) — "rediscovered".
    String? lastBefore;
    for (final k in d.keys) {
      if (k != _today && (lastBefore == null || k.compareTo(lastBefore) > 0)) {
        lastBefore = k;
      }
    }
    final firstToday = ((d[_today] as num?)?.toInt() ?? 0) == 0;
    d[_today] = ((d[_today] as num?)?.toInt() ?? 0) + 1;
    s['d'] = d;
    final m = Map<String, dynamic>.from((s['m'] as Map?) ?? {});
    final mk = AlutaMood.moment.name;
    m[mk] = ((m[mk] as num?)?.toInt() ?? 0) + 1;
    s['m'] = m;
    // The same, per day (two weeks) — "your late-night song this week".
    final dm = Map<String, dynamic>.from((s['dm'] as Map?) ?? {});
    final todayM = Map<String, dynamic>.from((dm[_today] as Map?) ?? {});
    todayM[mk] = ((todayM[mk] as num?)?.toInt() ?? 0) + 1;
    dm[_today] = todayM;
    s['dm'] = dm;
    int? gapDays;
    if (firstToday && lastBefore != null) {
      final y = int.parse(lastBefore.substring(0, 4));
      final mo = int.parse(lastBefore.substring(4, 6));
      final da = int.parse(lastBefore.substring(6, 8));
      gapDays = DateTime.now().difference(DateTime(y, mo, da)).inDays;
    }
    _maybeQueue(s, backAfterDays: gapDays);
    await _save();
  }

  /// Consecutive days played, ending today (or yesterday, if not yet today).
  int _streakOf(Map<String, dynamic> s) {
    final now = DateTime.now();
    final start = _playsOn(s, _today) > 0 ? 0 : 1;
    var n = 0;
    for (var i = start; i < 60; i++) {
      if (_playsOn(s, _day(now.subtract(Duration(days: i)))) > 0) {
        n++;
      } else {
        break;
      }
    }
    return n;
  }

  /// This week's plays of [s] in one part of the day.
  int _momentPlaysThisWeek(Map<String, dynamic> s, AlutaMoment m) {
    final cut = _day(DateTime.now().subtract(const Duration(days: 6)));
    var n = 0;
    ((s['dm'] as Map?) ?? {}).forEach((day, v) {
      if (day.toString().compareTo(cut) >= 0 && v is Map) {
        n += ((v[m.name] as num?)?.toInt() ?? 0);
      }
    });
    return n;
  }

  void _maybeQueue(Map<String, dynamic> s, {int? backAfterDays}) {
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
    // 8) Rediscovered: an old favourite back after 3+ weeks.
    if (backAfterDays != null &&
        backAfterDays >= 21 &&
        _playsSince(s, now.subtract(const Duration(days: 70))) >= 5 &&
        ago('bAt') >= 30) {
      s['bAt'] = now.millisecondsSinceEpoch;
      pending.value =
          SongNudge('back', title, artist: artist, feel: feel, day: _today);
      return;
    }
    // 9) A gentle streak: 5 days in a row (once a month per song).
    if (today == 1 && _streakOf(s) == 5 && ago('sAt') >= 30) {
      s['sAt'] = now.millisecondsSinceEpoch;
      pending.value =
          SongNudge('streak', title, artist: artist, feel: feel, day: _today);
      return;
    }
    // 10) Your late-night song this week (once a week, from 3 night plays).
    final wk = _weekId(now);
    if (AlutaMood.moment == AlutaMoment.night &&
        _lastNightWeek != wk &&
        _momentPlaysThisWeek(s, AlutaMoment.night) >= 3) {
      final best = _songs.values.fold<Map<String, dynamic>?>(null, (b, x) {
        if (b == null) return x;
        return _momentPlaysThisWeek(x, AlutaMoment.night) >
                _momentPlaysThisWeek(b, AlutaMoment.night)
            ? x
            : b;
      });
      if (identical(best, s)) {
        _lastNightWeek = wk;
        pending.value =
            SongNudge('night', title, artist: artist, feel: feel, day: _today);
        return;
      }
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

  /// Whether this song is already in Our Playlist with my partner.
  bool isOurs(String title) => _songs[_keyOf(title)]?['ours'] == true;

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

  /// Everything Aluta has learned about one song, for its insight card:
  /// plays per day over the last 7 days (oldest first), this week's total
  /// and rank, all-time plays (the ~10 weeks kept), its feel and "ours".
  ({
    String title,
    String artist,
    List<int> last7,
    int week,
    int? rank,
    int total,
    int daysThisWeek,
    SongFeel? feel,
    bool ours,
    int streak,
    int lastWeek,
    Map<AlutaMoment, int> moments,
  })? songStats(String title) {
    final s = _songs[_keyOf(title)];
    if (s == null) return null;
    final now = DateTime.now();
    final last7 = [
      for (var i = 6; i >= 0; i--)
        _playsOn(s, _day(now.subtract(Duration(days: i)))),
    ];
    var total = 0;
    ((s['d'] as Map?) ?? {}).forEach((_, v) => total += (v as num).toInt());
    final week = last7.fold<int>(0, (a, b) => a + b);
    int? rank;
    if (week > 0) {
      final ranking = weekInMusic().songs;
      final i = ranking.indexWhere((e) => _keyOf(e.title) == _keyOf(title));
      if (i >= 0) rank = i + 1;
    }
    return (
      title: s['t'].toString(),
      artist: (s['a'] ?? '').toString(),
      last7: last7,
      week: week,
      rank: rank,
      total: total,
      daysThisWeek: last7.where((n) => n > 0).length,
      feel: SongFeel.of(s['f'] as String?),
      ours: s['ours'] == true,
      streak: _streakOf(s),
      lastWeek: () {
        final v = _playsSince(s, now.subtract(const Duration(days: 13))) - week;
        return v < 0 ? 0 : v;
      }(),
      // When you listen: this week's part-of-day split, else all-time.
      moments: () {
        final w = {
          for (final mo in AlutaMoment.values)
            mo: _momentPlaysThisWeek(s, mo),
        };
        if (w.values.any((v) => v > 0)) return w;
        return {
          for (final mo in AlutaMoment.values)
            mo: ((s['m'] as Map?)?[mo.name] as num?)?.toInt() ?? 0,
        };
      }(),
    );
  }

  /// The whole last 7 days for the "Your week in music" sheet: every song
  /// played, most-played first, with plays, last week's plays (for the
  /// ▲▼ / new / 🔥 marks), feel, "ours" and streak; plus totals, how many
  /// are new, the mood mix and each part of the day's top song.
  ({
    List<
        ({
          String title,
          String artist,
          int plays,
          int lastWeek,
          SongFeel? feel,
          bool ours,
          int streak,
        })> songs,
    int total,
    SongFeel? feel,
    int together,
    int newCount,
    Map<SongFeel, int> feelMix,
    Map<AlutaMoment, String> momentTops,
  }) weekInMusic() {
    final now = DateTime.now();
    final since = now.subtract(const Duration(days: 6));
    final prevFrom = now.subtract(const Duration(days: 13));
    final ranked = _songs.values
        .map((s) => (s, _playsSince(s, since)))
        .where((e) => e.$2 > 0)
        .toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    final feels = <SongFeel, int>{};
    var total = 0;
    var fresh = 0;
    final rows = <({
      String title,
      String artist,
      int plays,
      int lastWeek,
      SongFeel? feel,
      bool ours,
      int streak,
    })>[];
    for (final e in ranked) {
      total += e.$2;
      final f = SongFeel.of(e.$1['f'] as String?);
      if (f != null) feels[f] = (feels[f] ?? 0) + e.$2;
      final last = _playsSince(e.$1, prevFrom) - e.$2;
      if (last <= 0) fresh++;
      rows.add((
        title: e.$1['t'].toString(),
        artist: (e.$1['a'] ?? '').toString(),
        plays: e.$2,
        lastWeek: last < 0 ? 0 : last,
        feel: f,
        ours: e.$1['ours'] == true,
        streak: _streakOf(e.$1),
      ));
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
    final tops = <AlutaMoment, String>{};
    for (final mo in AlutaMoment.values) {
      var best = 1; // at least 2 plays in that part of the day
      for (final e in ranked) {
        final c = _momentPlaysThisWeek(e.$1, mo);
        if (c > best) {
          best = c;
          tops[mo] = e.$1['t'].toString();
        }
      }
    }
    return (
      songs: rows,
      total: total,
      feel: feel,
      together: together,
      newCount: fresh,
      feelMix: feels,
      momentTops: tops,
    );
  }

  /// Top titles over the last [days] (for "Our soundtrack" overlap).
  List<String> topTitles({int days = 30, int limit = 10}) {
    final since = DateTime.now().subtract(Duration(days: days - 1));
    final ranked = _songs.values
        .map((s) => (s, _playsSince(s, since)))
        .where((e) => e.$2 > 0)
        .toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final e in ranked.take(limit)) e.$1['t'].toString()];
  }

  /// Live sessions started in the last [days].
  int togetherSince(int days) {
    final cut = _day(DateTime.now().subtract(Duration(days: days - 1)));
    var n = 0;
    _together.forEach((k, v) {
      if (k.compareTo(cut) >= 0) n += v;
    });
    return n;
  }

  /// The 1st–3rd of a month, once: time for "Our soundtrack" (last month).
  bool monthCardDue() {
    final now = DateTime.now();
    if (!enabled.value || now.day > 3) return false;
    final id = '${now.year}${now.month.toString().padLeft(2, '0')}';
    return _lastMonthCard != id;
  }

  void markMonthCardShown() {
    final now = DateTime.now();
    _lastMonthCard = '${now.year}${now.month.toString().padLeft(2, '0')}';
    _save();
  }

  /// Same key logic as the store (for matching titles across people).
  static String keyOf(String title) => _keyOf(title);

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

  /// User id of the bonded partner, or null (the player's Dedicate row puts
  /// them first for a song that feels like them).
  int? Function()? partnerId;

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
