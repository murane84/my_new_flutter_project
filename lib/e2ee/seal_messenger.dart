import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'seal_directory.dart';
import 'seal_keystore.dart';
import 'seal_primitives.dart';
import 'seal_session.dart';

/// How a sealed message turned out on this device.
enum SealOpenStatus {
  /// Not sealed: show `content` as it is.
  plain,

  /// Unlocked (or remembered from before).
  ok,

  /// Sealed for other devices only (e.g. sent before this phone joined).
  noKey,

  /// Couldn't unlock it (keys lost, broken or replayed copy).
  failed,
}

class SealOpened {
  const SealOpened(this.status, [this.text]);
  final SealOpenStatus status;
  final String? text;
}

/// The friend has no encryption keys yet (an older Aluta): send as before.
class SealNotSupported implements Exception {}

/// Prefs-backed plaintext memory (the chat cache already holds the same text).
class _PrefsStorage implements SealStorage {
  @override
  Future<String?> read(String key) async =>
      (await SharedPreferences.getInstance()).getString(key);
  @override
  Future<void> write(String key, String value) async =>
      (await SharedPreferences.getInstance()).setString(key, value);
  @override
  Future<void> delete(String key) async =>
      (await SharedPreferences.getInstance()).remove(key);
}

/// Seals and opens 1:1 text with Aluta Seal sessions — one session per
/// friend device (keyed by that device's identity), kept in secure storage.
///
/// Every unlocked text is remembered by message id + edit revision, because
/// a ratchet key works only once: refetching history must never try again.
class SealMessenger {
  SealMessenger({
    SealKeyStore? keys,
    SealKeyDirectory? directory,
    SealStorage? sessions,
    SealStorage? plain,
    DateTime Function()? clock,
  })  : _keysOverride = keys,
        _dirOverride = directory,
        _sessionsOverride = sessions,
        _plain = plain ?? _PrefsStorage(),
        _clock = clock ?? DateTime.now;

  static final SealMessenger instance = SealMessenger();

  static const int plainCap = 3000; // per friend, like the chat cache
  static const Duration devicesFresh = Duration(minutes: 1);

  final SealKeyStore? _keysOverride;
  final SealKeyDirectory? _dirOverride;
  final SealStorage? _sessionsOverride;
  final SealStorage _plain;
  final DateTime Function() _clock;
  SealStorage? _sessionsDefault;

  SealKeyStore get _keys => _keysOverride ?? SealKeyStore.instance;
  SealKeyDirectory get _dir => _dirOverride ?? SealDirectory.instance;
  SealStorage get _sessions =>
      _sessionsOverride ?? (_sessionsDefault ??= SealKeyStore.platformStorage());

  Future<void> _lock = Future<void>.value();
  final Map<int, (DateTime, List<SealPeerDevice>)> _devices = {};
  final Map<int, Map<String, List<dynamic>>> _plainCache = {};
  final Map<int, Map<String, String>> _heldCache = {};

  Future<T> _locked<T>(Future<T> Function() f) {
    final c = Completer<T>();
    final prev = _lock;
    _lock = c.future.then<void>((_) {}, onError: (_) {});
    prev.whenComplete(() async {
      try {
        c.complete(await f());
      } catch (e, s) {
        c.completeError(e, s);
      }
    });
    return c.future;
  }

  // ── Sessions ─────────────────────────────────────────────────────────────

  static String _ikKey(String ikSigB64) =>
      base64Url.encode(base64Decode(ikSigB64)).replaceAll('=', '');
  String _sessKey(int uid, String ikSigB64) =>
      'aluta_seal_s_${uid}_${_ikKey(ikSigB64)}';
  String _peersKey(int uid) => 'aluta_seal_p_$uid';
  static const String _uidsKey = 'aluta_seal_uids';

  Future<List<String>> _peerIks(int uid) async {
    try {
      final s = await _sessions.read(_peersKey(uid));
      return s == null ? [] : (jsonDecode(s) as List).cast<String>();
    } catch (_) {
      return [];
    }
  }

