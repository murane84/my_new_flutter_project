import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'seal_directory.dart';
import 'seal_keystore.dart';
import 'seal_primitives.dart';
import 'seal_session.dart';
import 'seal_tab.dart';

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

  /// What was sealed, as remembered: plain text, or [SealPayload] form
  /// for a message carrying sealed media.
  final String? text;

  /// The words (a sealed photo's caption, or the text).
  String get caption => SealPayload.textOf(text);

  /// A sealed photo / video / voice note / file: {k, n, mm} (key, name,
  /// type), or null.
  Map<String, dynamic>? get media => SealPayload.mediaOf(text);
}

/// How a sealed message is remembered on the device: plain text, or — when
/// it carries sealed media — "\u0001" + JSON {t, m}, so its file key, real
/// name and type stay with its words (and travel in a QR hand-over).
class SealPayload {
  SealPayload._();
  static const String _mark = '\u0001';

  static String store(String text, Map<String, dynamic>? media) =>
      media == null ? text : '$_mark${jsonEncode({'t': text, 'm': media})}';

  static String textOf(String? stored) {
    if (stored == null) return '';
    if (!stored.startsWith(_mark)) return stored;
    try {
      final j = jsonDecode(stored.substring(1)) as Map<String, dynamic>;
      return (j['t'] ?? '').toString();
    } catch (_) {
      return '';
    }
  }

  static Map<String, dynamic>? mediaOf(String? stored) {
    if (stored == null || !stored.startsWith(_mark)) return null;
    try {
      final m = (jsonDecode(stored.substring(1)) as Map<String, dynamic>)['m'];
      return m is Map<String, dynamic> ? m : null;
    } catch (_) {
      return null;
    }
  }
}

/// The friend has no encryption keys yet (an older Aluta): send as before.
class SealNotSupported implements Exception {}

