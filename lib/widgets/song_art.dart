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

  /// Big frames (Now Playing discs, Polaroid, Boombox…) show the WHOLE
  /// cover: fitted inside, over a soft blurred copy of itself filling the
  /// frame — a portrait or wide photo is never cropped. Small thumbnails
  /// (rows, chips) keep the simple fill.
  bool get _whole => size >= 72;

  Widget _clip(BuildContext context, Widget child) {
    final r = radius ?? ArtShape.radiusOf(context);
    return SizedBox(
      width: size,
      height: size,
      child: r == null
          ? ClipOval(child: child)
          : ClipRRect(borderRadius: BorderRadius.circular(r), child: child),
    );
  }

  /// [fill] (a tiny, naturally blurry decode) under [sharp] (contain-fit),
  /// darkened a touch so the photo stands out.
  Widget _wholeStack(Widget fill, Widget sharp) => Stack(
        fit: StackFit.expand,
        children: [
          fill,
          ColoredBox(color: Colors.black.withValues(alpha: 0.22)),
          sharp,
        ],
      );

  @override
  Widget build(BuildContext context) {
    final px = decode ?? (size * 3).round().clamp(64, 720);
    final whole = _whole;
    final online = ValueListenableBuilder<int>(
      valueListenable: CoverArt.instance.version,
      builder: (context, _, _) {
        final url =
            CoverArt.instance.urlFor(path, title: title, artist: artist);
        if (url == null) return fallback;
        Widget img(BoxFit fit, int w) => CachedNetworkImage(
              imageUrl: url,
              fit: fit,
              memCacheWidth: w,
              filterQuality: FilterQuality.medium,
              placeholder: (_, _) => fallback,
              errorWidget: (_, _, _) => fallback,
            );
        return _clip(
            context,
            whole
                ? _wholeStack(img(BoxFit.cover, 24), img(BoxFit.contain, px))
                : img(BoxFit.cover, px));
      },
    );
    final id = mediaId ?? ids[path];
    if (id == null || !_phone) return online;
    Widget art(BoxFit fit, int s, {Widget? none}) => QueryArtworkWidget(
          id: id,
          type: ArtworkType.AUDIO,
          artworkWidth: size,
          artworkHeight: size,
          size: s,
          artworkFit: fit,
          artworkBorder: BorderRadius.zero,
          keepOldArtwork: true,
          nullArtworkWidget: none ?? const SizedBox.shrink(),
        );
    if (!whole) {
      return _clip(context, art(BoxFit.cover, px, none: online));
    }
    // The sharp layer carries the "no cover in the file" fallback (online
    // cover / note) so a song without one looks exactly as before.
    return _clip(
        context,
        _wholeStack(art(BoxFit.cover, 24),
            art(BoxFit.contain, px, none: online)));
  }
}

/// Lets a square frame ask the art inside it for a rounded square instead
/// of a circle (SongArt's default) — Polaroid / Boombox windows.
class ArtShape extends InheritedWidget {
  const ArtShape({super.key, required this.radius, required super.child});

  final double radius;

  static double? radiusOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ArtShape>()?.radius;

  @override
  bool updateShouldNotify(ArtShape old) => old.radius != radius;
}
