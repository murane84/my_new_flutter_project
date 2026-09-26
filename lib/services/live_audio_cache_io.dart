import 'dart:io';
import 'dart:typed_data';

/// Disk-backed audio cache for native platforms (Android / iOS / desktop).
/// Files live under a private cache directory (the OS may reclaim it under
/// storage pressure — fine for a cache), keyed by the content fingerprint.
/// A simple LRU (by last-modified time) keeps the total under [_maxBytes].
class AudioCacheStore {
  static const int _maxBytes = 400 * 1024 * 1024; // 400 MB

  Directory? _dir;
  // In-memory index so hasSync() is instant and eviction needn't re-stat.
  final Map<String, int> _sizes = {}; // key -> byte length
  final Map<String, int> _used = {}; // key -> last-used epoch ms (LRU)
  int _total = 0;

  Future<void> init() async {
    final d = Directory('${Directory.systemTemp.path}/aluta_live_cache');
    if (!await d.exists()) {
      await d.create(recursive: true);
    }
    _dir = d;
    _sizes.clear();
    _used.clear();
    _total = 0;
    // Rebuild the index from whatever survived on disk.
    await for (final e in d.list(followLinks: false)) {
      if (e is File) {
        try {
          final st = await e.stat();
          final key = _basename(e.path);
          _sizes[key] = st.size;
          _used[key] = st.modified.millisecondsSinceEpoch;
          _total += st.size;
        } catch (_) {}
      }
    }
  }

  String _basename(String path) {
    final i = path.lastIndexOf(Platform.pathSeparator);
    return i < 0 ? path : path.substring(i + 1);
  }

  File _fileFor(String key) =>
      File('${_dir!.path}${Platform.pathSeparator}$key');

  bool hasSync(String key) => _sizes.containsKey(key);

  List<String> knownKeys() => _sizes.keys.toList();

  Future<Uint8List?> get(String key) async {
    if (_dir == null || !_sizes.containsKey(key)) return null;
    final f = _fileFor(key);
    if (!await f.exists()) {
      _drop(key);
      return null;
    }
    final bytes = await f.readAsBytes();
    // Touch it so LRU treats it as recently used.
    _used[key] = DateTime.now().millisecondsSinceEpoch;
    try {
      await f.setLastModified(DateTime.now());
    } catch (_) {}
    return bytes;
  }

  Future<void> put(String key, Uint8List bytes) async {
    if (_dir == null) return;
    if (_sizes.containsKey(key)) {
      _used[key] = DateTime.now().millisecondsSinceEpoch;
      return;
    }
    final f = _fileFor(key);
    await f.writeAsBytes(bytes, flush: false);
    _sizes[key] = bytes.length;
    _used[key] = DateTime.now().millisecondsSinceEpoch;
    _total += bytes.length;
    await _evictIfNeeded();
  }

  void _drop(String key) {
    _total -= _sizes.remove(key) ?? 0;
    _used.remove(key);
  }

  Future<void> _evictIfNeeded() async {
    if (_total <= _maxBytes) return;
    final keys = _used.keys.toList()
      ..sort((a, b) => (_used[a] ?? 0).compareTo(_used[b] ?? 0));
    for (final k in keys) {
      if (_total <= _maxBytes) break;
      try {
        await _fileFor(k).delete();
      } catch (_) {}
      _drop(k);
    }
  }
}
