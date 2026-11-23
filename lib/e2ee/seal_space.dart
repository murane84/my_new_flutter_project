import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../screens/token_helper.dart';
import '../utils/app_config.dart';
import '../utils/net.dart' as http;
import 'seal_directory.dart';
import 'seal_keystore.dart';
import 'seal_media.dart';
import 'seal_primitives.dart';
import 'seal_scope.dart';
import 'seal_tab.dart';

/// What [SealSpace] needs from the server's scope-key store (a fake in tests).
abstract class SealScopeApi {
  Future<Map<String, dynamic>?> fetch(String scope, String deviceId);

  /// HTTP status: 200 created, 409 someone else was first.
  Future<int> create(String scope, Map<String, dynamic> body);
  Future<int> addWraps(String scope, Map<String, dynamic> body);
}

class _HttpScopeApi implements SealScopeApi {
  static const Duration _wait = Duration(seconds: 10);

  Future<Map<String, String>?> _headers() async {
    final t = await getToken();
    return t == null
        ? null
        : {'Authorization': 'Bearer $t', 'Content-Type': 'application/json'};
  }

  @override
  Future<Map<String, dynamic>?> fetch(String scope, String deviceId) async {
    final h = await _headers();
    if (h == null) return null;
    final base = await AppConfig.baseUrl;
    final r = await http
        .get(
            Uri.parse('$base/e2ee/scopes/$scope')
                .replace(queryParameters: {'device_id': deviceId}),
            headers: h)
        .timeout(_wait);
    if (r.statusCode != 200) return null;
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<int> _post(String path, Map<String, dynamic> body) async {
    final h = await _headers();
    if (h == null) return 401;
    final base = await AppConfig.baseUrl;
    final r = await http
        .post(Uri.parse('$base$path'), headers: h, body: jsonEncode(body))
        .timeout(_wait);
    return r.statusCode;
  }

  /// Group history hand-over (not part of [SealScopeApi]: the app only).
  Future<List<Map<String, dynamic>>> historyNeeds(int cid, String device) async {
    final h = await _headers();
    if (h == null) return const [];
    final base = await AppConfig.baseUrl;
    final r = await http
        .get(
            Uri.parse('$base/e2ee/scopes/history/needs').replace(
                queryParameters: {
                  'conversation_id': '$cid',
                  'device_id': device
                }),
            headers: h)
        .timeout(_wait);
    if (r.statusCode != 200) return const [];
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (j['needs'] as List? ?? const []).cast<Map<String, dynamic>>();
  }

  Future<int> grant(String scope, Map<String, dynamic> body) =>
      _post('/e2ee/scopes/$scope/grant', body);

  @override
  Future<int> create(String scope, Map<String, dynamic> body) =>
      _post('/e2ee/scopes/$scope/create', body);

  @override
  Future<int> addWraps(String scope, Map<String, dynamic> body) =>
      _post('/e2ee/scopes/$scope/wraps', body);
}

/// The friend can't read sealed Our Space yet (an older Aluta): keep plain.
class SealSpaceNotReady implements Exception {}

/// 🔒 Seals and opens Our Space words (see [SealScope] for the format).
///
/// One key per group of members, made by the first of their devices that
/// needs it and wrapped for every member device; held only on the devices
/// (this device's copies in secure storage). Any device holding the key
/// wraps it for members' devices that joined later.
class SealSpace {
  SealSpace({
    SealKeyStore? keys,
    SealKeyDirectory? directory,
    SealScopeApi? api,
    SealStorage? storage,
  })  : _keysOverride = keys,
        _dirOverride = directory,
        _apiOverride = api,
        _storageOverride = storage;

  static final SealSpace instance = SealSpace();

  static const String waitingForKey = '🔒 Waiting for the key to Our Space';
  static const String unlockFailed = "🔒 Couldn't unlock this";

  final SealKeyStore? _keysOverride;
  final SealKeyDirectory? _dirOverride;
  final SealScopeApi? _apiOverride;
  final SealStorage? _storageOverride;
  SealScopeApi? _apiDefault;
  SealStorage? _storageDefault;

  SealKeyStore get _keys => _keysOverride ?? SealKeyStore.instance;
  SealKeyDirectory get _dir => _dirOverride ?? SealDirectory.instance;
  SealScopeApi get _api => _apiOverride ?? (_apiDefault ??= _HttpScopeApi());
  SealStorage get _store =>
      _storageOverride ?? (_storageDefault ??= SealKeyStore.platformStorage());

