import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-edited track details, keyed by file path.
///
/// We deliberately DON'T rewrite the device's audio files — doing so needs the
/// all-files-access permission that Google Play restricts. Instead these custom
/// details are stored by the app and applied everywhere a song is shown
/// (playlist, now-playing bar, footer, media notification, live share). This is
/// permission-free and Play-compliant.
class TrackMeta {
  final String? title;
  final String? artist;
  final String? album;
  final String? genre;
  final String? year;

  const TrackMeta({
    this.title,
    this.artist,
    this.album,
    this.genre,
    this.year,
  });

  bool get isEmpty =>
      (title == null || title!.trim().isEmpty) &&
      (artist == null || artist!.trim().isEmpty) &&
      (album == null || album!.trim().isEmpty) &&
      (genre == null || genre!.trim().isEmpty) &&
      (year == null || year!.trim().isEmpty);

  Map<String, dynamic> toJson() => {
        if (title != null) 't': title,
        if (artist != null) 'a': artist,
        if (album != null) 'al': album,
        if (genre != null) 'g': genre,
        if (year != null) 'y': year,
      };

  factory TrackMeta.fromJson(Map<String, dynamic> j) => TrackMeta(
        title: j['t'] as String?,
        artist: j['a'] as String?,
        album: j['al'] as String?,
        genre: j['g'] as String?,
        year: j['y'] as String?,
      );
}

class MetadataStore extends ChangeNotifier {
  final Map<String, TrackMeta> _m = {};
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('track_meta_overrides');
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        decoded.forEach((k, v) {
          _m[k] = TrackMeta.fromJson((v as Map).cast<String, dynamic>());
        });
      }
    } catch (_) {}
    notifyListeners();
  }

  TrackMeta? of(String path) => _m[path];

  Future<void> set(String path, TrackMeta meta) async {
    if (meta.isEmpty) {
      _m.remove(path);
    } else {
      _m[path] = meta;
    }
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      final map = _m.map((k, v) => MapEntry(k, v.toJson()));
      await p.setString('track_meta_overrides', jsonEncode(map));
    } catch (_) {}
  }

  /// Effective title with fallback to the file-derived name.
  String title(String path, String fallback) {
    final t = _m[path]?.title;
    return (t != null && t.trim().isNotEmpty) ? t.trim() : fallback;
  }

  /// Effective artist with fallback.
  String artist(String path, String fallback) {
    final a = _m[path]?.artist;
    return (a != null && a.trim().isNotEmpty) ? a.trim() : fallback;
  }
}

final metadataStore = MetadataStore();
