import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/token_helper.dart';
import 'seal_primitives.dart';
import 'seal_x3dh.dart';

/// Where this device's private keys live: the phone's secure storage
/// (Android Keystore-backed), localStorage on web (weaker — clearing site
/// data loses them, see the E2EE plan).
abstract class SealStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class _PlatformStorage implements SealStorage {
  static final FlutterSecureStorage _secure = FlutterSecureStorage();

  @override
  Future<String?> read(String key) async => kIsWeb
      ? (await SharedPreferences.getInstance()).getString(key)
      : _secure.read(key: key);

  @override
  Future<void> write(String key, String value) async {
    if (kIsWeb) {
      await (await SharedPreferences.getInstance()).setString(key, value);
    } else {
      await _secure.write(key: key, value: value);
    }
  }

  @override
  Future<void> delete(String key) async {
    if (kIsWeb) {
      await (await SharedPreferences.getInstance()).remove(key);
    } else {
      await _secure.delete(key: key);
    }
  }
}

/// In-memory storage for tests.
class MemorySealStorage implements SealStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// This device's Aluta Seal keys for one signed-in account: identity, the
/// current + previous signed prekeys, and the unused one-time prekeys.
class SealKeyStore {
  SealKeyStore(
      {SealStorage? storage,
      DateTime Function()? clock,
      Future<String?> Function()? currentOwner})
      : _storage = storage ?? _PlatformStorage(),
        _clock = clock ?? DateTime.now,
        _currentOwner = currentOwner;

  static final SealKeyStore instance =
      SealKeyStore(currentOwner: _tokenOwner);