  Future<void> _lock = Future<void>.value();
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

  // scope → {epoch: key}; and scope → current epoch.
  Map<String, Map<int, Uint8List>>? _held;
  final Map<String, int> _current = {};
  String? _heldNs;
  final Map<String, DateTime> _lastAsked = {};
  // The latest server answer per scope (a named scope's members / devices).
  final Map<String, Map<String, dynamic>> _lastAnswer = {};

  /// Who a scope's keys may come from: its member list, or — named — the
  /// members the server answered with.
  List<int> _membersIn(String scope, Map<String, dynamic> j) =>
      SealScope.membersOf(scope) ??
      [
        for (final m in (j['members'] as List? ?? const []))
          if (m is int) m
      ];

  /// A named scope's members changed (a group's members, a status
  /// audience): ask the server afresh before the next seal.
  void forgetScope(String scope) {
    _lastAsked.remove(scope);
    _lastAnswer.remove(scope);
  }
  final Map<int, String> _spaceScopes = {};

  String get _storeKey => 'aluta_seal_scopes_${_keys.deviceIdOrNull}';

  Future<Map<String, Map<int, Uint8List>>> _heldKeys() async {
    await _keys.load();
    if (_held != null && _heldNs == _keys.deviceIdOrNull) return _held!;
    _heldNs = _keys.deviceIdOrNull;
    _current.clear();
    final out = <String, Map<int, Uint8List>>{};
    try {
      final s = await _store.read(_storeKey);
      if (s != null) {
        final j = jsonDecode(s) as Map<String, dynamic>;
        for (final e in j.entries) {
          final v = e.value as Map<String, dynamic>;
          _current[e.key] = v['cur'] as int;
          out[e.key] = {
            for (final k in (v['keys'] as Map<String, dynamic>).entries)
              int.parse(k.key): base64Decode(k.value as String)
          };
        }
      }
    } catch (_) {}
    return _held = out;
  }

  /// Forget what's cached in memory (another browser tab was in use).
  void dropCaches() {
    _held = null;
    _current.clear();
  }

  Future<void> _saveHeld() async {
    // Only the browser tab in use writes (see [SealTab]); another keeps
    // what it learned in memory.
    if (!SealTab.inUse) return;
    final h = _held ?? {};
    await _store.write(
        _storeKey,
        jsonEncode({
          for (final e in h.entries)
            e.key: {
              'cur': _current[e.key] ?? 1,
              'keys': {
                for (final k in e.value.entries) '${k.key}': base64Encode(k.value)
              },
            }
        }));
  }

  // ── Which group a Space is ──────────────────────────────────────────────

  /// Remember a Space's members (from any Space JSON the app sees).
  void noteSpace(Map<String, dynamic> space) {
    final id = space['id'];
    final members = space['members'];
    // Only a Space answer (owner + is_primary): a group chat's JSON also has
    // an id and members, and must never be taken for a Space.
    if (id is! int ||
        members is! List ||
        space['owner_id'] is! int ||
        !space.containsKey('is_primary')) {
      return;
    }
    final ids = <int>{
      if (space['owner_id'] is int) space['owner_id'] as int,
      for (final m in members)
        if (m is Map && m['id'] is int) m['id'] as int,
    };
    if (ids.length >= 2) _spaceScopes[id] = SealScope.of(ids);
  }

  String? scopeOfSpace(int spaceId) => _spaceScopes[spaceId];

  // ── Keys ────────────────────────────────────────────────────────────────

  Future<SealPeerDevice?> _deviceOf(int uid, String deviceId) async {
    final list = await _dir.devicesOf(uid);
    for (final d in list ?? const <SealPeerDevice>[]) {
      if (d.deviceId == deviceId) return d;
    }
    return null;
  }

