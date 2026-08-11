import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/api_service.dart';

/// User-edited track details, keyed by file path.
///
/// We deliberately DON'T rewrite the device's audio files — doing so needs the
/// all-files-access permission that Google Play restricts. Instead these custom
/// details are stored by the app and applied everywhere a song is shown
/// (playlist, now-playing bar, footer, media notification, live share). This is
/// permission-free and Play-compliant.
///
/// These edits are ALSO backed up to the user's account (see [pullFromServer] /
/// [_schedulePush]) so they survive an app reinstall/update or a move to a new
/// device on the same account — otherwise they'd live only in local prefs and
/// vanish whenever the app's private storage is wiped.
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
  static const _prefsKey = 'track_meta_overrides';

  final Map<String, TrackMeta> _m = {};
  bool _loaded = false;

  // --- account backup state ---
  // We only push the full map to the server AFTER a successful pull+merge, so a
  // race (user edits before the pull lands) can never overwrite the server's
  // copy with a near-empty local map. Any edit made before the first pull is
  // still captured, because pullFromServer() pushes the merged union at the end.
  bool _synced = false;
  Timer? _pushTimer;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_prefsKey);
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
    await _persistLocal();
    // Back the change up to the account (debounced) once the initial pull+merge
    // has happened. Before that, pullFromServer() will push the merged union
    // (which includes this edit), so nothing is lost.
    if (_synced) _schedulePush();
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

  // -------------------------------------------------------------------------
  // Account backup / restore
  // -------------------------------------------------------------------------

  /// Pull the account's backed-up edits and MERGE them in (local edits win on
  /// conflict), then push the merged result back once so the server converges
  /// and any pre-existing local-only edits get backed up. Call this after login
  /// (e.g. when Home mounts). Safe to call more than once — it only pulls once.
  Future<void> pullFromServer() async {
    if (_synced) return;
    // Make sure local prefs are loaded first so "local wins" is meaningful.
    await load();
    try {
      final remote = await ApiService().fetchTrackOverrides();
      var changed = false;
      remote.forEach((path, json) {
        // Local edit for this path always wins; only fill in what we don't have.
        if (!_m.containsKey(path)) {
          try {
            final meta = TrackMeta.fromJson(json.cast<String, dynamic>());
            if (!meta.isEmpty) {
              _m[path] = meta;
              changed = true;
            }
          } catch (_) {}
        }
      });
      if (changed) {
        await _persistLocal();
        notifyListeners();
      }
    } catch (_) {
      // Offline / not logged in — leave _synced false so the next launch pulls
      // again and then pushes the merged union (any edits made meanwhile ride
      // along in that push).
      return;
    }
    _synced = true;
    // Converge the server with the merged union (covers first-run migration of
    // existing local-only edits and any edits made during the pull).
    _pushNow();
  }

  Future<void> _persistLocal() async {
    try {
      final p = await SharedPreferences.getInstance();
      final map = _m.map((k, v) => MapEntry(k, v.toJson()));
      await p.setString(_prefsKey, jsonEncode(map));
    } catch (_) {}
  }

  // Debounce rapid successive edits into a single upload.
  void _schedulePush() {
    _pushTimer?.cancel();
    _pushTimer = Timer(const Duration(milliseconds: 1200), _pushNow);
  }

  void _pushNow() {
    _pushTimer?.cancel();
    final map = _m.map((k, v) => MapEntry(k, v.toJson()));
    // Fire-and-forget; a failed upload just means we retry on the next edit or
    // next launch's pull-then-push.
    ApiService().uploadTrackOverrides(map);
  }

  @override
  void dispose() {
    _pushTimer?.cancel();
    super.dispose();
  }
}

final metadataStore = MetadataStore();
