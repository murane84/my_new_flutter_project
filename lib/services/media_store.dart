import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// A small on-device cache for downloaded media (space background photos,
/// pinned-moment photos/voice, …), keyed by the attachment id in its URL.
///
/// Why: the server keeps almost nothing long-term, and the desktop image
/// loaders don't persist to disk, so a photo would vanish offline / after a
/// restart. This writes each fetched image to app-support storage once, then
/// serves it from disk forever after — so memories survive with no connection,
/// and it's the store that makes purging moment media on the server safe.
class MediaStore {
  MediaStore._();
  static final MediaStore instance = MediaStore._();

  Directory? _dir;

  Future<Directory?> _base() async {
    if (kIsWeb) return null; // no persistent FS on web
    if (_dir != null) return _dir;
    try {
      final base = await getApplicationSupportDirectory();
      final d = Directory('${base.path}/media_store');
      if (!await d.exists()) await d.create(recursive: true);
      _dir = d;
      return d;
    } catch (_) {
      return null;
    }
  }

  /// A stable, collision-free cache-file name for [url].
  ///
  /// Keying on the last path segment alone is unsafe: many CDNs (notably
  /// GIPHY) serve EVERY item under the same file name ("giphy.gif"), with the
  /// unique id earlier in the path — so that scheme collapses every GIF /
  /// sticker onto one cache file and the first one ever cached is then shown
  /// for all of them. Instead we hash the FULL query-stripped URL (a stable,
  /// cross-run FNV-1a hash) and keep the original extension for readability.
  String _idFor(String url) {
    final u = url.split('?').first;
    final segs = u.split('/').where((x) => x.isNotEmpty).toList();
    final last = segs.isNotEmpty ? segs.last : '';
    final dot = last.lastIndexOf('.');
    final ext =
        (dot > 0 && dot < last.length - 1) ? last.substring(dot) : '';
    final h = _stableHash(u).toRadixString(16).padLeft(8, '0');
    return 'm_$h$ext';
  }

  /// Deterministic 32-bit FNV-1a hash — stable across app runs (unlike
  /// String.hashCode, which Dart does not guarantee to be), so the disk cache
  /// keeps hitting after a restart.
  int _stableHash(String s) {
    int h = 0x811c9dc5;
    for (final u in s.codeUnits) {
      h = (h ^ u) & 0xFFFFFFFF;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h;
  }

  Future<File?> _fileFor(String url) async {
    final d = await _base();
    if (d == null) return null;
    return File('${d.path}/${_idFor(url)}');
  }

  /// The already-cached file for [url], or null if it isn't on disk yet.
  Future<File?> cached(String url) async {
    try {
      final f = await _fileFor(url);
      if (f != null && await f.exists() && await f.length() > 0) return f;
    } catch (_) {}
    return null;
  }

  /// The local file for [url]: returns the cached copy if present, otherwise
  /// downloads it (with [headers] for auth), persists it, and returns it.
  /// Returns null when offline-and-uncached or on any failure — callers then
  /// fall back to a network image (or the default backdrop).
  Future<File?> getFile(String url, Map<String, String> headers) async {
    final hit = await cached(url);
    if (hit != null) return hit;
    if (kIsWeb) return null;
    try {
      final res = await http.get(Uri.parse(url), headers: headers);
      if (res.statusCode >= 200 &&
          res.statusCode < 300 &&
          res.bodyBytes.isNotEmpty) {
        final f = await _fileFor(url);
        if (f == null) return null;
        await f.writeAsBytes(res.bodyBytes, flush: true);
        return f;
      }
    } catch (_) {}
    return null;
  }

  /// Drop a cached file (e.g. when a background is changed/removed).
  Future<void> remove(String url) async {
    try {
      final f = await _fileFor(url);
      if (f != null && await f.exists()) await f.delete();
    } catch (_) {}
  }
}
