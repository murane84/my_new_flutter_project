// 🔒 Named scopes: a big group's key ("g:<id>") and a person's Stories key
// ("s:<id>") use the same sealed-field format as member-list scopes.
import 'dart:convert';

import 'package:aluta/e2ee/seal.dart';
import 'package:aluta/e2ee/seal_scope.dart';
import 'package:aluta/e2ee/seal_space.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('named scopes are recognised, odd ones are not', () {
    expect(SealScope.isNamed(SealScope.group(12)), isTrue);
    expect(SealScope.isNamed(SealScope.story(7)), isTrue);
    for (final bad in ['g:', 'g:0', 'g:012', 'x:5', 'g:5a', 's:-1', '3,7']) {
      expect(SealScope.isNamed(bad), isFalse, reason: bad);
    }
    expect(SealScope.isScope('3,7'), isTrue);
    expect(SealScope.isScope('g:44'), isTrue);
    expect(SealScope.isScope('7'), isFalse);
  });

  test('a field sealed with a named scope opens, and only with its scope',
      () async {
    final key = List<int>.generate(32, (i) => i * 7 & 0xff);
    final s = await SealScope.seal(key, 'g:44', 3, 'Habari wote');
    expect(SealScope.keyOf(s), ('g:44', 3));
    expect(await SealScope.open(key, s), 'Habari wote');
    // The scope is bound into the lock: moved to another scope, it fails.
    final moved = s.replaceFirst('g:44', 'g:45');
    await expectLater(SealScope.open(key, moved), throwsA(isA<SealError>()));
  });

  test('a key wrapped for many devices opens on each; a forged one is skipped',
      () async {
    final me = await SealIdentity.generate();
    final others = [for (var i = 0; i < 3; i++) await SealIdentity.generate()];
    final key = sealRandomBytes(32);
    Map<String, dynamic> entry(int uid, SealIdentity id, {bool forge = false}) =>
        {
          'user_id': uid,
          'device_id': 'device-$uid',
          'ik_sig': base64Encode(id.sig.public),
          'ik_dh': base64Encode(id.dh.public),
          // A device whose DH key isn't signed by its identity: no copy.
          'ik_dh_sig': base64Encode(forge ? others[0].dhSig : id.dhSig),
        };
    final devices = [
      for (var i = 0; i < others.length; i++) entry(i + 2, others[i]),
      entry(9, others[1], forge: true),
    ];
    final wraps = await SealSpace.wrapList(me, 'g:44', 2, key, devices);
    expect(wraps.map((w) => w['user_id']), [2, 3, 4]);
    for (var i = 0; i < others.length; i++) {
      expect(
          await SealScope.unwrap(
              me: others[i],
              blob: wraps[i]['wrapped'] as String,
              senderIkSig: me.sig.public,
              scope: 'g:44',
              epoch: 2),
          key);
    }
  });
}
