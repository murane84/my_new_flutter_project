import 'dart:convert';

import 'seal_scope.dart';
import 'seal_space.dart';

/// 🔒 A group poll's question and options sealed with the group's key.
///
/// The server keeps the poll as `{"sealed": "🔒s1…", "n": 3, "multi": …,
/// "kind": …, "votes": {uid: [index]}}`: it counts votes by NUMBER and runs
/// a jam's clock, but can't read what the question or the options say. The
/// words (`q`, `options`, a decider's `rest`) live only inside `sealed`.
class SealPolls {
  SealPolls._();

  /// Opened words by their sealed string (stable while votes change).
  static final Map<String, Map<String, dynamic>> _words = {};
  static final Map<String, Future<bool>> _opening = {};
  // Couldn't open (no key yet): asked again only after a minute, not on
  // every repaint.
  static final Map<String, DateTime> _failedAt = {};

  static const _wordKeys = ['q', 'options', 'rest'];

  /// [specJson] (the composer's poll) with its words sealed for [members].
  static Future<String> sealSpec(Iterable<int> members, String specJson,
      {bool stay = false}) async {
    final spec = Map<String, dynamic>.from(jsonDecode(specJson) as Map);
    final words = {
      for (final k in _wordKeys)
        if (spec[k] != null) k: spec[k],
    };
    final sealed = await SealSpace.instance
        .seal(members, jsonEncode(words), stay: stay);
    if (!SealScope.isSealed(sealed)) throw StateError('poll not sealed');
    _words[sealed] = words;
    final out = Map<String, dynamic>.from(spec)
      ..removeWhere((k, _) => _wordKeys.contains(k))
      ..['sealed'] = sealed
      ..['n'] = (spec['options'] as List?)?.length ?? 0;
    return jsonEncode(out);
  }

  /// Sign-out: nothing opened stays in memory.
  static void forget() {
    _words.clear();
    _failedAt.clear();
  }

  /// The words of a sealed poll this device has opened (null: not yet).
  static Map<String, dynamic>? wordsOf(String sealed) => _words[sealed];

  /// [poll] (a decoded server poll) with its words put back, when they're
  /// open here; unchanged otherwise (an ordinary poll too).
  static Map<String, dynamic> merged(Map<String, dynamic> poll) {
    final s = poll['sealed'];
    if (s is! String) return poll;
    final w = _words[s];
    if (w == null) return poll;
    return {...poll, ...w};
  }

  /// A sealed poll that still needs opening (no words here yet).
  static String? pending(Map<String, dynamic> poll) {
    final s = poll['sealed'];
    return s is String && !_words.containsKey(s) ? s : null;
  }

  /// Open [sealed] (once at a time): true when its words are now here.
  static Future<bool> open(String sealed) {
    if (_words.containsKey(sealed)) return Future.value(true);
    final f = _failedAt[sealed];
    if (f != null && DateTime.now().difference(f).inSeconds < 60) {
      return Future.value(false);
    }
    return _opening.putIfAbsent(sealed, () async {
      try {
        final t = await SealSpace.instance.open(sealed);
        if (SealScope.isSealed(t) ||
            t == SealSpace.waitingForKey ||
            t == SealSpace.unlockFailed) {
          _failedAt[sealed] = DateTime.now();
          return false;
        }
        final d = jsonDecode(t);
        if (d is! Map) return false;
        _words[sealed] = Map<String, dynamic>.from(d);
        return true;
      } catch (_) {
        _failedAt[sealed] = DateTime.now();
        return false;
      } finally {
        // Block body: whenComplete would wait on the returned future.
        Future<void>.microtask(() {
          _opening.remove(sealed);
        });
      }
    });
  }

  /// A message's poll opened in place (its words merged into `poll`).
  static Future<void> openIn(Map<String, dynamic> m) async {
    final p = _decode(m['poll']);
    final s = p == null ? null : pending(p);
    if (s != null) await open(s);
    if (p != null && p['sealed'] is String) {
      m['poll'] = jsonEncode(merged(p));
    }
  }

  /// The server's answer to my own poll, with the words I just sealed.
  static String? mergeRaw(Object? serverPoll, String specJson) {
    final p = _decode(serverPoll);
    if (p == null) return serverPoll?.toString();
    return jsonEncode(merged(p));
  }

  static Map<String, dynamic>? _decode(Object? raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is! String || raw.isEmpty) return null;
    try {
      final d = jsonDecode(raw);
      return d is Map ? Map<String, dynamic>.from(d) : null;
    } catch (_) {
      return null;
    }
  }
}