  Future<SealSession?> _load(int uid, String ikSig) async {
    try {
      final s = await _sessions.read(_sessKey(uid, ikSig));
      return s == null
          ? null
          : SealSession.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _save(int uid, String ikSig, SealSession s) async {
    await _sessions.write(_sessKey(uid, ikSig), jsonEncode(s.toJson()));
    final iks = await _peerIks(uid);
    if (!iks.contains(ikSig)) {
      await _sessions.write(_peersKey(uid), jsonEncode([...iks, ikSig]));
      final raw = await _sessions.read(_uidsKey);
      final uids = raw == null ? <int>[] : (jsonDecode(raw) as List).cast<int>();
      if (!uids.contains(uid)) {
        await _sessions.write(_uidsKey, jsonEncode([...uids, uid]));
      }
    }
  }

  Future<List<SealPeerDevice>?> _devicesOf(int uid, {bool fresh = false}) async {
    final c = _devices[uid];
    if (!fresh && c != null && _clock().difference(c.$1) < devicesFresh) {
      return c.$2;
    }
    final d = await _dir.devicesOf(uid);
    if (d != null) _devices[uid] = (_clock(), d);
    return d ?? c?.$2;
  }

  // ── Sealing ──────────────────────────────────────────────────────────────

  /// Seal [text] for every device of [peerUid] and this person's other
  /// devices. Returns the envelopes ({"uid:device": b64}) to send.
  /// Throws [SealNotSupported] when the friend has no keys yet (send plain),
  /// or a [SealError] / network error when it can't seal right now (don't
  /// send plain then — the friend expects sealed text).
  Future<Map<String, String>> seal(int peerUid, int myUid, String text) =>
      _locked(() async {
        await _keys.load();
        if (!_keys.isReady) throw SealNotSupported();
        final theirs = await _devicesOf(peerUid);
        if (theirs == null) throw SealError('offline');
        if (theirs.isEmpty) throw SealNotSupported();
        final mine = (await _devicesOf(myUid) ?? const <SealPeerDevice>[])
            .where((d) => d.deviceId != _keys.deviceId);
        final plain = utf8.encode(jsonEncode({'v': 1, 't': text}));
        final out = <String, String>{};
        Future<void> one(int uid, SealPeerDevice d) async {
          var s = await _load(uid, d.ikSig);
          if (s == null) {
            final b = await _dir.bundlesFor(uid, deviceId: d.deviceId);
            final hit = b?.where((x) => x.deviceId == d.deviceId);
            if (hit == null || hit.isEmpty) throw SealError('no bundle');
            if (base64Encode(hit.first.bundle.ikSig) != d.ikSig) {
              throw SealError('identity mismatch');
            }
            s = await SealSession.start(_keys.identity, hit.first.bundle);
          }
          final env = await s.encrypt(plain);
          await _save(uid, d.ikSig, s);
          out['$uid:${d.deviceId}'] = env.toBase64();
        }

        Object? lastError;
        for (final d in theirs) {
          try {
            await one(peerUid, d);
          } catch (e) {
            lastError = e; // one stale device mustn't stop the message
          }
        }
        if (!out.keys.any((k) => k.startsWith('$peerUid:'))) {
          throw lastError ?? SealError('no device');
        }
        // A note-to-self copy, so this phone can reopen what it sent.
        out['$myUid:${_keys.deviceId}'] =
            base64Encode(await sealSelfBox(_keys.selfKey, plain));
        for (final d in mine) {
          try {
            await one(myUid, d);
          } catch (_) {/* my other device can catch up later */}
        }
        return out;
      });

  // ── Opening ──────────────────────────────────────────────────────────────

  static int _int(Object? v) => v is int ? v : int.tryParse('$v') ?? 0;

  /// Unlock a message map from the server (or the chat cache). Safe to call
  /// again and again: text is remembered by id + edit revision.
  Future<SealOpened> open(Map<String, dynamic> m, int myUid) =>
      _open(m, myUid, commit: true);

  /// Read a sealed text for a notification without moving any session on
  /// (the chat opens it for real later). Used by the background isolate.
  Future<SealOpened> peek(Map<String, dynamic> m, int myUid) =>
      _open(m, myUid, commit: false);

  Future<SealOpened> _open(Map<String, dynamic> m, int myUid,
      {required bool commit}) {
    if (m['e2ee'] == null) {
      return Future.value(const SealOpened(SealOpenStatus.plain));
    }
    return _locked(() async {
      final id = _int(m['id']);
      final rev = _int(m['e2ee_rev']);
      final sender = _int(m['sender_id']);
      final peer = sender == myUid ? _int(m['receiver_id']) : sender;
      final known = await _recall(peer, id);
      if (known != null && (known.$1 >= rev || !commit)) {
        return SealOpened(SealOpenStatus.ok, known.$2);
      }
      await _keys.load();
      final Map<String, dynamic> envs;
      try {
        envs = jsonDecode((m['envelopes'] as String?) ?? '{}')
            as Map<String, dynamic>;
      } catch (_) {
        return const SealOpened(SealOpenStatus.failed);
      }
      final mine = _keys.isReady ? envs['$myUid:${_keys.deviceId}'] : null;
      if (mine is! String) {
        // My own morning message: its text waits under the hold's id.
        final held = _heldIdOf(m['meta']);
        if (held != null) {
          final t = await recallHeld(peer, held);
          if (t != null) {
            if (commit) await _remember(peer, id, rev, t);
            return SealOpened(SealOpenStatus.ok, t);
          }
        }
        if (known != null) return SealOpened(SealOpenStatus.ok, known.$2);
        return const SealOpened(SealOpenStatus.noKey);
      }
      try {
        final text = await _decrypt(sender, mine, commit: commit);
        if (commit) await _remember(peer, id, rev, text);
        return SealOpened(SealOpenStatus.ok, text);
      } catch (_) {
        if (known != null) return SealOpened(SealOpenStatus.ok, known.$2);
        return const SealOpened(SealOpenStatus.failed);
      }
    });
  }

  static String _textOf(List<int> clear) {
    final j = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    return (j['t'] ?? '').toString();
  }

  Future<String> _decrypt(int from, String b64, {required bool commit}) async {
    final List<int> raw;
    try {
      raw = base64Decode(b64);
    } on FormatException {
      throw SealError('not base64');
    }
    if (raw.length > 2 && raw[1] == SealSpec.typeSelf) {
      return _textOf(await openSelfBox(_keys.selfKey, raw));
    }
    final env = SealEnvelope.decode(raw);
    Future<String> done(SealSession s, List<int> clear, String ik) async {
      if (commit) await _save(from, ik, s);
      return _textOf(clear);
    }

    SealSession copyOf(SealSession s) => SealSession.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);

    final pre = env.preKey;
    if (pre != null) {
      final ik = base64Encode(pre.ikSig);
      final existing = await _load(from, ik);
      if (existing != null) {
        final s = commit ? existing : copyOf(existing);
        try {
          return await done(s, await s.decrypt(env), ik);
        } on SealError {/* they started over: accept the new session */}
      }
      final spk = _keys.spkById(pre.spkId);
      if (spk == null) throw SealError('signed prekey gone');
      final opk = pre.opkId == null ? null : _keys.opkById(pre.opkId!);
      final (s, clear) =
          await SealSession.accept(_keys.identity, env, spk, opk);
      final text = await done(s, clear, ik);
      if (commit && pre.opkId != null) await _keys.takeOpk(pre.opkId!);
      return text;
    }
    for (final ik in await _peerIks(from)) {
      final stored = await _load(from, ik);
      if (stored == null) continue;
      final s = commit ? stored : copyOf(stored);
      try {
        return await done(s, await s.decrypt(env), ik);
      } on SealError {
        continue;
      }
    }
    throw SealError('no session');
  }

  // ── Remembered text ──────────────────────────────────────────────────────

  Future<Map<String, List<dynamic>>> _plainOf(int peer) async {
    final c = _plainCache[peer];
    if (c != null) return c;
    Map<String, List<dynamic>> m = {};
    try {
      final s = await _plain.read('aluta_seal_plain_$peer');
      if (s != null) {
        m = (jsonDecode(s) as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, v as List<dynamic>));
      }
    } catch (_) {}
    return _plainCache[peer] = m;
  }

