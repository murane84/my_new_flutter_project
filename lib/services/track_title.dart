import 'metadata_overrides.dart';

/// Cleans junk that downloaders bake into filenames, e.g.
/// "Two of us- Downloaded from clipzag.com" → "Two of us".
///
/// This mirrors the cleaning used by the main music screen so a song shows the
/// SAME nice title everywhere it appears (playlist, now-playing, Listen
/// Together picker, live share).
String cleanTrackName(String raw) {
  var n = raw;
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
  return n.isEmpty ? raw.trim() : n;
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
  final fallback = cleanedNameFromPath(path);
  final t = metadataStore.title(path, fallback);
  final out = t.trim();
  return out.isEmpty ? 'Live song' : out;
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
