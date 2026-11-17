import 'dart:convert';

import 'package:aluta/e2ee/seal.dart';
import 'package:aluta/e2ee/seal_directory.dart';
import 'package:aluta/e2ee/seal_keystore.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  var now = DateTime(2026, 11, 16, 20);
  late MemorySealStorage disk;
  SealKeyStore store() => SealKeyStore(storage: disk, clock: () => now);

  setUp(() {
    now = DateTime(2026, 11, 16, 20);
    disk = MemorySealStorage();
  });

  test('first run makes a signed identity and prekey that survive a restart',
      () async {
    final a = store();
    await a.ensure('me@aluta');
    final id = a.identity;
    expect(
        await sealVerify(id.sig.public,
            [...SealSpec.ikDhSigPrefix, ...id.dh.public], id.dhSig),
        isTrue);
    expect(
        await sealVerify(id.sig.public,
            [...SealSpec.spkSigPrefix, ...a.currentSpk.keys.public],
            a.currentSpk.sig),
        isTrue);
    expect(a.deviceId.length, greaterThanOrEqualTo(16));
    await a.addOpks(5);
    final b = store();
    await b.ensure('me@aluta');
    expect(b.deviceId, a.deviceId);
    expect(b.identity.sig.public, a.identity.sig.public);
    expect(b.opkCount, 5);
  });

  test("another account never reuses this device's keys", () async {
    final a = store();
    await a.ensure('me@aluta');
    final b = store();
    await b.ensure('someone@aluta');
    expect(b.identity.sig.public, isNot(a.identity.sig.public));
    expect(b.deviceId, isNot(a.deviceId));
  });

  test('signed prekey rotates weekly and the old one is kept a while',
      () async {
    final a = store();
    await a.ensure('me@aluta');
    final first = a.currentSpk.id;
    expect(await a.rotateSpkIfDue(), isFalse);
    now = now.add(const Duration(days: 8));
    expect(await a.rotateSpkIfDue(), isTrue);
    expect(a.currentSpk.id, isNot(first));
    expect(a.spkById(first), isNotNull, reason: 'messages in flight');
    now = now.add(const Duration(days: 40));
    await a.rotateSpkIfDue();
    expect(a.spkById(first), isNull);
  });

  test('a used one-time prekey is gone, also after a restart', () async {
    final a = store();
    await a.ensure('me@aluta');
    final made = await a.addOpks(3);
    await a.takeOpk(made[1].id);
    expect(a.opkById(made[1].id), isNull);
    final b = store();
    await b.ensure('me@aluta');
    expect(b.opkCount, 2);
    expect(b.opkById(made[0].id)!.keys.public, made[0].keys.public);
  });

  test('one-time prekeys never handed in are not kept forever', () async {
    final a = store();
    await a.ensure('me@aluta');
    for (var i = 0; i < 5; i++) {
      await a.addOpks(100);
    }
    expect(a.opkCount, SealKeyStore.opkKeep);
    expect(a.opkById(1), isNull, reason: 'the oldest went first');
    expect(a.opkById(500), isNotNull);
  });

  test('wipe forgets everything', () async {
    final a = store();
    await a.ensure('me@aluta');
    await a.wipe();
    expect(a.isReady, isFalse);
    expect(disk.data, isEmpty);
  });

  test('the account owner is read from the session token', () {
    String part(Map<String, dynamic> m) =>
        base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
    final jwt = '${part({'alg': 'HS256'})}.${part({'sub': 'me@aluta'})}.sig';
    expect(SealDirectory.ownerOf(jwt), 'me@aluta');
    expect(SealDirectory.ownerOf('nope'), isNull);
    expect(SealDirectory.ownerOf(null), isNull);
  });
}