  Future<(int, String)?> _recall(int peer, int id) async {
    final e = (await _plainOf(peer))['$id'];
    return e == null ? null : (_int(e[0]), e[1].toString());
  }

  Future<void> _remember(int peer, int id, int rev, String text) async {
    final m = await _plainOf(peer);
    m['$id'] = [rev, text];
    if (m.length > plainCap) {
      final ids = m.keys.map(int.parse).toList()..sort();
      for (final old in ids.take(m.length - plainCap)) {
        m.remove('$old');
      }
    }
    await _plain.write('aluta_seal_plain_$peer', jsonEncode(m));
  }

  /// My own sent / edited text (I have no envelope of my own).
  Future<void> rememberSent(int peer, int id, int rev, String text) =>
      _locked(() => _remember(peer, id, rev, text));

  /// The remembered text of a message, if this device unlocked / sent it.
  Future<String?> textOf(int peer, int id) async =>
      (await _locked(() => _recall(peer, id)))?.$2;

  static int? _heldIdOf(Object? meta) {
    if (meta is! String || !meta.contains('"held"')) return null;
    try {
      final v = (jsonDecode(meta) as Map<String, dynamic>)['held'];
      return v is int ? v : int.tryParse('$v');
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, String>> _heldOf(int peer) async {
    final c = _heldCache[peer];
    if (c != null) return c;
    Map<String, String> m = {};
    try {
      final s = await _plain.read('aluta_seal_held_$peer');
      if (s != null) {
        m = (jsonDecode(s) as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, v.toString()));
      }
    } catch (_) {}
    return _heldCache[peer] = m;
  }

  /// A morning message's text, kept until it is delivered.
  Future<void> rememberHeld(int peer, int heldId, String text) =>
      _locked(() async {
        final m = await _heldOf(peer);
        m['$heldId'] = text;
        if (m.length > 200) m.remove(m.keys.first);
        await _plain.write('aluta_seal_held_$peer', jsonEncode(m));
      });

  Future<String?> recallHeld(int peer, int heldId) async =>
      (await _heldOf(peer))['$heldId'];

  /// Sign-out: forget every session and remembered text.
  Future<void> wipe() => _locked(() async {
        try {
          final raw = await _sessions.read(_uidsKey);
          final uids =
              raw == null ? <int>[] : (jsonDecode(raw) as List).cast<int>();
          for (final uid in uids) {
            for (final ik in await _peerIks(uid)) {
              await _sessions.delete(_sessKey(uid, ik));
            }
            await _sessions.delete(_peersKey(uid));
            await _plain.delete('aluta_seal_plain_$uid');
            await _plain.delete('aluta_seal_held_$uid');
          }
          await _sessions.delete(_uidsKey);
        } catch (_) {}
        _devices.clear();
        _plainCache.clear();
        _heldCache.clear();
      });
}
