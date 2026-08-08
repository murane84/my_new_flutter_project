import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Local cache for EPHEMERAL shared songs.
///
/// Shared songs are uploaded to the server only long enough to reach the
/// recipient: the recipient downloads the bytes, stores them here, and acks the
/// server, which then purges its copy (see routers/attachments.py). From that
/// point on both ends play the song from THIS on-device cache — the server only
/// keeps a reference row. Keyed by the attachment id embedded in the media URL
/// (`/attachments/<id>`), so a given song caches once per device.
///
/// Web has no persistent file cache here (and desktop/mobile is where music
/// lives), so on web the helpers degrade to no-ops and playback simply uses the
/// network URL while it's still available.
class SongCache {
  SongCache._();

  static Directory? _dir;

  /// Asset ids we've already acked to the server this app session, so we don't
  /// re-POST /cached on every list rebuild once a song is cached.
  static final Set<String> _acked = <String>{};

  /// Extract the attachment id from a media URL/path. Accepts a relative
  /// `/attachments/<id>` or an absolute `https://host/attachments/<id>`, with or
  /// without a trailing query string. Returns null if the URL isn't an
  /// attachment reference.
  static String? assetId(String? mediaUrl) {
    if (mediaUrl == null || mediaUrl.isEmpty) return null;
    const marker = '/attachments/';
    final i = mediaUrl.indexOf(marker);
    if (i < 0) return null;
    var id = mediaUrl.substring(i + marker.length);
    final q = id.indexOf('?');
    if (q >= 0) id = id.substring(0, q);
    final slash = id.indexOf('/');
    if (slash >= 0) id = id.substring(0, slash);
    id = id.trim();
    return id.isEmpty ? null : id;
  }

  static Future<Directory?> _cacheDir() async {
    if (kIsWeb) return null;
    if (_dir != null) return _dir;
    try {
      final base = await getApplicationSupportDirectory();
      final d = Directory('${base.path}/song_cache');
      if (!await d.exists()) await d.create(recursive: true);
      _dir = d;
      return d;
    } catch (_) {
      return null;
    }
  }

  static String _ext(String? filename, String? mime) {
    if (filename != null) {
      final dot = filename.lastIndexOf('.');
      if (dot > 0 && dot < filename.length - 1) {
        final e = filename.substring(dot).toLowerCase();
        // Guard against absurd "extensions" from odd filenames.
        if (e.length <= 6 && !e.contains('/')) return e;
      }
    }
    final m = (mime ?? '').toLowerCase();
    if (m.contains('mpeg') || m.contains('mp3')) return '.mp3';
    if (m.contains('mp4') || m.contains('aac') || m.contains('m4a')) return '.m4a';
    if (m.contains('wav')) return '.wav';
    if (m.contains('ogg') || m.contains('opus')) return '.ogg';
    if (m.contains('flac')) return '.flac';
    return '.mp3';
  }

  static Future<File?> _fileFor(String id,
      {String? filename, String? mime}) async {
    final d = await _cacheDir();
    if (d == null) return null;
    return File('${d.path}/$id${_ext(filename, mime)}');
  }

  /// The local path for [id] if it's already cached and non-empty, else null.
  static Future<String?> cachedPath(String id,
      {String? filename, String? mime}) async {
    try {
      final f = await _fileFor(id, filename: filename, mime: mime);
      if (f != null && await f.exists() && await f.length() > 0) return f.path;
    } catch (_) {}
    return null;
  }

  /// Store bytes we already hold (sender side, at send time). Returns the path.
  static Future<String?> putBytes(String id, List<int> bytes,
      {String? filename, String? mime}) async {
    try {
      if (bytes.isEmpty) return null;
      final f = await _fileFor(id, filename: filename, mime: mime);
      if (f == null) return null;
      await f.writeAsBytes(bytes, flush: true);
      return f.path;
    } catch (_) {
      return null;
    }
  }

  /// Ensure [id] is cached, downloading from [url] with [headers] if needed.
  /// Returns the local path, or null if it couldn't be cached (offline, or the
  /// server already purged it — HTTP 410 — before we fetched).
  static Future<String?> ensureCached(
    String id,
    String url,
    Map<String, String> headers, {
    String? filename,
    String? mime,
  }) async {
    final existing = await cachedPath(id, filename: filename, mime: mime);
    if (existing != null) return existing;
    try {
      final res = await http.get(Uri.parse(url), headers: headers);
      if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
        return await putBytes(id, res.bodyBytes, filename: filename, mime: mime);
      }
    } catch (_) {}
    return null;
  }

  /// Whether we've already acked [id] to the server this session.
  static bool hasAcked(String id) => _acked.contains(id);

  /// Mark [id] acked so we don't POST /cached again this session.
  static void markAcked(String id) => _acked.add(id);
}