  /// Wraps of [key] for [devices] ({user_id, device_id, ik_sig, ik_dh,
  /// ik_dh_sig}), skipping any whose X25519 identity isn't signed by its
  /// Ed25519 identity.
  Future<List<Map<String, dynamic>>> _wrapFor(String scope, int epoch,
      List<int> key, Iterable<Map<String, dynamic>> devices) async {
    final out = <Map<String, dynamic>>[];
    for (final d in devices) {
      try {
        final ikSig = base64Decode(d['ik_sig'] as String);
        final ikDh = base64Decode(d['ik_dh'] as String);
        final ikDhSig = base64Decode(d['ik_dh_sig'] as String);
        if (!await sealVerify(
            ikSig, sealConcat([SealSpec.ikDhSigPrefix, ikDh]), ikDhSig)) {
          continue;
        }
        out.add({
          'user_id': d['user_id'],
          'device_id': d['device_id'],
          'wrapped': await SealScope.wrap(
              me: _keys.identity,
              recipIkDh: ikDh,
              recipIkSig: ikSig,
              scope: scope,
              epoch: epoch,
              scopeKey: key),
        });
      } catch (_) {/* a broken device entry can't stop the others */}
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _allDevices(List<int> members) async {
    final out = <Map<String, dynamic>>[];
    for (final uid in members) {
      final list = await _dir.devicesOf(uid);
      if (list == null) throw SealError('offline');
      for (final d in list) {
        if (d.ikDh == null || d.ikDhSig == null) continue;
        out.add({
          'user_id': uid,
          'device_id': d.deviceId,
          'ik_sig': d.ikSig,
          'ik_dh': d.ikDh,
          'ik_dh_sig': d.ikDhSig,
        });
      }
    }
    return out;
  }

  /// Take in my copies from a server answer; returns the current epoch.
  Future<int?> _absorb(String scope, Map<String, dynamic> j) async {
    final epoch = j['epoch'] as int?;
    if (epoch == null) return null;
    final held = await _heldKeys();
    final mine = held.putIfAbsent(scope, () => {});
    for (final k in (j['keys'] as List).cast<Map<String, dynamic>>()) {
      final e = k['epoch'] as int;
      if (mine.containsKey(e)) continue;
      final from = await _deviceOf(
          k['from_user'] as int, k['from_device'] as String);
      final members = _membersIn(scope, j);
      if (from == null || !members.contains(k['from_user'])) continue;
      try {
        mine[e] = await SealScope.unwrap(
            me: _keys.identity,
            blob: k['wrapped'] as String,
            senderIkSig: base64Decode(from.ikSig),
            scope: scope,
            epoch: e);
      } catch (_) {/* not signed by a member device: ignore it */}
    }
    _current[scope] = epoch;
    await _saveHeld();
    return epoch;
  }

  /// Wrap the current key for member devices that don't have it yet.
  /// Wrap every key this device holds for member devices that lack it —
  /// older keys too, so a device that joined later can open what was
  /// written before it.
  Future<void> _serveMissing(String scope, Map<String, dynamic> j) async {
    final current = j['epoch'] as int?;
    final held = (await _heldKeys())[scope] ?? const <int, Uint8List>{};
    final byEpoch = <int, List<Map<String, dynamic>>>{};
    for (final m in (j['missing'] as List? ?? const [])
        .cast<Map<String, dynamic>>()) {
      final e = m['epoch'] as int? ?? current;
      if (e != null) byEpoch.putIfAbsent(e, () => []).add(m);
    }
    for (final e in byEpoch.entries) {
      final key = held[e.key];
      if (key == null) continue;
      final wraps = await _wrapFor(scope, e.key, key, e.value);
      if (wraps.isEmpty) continue;
      await _api.addWraps(scope, {
        'epoch': e.key,
        'from_device': _keys.deviceId,
        'wraps': wraps,
      });
    }
  }

  /// The current (epoch, key) of [scope], making the first key when the
  /// group has none. Null when this device must wait for a member's device
  /// to give it the key.
  Future<(int, Uint8List)?> _currentKey(String scope,
      {bool make = true, bool force = false}) async {
    final held = await _heldKeys();
    final cur = _current[scope];
    final known = cur == null ? null : held[scope]?[cur];
    final asked = _lastAsked[scope];
    final fresh =
        asked != null && DateTime.now().difference(asked).inSeconds < 30;
    if (known != null && fresh && !force) return (cur!, known);
    for (var attempt = 0; attempt < 2; attempt++) {
      final j = await _api.fetch(scope, _keys.deviceId);
      if (j == null) {
        return known == null ? null : (cur!, known);
      }
      _lastAsked[scope] = DateTime.now();
      _lastAnswer[scope] = j;
      final epoch = await _absorb(scope, j);
      if (epoch != null) {
        unawaited(_serveMissing(scope, j).catchError((_) {}));
        final k = held[scope]?[epoch];
        // A named scope whose members changed since its key was made (a
        // join / leave; someone who lost sight of a Story): writing moves
        // it on to a new key for exactly today's members.
        final rotate = make && j['rotate'] == true;
        if (k != null && !rotate) return (epoch, k);
        // No copy of the current key here (a new phone nobody has served
        // yet): reading waits, but writing moves the group on to a new key
        // rather than staying stuck.
        if (!make) return null;
      } else if (!make) {
        return null;
      }
      // Make the group's (next) key, wrapped for every member device (this
      // one included).
      final next = (epoch ?? 0) + 1;
      final key = sealRandomBytes(32);
      // A named scope's devices come with the server's answer (a big group
      // or a Story audience isn't looked up person by person).
      final devices = SealScope.isNamed(scope)
          ? [
              for (final d in (j['member_devices'] as List? ?? const []))
                if (d is Map<String, dynamic> &&
                    d['ik_dh'] != null &&
                    d['ik_dh_sig'] != null)
                  d
            ]
          : await _allDevices(SealScope.membersOf(scope)!);
      final wraps = await _wrapFor(scope, next, key, devices);
      // This device keeps a copy too (it must be on the key directory).
      if (!wraps.any((w) => w['device_id'] == _keys.deviceId)) return null;
      final code = await _api.create(scope, {
        'epoch': next,
        'from_device': _keys.deviceId,
        'wraps': wraps,
      });
      if (code == 200) {
        held.putIfAbsent(scope, () => {})[next] = key;
        _current[scope] = next;
        _lastAsked[scope] = DateTime.now();
        await _saveHeld();
        return (next, key);
      }
      if (code != 409) return null;
      // Another device was first: loop once and take theirs.
    }
    return null;
  }

  // ── Sealing / opening ───────────────────────────────────────────────────

  /// Seal [text] for the group [members] (this person included). Throws
  /// [SealSpaceNotReady] when a member's Aluta can't read sealed Our Space
  /// yet (send it plain), or a [SealError] when it should be sealed but
  /// can't be right now (don't send it plain then).
  ///
  /// [stay]: the caller knows this chat was sealed before (a group whose
  /// members changed has a new scope): never back to plain.
  Future<String> seal(Iterable<int> members, String text,
          {bool stay = false}) =>
      _locked(() async {
        if (text.isEmpty || SealScope.isSealed(text)) return text;
        if (!SealTab.inUse) throw SealError('Aluta is in use in another tab');
        await _keys.load();
        final ids = members.toSet().toList();
        if (ids.length < 2) throw SealSpaceNotReady();
        final scope = SealScope.of(ids);
        // Once this Space has been sealed it stays sealed: a member with no
        // keys right now (signed out — or a server saying so) doesn't turn
        // it back to plain.
        final sealedBefore = stay ||
            (_keys.isReady &&
                ((await _heldKeys())[scope]?.isNotEmpty ?? false));
        for (final uid in ids) {
          final d = await _dir.devicesOf(uid);
          if (d == null) throw SealError('offline');
          if (d.isEmpty && !sealedBefore) throw SealSpaceNotReady();
        }
        // My own keys still being set up: "not now", never plain.
        if (!_keys.isReady) throw SealError('my keys are not ready yet');
        final k = await _currentKey(scope);
        if (k == null) throw SealError('no key for this space yet');
        return SealScope.seal(k.$2, scope, k.$1, text);
      });

  /// Seal [text] for a Space by id (its members as last seen in a Space
  /// answer — the app always loads the Space before writing in it).
  Future<String> sealForSpace(int spaceId, String text) {
    final scope = _spaceScopes[spaceId];
    if (scope == null) throw SealSpaceNotReady();
    return seal(SealScope.membersOf(scope)!, text);
  }

  /// Seal [text] with NAMED scope [scope] (a big group "g:<id>", Stories
  /// "s:<id>"): its key is made for whoever belongs today, and moved on
  /// when that changes. Throws [SealError] when it can't be sealed right
  /// now (never plain then) — callers check [namedReady] first.
  Future<String> sealNamed(String scope, String text) => _locked(() async {
        if (text.isEmpty || SealScope.isSealed(text)) return text;
        if (!SealTab.inUse) throw SealError('Aluta is in use in another tab');
        await _keys.load();
        if (!_keys.isReady) throw SealError('my keys are not ready yet');
        // (A Story audience changes without any event reaching this phone:
        // posting always checks whether a new key is due.)
        final k = await _currentKey(scope,
            force: scope.startsWith('s:') && !_postingFresh(scope));
        if (k == null) throw SealError('no key for this scope yet');
        return SealScope.seal(k.$2, scope, k.$1, text);
      });

  // One status seals several fields: the key is checked once per post (the
  // first field), not per field.
  final Map<String, DateTime> _postedAt = {};
  bool _postingFresh(String scope) {
    final t = _postedAt[scope];
    final now = DateTime.now();
    _postedAt[scope] = now;
    return t != null && now.difference(t).inSeconds < 5;
  }

  /// Whether every device of everyone in named [scope] can open what it
  /// seals ([caps] all present). Throws [SealError] when it can't be told
  /// right now.
  ///
  /// [skipKeyless]: someone with no device on the key directory at all (an
  /// account unused for two months) doesn't hold it back — for Stories,
  /// where one long-gone friend in the audience would keep every status
  /// plain.
  Future<bool> namedReady(String scope, Set<String> caps,
          {bool skipKeyless = false}) =>
      _locked(() async {
        await _keys.load();
        if (!_keys.isReady) throw SealError('my keys are not ready yet');
        final j = await _api.fetch(scope, _keys.deviceId);
        if (j == null) throw SealError('key store unreachable');
        _lastAnswer[scope] = j;
        final devices = (j['member_devices'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        final members = _membersIn(scope, j).toSet();
        // Everyone needs at least one device with keys.
        final withKeys = {for (final d in devices) d['user_id']};
        if (!skipKeyless && !members.every(withKeys.contains)) return false;
        for (final d in devices) {
          if (d['device_id'] == _keys.deviceId) continue;
          final have = '${d['caps'] ?? ''}'.split(',').toSet();
          if (!caps.every(have.contains)) return false;
        }
        return true;
      });

  /// Seal [text] for group chat [cid] whose members are [members]: with
  /// their member-list key up to 32, the group's named key above that.
  Future<String> sealGroup(int cid, List<int> members, String text,
          {bool stay = false}) =>
      members.length > SealScope.maxListMembers
          ? sealNamed(SealScope.group(cid), text)
          : seal(members, text, stay: stay);

  /// Open one sealed field (a note when it can't be opened yet).
  /// [asked]: share one set across a batch so a missing key is asked for
  /// once, not per field.
  Future<String> open(String sealed, {Set<String>? asked}) =>
      _open(sealed, asked);

  /// [asked]: groups already looked up during this answer — a page full of
  /// fields waiting for the same key asks the server once, not per field.
  Future<String> _open(String sealed, Set<String>? asked) =>
      _locked(() async {
        final k = SealScope.keyOf(sealed);
        if (k == null) return sealed;
        final held = await _heldKeys();
        var key = held[k.$1]?[k.$2];
        if (key == null && (asked == null || asked.add('${k.$1}#${k.$2}'))) {
          try {
            // Ask the server even if the current key is fresh here: this
            // field may use a newer (or older) key we haven't taken in yet.
            await _currentKey(k.$1, make: false, force: true);
          } catch (_) {}
          key = held[k.$1]?[k.$2];
        }
        if (key == null) return waitingForKey;
        try {
          return await SealScope.open(key, sealed);
        } catch (_) {
          return unlockFailed;
        }
      });

  /// Open every sealed string inside a decoded JSON answer, in place, and
  /// remember the members of any Space it describes. Returns [json].
  Future<T> openJson<T>(T json) async {
    final asked = <String>{};
    Future<void> walk(Object? v) async {
      if (v is Map) {
        if (v is Map<String, dynamic>) noteSpace(v);
        for (final key in v.keys.toList()) {
          final x = v[key];
          if (SealScope.isSealed(x)) {
            v[key] = await _open(x as String, asked);
          } else {
            await walk(x);
          }
        }
        withMediaKeys(v);
      } else if (v is List) {
        for (var i = 0; i < v.length; i++) {
          final x = v[i];
          if (SealScope.isSealed(x)) {
            v[i] = await _open(x as String, asked);
          } else {
            await walk(x);
          }
        }
      }
    }

    await walk(json);
    return json;
  }

  /// Decode a JSON body and open it (for the Our Space API answers).
  /// 🔒 A sealed Our Space photo / voice / song keeps its bare address in
  /// a field (`ref`, `cover_ref`, `background_url`…) and its address WITH
  /// the key sealed next to it (`ref_key`…). Once opened, the key goes back
  /// onto the address in place, so every viewer / player opens the file.
  static void withMediaKeys(Map v) {
    for (final k in v.keys.toList()) {
      if (k is! String || !k.endsWith('_key')) continue;
      final keyed = v[k];
      if (keyed is! String || !SealMedia.isSealed(keyed)) continue;
      final base = k.substring(0, k.length - 4);
      final cur = v[base];
      if (cur is! String || cur.isEmpty || cur.contains(keyed)) continue;
      final bare = SealMedia.bare(keyed);
      if (bare.isEmpty) {
        // Just the key ("#ask=…"): it belongs on the address as it is.
        if (!SealMedia.isSealed(cur)) {
          v[base] = SealMedia.withKey(cur, SealMedia.keyOf(keyed)!);
        }
      } else if (cur.contains(bare)) {
        v[base] = cur.replaceFirst(bare, keyed);
      }
    }
  }

  Future<dynamic> decode(String body) {
    final j = jsonDecode(body);
    return openJson(j);
  }

  /// Hand this device's held keys over (QR linking): {scope: {cur, keys}}.
  Future<Map<String, dynamic>> exportKeys() => _locked(() async {
        final held = await _heldKeys();
        return {
          for (final e in held.entries)
            e.key: {
              'cur': _current[e.key] ?? 1,
              'keys': {
                for (final k in e.value.entries) '${k.key}': base64Encode(k.value)
              },
            }
        };
      });

  /// Take in keys handed over by this person's phone.
  Future<void> importKeys(Map<String, dynamic> data) => _locked(() async {
        final held = await _heldKeys();
        for (final e in data.entries) {
          if (!SealScope.isScope(e.key)) continue;
          final v = e.value as Map<String, dynamic>;
          final mine = held.putIfAbsent(e.key, () => {});
          for (final k in (v['keys'] as Map<String, dynamic>).entries) {
            final key = base64Decode(k.value as String);
            if (key.length == 32) mine.putIfAbsent(int.parse(k.key), () => key);
          }
          final cur = v['cur'] as int? ?? 1;
          if ((_current[e.key] ?? 0) < cur) _current[e.key] = cur;
        }
        await _saveHeld();
      });

  /// A group that lets new members read its earlier messages: hand the
  /// older keys this device holds to members who joined after them (each
  /// copy wrapped to one of their devices, checked against the directory).
  /// Best-effort; returns how many members were given keys.
  Future<int> serveHistory(int cid) async {
    if (_apiOverride != null) return 0;
    final api = _HttpScopeApi();
    var given = 0;
    try {
      await _keys.load();
      if (!_keys.isReady || !SealTab.inUse) return 0;
      final needs = await api.historyNeeds(cid, _keys.deviceId);
      for (final n in needs) {
        final scope = n['scope'] as String;
        final uid = n['user_id'] as int;
        final keys = await historyWraps(scope, uid,
            (n['devices'] as List).cast<Map<String, dynamic>>());
        if (keys.isEmpty) continue;
        final code = await api.grant(scope, {
          'conversation_id': cid,
          'user_id': uid,
          'keys': keys,
        });
        if (code == 200) given++;
      }
    } catch (e) {
      debugPrint('Seal history: $e');
    }
    return given;
  }

  /// Copies of [scope]'s keys this device holds, wrapped for [devices] of
  /// member [uid] (each {device_id, ik_sig, ik_dh, ik_dh_sig, epochs}),
  /// grouped by epoch: [{epoch, from_device, wraps}].
  Future<List<Map<String, dynamic>>> historyWraps(String scope, int uid,
          List<Map<String, dynamic>> devices) =>
      _locked(() async {
        final held = (await _heldKeys())[scope] ?? const <int, Uint8List>{};
        final out = <Map<String, dynamic>>[];
        for (final e in held.entries) {
          final want = [
            for (final d in devices)
              if ((d['epochs'] as List? ?? const []).contains(e.key))
                {...d, 'user_id': uid}
          ];
          if (want.isEmpty) continue;
          final wraps = await _wrapFor(scope, e.key, e.value, want);
          if (wraps.isEmpty) continue;
          out.add({
            'epoch': e.key,
            'from_device': _keys.deviceId,
            'wraps': wraps,
          });
        }
        return out;
      });

  /// Every so often: give member devices that joined later their copy of
  /// the keys this device holds. Best-effort.
  Future<void> serveAll() async {
    try {
      final scopes = (await _locked(() async => (await _heldKeys()).keys))
          .toList();
      for (final s in scopes) {
        final j = await _api.fetch(s, _keys.deviceId);
        if (j != null) await _locked(() => _serveMissing(s, j));
      }
    } catch (e) {
      debugPrint('Seal space serve: $e');
    }
  }

  /// Sign-out: forget this device's Our Space keys.
  Future<void> wipe() => _locked(() async {
        await _keys.load();
        await _store.delete(_storeKey);
        _held = null;
        _current.clear();
        _lastAsked.clear();
        _lastAnswer.clear();
      });
}
