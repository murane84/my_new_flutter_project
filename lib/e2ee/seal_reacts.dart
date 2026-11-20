import 'dart:convert';

import 'seal_scope.dart';
import 'seal_space.dart';

/// 🔒 Message reactions sealed for the chat: in a sealed 1:1 the emoji is
/// locked with the two people's key, in a sealed group with the group's.
///
/// The server keeps `{"<user id>": "🔒s1…"}` — who reacted and when, never
/// with what. Every sealed reaction has its own lock (a fresh nonce), so to
/// take mine back the app sends my stored sealed value again (the server's
/// "same value again = remove").
class SealReacts {
  SealReacts._();

  static final Map<String, String> _emoji = {};
  static final Map<String, Future<bool>> _opening = {};
  // A reaction this device couldn't open (no key yet): asked again only
  // after a minute, not on every repaint.
  static final Map<String, DateTime> _failedAt = {};

  /// Sign-out: nothing opened stays in memory.
  static void forget() {
    _emoji.clear();
    _failedAt.clear();
  }

  /// Lock [emoji] for [members].
  static Future<String> seal(Iterable<int> members, String emoji,
      {bool stay = false}) async {
    final s = await SealSpace.instance.seal(members, emoji, stay: stay);
    if (SealScope.isSealed(s)) _emoji[s] = emoji;
    return s;
  }

  /// The raw `{uid: value}` map (values as the server has them).
  static Map<String, String> raw(Object? reactions) {
    if (reactions == null || (reactions is String && reactions.isEmpty)) {
      return const {};
    }
    try {
      final d = reactions is String ? jsonDecode(reactions) : reactions;
      if (d is Map) {
        return d.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {}
    return const {};
  }

  /// `{uid: emoji}` with sealed ones opened. One not open yet is left out
  /// for now and opened in the background — [onOpened] then repaints.
  static Map<String, String> opened(Object? reactions,
      {void Function()? onOpened}) {
    final out = <String, String>{};
    raw(reactions).forEach((uid, v) {
      if (!SealScope.isSealed(v)) {
        out[uid] = v;
        return;
      }
      final e = _emoji[v];
      if (e != null) {
        out[uid] = e;
      } else {
        _open(v).then((ok) {
          if (ok) onOpened?.call();
        });
      }
    });
    return out;
  }

  /// Open every sealed reaction in [reactions] (before reading them, e.g.
  /// to play a friend's new one as it lands).
  static Future<void> openAll(Object? reactions) async {
    for (final v in raw(reactions).values) {
      if (SealScope.isSealed(v)) await _open(v);
    }
  }

  /// The JSON string of [opened] (for code that reads `reactions` as text).
  static String? openedJson(Object? reactions, {void Function()? onOpened}) {
    final m = opened(reactions, onOpened: onOpened);
    return m.isEmpty ? null : jsonEncode(m);
  }

  static Future<bool> _open(String sealed) {
    if (_emoji.containsKey(sealed)) return Future.value(true);
    final f = _failedAt[sealed];
    if (f != null && DateTime.now().difference(f).inSeconds < 60) {
      return Future.value(false);
    }
    return _opening.putIfAbsent(sealed, () async {
      try {
        final t = await SealSpace.instance.open(sealed);
        // An emoji (or a "🎵 <title>" song reaction) is short; anything
        // else is a lock note or still sealed.
        if (SealScope.isSealed(t) ||
            t == SealSpace.waitingForKey ||
            t == SealSpace.unlockFailed ||
            t.isEmpty ||
            t.length > 80) {
          _failedAt[sealed] = DateTime.now();
          return false;
        }
        _emoji[sealed] = t;
        return true;
      } catch (_) {
        _failedAt[sealed] = DateTime.now();
        return false;
      } finally {
        Future<void>.microtask(() {
          _opening.remove(sealed);
        });
      }
    });
  }
}
