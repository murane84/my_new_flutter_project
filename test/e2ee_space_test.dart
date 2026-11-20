// 🔒 Our Space sealing: the field format (matches a Python reference), key
// copies for each device, and SealSpace across people and devices.
import 'dart:convert';
import 'dart:typed_data';

import 'package:aluta/e2ee/seal.dart';
import 'package:aluta/e2ee/seal_directory.dart';
import 'package:aluta/e2ee/seal_keystore.dart';
import 'package:aluta/e2ee/seal_scope.dart';
import 'package:aluta/e2ee/seal_space.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _h(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16)
    ]);

class _Dev {
  _Dev(this.uid, this.keys, this.space);
  final int uid;
  final SealKeyStore keys;
  final SealSpace space;
}

class _Dir implements SealKeyDirectory {
  final Map<int, List<_Dev>> people = {};
  bool offline = false;

  @override
  Future<List<SealPeerDevice>?> devicesOf(int userId) async {
    if (offline) return null;
    return [
      for (final d in people[userId] ?? const <_Dev>[])
        SealPeerDevice(d.keys.deviceId,
            base64Encode(d.keys.identity.sig.public),
            ikDh: base64Encode(d.keys.identity.dh.public),
            ikDhSig: base64Encode(d.keys.identity.dhSig))
    ];
  }

  @override
  Future<List<SealDeviceBundle>?> bundlesFor(int userId,
          {String? deviceId}) async =>
      const [];

  int? uidOf(String deviceId) {
    for (final e in people.entries) {
      if (e.value.any((d) => d.keys.deviceId == deviceId)) return e.key;
    }
    return null;
  }
}

/// Plays the server's /e2ee/scopes rules.
class _Scopes implements SealScopeApi {
  _Scopes(this.dir);
  final _Dir dir;
  final Map<String, int> epochs = {};
  final Map<String, Map<String, Map<String, dynamic>>> copies = {};

  @override
  Future<Map<String, dynamic>?> fetch(String scope, String deviceId) async {
    final me = dir.uidOf(deviceId)!;
    final epoch = epochs[scope];
    if (epoch == null) return {'epoch': null, 'keys': [], 'missing': []};
    final c = copies[scope] ?? {};
    final mine = [
      for (final e in c.entries)
        if (e.key.endsWith('|$me:$deviceId')) e.value
    ];
    final missing = <Map<String, dynamic>>[];
    for (final uid in SealScope.membersOf(scope)!) {
      for (final d in await dir.devicesOf(uid) ?? const <SealPeerDevice>[]) {
        for (var e = 1; e <= epoch; e++) {
          if (c.containsKey('$e|$uid:${d.deviceId}')) continue;
          missing.add({
            'epoch': e,
            'user_id': uid,
            'device_id': d.deviceId,
            'ik_sig': d.ikSig,
            'ik_dh': d.ikDh,
            'ik_dh_sig': d.ikDhSig,
          });
        }
      }
    }
    return {
      'epoch': epoch,
      'keys': mine,
      'missing': missing,
    };
  }

  void _put(String scope, Map<String, dynamic> body) {
    final from = body['from_device'] as String;
    final c = copies.putIfAbsent(scope, () => {});
    for (final w in (body['wraps'] as List).cast<Map<String, dynamic>>()) {
      c.putIfAbsent('${body['epoch']}|${w['user_id']}:${w['device_id']}',
          () => {
            'epoch': body['epoch'],
            'wrapped': w['wrapped'],
            'from_user': dir.uidOf(from),
            'from_device': from,
          });
    }
  }

  @override
  Future<int> create(String scope, Map<String, dynamic> body) async {
    if (body['epoch'] != (epochs[scope] ?? 0) + 1) return 409;
    epochs[scope] = body['epoch'] as int;
    _put(scope, body);
    return 200;
  }

  @override
  Future<int> addWraps(String scope, Map<String, dynamic> body) async {
    final cur = epochs[scope];
    if (cur == null || (body['epoch'] as int) > cur) return 409;
    _put(scope, body);
    return 200;
  }
}

