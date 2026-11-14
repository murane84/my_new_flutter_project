import 'metadata_overrides.dart';
import 'song_names.dart';

/// Cleans junk that downloaders bake into filenames, e.g.
/// "Two of us- Downloaded from clipzag.com" → "Two of us".
///
/// This mirrors the cleaning used by the main music screen so a song shows the
/// SAME nice title everywhere it appears (playlist, now-playing, Listen
/// Together picker, live share).
String cleanTrackName(String raw) {
  var n = raw;
  // "Sean_Paul_-_We_Be_Burning_(mp3.pm)" → "Sean Paul - We Be Burning".
  n = n.replaceAll(RegExp(r'[\(\[]?\s*mp3\s*\.\s*\w+\s*[\)\]]?', caseSensitive: false), ' ');
  // A time / id stamp glued on with an underscore ("Asante_064918").
  n = n.replaceAll(RegExp(r'_\d{5,}(?!\w)'), ' ');
  n = n.replaceAll(RegExp(r'_+'), ' ');
  // Numbers that aren't part of the name: a bitrate ("320kbps", "128k"), a
  // downloader's long id ("…_1699872034"), a track number in front
  // ("03. Title", "7) Title", "07 - Title", "01 Title") and a copy counter
  // at the end ("Title (1)"). "50 Cent", "7 Days", "2 Pac" stay.
  n = n.replaceAll(
      RegExp(r'\b\d{2,3}\s*kbps\b|\b(128|192|256|320)\s*k\b',
          caseSensitive: false),
      ' ');
  n = n.replaceAll(RegExp(r'(?<![\w.])\d{7,}(?![\w.])'), ' ');
  n = n.replaceFirst(RegExp(r'^\s*\d{1,3}\s*[.)\-–]\s+'), '');
  n = n.replaceFirst(RegExp(r'^\s*0\d\s+(?=\D)'), '');
  n = n.replaceFirst(RegExp(r'\s*[\(\[]\d{1,2}[\)\]]\s*$'), '');
  n = n.replaceAll(RegExp(r'\bsms\s*skiza\b.*', caseSensitive: false), ' ');
  n = n.replaceAll(RegExp(r'\bskiza\b.*', caseSensitive: false), ' ');
  n = n.replaceAll(
      RegExp(r'[-_(\[ ]*downloaded\s*from[^)\]]*', caseSensitive: false), ' ');
  n = n.replaceAll(
      RegExp(r'\b(clipzag|y2mate|ytmp3|mp3juice|tubidy|savefrom|snaptube)\S*',
          caseSensitive: false),
      ' ');
  n = n.replaceAll(
      RegExp(r'\b(www\.)?\S+\.(com|net|co|info|xyz|me|tz)\b',
          caseSensitive: false),
      ' ');
  n = n.replaceAll(
      RegExp(
          r'[\(\[][^\)\]]*\b(official|lyric|lyrics|video|audio|visuali[sz]er|hd|4k|mv|dir(ected)?\s*by)\b[^\)\]]*[\)\]]?',
          caseSensitive: false),
      ' ');
  n = n.replaceAll(RegExp(r'\(\s*\)|\[\s*\]'), ' ');
  n = n.replaceAll(RegExp(r'\s+'), ' ').trim();
  n = n.replaceAll(RegExp(r'^[\s\-_|)\]\(\[]+|[\s\-_|)\]\(\[]+$'), '').trim();
  if (n.isNotEmpty) return n;
  // Nothing but site junk ("- Downloaded from clipzag.com"): never show the
  // junk back — the song simply has no name of its own.
  if (RegExp(r'downloaded\s*from|clipzag|y2mate|tubidy|mp3\s*\.',
          caseSensitive: false)
      .hasMatch(raw)) {
    return 'Untitled song';
  }
  return raw.trim();
}

/// A song from a shared playlist (Our Playlist rows from the server, or a
/// lullaby / voice-note bed) named the way MY playlist names it:
/// (title, artist, my own copy's path when I have it). [myPaths] = my
/// loaded playlist.
(String, String, String?) sharedTrackNames(
    Map t, List<String> myPaths) {
  final raw = (t['title'] ?? '').toString().trim();
  final ref = (t['ref'] ?? '').toString().trim();
  String? local;
  if (ref.isNotEmpty && myPaths.contains(ref)) {
    local = ref;
  } else if (raw.isNotEmpty) {
    final want = raw.toLowerCase();
    for (final p in myPaths) {
      final stem = p
          .split(RegExp(r'[\\/]+'))
          .last
          .replaceAll(RegExp(r'\.[^.]+$'), '')
          .toLowerCase();
      if (stem == want ||
          displayLabelForPath(p).toLowerCase() == want ||
          displayTitleForPath(p).toLowerCase() == want) {
        local = p;
        break;
      }
    }
  }
  if (local != null) {
    return (displayTitleForPath(local), displayArtistForPath(local), local);
  }
  final p = SongNames.instance.parseName(raw);
  final stored = (t['artist'] ?? '').toString().trim();
  return (
    p.title.isEmpty ? cleanTrackName(raw) : p.title,
    stored.isNotEmpty ? stored : p.artist,
    null,
  );
}

/// The cleaned file-name (no extension) for a device path — the app's default
/// title before any manual rename.
String cleanedNameFromPath(String path) {
  var name = path;
  final slash = name.lastIndexOf(RegExp(r'[\\/]'));
  if (slash >= 0) name = name.substring(slash + 1);
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  return cleanTrackName(name);
}

/// The display title the app shows for a song ANYWHERE: the user's manual
/// rename from [metadataStore] when set, otherwise the cleaned file name.
/// Native (Windows/Android) paths only — web uses its own queue titles.
String displayTitleForPath(String path) {
  // The smartly read title ("Sean Paul - We Be Burning" → "We Be Burning").
  final smart = SongNames.instance.parse(path).title;
  final fallback = smart.isEmpty ? cleanedNameFromPath(path) : smart;
  final t = metadataStore.title(path, fallback);
  final out = t.trim();
  return out.isEmpty ? 'Live song' : out;
}

/// The artist as the playlist shows it (your edit, else read from the
/// file name; '' when unknown).
String displayArtistForPath(String path) =>
    metadataStore.artist(path, SongNames.instance.parse(path).artist).trim();

/// "Title — Artist" as the playlist shows it (just the title when the
/// artist is unknown) — for anything that names a song from a path.
String displayLabelForPath(String path) {
  final t = displayTitleForPath(path);
  final a = displayArtistForPath(path);
  return a.isEmpty ? t : '$t — $a';
}

/// Strip a file extension then clean downloader junk from a raw file name,
/// giving the nice display title the app shows for web-picked files.
String cleanDisplayName(String fileName) {
  final noExt = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
  return cleanTrackName(noExt);
}

/// Splits a cleaned name into (title, artist) when it looks like
/// "Title - Artist" (or "Title-Artist"). Mirrors the main music screen so the
/// web queue reads the same two-line way as the native playlist.
(String, String?) splitTitleArtist(String cleaned) {
  final parts = cleaned
      .split(RegExp(r'\s*-\s*'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.length < 2) return (cleaned, null);
  return (parts.first, parts.sublist(1).join(' · '));
}
