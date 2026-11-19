import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb, listEquals;
import 'package:path_provider/path_provider.dart';

import '../e2ee/seal_media.dart';
import '../screens/web_fs/blob_url.dart' show makeBlobUrl;
import '../utils/net.dart' as http;
import 'download_manager.dart';

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
    // 🔒 An opened sealed file is named by its key (each file has its own),
    // so deleting the message can find it without its address.
    final key = SealMedia.keyOf(url);
    if (key != null) return _sealedId(key);
    final u = url.split('?').first;
    final segs = u.split('/').where((x) => x.isNotEmpty).toList();
    final last = segs.isNotEmpty ? segs.last : '';
    final dot = last.lastIndexOf('.');
    final ext =
        (dot > 0 && dot < last.length - 1) ? last.substring(dot) : '';
    final h = _stableHash(u).toRadixString(16).padLeft(8, '0');
    return 'm_$h$ext';
  }

  String _sealedId(List<int> key) {
    final k = String.fromCharCodes(key);
    final a = _stableHash(k).toRadixString(16).padLeft(8, '0');
    final b = _stableHash(k.split('').reversed.join() + k)
        .toRadixString(16)
        .padLeft(8, '0');
    return 's_$a$b';
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
    // 🔒 Sealed media: fetch the locked bytes, open them with the key the
    // address carries, and keep the opened file (only ever on this device).
    final key = SealMedia.keyOf(url);
    if (key != null) return _sealedFile(url, key, headers);
    try {
      final f = await _fileFor(url);
      if (f == null) return null;
      // Streamed to disk by the app-wide DownloadManager: survives leaving
      // the screen, resumes, joins a duplicate request. Silent (no shade
      // notification) — these are photos / wallpapers / clips.
      final res = await DownloadManager.instance
          .fetch(url, f, headers: headers, notify: false);
      if (!res.ok || res.file == null) return null;
      if (res.file!.path != f.path) {
        await res.file!.copy(f.path);
      }
      return (await f.exists() && await f.length() > 0) ? f : null;
    } catch (_) {}
    return null;
  }

  Future<File?> _sealedFile(
      String url, Uint8List key, Map<String, String> headers) async {
    try {
      final f = await _fileFor(url);
      if (f == null) return null;
      final locked = File('${f.path}.locked');
      final res = await DownloadManager.instance.fetch(
          SealMedia.bare(url), locked,
          headers: headers, notify: false);
      if (!res.ok || res.file == null) return null;
      final bytes = await res.file!.readAsBytes();
      try {
        await res.file!.delete();
        if (await locked.exists()) await locked.delete();
      } catch (_) {}
      final open = await SealMedia.openInBackground(bytes, key);
      await f.writeAsBytes(open, flush: true);
      return f;
    } catch (_) {
      return null; // never hand out the locked bytes
    }
  }

  /// Opened bytes of a sealed address held in memory (the web has no disk
  /// cache) — a handful, newest kept.
  final Map<String, Uint8List> _webSealed = {};

  /// The bytes behind [url] — opened, when it's sealed media — on any
  /// platform. Null when it can't be fetched (or opened).
  Future<Uint8List?> bytes(String url, Map<String, String> headers) async {
    final key = SealMedia.keyOf(url);
    if (!kIsWeb) {
      if (key != null) {
        final f = await getFile(url, headers);
        return f?.readAsBytes();
      }
      final hit = await cached(url);
      if (hit != null) return hit.readAsBytes();
    } else if (key != null && _webSealed.containsKey(url)) {
      return _webSealed[url];
    }
    try {
      final r = await http.get(Uri.parse(SealMedia.bare(url)), headers: headers);
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
      if (key == null) return r.bodyBytes;
      final open = await SealMedia.openInBackground(r.bodyBytes, key);
      if (kIsWeb) {
        if (_webSealed.length >= 24) _webSealed.remove(_webSealed.keys.first);
        _webSealed[url] = open;
      }
      return open;
    } catch (_) {
      return null;
    }
  }

  /// Opened sealed media handed to a web player as a local blob address.
  final Map<String, String> _webBlobs = {};

  /// What a player on the WEB should load for [url]: plain media streams from
  /// its own address; sealed media is opened here first and given to the
  /// player as a local blob address, so the locked bytes never reach it.
  /// Null when sealed media can't be fetched or opened.
  Future<String?> webSource(String url, Map<String, String> headers,
      {String mime = 'application/octet-stream'}) async {
    if (!SealMedia.isSealed(url)) return url;
    final hit = _webBlobs[url];
    if (hit != null) return hit;
    final data = await bytes(url, headers);
    if (data == null) return null;
    final blob = makeBlobUrl(data, mime);
    if (blob.isEmpty) return null;
    _webBlobs[url] = blob;
    return blob;
  }

  /// Keep [data] as the file for [url] (e.g. my own sealed photo, which I
  /// already hold opened — no download, no unlocking).
  Future<void> putBytes(String url, Uint8List data) async {
    if (kIsWeb) {
      if (SealMedia.isSealed(url)) _webSealed[url] = data;
      return;
    }
    try {
      final f = await _fileFor(url);
      if (f == null) return;
      await f.writeAsBytes(data, flush: true);
    } catch (_) {}
  }

  /// Deposit an already-downloaded [src] into the cache under [url]'s key
  /// (native file copy - no bytes through the Dart heap), so a later
  /// cached(url)/getFile(url) serves it from disk with no re-download. Used
  /// when a file is fetched for one purpose (save to Downloads) and may be
  /// opened/installed later.
  Future<void> store(String url, File src) async {
    try {
      final f = await _fileFor(url);
      if (f == null || f.path == src.path) return;
      if (!await src.exists() || await src.length() == 0) return;
      await src.copy(f.path);
    } catch (_) {}
  }

  /// Drop the opened copy of sealed media locked with [key] (its message
  /// was deleted) — from disk, or from memory on the web.
  Future<void> removeSealed(List<int> key) async {
    if (kIsWeb) {
      bool same(String url) {
        final k = SealMedia.keyOf(url);
        return k != null && listEquals(k, key);
      }
      _webSealed.removeWhere((url, _) => same(url));
      _webBlobs.removeWhere((url, _) => same(url));
      return;
    }
    try {
      final d = await _base();
      if (d == null) return;
      final f = File('${d.path}/${_sealedId(key)}');
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Drop a cached file (e.g. when a background is changed/removed).
  Future<void> remove(String url) async {
    try {
      final f = await _fileFor(url);
      if (f != null && await f.exists()) await f.delete();
    } catch (_) {}
  }
}
