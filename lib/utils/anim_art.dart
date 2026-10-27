import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;

/// Animated stickers / GIF art: downloads the bytes once (shared by the
/// precache and the on-screen image) and reads how long ONE loop of the
/// animation lasts, so a status can run exactly as long as its GIF.
///
/// Supports GIF and animated WebP (the frame delays are in the file header
/// blocks — no decoding needed). Anything else reports no duration.
class AnimArt {
  AnimArt._();

  static final Map<String, Uint8List> _bytes = {};
  static final Map<String, Duration?> _loop = {};
  static final Map<String, Future<Uint8List?>> _inflight = {};
  static const int _maxEntries = 24;

  /// Bytes already downloaded for [url] (null until [load] finishes).
  static Uint8List? bytesOf(String url) => _bytes[url];

  /// A NEW image of the downloaded bytes (a fresh view, no copy): Flutter
  /// shares one animation per provider, so a fresh one always starts at
  /// frame 0 — the status timer and the GIF begin together every time.
  static MemoryImage? freshImage(String url) {
    final b = _bytes[url];
    return b == null ? null : MemoryImage(Uint8List.sublistView(b));
  }

  /// One loop of [url]'s animation, if known and animated.
  static Duration? loopOf(String url) => _loop[url];

  /// Download [url] (once; concurrent callers share the request).
  static Future<Uint8List?> load(String url,
      {Duration timeout = const Duration(seconds: 25)}) {
    final have = _bytes[url];
    if (have != null) return Future.value(have);
    final running = _inflight[url];
    if (running != null) return running;
    final f = () async {
      try {
        final res = await http.get(Uri.parse(url)).timeout(timeout);
        if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
        final b = res.bodyBytes;
        if (_bytes.length >= _maxEntries) {
          final old = _bytes.keys.first;
          _bytes.remove(old);
          _loop.remove(old);
        }
        _bytes[url] = b;
        _loop[url] = loopDuration(b);
        return b;
      } catch (_) {
        return null;
      } finally {
        _inflight.remove(url);
      }
    }();
    _inflight[url] = f;
    return f;
  }

  /// Length of one animation loop, or null for a still / unknown format.
  static Duration? loopDuration(Uint8List b) {
    try {
      if (b.length > 6 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
        return _gif(b);
      }
      if (b.length > 16 &&
          b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
          b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
        return _webp(b);
      }
    } catch (_) {}
    return null;
  }

  static Duration? _gif(Uint8List b) {
    var i = 13; // header (6) + logical screen descriptor (7)
    final packed = b[10];
    if (packed & 0x80 != 0) i += 3 * (1 << ((packed & 7) + 1));
    var frames = 0, totalMs = 0, delayCs = 0;
    void skipSubBlocks() {
      while (i < b.length) {
        final n = b[i++];
        if (n == 0) break;
        i += n;
      }
    }

    while (i < b.length) {
      final t = b[i++];
      if (t == 0x3B) break; // trailer
      if (t == 0x21) {
        final label = b[i++];
        if (label == 0xF9 && i + 4 < b.length) {
          delayCs = b[i + 2] | (b[i + 3] << 8);
          i += b[i] + 1; // block
          skipSubBlocks();
        } else {
          skipSubBlocks();
        }
      } else if (t == 0x2C) {
        if (i + 9 > b.length) break;
        final p = b[i + 8];
        i += 9;
        if (p & 0x80 != 0) i += 3 * (1 << ((p & 7) + 1));
        i++; // LZW minimum code size
        skipSubBlocks();
        frames++;
        // Browsers / Flutter treat 0–1 cs as "fast": 10 cs.
        totalMs += (delayCs <= 1 ? 10 : delayCs) * 10;
        delayCs = 0;
      } else {
        break; // corrupt — stop with what we have
      }
    }
    if (frames < 2 || totalMs <= 0) return null;
    return Duration(milliseconds: totalMs);
  }

  static Duration? _webp(Uint8List b) {
    var i = 12, frames = 0, totalMs = 0;
    while (i + 8 <= b.length) {
      final fourcc = String.fromCharCodes(b.sublist(i, i + 4));
      final size =
          b[i + 4] | (b[i + 5] << 8) | (b[i + 6] << 16) | (b[i + 7] << 24);
      final data = i + 8;
      if (fourcc == 'ANMF' && data + 15 <= b.length) {
        final d = b[data + 12] | (b[data + 13] << 8) | (b[data + 14] << 16);
        totalMs += d <= 10 ? 100 : d;
        frames++;
      }
      i = data + size + (size & 1);
    }
    if (frames < 2 || totalMs <= 0) return null;
    return Duration(milliseconds: totalMs);
  }

  /// How long a status showing this animation should run: whole loops, at
  /// least [min], at most [max] (a very long GIF is cut at [max]).
  static Duration storyLength(Duration? loop,
      {Duration min = const Duration(seconds: 5),
      Duration max = const Duration(seconds: 30)}) {
    if (loop == null || loop.inMilliseconds <= 0) return min;
    final l = loop.inMilliseconds;
    if (l >= max.inMilliseconds) return max;
    final loops = (min.inMilliseconds / l).ceil().clamp(1, 1000);
    final ms = (l * loops).clamp(min.inMilliseconds, max.inMilliseconds);
    return Duration(milliseconds: ms);
  }
}