void main() {
  group('Field format', () {
    final key =
        _h('978d551f25f316c1ed2721402dc76049812d79d4f45e5706dcaded47bb3ab644');
    const vector =
        '🔒s1.3,7.1.AAECAwQFBgcICQoLwkwWN06nQV9m4tEKbaCQkoQHNmMdKh-kk0MCZRlD';

    test('matches the Python reference', () async {
      final s = await SealScope.seal(key, '3,7', 1, 'Nakupenda 💕',
          nonce: List<int>.generate(12, (i) => i));
      expect(s, vector);
      expect(await SealScope.open(key, vector), 'Nakupenda 💕');
      expect(SealScope.keyOf(vector), ('3,7', 1));
    });

    test('a sealed field cannot be moved to another group or key', () async {
      await expectLater(SealScope.open(key, vector.replaceFirst('3,7', '3,8')),
          throwsA(isA<SealError>()));
      await expectLater(SealScope.open(key, vector.replaceFirst('.1.', '.2.')),
          throwsA(isA<SealError>()));
    });

    test('scopes are sorted member ids', () {
      expect(SealScope.of([7, 3, 7]), '3,7');
      expect(SealScope.membersOf('3,7'), [3, 7]);
      expect(SealScope.membersOf('7,3'), isNull);
      expect(SealScope.membersOf('3'), isNull);
    });
  });

  group('Key copies', () {
    test('only the device it was wrapped for opens it, signed by a member',
        () async {
      final alice = await SealIdentity.generate();
      final bob = await SealIdentity.generate();
      final mallory = await SealIdentity.generate();
      final key = sealRandomBytes(32);
      final blob = await SealScope.wrap(
          me: alice,
          recipIkDh: bob.dh.public,
          recipIkSig: bob.sig.public,
          scope: '1,2',
          epoch: 1,
          scopeKey: key);
      expect(
          await SealScope.unwrap(
              me: bob,
              blob: blob,
              senderIkSig: alice.sig.public,
              scope: '1,2',
              epoch: 1),
          key);
      await expectLater(
          SealScope.unwrap(
              me: bob,
              blob: blob,
              senderIkSig: mallory.sig.public,
              scope: '1,2',
              epoch: 1),
          throwsA(isA<SealError>()),
          reason: 'not signed by that device');
      await expectLater(
          SealScope.unwrap(
              me: mallory,
              blob: blob,
              senderIkSig: alice.sig.public,
              scope: '1,2',
              epoch: 1),
          throwsA(isA<SealError>()),
          reason: 'not for that device');
      await expectLater(
          SealScope.unwrap(
              me: bob,
              blob: blob,
              senderIkSig: alice.sig.public,
              scope: '1,3',
              epoch: 1),
          throwsA(isA<SealError>()),
          reason: 'not for that group');
    });
  });

  group('SealSpace', () {
    late _Dir dir;
    late _Scopes scopes;

    setUp(() {
      dir = _Dir();
      scopes = _Scopes(dir);
    });

    Future<_Dev> device(int uid) async {
      final keys = SealKeyStore(storage: MemorySealStorage());
      await keys.ensure('user$uid');
      final d = _Dev(
          uid,
          keys,
          SealSpace(
              keys: keys,
              directory: dir,
              api: scopes,
              storage: MemorySealStorage()));
      dir.people.putIfAbsent(uid, () => []).add(d);
      return d;
    }

    test('a couple shares one key; nothing on the server reads it', () async {
      final a = await device(1);
      final b = await device(2);
      final sealed = await a.space.seal([1, 2], 'Kumbukumbu yetu ya kwanza');
      expect(SealScope.isSealed(sealed), isTrue);
      expect(sealed.contains('Kumbukumbu'), isFalse);
      expect(await b.space.open(sealed), 'Kumbukumbu yetu ya kwanza');
      final back = await b.space.seal([2, 1], 'Nakumbuka 💞');
      expect(await a.space.open(back), 'Nakumbuka 💞');
      expect(scopes.epochs, {'1,2': 1});
    });

    test('both make the first key at once and still agree', () async {
      final a = await device(1);
      final b = await device(2);
      final both = await Future.wait(
          [a.space.seal([1, 2], 'ya Anna'), b.space.seal([1, 2], 'ya Ben')]);
      expect(await b.space.open(both[0]), 'ya Anna');
      expect(await a.space.open(both[1]), 'ya Ben');
    });

    test('a device that joins later gets the key from a member', () async {
      final a = await device(1);
      await device(2);
      final s = await a.space.seal([1, 2], 'siri');
      final pc = await device(1);
      expect(await pc.space.open(s), SealSpace.waitingForKey);
      await a.space.serveAll();
      expect(await pc.space.open(s), 'siri');
    });

    test('a member on an older Aluta keeps Our Space plain', () async {
      final a = await device(1);
      await expectLater(
          a.space.seal([1, 9], 'x'), throwsA(isA<SealSpaceNotReady>()));
    });

    test('a sealed Space stays sealed when a member has no keys', () async {
      final a = await device(1);
      await device(2);
      final first = await a.space.seal([1, 2], 'kwanza');
      final b = dir.people.remove(2)!; // signed out (or the server says so)
      final next = await a.space.seal([1, 2], 'pili');
      expect(SealScope.isSealed(next), isTrue);
      dir.people[2] = b;
      expect(await b.first.space.open(first), 'kwanza');
      expect(await b.first.space.open(next), 'pili');
    });

    test('a group chat: joiners read from then on, leavers stop', () async {
      final a = await device(1);
      final b = await device(2);
      final c = await device(3);
      final before = await a.space.seal([1, 2, 3], 'habari kikundi');
      expect(await b.space.open(before), 'habari kikundi');
      expect(await c.space.open(before), 'habari kikundi');

      // D joins: the group's members — and so its key — change.
      final d = await device(4);
      final after = await b.space.seal([1, 2, 3, 4], 'karibu D');
      expect(await d.space.open(after), 'karibu D');
      expect(await d.space.open(before), SealSpace.waitingForKey,
          reason: 'written before D joined');
      expect(await a.space.open(after), 'karibu D');

      // C leaves.
      final later = await a.space.seal([1, 2, 4], 'C ameondoka');
      expect(await c.space.open(later), SealSpace.waitingForKey);
      expect(await d.space.open(later), 'C ameondoka');
    });

    test('a group that shares its history hands a newcomer the older keys',
        () async {
      final a = await device(1);
      await device(2);
      final before = await a.space.seal([1, 2], 'kabla hujaja');
      final d = await device(4);
      expect(await d.space.open(before), SealSpace.waitingForKey);
      // A's phone wraps the older key for D's devices (the grant).
      final devs = [
        for (final x in (await dir.devicesOf(4))!)
          {
            'device_id': x.deviceId,
            'ik_sig': x.ikSig,
            'ik_dh': x.ikDh,
            'ik_dh_sig': x.ikDhSig,
            'epochs': [1],
          }
      ];
      final keys = await a.space.historyWraps('1,2', 4, devs);
      expect(keys, hasLength(1));
      expect((keys.first['wraps'] as List).single['user_id'], 4);
      for (final k in keys) {
        await scopes.addWraps('1,2', k);
      }
      expect(await d.space.open(before), 'kabla hujaja');
      // Nothing for epochs D already has.
      expect(
          await a.space.historyWraps('1,2', 4, [
            {...devs.first, 'epochs': <int>[]}
          ]),
          isEmpty);
    });

    test('a sealed group stays sealed when a new member has no keys',
        () async {
      final a = await device(1);
      await device(2);
      await a.space.seal([1, 2], 'kwanza');
      // Member 9 (an older Aluta, no keys) joins: a new group of people.
      await expectLater(a.space.seal([1, 2, 9], 'x'),
          throwsA(isA<SealSpaceNotReady>()),
          reason: 'never sealed for these people: the caller decides');
      final s = await a.space.seal([1, 2, 9], 'bado siri', stay: true);
      expect(SealScope.isSealed(s), isTrue);
      expect(await dir.people[2]!.first.space.open(s), 'bado siri');
    });

    test('offline: it refuses to seal rather than send plain', () async {
      final a = await device(1);
      await device(2);
      dir.offline = true;
      await expectLater(
          a.space.seal([1, 2], 'x'), throwsA(isA<SealError>()));
    });

    test('a whole answer opens in place and its Space is remembered',
        () async {
      final a = await device(1);
      final b = await device(2);
      final cap = await a.space.seal([1, 2], 'Siku ya kwanza');
      final body = jsonEncode({
        'id': 5,
        'owner_id': 1,
        'is_primary': true,
        'members': [
          {'id': 2, 'username': 'b'}
        ],
        'moments': [
          {'caption': cap, 'kind': 'note'},
          {'caption': 'plain old one', 'kind': 'note'},
        ],
      });
      final j = await b.space.decode(body) as Map<String, dynamic>;
      expect((j['moments'] as List)[0]['caption'], 'Siku ya kwanza');
      expect((j['moments'] as List)[1]['caption'], 'plain old one');
      expect(b.space.scopeOfSpace(5), '1,2');
      final reply = await b.space.sealForSpace(5, 'Ndiyo!');
      expect(await a.space.open(reply), 'Ndiyo!');
    });

    test('a group chat answer is never taken for a Space', () async {
      final b = await device(2);
      await b.space.openJson({
        'id': 9,
        'members': [
          {'id': 1},
          {'id': 2},
          {'id': 3}
        ],
      });
      expect(b.space.scopeOfSpace(9), isNull);
    });

    test('a new phone nobody has served yet can still write (next key)',
        () async {
      final a = await device(1);
      final b = await device(2);
      final old = await a.space.seal([1, 2], 'ya zamani');
      final phone = await device(1); // reinstalled, no hand-over
      expect(await phone.space.open(old), SealSpace.waitingForKey);
      final fresh = await phone.space.seal([1, 2], 'mpya');
      expect(SealScope.keyOf(fresh)!.$2, 2);
      expect(await b.space.open(fresh), 'mpya');
      expect(await a.space.open(fresh), 'mpya');
      expect(await b.space.open(old), 'ya zamani', reason: 'old key kept');
      // …and a member device gives the new phone the older key too.
      await a.space.serveAll();
      expect(await phone.space.open(old), 'ya zamani');
    });

    test("a linked computer takes the phone's keys over", () async {
      final a = await device(1);
      await device(2);
      final s = await a.space.seal([1, 2], 'safari yetu');
      final pc = await device(1);
      await pc.space.importKeys(await a.space.exportKeys());
      expect(await pc.space.open(s), 'safari yetu');
    });
  });
}