/// The friend's chat was end-to-end encrypted, but none of their devices
/// has keys right now (signed out everywhere — or a server pretending so).
/// Never a reason to send in the clear: the send fails instead.
class SealPeerAway extends SealError {
  SealPeerAway() : super('friend has no keys right now');
}

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
  /// How long a device list is trusted: short, so a just-linked computer
  /// (or a friend's new phone) gets sealed copies within seconds.
  static const Duration devicesFresh = Duration(seconds: 20);

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
  // Keyed '<device id>:<peer>' (see [_ns]).
  final Map<String, Map<String, List<dynamic>>> _plainCache = {};
  final Map<String, Map<String, String>> _heldCache = {};

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
  // Sessions belong to THIS device identity: another account signed in on
  // the same phone (new keys, new device id) never picks them up — it would
  // seal with someone else's session and nothing it sent could be opened.
  String get _ns => _keys.deviceIdOrNull ?? 'none';
  String _sessKey(int uid, String ikSigB64) =>
      'aluta_seal_s_${_ns}_${uid}_${_ikKey(ikSigB64)}';
  String _peersKey(int uid) => 'aluta_seal_p_${_ns}_$uid';
  String get _uidsKey => 'aluta_seal_uids_$_ns';

  Future<List<String>> _peerIks(int uid) async {
    try {
      final s = await _sessions.read(_peersKey(uid));
      return s == null ? [] : (jsonDecode(s) as List).cast<String>();
    } catch (_) {
      return [];
    }
  }

  /// Sessions kept per friend device besides the current one: when both
  /// sides start a session at the same moment, messages can arrive on
  /// either until they settle on one.
  static const int keepOldSessions = 3;

  /// The sessions with one friend device, current first.
  Future<List<SealSession>> _loadAll(int uid, String ikSig) async {
    try {
      final s = await _sessions.read(_sessKey(uid, ikSig));
      if (s == null) return [];
      final j = jsonDecode(s) as Map<String, dynamic>;
      if (j.containsKey('r')) return [SealSession.fromJson(j)];
      return [
        SealSession.fromJson(j['cur'] as Map<String, dynamic>),
        for (final o in (j['old'] as List? ?? const []))
          SealSession.fromJson(o as Map<String, dynamic>),
      ];
    } catch (_) {
      return [];
    }
  }

  /// Make [s] the current session with that device (the one replies use).
  Future<void> _save(int uid, String ikSig, SealSession s) async {
    final kept = [
      s,
      ...(await _loadAll(uid, ikSig)).where((x) => x.sid != s.sid),
    ].take(1 + keepOldSessions).toList();
    await _sessions.write(
        _sessKey(uid, ikSig),
        jsonEncode({
          'cur': kept.first.toJson(),
          'old': [for (final o in kept.skip(1)) o.toJson()],
        }));
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

  /// [uid]'s devices as sealing sees them, fetched fresh (and kept for the
  /// next seals) — so a safety-code check covers the very keys messages
  /// are locked for.
  /// (Not under the messenger's lock: a slow network here must never hold
  /// up opening or sending messages.)
  Future<List<SealPeerDevice>?> devicesFor(int uid) async {
    final d = await _dir.devicesOf(uid);
    if (d != null) _devices[uid] = (_clock(), d);
    return d ?? _devices[uid]?.$2;
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
  /// Throws [SealNotSupported] only when the friend has never had keys (an
  /// older Aluta: send plain), or a [SealError] / network error when it
  /// can't seal right now — don't send plain then. Once a chat has been
  /// sealed it never goes back to plain ([SealPeerAway]); and my own keys
  /// still being set up is "not now", not "plain".
  Future<Map<String, String>> seal(int peerUid, int myUid, String text,
          {Map<String, dynamic>? media}) =>
      _locked(() async {
        if (!SealTab.inUse) throw SealError('Aluta is in use in another tab');
        await _keys.load();
        final theirs = await _devicesOf(peerUid);
        if (theirs == null) throw SealError('offline');
        if (theirs.isEmpty) {
          // Sealed before: a session here, or sealed texts (a computer
          // linked by QR has the phone's texts, not its sessions).
          if (_keys.isReady &&
              ((await _peerIks(peerUid)).isNotEmpty ||
                  (await _plainOf(peerUid)).isNotEmpty)) {
            throw SealPeerAway();
          }
          throw SealNotSupported();
        }
        if (!_keys.isReady) throw SealError('my keys are not ready yet');
        final mine = (await _devicesOf(myUid) ?? const <SealPeerDevice>[])
            .where((d) => d.deviceId != _keys.deviceId);
        final plain = utf8.encode(
            jsonEncode({'v': 1, 't': text, 'm': ?media}));
        final out = <String, String>{};
        Future<void> one(int uid, SealPeerDevice d) async {
          final known = await _loadAll(uid, d.ikSig);
          var s = known.isEmpty ? null : known.first;
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
  /// (A browser tab not in use only reads: nothing moves — see [SealTab].)
  Future<SealOpened> open(Map<String, dynamic> m, int myUid) =>
      _open(m, myUid, commit: SealTab.inUse);

  /// Forget what's cached in memory (another browser tab was in use).
  void dropCaches() {
    _plainCache.clear();
    _heldCache.clear();
    _devices.clear();
  }

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
      await _keys.load(); // texts and sessions are filed under its id
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
        final text = await _decrypt(sender, mine,
            commit: commit, keep: (t) => _remember(peer, id, rev, t));
        return SealOpened(SealOpenStatus.ok, text);
      } catch (_) {
        if (known != null) return SealOpened(SealOpenStatus.ok, known.$2);
        return const SealOpened(SealOpenStatus.failed);
      }
    });
  }

  /// Whether a photo / video / voice note / file for [peerUid] can go
  /// sealed: every device of theirs, and my own other devices, can open
  /// sealed media (an older Aluta would only see a broken file). False
  /// only when that's known (no keys, or a device without it — the file
  /// goes as before); "not right now" (my keys still being set up, the
  /// directory unreachable, another tab in use) throws [SealError] — the
  /// send fails rather than go unlocked, as text does.
  Future<bool> canSealMedia(int peerUid, int myUid) => _locked(() async {
        if (!SealTab.inUse) throw SealError('Aluta is in use in another tab');
        await _keys.load();
        final theirs = await _devicesOf(peerUid);
        if (theirs == null) throw SealError('key directory unreachable');
        if (theirs.isEmpty) {
          // No keys any more after a sealed chat: never back to plain (as
          // [seal] decides for text).
          if (_keys.isReady &&
              ((await _peerIks(peerUid)).isNotEmpty ||
                  (await _plainOf(peerUid)).isNotEmpty)) {
            throw SealPeerAway();
          }
          return false;
        }
        if (!_keys.isReady) throw SealError('my keys are not ready yet');
        final mine = await _devicesOf(myUid);
        if (mine == null) throw SealError('key directory unreachable');
        return [
          ...theirs,
          ...mine.where((d) => d.deviceId != _keys.deviceId),
        ].every((d) => d.caps.contains('m1'));
      });

  static String _textOf(List<int> clear) {
    final j = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    final m = j['m'];
    return SealPayload.store(
        (j['t'] ?? '').toString(), m is Map<String, dynamic> ? m : null);
  }

  /// [keep] stores the text BEFORE the session moves on: if the app dies in
  /// between, the text is safe and the session can still re-derive the key —
  /// the other order would lose the message for good.
  Future<String> _decrypt(int from, String b64,
      {required bool commit,
      required Future<void> Function(String text) keep}) async {
    final List<int> raw;
    try {
      raw = base64Decode(b64);
    } on FormatException {
      throw SealError('not base64');
    }
    if (raw.length > 2 && raw[1] == SealSpec.typeSelf) {
      final text = _textOf(await openSelfBox(_keys.selfKey, raw));
      if (commit) await keep(text);
      return text;
    }
    final env = SealEnvelope.decode(raw);
    Future<String> done(SealSession s, List<int> clear, String ik) async {
      final text = _textOf(clear);
      if (commit) {
        await keep(text);
        await _save(from, ik, s);
      }
      return text;
    }

    SealSession copyOf(SealSession s) => SealSession.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);

    final pre = env.preKey;
    if (pre != null) {
      final ik = base64Encode(pre.ikSig);
      for (final existing in await _loadAll(from, ik)) {
        final s = commit ? existing : copyOf(existing);
        try {
          return await done(s, await s.decrypt(env), ik);
        } on SealError {
          continue; // not this one — maybe they started over
        }
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
      for (final stored in await _loadAll(from, ik)) {
        final s = commit ? stored : copyOf(stored);
        try {
          return await done(s, await s.decrypt(env), ik);
        } on SealError {
          continue;
        }
      }
    }
    throw SealError('no session');
  }

  // ── Remembered text ──────────────────────────────────────────────────────

  Future<Map<String, List<dynamic>>> _plainOf(int peer) async {
    final c = _plainCache['$_ns:$peer'];
    if (c != null) return c;
    Map<String, List<dynamic>> m = {};
    try {
      final s = await _plain.read(_plainKey(peer));
      if (s != null) {
        m = (jsonDecode(s) as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, v as List<dynamic>));
      }
    } catch (_) {}
    return _plainCache['$_ns:$peer'] = m;
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
    await _plain.write(_plainKey(peer), jsonEncode(m));
    await _notePlainPeer(peer);
  }

  // Unlocked texts are filed under this device identity too: another account
  // on the same phone (new keys → new id) never sees them — nor hands them
  // over to a computer it links.
  String _plainKey(int peer) => 'aluta_seal_plain_${_ns}_$peer';
  String _heldKey(int peer) => 'aluta_seal_held_${_ns}_$peer';
  String get _plainPeersKey => 'aluta_seal_plain_peers_$_ns';

  Future<List<int>> _plainPeers() async {
    try {
      final s = await _plain.read(_plainPeersKey);
      return s == null ? [] : (jsonDecode(s) as List).cast<int>();
    } catch (_) {
      return [];
    }
  }

  Future<void> _notePlainPeer(int peer) async {
    final peers = await _plainPeers();
    if (peers.contains(peer)) return;
    await _plain.write(_plainPeersKey, jsonEncode([...peers, peer]));
  }

  /// Every text this device has unlocked or sent, by friend — what a newly
  /// linked computer needs to read the sealed history ({peer: {id: [rev,
  /// text]}}).
  Future<Map<String, dynamic>> exportPlain() => _locked(() async {
        await _keys.load();
        return {
          for (final peer in await _plainPeers()) '$peer': await _plainOf(peer),
        };
      });

  /// Take in a phone's texts (the hand-over); a newer revision wins.
  /// Returns how many texts were new here.
  Future<int> importPlain(Map<String, dynamic> data) => _locked(() async {
        await _keys.load();
        var added = 0;
        for (final e in data.entries) {
          final peer = int.tryParse(e.key);
          final rows = e.value;
          if (peer == null || rows is! Map) continue;
          final m = await _plainOf(peer);
          for (final r in rows.entries) {
            final v = r.value;
            if (v is! List || v.length != 2) continue;
            final have = m['${r.key}'];
            if (have != null && _int(have[0]) >= _int(v[0])) continue;
            m['${r.key}'] = [_int(v[0]), v[1].toString()];
            added++;
          }
          await _plain.write(_plainKey(peer), jsonEncode(m));
          await _notePlainPeer(peer);
        }
        return added;
      });

  /// My own sent / edited text (I have no envelope of my own).
  Future<void> rememberSent(int peer, int id, int rev, String text) =>
      _locked(() async {
        await _keys.load();
        await _remember(peer, id, rev, text);
      });

  /// The remembered text of a message, if this device unlocked / sent it.
  /// The remembered words of a message (a sealed photo: its caption).
  Future<String?> textOf(int peer, int id) async {
    final s = await storedOf(peer, id);
    return s == null ? null : SealPayload.textOf(s);
  }

  /// As remembered, sealed media included ([SealPayload]).
  Future<String?> storedOf(int peer, int id) async =>
      (await _locked(() async {
        await _keys.load();
        return _recall(peer, id);
      }))?.$2;

  /// A message's remembered text by id alone (any friend) — for the
  /// sender's peek at their own timed heart.
  Future<String?> textOfAny(int id) async {
    final s = await storedOfAny(id);
    return s == null ? null : SealPayload.textOf(s);
  }

  /// As remembered by id alone, sealed media included ([SealPayload]).
  Future<String?> storedOfAny(int id) => _locked(() async {
        await _keys.load();
        for (final peer in await _plainPeers()) {
          final t = await _recall(peer, id);
          if (t != null) return t.$2;
        }
        return null;
      });

  /// Forget the unlocked texts of deleted messages (for me or for
  /// everyone): off this device, and never in a later hand-over. [peer]
  /// null looks in every chat.
  /// Returns the sealed media ({k, n, mm}) those messages carried, so
  /// their opened files can go too.
  Future<List<Map<String, dynamic>>> forget(Iterable<int> ids, {int? peer}) =>
      _locked(() async {
        final dropped = <Map<String, dynamic>>[];
        // The tab in use catches up from the list.
        if (!SealTab.inUse) return dropped;
        final gone = {for (final i in ids) '$i'};
        if (gone.isEmpty) return dropped;
        await _keys.load();
        for (final p in peer != null ? [peer] : await _plainPeers()) {
          final m = await _plainOf(p);
          final before = m.length;
          m.removeWhere((k, v) {
            if (!gone.contains(k)) return false;
            final media = SealPayload.mediaOf(v.length > 1 ? '${v[1]}' : null);
            if (media != null) dropped.add(media);
            return true;
          });
          if (m.length != before) {
            await _plain.write(_plainKey(p), jsonEncode(m));
          }
        }
        return dropped;
      });

  /// Forget every unlocked text of the chat with [peer] (chat cleared);
  /// returns its sealed media, as [forget] does.
  Future<List<Map<String, dynamic>>> forgetChat(int peer) =>
      _locked(() async {
        final dropped = <Map<String, dynamic>>[];
        if (!SealTab.inUse) return dropped;
        await _keys.load();
        final m = await _plainOf(peer);
        if (m.isEmpty) return dropped;
        for (final v in m.values) {
          final media = SealPayload.mediaOf(v.length > 1 ? '${v[1]}' : null);
          if (media != null) dropped.add(media);
        }
        m.clear();
        await _plain.write(_plainKey(peer), jsonEncode(m));
        return dropped;
      });

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
    final c = _heldCache['$_ns:$peer'];
    if (c != null) return c;
    Map<String, String> m = {};
    try {
      final s = await _plain.read(_heldKey(peer));
      if (s != null) {
        m = (jsonDecode(s) as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, v.toString()));
      }
    } catch (_) {}
    return _heldCache['$_ns:$peer'] = m;
  }

  /// A morning message's text, kept until it is delivered.
  Future<void> rememberHeld(int peer, int heldId, String text) =>
      _locked(() async {
        await _keys.load();
        final m = await _heldOf(peer);
        m['$heldId'] = text;
        if (m.length > 200) m.remove(m.keys.first);
        await _plain.write(_heldKey(peer), jsonEncode(m));
      });

  Future<String?> recallHeld(int peer, int heldId) async {
    await _keys.load();
    return (await _heldOf(peer))['$heldId'];
  }

  /// Sign-out: forget every session and remembered text.
  Future<void> wipe() => _locked(() async {
        try {
          await _keys.load(); // the namespace is this device's id
          final raw = await _sessions.read(_uidsKey);
          final uids =
              raw == null ? <int>[] : (jsonDecode(raw) as List).cast<int>();
          for (final uid in uids) {
            for (final ik in await _peerIks(uid)) {
              await _sessions.delete(_sessKey(uid, ik));
            }
            await _sessions.delete(_peersKey(uid));
            await _plain.delete(_plainKey(uid));
            await _plain.delete(_heldKey(uid));
          }
          await _sessions.delete(_uidsKey);
          for (final peer in await _plainPeers()) {
            await _plain.delete(_plainKey(peer));
            await _plain.delete(_heldKey(peer));
          }
          await _plain.delete(_plainPeersKey);
        } catch (_) {}
        _devices.clear();
        _plainCache.clear();
        _heldCache.clear();
      });
}
