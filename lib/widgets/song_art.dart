import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';

import '../services/cover_art.dart';

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
