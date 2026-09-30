import 'package:on_audio_query/on_audio_query.dart';

/// A tiny shared cache for the device song list.
///
/// The app was running the (expensive) full MediaStore scan several times in
/// quick succession — on every play (metadata + content-URI resolve), when the
/// playlist opened, and at launch — which hammered the platform thread and was
/// part of what tripped Android's "isn't responding" (ANR). This caches one
/// scan for a short window and coalesces concurrent callers onto a single query.
class SongLibrary {
  SongLibrary._();

  static final OnAudioQuery _q = OnAudioQuery();
  static List<SongModel>? _cache;
  static DateTime? _at;
  static Future<List<SongModel>>? _inflight;

  /// Cached device songs (empty on failure). Pass [force] to bypass the cache.
  static Future<List<SongModel>> songs({bool force = false}) async {
    if (!force &&
        _cache != null &&
        _at != null &&
        DateTime.now().difference(_at!) < const Duration(minutes: 2)) {
      return _cache!;
    }
    // Coalesce: many callers during one play share a single scan.
    final existing = _inflight;
    if (existing != null) return existing;
    final f = _q.querySongs();
    _inflight = f;
    try {
      final r = await f;
      _cache = r;
      _at = DateTime.now();
      return r;
    } catch (_) {
      return _cache ?? const <SongModel>[];
    } finally {
      _inflight = null;
    }
  }

  /// Drop the cache (e.g. after the library changed).
  static void invalidate() {
    _cache = null;
    _at = null;
  }
}
