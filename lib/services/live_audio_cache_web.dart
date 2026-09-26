import 'dart:typed_data';

/// In-memory audio cache used on web (no dart:io there, so no disk). Keyed by
/// the content fingerprint, capped by total size with a simple move-to-front
/// LRU. Per-session only — a page reload starts empty — which is the graceful
/// web fallback for the persistent native cache.
class AudioCacheStore {
  static const int _maxBytes = 120 * 1024 * 1024; // 120 MB in memory

  // LinkedHashMap iteration order = insertion order; we re-insert on access to
  // approximate LRU (first key = least recently used).
  final Map<String, Uint8List> _mem = <String, Uint8List>{};
  int _total = 0;

  Future<void> init() async {}

  bool hasSync(String key) => _mem.containsKey(key);

  List<String> knownKeys() => _mem.keys.toList();

  Future<Uint8List?> get(String key) async {
    final v = _mem.remove(key);
    if (v == null) return null;
    _mem[key] = v; // move to most-recently-used
    return v;
  }

  Future<void> put(String key, Uint8List bytes) async {
    if (_mem.containsKey(key)) {
      final v = _mem.remove(key)!;
      _mem[key] = v;
      return;
    }
    _mem[key] = bytes;
    _total += bytes.length;
    while (_total > _maxBytes && _mem.isNotEmpty) {
      final oldest = _mem.keys.first;
      _total -= _mem.remove(oldest)?.length ?? 0;
    }
  }
}
