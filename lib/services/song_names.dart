import '../utils/prefs_now.dart';
import 'track_title.dart';

/// Smart song names for files that have no proper tags — the name is all
/// there is ("Sean_Paul_-_We_Be_Burning_(mp3.pm).mp3", "God's Plan_Drake").
///
/// * The junk is cleaned (underscores, download-site tags, "(mp3.pm") by
///   [cleanTrackName] — display only, files are never touched.
/// * "A - B" is split into title + artist. Which side is the artist? The one
///   Aluta already knows as an artist (from other songs' tags, from your own
///   edits, or because it names several of your files); with no clue, the
///   usual download order "Artist - Title".
/// * One-line "Title_Artist" names split only when the other part is an
///   artist Aluta already knows — never a guess.
/// * "Feat X" becomes "(feat. X)".
///
/// Your own edits (MetadataStore) always win over this; it's the fallback.
class SongNames {
  SongNames._();
  static final SongNames instance = SongNames._();

  // Lower-cased names known to be artists.
  final Set<String> _artists = <String>{};
  // How many files each "A - B" side appears in (lower-cased).
  final Map<String, int> _sideCounts = <String, int>{};
  final Map<String, ({String title, String artist})> _memo = {};
  int _learnedFrom = -1;

  /// Teach the parser from the whole library: every file's name, plus any
  /// real artist tags / artists you typed yourself.
  void learn(Iterable<String> paths, {Iterable<String?> artists = const []}) {
    final list = paths.toList();
    final tagged = artists.where((a) => _realArtist(a)).length;
    final key = list.length * 1000 + tagged;
    if (key == _learnedFrom) return;
    _learnedFrom = key;
    _sideCounts.clear();
    _memo.clear();
    for (final a in artists) {
      if (_realArtist(a)) _artists.add(_norm(a!));
    }
    for (final p in list) {
      final parts = _dashParts(cleanTrackName(_base(p)));
      if (parts.length < 2) continue;
      for (final s in {parts.first, parts.sublist(1).join(' - ')}) {
        final k = _norm(s);
        _sideCounts[k] = (_sideCounts[k] ?? 0) + 1;
      }
    }
  }

  /// Remember one artist name (e.g. one the user just typed).
  void addArtist(String? a) {
    if (_realArtist(a) && _artists.add(_norm(a!))) _memo.clear();
  }

  bool isKnownArtist(String s) {
    final k = _norm(s);
    if (k.isEmpty) return false;
    if (_artists.contains(k)) return true;
    // A "featuring" artist: "50 Cent feat. Mase" counts as known when
    // "50 Cent" is.
    final lead = k.split(RegExp(r'\s+(feat\.?|ft\.?|featuring|&|x|and)\s+')).first;
    return lead != k && _artists.contains(lead);
  }

  /// Title + artist for a device path, from its file name.
  ({String title, String artist}) parse(String path) =>
      _memo[path] ??= _parse(_base(path));

  /// Same, for a bare name (no folder / extension).
  ({String title, String artist}) parseName(String name) => _parse(name);

  /// Does this file's name look messy (worth a "Tidy" — underscores,
  /// site junk, a hidden artist)?
  bool looksMessy(String path) {
    final raw = _base(path);
    final p = parse(path);
    // Anything the cleaner strips (underscores, site junk, stray numbers…)
    // or a hidden artist — and never a name you chose to keep.
    return raw != p.title &&
        !isKept(path) &&
        (cleanTrackName(raw) != raw.trim() || p.artist.isNotEmpty);
  }

  // Files whose own name you chose to keep (you undid a tidy): Aluta
  // remembers and never offers or tidies them again.
  static const _kKept = 'song_names_kept_v1';
  Set<String>? _keptMemo;

  bool isKept(String path) =>
      (_keptMemo ??= (prefsNow?.getStringList(_kKept) ?? const []).toSet())
          .contains(path);

  Future<void> keep(Iterable<String> paths) async {
    final set = (_keptMemo ??=
        (prefsNow?.getStringList(_kKept) ?? const []).toSet())
      ..addAll(paths);
    await prefsNow?.setStringList(_kKept, set.toList());
  }

  ({String title, String artist}) _parse(String raw) {
    final clean = cleanTrackName(raw);
    final parts = _dashParts(clean);
    if (parts.length >= 2) {
      final a = parts.first;
      final b = parts.sublist(1).join(' - ');
      final aArtist = _artistScore(a), bArtist = _artistScore(b);
      // "Title - Artist" only when B is clearly the artist and A isn't;
      // otherwise the common download order "Artist - Title".
      return bArtist > aArtist
          ? (title: _feat(a), artist: _featArtist(b))
          : (title: _feat(b), artist: _featArtist(a));
    }
    // One-line "Title_Artist" (a single underscore between two worded
    // parts): split only on a known artist.
    final us = raw.split('_');
    if (us.length == 2 && us[0].trim().contains(' ') ||
        us.length == 2 && us[1].trim().contains(' ')) {
      final a = cleanTrackName(us[0]), b = cleanTrackName(us[1]);
      if (a.isNotEmpty && b.isNotEmpty) {
        if (isKnownArtist(b)) return (title: _feat(a), artist: _featArtist(b));
        if (isKnownArtist(a)) return (title: _feat(b), artist: _featArtist(a));
      }
    }
    return (title: _feat(clean), artist: '');
  }

  int _artistScore(String s) {
    if (isKnownArtist(s)) return 3;
    final n = _sideCounts[_norm(s)] ?? 0;
    return n >= 2 ? 2 : 0; // names several files → an artist, not a title
  }

  static final _featRe = RegExp(
      r'\s*[\(\[]?\b(?:feat\.?|ft\.?|featuring)\s+([^\)\]]+?)[\)\]]?\s*$',
      caseSensitive: false);

  /// "All On Me Feat Tami Chynn" → "All On Me (feat. Tami Chynn)".
  static String _feat(String t) {
    final m = _featRe.firstMatch(t);
    if (m == null || m.start == 0) return t;
    return '${t.substring(0, m.start).trim()} (feat. ${m.group(1)!.trim()})';
  }

  /// "50 Cent feat Mase" → "50 Cent feat. Mase".
  static String _featArtist(String a) => a.replaceAllMapped(
      RegExp(r'\b(feat|ft)\.?\s+', caseSensitive: false), (_) => 'feat. ');

  static List<String> _dashParts(String s) => s
      .split(RegExp(r'\s+[-~]\s+|\s*[–—]\s*'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();

  static bool _realArtist(String? a) {
    final t = (a ?? '').trim().toLowerCase();
    return t.isNotEmpty &&
        t != '<unknown>' &&
        t != 'unknown' &&
        t != 'unknown artist' &&
        t != 'various artists';
  }

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _base(String path) {
    var n = path;
    final slash = n.lastIndexOf(RegExp(r'[\\/]'));
    if (slash >= 0) n = n.substring(slash + 1);
    final dot = n.lastIndexOf('.');
    return dot > 0 ? n.substring(0, dot) : n;
  }
}
