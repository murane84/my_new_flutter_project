import 'dart:convert';
import 'dart:io';

import 'package:on_audio_query/on_audio_query.dart';
import 'package:path_provider/path_provider.dart';

/// A shared, persistent cache for the device song list.
///
/// Two jobs:
///  1. Collapse the many full MediaStore scans the app used to run in quick
///     succession (every play, playlist open, launch) onto one query, coalescing
///     concurrent callers — this was part of what tripped Android's ANR.
///  2. PERSIST the last scan to disk so a cold launch — including the first
///     launch after an app update — serves the saved library instantly instead
///     of blocking on a fresh device scan. The heavy scan then runs in the
///     background (throttled), so low-end phones (e.g. Redmi) get their startup
///     headroom back and only pick up genuinely new songs. App data survives
///     updates on Android, so the saved library carries from one version to the
///     next; a brand-new install (no cache yet) scans once and saves it.
class SongLibrary {
  SongLibrary._();

  static final OnAudioQuery _q = OnAudioQuery();
  static List<SongModel>? _cache; // in-memory copy for this session
  static DateTime? _at; // when _cache was last set (memory freshness)
  static DateTime? _diskAt; // when the persisted snapshot was scanned
  static Future<List<SongModel>>? _inflight; // coalesce concurrent scans
  static bool _diskTried = false; // only hit disk once per session
  static File? _file;

  // Serve the in-memory copy without any work inside this window.
  static const Duration _memFresh = Duration(minutes: 2);
  // Don't bother background-rescanning if the saved snapshot is newer than this
  // (covers quick restarts — no redundant scan).
  static const Duration _rescanAfter = Duration(minutes: 10);

  static Future<File> _cacheFile() async {
    if (_file != null) return _file!;
    final dir = await getApplicationDocumentsDirectory();
    _file = File('${dir.path}/song_library_cache.json');
    return _file!;
  }

  /// Serve device songs (empty on failure). [force] bypasses every cache and
  /// does a fresh device scan (use for pull-to-refresh).
  static Future<List<SongModel>> songs({bool force = false}) async {
    if (!force &&
        _cache != null &&
        _at != null &&
        DateTime.now().difference(_at!) < _memFresh) {
      return _cache!;
    }
    final existing = _inflight;
    if (existing != null) return existing;

    // Cold start (nothing in memory) and not forcing: hand back the persisted
    // snapshot instantly, then refresh in the background if it's stale. This is
    // what keeps a launch/update from blocking on the full MediaStore scan.
    if (!force && _cache == null) {
      final disk = await _loadDisk();
      if (disk != null && disk.isNotEmpty) {
        _cache = disk;
        _at = DateTime.now();
        final stale = _diskAt == null ||
            DateTime.now().difference(_diskAt!) > _rescanAfter;
        if (stale) _refreshInBackground();
        return disk;
      }
    }
    return _scan();
  }

  /// Force a fresh device scan (pull-to-refresh).
  static Future<List<SongModel>> refresh() => songs(force: true);

  static Future<List<SongModel>> _scan() async {
    final f = _q.querySongs();
    _inflight = f;
    try {
      final r = await f;
      _cache = r;
      _at = DateTime.now();
      _persist(r); // fire-and-forget
      return r;
    } catch (_) {
      return _cache ?? const <SongModel>[];
    } finally {
      _inflight = null;
    }
  }

  // Run a scan a few seconds later so it never competes with first-frame work.
  static void _refreshInBackground() {
    if (_inflight != null) return;
    Future.delayed(const Duration(seconds: 4), () {
      if (_inflight != null) return;
      _scan();
    });
  }

  static Future<List<SongModel>?> _loadDisk() async {
    if (_diskTried) return _cache;
    _diskTried = true;
    try {
      final f = await _cacheFile();
      if (!await f.exists()) return null;
      final raw = await f.readAsString();
      if (raw.isEmpty) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final atMs = (map['at'] as num?)?.toInt();
      _diskAt =
          atMs != null ? DateTime.fromMillisecondsSinceEpoch(atMs) : null;
      final list = (map['songs'] as List)
          .whereType<Map>()
          .map((e) => SongModel(Map<String, dynamic>.from(e)))
          .toList();
      return list;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _persist(List<SongModel> list) async {
    try {
      final f = await _cacheFile();
      final payload = <String, dynamic>{
        'at': DateTime.now().millisecondsSinceEpoch,
        'songs': list.map((s) => s.getMap).toList(),
      };
      await f.writeAsString(jsonEncode(payload));
      _diskAt = DateTime.now();
    } catch (_) {
      // Best-effort — a failed persist just means the next launch rescans.
    }
  }

  /// Drop the in-memory copy (e.g. after the library changed). The on-disk
  /// snapshot stays until the next successful scan overwrites it.
  static void invalidate() {
    _cache = null;
    _at = null;
  }
}
