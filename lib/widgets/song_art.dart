import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';

import '../services/cover_art.dart';
import '../services/song_names.dart';

/// A song's picture, the same everywhere it shows — playlist rows, the
/// mini-player, Up next, the Now Playing disc and the home music bar:
///
///   1. the cover inside the file (phones: read through the media library),
///   2. else the real cover Aluta found online for it (CoverArt),
///   3. else [fallback] (the music-note badge).
///
/// One source of truth, so a song never has art in one place and a bare
/// note in another.
class SongArt extends StatelessWidget {
  const SongArt({
    super.key,
    required this.path,
    required this.title,
    required this.artist,
    required this.size,
    required this.fallback,
    this.radius,
    this.mediaId,
    this.decode,
  });

  final String path;
  final String title;
  final String artist;
  final double size;
  final Widget fallback;

  /// null → a circle; else a rounded square with this corner radius.
  final double? radius;

  /// The song's media-library id (phones), when the caller knows it; else
  /// looked up in [ids].
  final int? mediaId;

  /// Decode size in px (defaults to ~3× the box).
  final int? decode;

  /// path → media-library id, filled as the library is read (so places
  /// that don't read it themselves — Up next — still find embedded covers).
  static final Map<String, int> ids = <String, int>{};

  /// The song the player has now (path + the title it shows), for surfaces
  /// that only know the title — the home music bar uses the art only while
  /// its title matches (a Listen Together song from someone else never gets
  /// my song's cover).
  static final ValueNotifier<({String path, String title})?> now =
      ValueNotifier<({String path, String title})?>(null);

  /// The cover key for a song known only by name (a chat song, a Listen
  /// Together song): the same key everywhere, so it's looked up once.
  static String keyFor(String title, String artist) =>
      'song:${title.trim().toLowerCase()}|${artist.trim().toLowerCase()}';

  /// Art for a song known only by its label — "Title — Artist" or a file-ish
  /// "Artist - Title". No artist → [fallback] (a title alone finds the wrong
  /// cover too often).
  /// Title + artist from a song's label, the one way every surface reads it
  /// (disc, live screen, lock-screen card) — so they share one cover lookup.
  static ({String title, String artist}) splitLabel(String label) {
    var t = label.trim(), a = '';
    final i = t.indexOf(' — ');
    if (i > 0) {
      a = t.substring(i + 3).trim();
      t = t.substring(0, i).trim();
    } else {
      final n = SongNames.instance.parseName(t);
      if (n.title.isNotEmpty) t = n.title;
      a = n.artist;
    }
    return (title: t, artist: a);
  }

  static Widget byName(String label,
      {required double size, required Widget fallback, int? decode}) {
    final ta = splitLabel(label);
    final t = ta.title, a = ta.artist;
    if (a.isEmpty || t.isEmpty) return fallback;
    return SongArt(
        path: keyFor(t, a),
        title: t,
        artist: a,
        size: size,
        fallback: fallback,
        decode: decode);
  }

  static bool get _phone =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Widget _clip(Widget child) => SizedBox(
        width: size,
        height: size,
        child: radius == null
            ? ClipOval(child: child)
            : ClipRRect(
                borderRadius: BorderRadius.circular(radius!), child: child),
      );

  @override
  Widget build(BuildContext context) {
    final px = decode ?? (size * 3).round().clamp(64, 720);
    final online = ValueListenableBuilder<int>(
      valueListenable: CoverArt.instance.version,
      builder: (context, _, _) {
        final url =
            CoverArt.instance.urlFor(path, title: title, artist: artist);
        if (url == null) return fallback;
        return _clip(CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          memCacheWidth: px,
          placeholder: (_, _) => fallback,
          errorWidget: (_, _, _) => fallback,
        ));
      },
    );
    final id = mediaId ?? ids[path];
    if (id == null || !_phone) return online;
    return _clip(QueryArtworkWidget(
      id: id,
      type: ArtworkType.AUDIO,
      artworkWidth: size,
      artworkHeight: size,
      size: px,
      artworkFit: BoxFit.cover,
      artworkBorder: BorderRadius.circular(radius ?? size / 2),
      keepOldArtwork: true,
      nullArtworkWidget: online,
    ));
  }
}
