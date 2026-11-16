import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../screens/token_helper.dart';
import '../utils/app_config.dart';
import '../utils/net.dart' as http;
import 'seal_directory.dart';
import 'seal_keystore.dart';
import 'seal_primitives.dart';
import 'seal_scope.dart';

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

  Future<void> _saveHeld() async {
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
    if (id is! int || members is! List) return;
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
      final members = SealScope.membersOf(scope) ?? const <int>[];
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
  Future<void> _serveMissing(String scope, Map<String, dynamic> j) async {
    final epoch = j['epoch'] as int?;
    final key = epoch == null ? null : (await _heldKeys())[scope]?[epoch];
    final missing = (j['missing'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    if (key == null || missing.isEmpty) return;
    final wraps = await _wrapFor(scope, epoch!, key, missing);
    if (wraps.isEmpty) return;
    await _api.addWraps(scope, {
      'epoch': epoch,
      'from_device': _keys.deviceId,
      'wraps': wraps,
    });
  }

  /// The current (epoch, key) of [scope], making the first key when the
  /// group has none. Null when this device must wait for a member's device
  /// to give it the key.
  Future<(int, Uint8List)?> _currentKey(String scope,
      {bool make = true}) async {
    final held = await _heldKeys();
    final cur = _current[scope];
    final known = cur == null ? null : held[scope]?[cur];
    final asked = _lastAsked[scope];
    final fresh =
        asked != null && DateTime.now().difference(asked).inMinutes < 2;
    if (known != null && fresh) return (cur!, known);
    for (var attempt = 0; attempt < 2; attempt++) {
      final j = await _api.fetch(scope, _keys.deviceId);
      if (j == null) {
        return known == null ? null : (cur!, known);
      }
      _lastAsked[scope] = DateTime.now();
      final epoch = await _absorb(scope, j);
      if (epoch != null) {
        unawaited(_serveMissing(scope, j).catchError((_) {}));
        final k = held[scope]?[epoch];
        return k == null ? null : (epoch, k);
      }
      if (!make) return null;
      // Nobody has made this group's key yet: make it, wrapped for every
      // member device (this one included).
      final members = SealScope.membersOf(scope)!;
      final key = sealRandomBytes(32);
      final devices = await _allDevices(members);
      final wraps = await _wrapFor(scope, 1, key, devices);
      // This device keeps a copy too (it must be on the key directory).
      if (!wraps.any((w) => w['device_id'] == _keys.deviceId)) return null;
      final code = await _api.create(scope, {
        'epoch': 1,
        'from_device': _keys.deviceId,
        'wraps': wraps,
      });
      if (code == 200) {
        held.putIfAbsent(scope, () => {})[1] = key;
        _current[scope] = 1;
        _lastAsked[scope] = DateTime.now();
        await _saveHeld();
        return (1, key);
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
  Future<String> seal(Iterable<int> members, String text) => _locked(() async {
        if (text.isEmpty || SealScope.isSealed(text)) return text;
        await _keys.load();
        if (!_keys.isReady) throw SealSpaceNotReady();
        final ids = members.toSet().toList();
        if (ids.length < 2) throw SealSpaceNotReady();
        for (final uid in ids) {
          final d = await _dir.devicesOf(uid);
          if (d == null) throw SealError('offline');
          if (d.isEmpty) throw SealSpaceNotReady();
        }
        final scope = SealScope.of(ids);
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

  /// Open one sealed field (a note when it can't be opened yet).
  Future<String> open(String sealed) => _locked(() async {
        final k = SealScope.keyOf(sealed);
        if (k == null) return sealed;
        final held = await _heldKeys();
        var key = held[k.$1]?[k.$2];
        if (key == null) {
          try {
            await _currentKey(k.$1, make: false);
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
    Future<void> walk(Object? v) async {
      if (v is Map) {
        if (v is Map<String, dynamic>) noteSpace(v);
        for (final key in v.keys.toList()) {
          final x = v[key];
          if (SealScope.isSealed(x)) {
            v[key] = await open(x as String);
          } else {
            await walk(x);
          }
        }
      } else if (v is List) {
        for (var i = 0; i < v.length; i++) {
          final x = v[i];
          if (SealScope.isSealed(x)) {
            v[i] = await open(x as String);
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
          if (SealScope.membersOf(e.key) == null) continue;
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
      });
}
