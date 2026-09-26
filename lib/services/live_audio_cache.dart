import 'dart:typed_data';

// Pick the disk-backed store on native (dart:io) and the in-memory store on web
// (no dart:io there). Both files define `class AudioCacheStore` with the same
// surface, so the rest of the app is platform-agnostic.
import 'live_audio_cache_web.dart'
    if (dart.library.io) 'live_audio_cache_io.dart';

/// A content-addressed cache of Listen-Together audio, so a song's bytes only
/// ever cross the wire to a device ONCE. Keyed by a stable content fingerprint
/// (see `liveTrackFingerprint`): the host offers a track's hash, and a listener
/// that already holds it plays instantly from its own copy instead of waiting
/// for the whole transfer to re-arrive.
///
/// Persistent on disk on mobile/desktop (survives restarts); an in-memory
/// fallback on web (per session). Entirely best-effort — every call is guarded,
/// so a cache failure simply degrades to the normal live stream.
class LiveAudioCache {
  LiveAudioCache._();
  static final LiveAudioCache instance = LiveAudioCache._();

  final AudioCacheStore _store = AudioCacheStore();
  bool _ready = false;
  bool _initing = false;

  /// Prepare the store (create/scan the cache dir). Idempotent + safe to call
  /// eagerly; never throws.
  Future<void> init() async {
    if (_ready || _initing) return;
    _initing = true;
    try {
      await _store.init();
      _ready = true;
    } catch (_) {
      // best-effort: leave _ready false; get/put still no-op safely.
    } finally {
      _initing = false;
    }
  }

  /// Fast, synchronous "do we already have this?" using the in-memory index.
  /// Used to answer a prefetch offer without a disk hit.
  bool hasSync(String key) {
    try {
      return _store.hasSync(key);
    } catch (_) {
      return false;
    }
  }

  /// The cached bytes for [key], or null on a miss / any error.
  Future<Uint8List?> get(String key) async {
    if (key.isEmpty) return null;
    try {
      return await _store.get(key);
    } catch (_) {
      return null;
    }
  }

  /// Store [bytes] under [key] (best-effort). Evicts oldest entries past the cap.
  Future<void> put(String key, Uint8List bytes) async {
    if (key.isEmpty || bytes.isEmpty) return;
    try {
      await _store.put(key, bytes);
    } catch (_) {}
  }

  /// The hashes currently held — for the session-start "manifest" exchange, so a
  /// partner knows which songs this device can play with zero transfer. Capped
  /// to bound the control message size.
  List<String> knownKeys({int max = 1500}) {
    try {
      final k = _store.knownKeys();
      return k.length > max ? k.sublist(0, max) : k;
    } catch (_) {
      return const <String>[];
    }
  }
}

/// A stable, web-safe content fingerprint for a track's bytes: total length plus
/// a fixed set of bytes sampled evenly across the file. Deterministic (same file
/// → same id on any device, this session or a future one) and cheap — it reads
/// only ~48 bytes regardless of song size, and uses no 64-bit integer math (so
/// it is identical on native and on web, where ints are doubles).
String liveTrackFingerprint(Uint8List b) {
  final n = b.length;
  if (n == 0) return '0';
  const samples = 48;
  final sb = StringBuffer()..write(n);
  for (var i = 0; i < samples; i++) {
    final idx = n == 1 ? 0 : ((i * (n - 1)) ~/ (samples - 1));
    sb
      ..write('_')
      ..write(b[idx].toRadixString(16));
  }
  return sb.toString();
}