  /// The signed-in account (the session token's subject), so keys made for
  /// another account on this device are never used — not even for the few
  /// seconds before the new account's own keys are made.
  static Future<String?> _tokenOwner() async {
    try {
      final parts = (await getToken() ?? '').split('.');
      if (parts.length != 3) return null;
      final body = jsonDecode(
              utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))))
          as Map<String, dynamic>;
      return body['sub']?.toString();
    } catch (_) {
      return null;
    }
  }

  final Future<String?> Function()? _currentOwner;

  /// Secure storage on phones / desktop, localStorage on web.
  static SealStorage platformStorage() => _PlatformStorage();

  static const String _key = 'aluta_seal_keys_v1';
  static const Duration spkRotateAfter = Duration(days: 7);

  /// One-time prekeys kept on the device (the server holds ≤ 100).
  static const int opkKeep = 400;

  /// An old signed prekey stays usable this long for first messages that
  /// were sent to it before the rotation reached them.
  static const Duration spkKeepFor = Duration(days: 30);

  final SealStorage _storage;
  final DateTime Function() _clock;
  Future<void> _lock = Future<void>.value();

  String? _owner;
  String? _deviceId;
  SealIdentity? _identity;
  final List<SignedPreKey> _spks = []; // newest first
  final Map<int, OneTimePreKey> _opks = {};
  int _nextOpkId = 1;
  int _nextSpkId = 1;
  Uint8List? _selfKey;

  /// The spk id last accepted by the server (0 = not registered yet).
  int registeredSpkId = 0;

  String get deviceId => _deviceId!;
  String? get deviceIdOrNull => _deviceId;
  SealIdentity get identity => _identity!;
  SignedPreKey get currentSpk => _spks.first;
  int get opkCount => _opks.length;
  bool get isReady => _identity != null;

  /// This device's own key for "note to self" copies of what it sends, so
  /// it can reopen its own messages from the server.
  Uint8List get selfKey => _selfKey!;

  /// Runs [f] with the store to itself (keys are read-modify-write).
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

  /// Load (or create) the keys of [owner] — the signed-in account. Another
  /// account's keys on this device are dropped, never reused.
  Future<void> ensure(String owner) => _locked(() async {
        if (_owner == owner && _identity != null) return;
        final raw = await _read();
        if (raw != null && raw['owner'] == owner) {
          _fromJson(raw);
          await _saveIfUpgraded();
          return;
        }
        _owner = owner;
        _deviceId = base64Url
            .encode(sealRandomBytes(16))
            .replaceAll('=', '');
        _identity = await SealIdentity.generate();
        _selfKey = sealRandomBytes(32);
        _spks
          ..clear()
          ..add(await SignedPreKey.generate(_identity!, _nextSpkId++,
              now: _clock()));
        _opks.clear();
        registeredSpkId = 0;
        await _save();
      });

  /// Load whatever keys this device holds, without making new ones.
  Future<void> load() => _locked(() async {
        final want = await _currentOwner?.call();
        if (_identity != null) {
          if (want == null || want == _owner) return;
          _forget(); // another account signed in: not these keys
        }
        final raw = await _read();
        if (raw != null && (want == null || raw['owner'] == want)) {
          _fromJson(raw);
          await _saveIfUpgraded();
        }
      });

  void _forget() {
    _owner = null;
    _deviceId = null;
    _identity = null;
    _selfKey = null;
    _spks.clear();
    _opks.clear();
    registeredSpkId = 0;
  }

  /// A fresh signed prekey once the current one is a week old; prekeys
  /// older than [spkKeepFor] are forgotten. True when it rotated.
  Future<bool> rotateSpkIfDue() => _locked(() async {
        final now = _clock();
        var changed = false;
        if (now.difference(_spks.first.createdAt) >= spkRotateAfter) {
          _spks.insert(0,
              await SignedPreKey.generate(_identity!, _nextSpkId++, now: now));
          changed = true;
        }
        final before = _spks.length;
        _spks.removeWhere((k) =>
            k != _spks.first && now.difference(k.createdAt) > spkKeepFor);
        if (changed || _spks.length != before) await _save();
        return changed;
      });

  /// Makes [n] new one-time prekeys and returns them (to upload).
  Future<List<OneTimePreKey>> addOpks(int n) => _locked(() async {
        final made = <OneTimePreKey>[];
        for (var i = 0; i < n; i++) {
          final k = await OneTimePreKey.generate(_nextOpkId++);
          _opks[k.id] = k;
          made.add(k);
        }
        // Keys handed out for a first message that never came stay here
        // forever otherwise. The server holds at most 100 (topped up below
        // 20), so anything older than the newest [opkKeep] went out long ago.
        if (_opks.length > opkKeep) {
          final ids = _opks.keys.toList()..sort();
          for (final id in ids.take(_opks.length - opkKeep)) {
            _opks.remove(id);
          }
        }
        await _save();
        return made;
      });

  /// A signed prekey still kept, by id (first messages name the one used).
  SignedPreKey? spkById(int id) {
    for (final k in _spks) {
      if (k.id == id) return k;
    }
    return null;
  }

  /// One-time prekeys are only removed by [takeOpk]: the server may have
  /// handed one out for a first message that hasn't arrived yet.
  OneTimePreKey? opkById(int id) => _opks[id];

  /// Removes a one-time prekey once a first message that used it opened.
  Future<void> takeOpk(int id) => _locked(() async {
        if (_opks.remove(id) != null) await _save();
      });

  Future<void> markRegistered(int spkId) => _locked(() async {
        registeredSpkId = spkId;
        await _save();
      });

  /// Forget everything (sign-out).
  Future<void> wipe() => _locked(() async {
        _owner = null;
        _deviceId = null;
        _identity = null;
        _selfKey = null;
        _spks.clear();
        _opks.clear();
        registeredSpkId = 0;
        await _storage.delete(_key);
      });

  Future<Map<String, dynamic>?> _read() async {
    try {
      final s = await _storage.read(_key);
      return s == null ? null : jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  void _fromJson(Map<String, dynamic> j) {
    _owner = j['owner'] as String;
    _deviceId = j['device'] as String;
    _identity = SealIdentity.fromJson(j['identity'] as Map<String, dynamic>);
    _spks
      ..clear()
      ..addAll([
        for (final k in j['spks'] as List)
          SignedPreKey.fromJson(k as Map<String, dynamic>)
      ]);
    _opks
      ..clear()
      ..addAll({
        for (final k in j['opks'] as List)
          (k as Map<String, dynamic>)['id'] as int: OneTimePreKey.fromJson(k)
      });
    _nextOpkId = j['nextOpk'] as int;
    _nextSpkId = j['nextSpk'] as int;
    registeredSpkId = j['registered'] as int? ?? 0;
    final sk = j['self'] as String?;
    _selfKey = sk == null ? sealRandomBytes(32) : base64Decode(sk);
    _upgraded = sk == null;
  }

  bool _upgraded = false;

  /// Save once when an older stored copy just gained a field.
  Future<void> _saveIfUpgraded() async {
    if (!_upgraded) return;
    _upgraded = false;
    await _save();
  }

  Future<void> _save() => _storage.write(
      _key,
      jsonEncode({
        'v': SealSpec.version,
        'owner': _owner,
        'device': _deviceId,
        'identity': _identity!.toJson(),
        'spks': [for (final k in _spks) k.toJson()],
        'opks': [for (final k in _opks.values) k.toJson()],
        'nextOpk': _nextOpkId,
        'nextSpk': _nextSpkId,
        'registered': registeredSpkId,
        'self': base64Encode(_selfKey!),
      }));
}
