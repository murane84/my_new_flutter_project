import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/api_service.dart';

/// Real album covers for songs that have none (only a music-note badge).
///
/// Asked once per song — only when its artist is known (a title alone finds
/// the wrong cover too often) — through the Aluta server, which answers only
/// on a close title + artist match. The answer (a cover, or "none") is kept
/// on the device, so each song is looked up once. Covers the file already
/// has always win; ⋮ → "Wrong cover" removes one for good.
class CoverArt {
  CoverArt._();
  static final CoverArt instance = CoverArt._();

  static const _kUrls = 'cover_art_urls_v1';
  static const _kWrong = 'cover_art_wrong_v1';

  /// Bumped whenever a lookup lands, so rows rebuild.
  final ValueNotifier<int> version = ValueNotifier<int>(0);

  final Map<String, String> _urls = {}; // path → url ('' = no cover found)
  final Set<String> _wrong = {};
  final List<(String, String, String)> _queue = []; // path, title, artist
  final Set<String> _queued = {};
  bool _loaded = false, _ready = false, _running = false;
  int _lookupsThisRun = 0;
  // Server / network trouble → wait before asking again (no hammering on
  // every rebuild).
  DateTime _pauseUntil = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kUrls);
      if (raw != null) {
        (jsonDecode(raw) as Map).forEach((k, v) {
          if (k is String && v is String) _urls[k] = v;
        });
      }
      _wrong.addAll(p.getStringList(_kWrong) ?? const []);
    } catch (_) {}
    _ready = true; // only now is "not looked up yet" really unknown
    version.value++;
  }

  /// The cover to show for [path], or null. Unknown → looked up quietly in
  /// the background (rows rebuild via [version] when it lands).
  String? urlFor(String path, {required String title, required String artist}) {
    if (!_ready) {
      _load();
      return null;
    }
    if (_wrong.contains(path)) return null;
    final u = _urls[path];
    if (u != null) return u.isEmpty ? null : u;
    if (kIsWeb || title.trim().isEmpty || artist.trim().isEmpty) return null;
    if (DateTime.now().isBefore(_pauseUntil)) return null;
    if (_queued.add(path)) {
      _queue.add((path, title, artist));
      _pump();
    }
    return null;
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      // Gentle: one at a time, a short gap, at most 150 lookups per run.
      while (_queue.isNotEmpty && _lookupsThisRun < 150) {
        final (path, title, artist) = _queue.removeAt(0);
        _lookupsThisRun++;
        final url = await ApiService().coverFor(title: title, artist: artist);
        if (url == null) {
          // Offline / server busy: drop the queue, try again in 10 minutes.
          _pauseUntil = DateTime.now().add(const Duration(minutes: 10));
          for (final q in _queue) {
            _queued.remove(q.$1);
          }
          _queue.clear();
          _queued.remove(path);
          break;
        }
        _urls[path] = url; // '' = looked, nothing close enough
        version.value++;
        await Future.delayed(const Duration(milliseconds: 250));
      }
      final p = await SharedPreferences.getInstance();
      await p.setString(_kUrls, jsonEncode(_urls));
    } catch (_) {
    } finally {
      _running = false;
    }
  }

  bool hasCover(String path) =>
      !_wrong.contains(path) && (_urls[path]?.isNotEmpty ?? false);

  /// ⋮ → "Wrong cover": never show one for this song again.
  Future<void> markWrong(String path) async {
    _wrong.add(path);
    version.value++;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_kWrong, _wrong.toList());
    } catch (_) {}
  }
}
