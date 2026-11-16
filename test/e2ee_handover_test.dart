// 🔒 History hand-over to a linked computer: the crypto, the QR fingerprint
// (must match the server's), and the phone → computer texts.
import 'dart:convert';
import 'dart:typed_data';

import 'package:aluta/e2ee/seal.dart';
import 'package:aluta/e2ee/seal_handover.dart';
import 'package:aluta/e2ee/seal_keystore.dart';
import 'package:aluta/e2ee/seal_messenger.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _h(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16)
    ]);

void main() {
  test('fingerprint matches the server (sha256, 16 bytes, base64url)',
      () async {
    final pub = _h(
        '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a');
    expect(await sealFingerprint(pub), 'MAyclgO5Kks57TlYv5JAEQ');
  });

  test('the fingerprint is read from the link code', () {
    expect(SealHandover.fingerprintOf('abc~MAyclgO5Kks57TlYv5JAEQ'),
        'MAyclgO5Kks57TlYv5JAEQ');
    expect(SealHandover.fingerprintOf('abc'), isNull, reason: 'older computer');
    expect(SealHandover.fingerprintOf('abc~'), isNull);
  });

  test('only the computer that made the key opens the package', () async {
    final computer = await XKeys.generate();
    final other = await XKeys.generate();
    final pkg = await sealHandover(computer.public, utf8.encode('historia'));
    expect(pkg[0], SealSpec.version);
    expect(pkg[1], SealSpec.typeHandover);
    expect(utf8.decode(await openHandover(computer, pkg)), 'historia');
    await expectLater(openHandover(other, pkg), throwsA(isA<SealError>()));
    final bad = Uint8List.fromList(pkg)..[pkg.length - 1] ^= 1;
    await expectLater(openHandover(computer, bad), throwsA(isA<SealError>()));
  });

  test("another account on the same phone never hands over the first's texts",
      () async {
    final keyDisk = MemorySealStorage();
    final plainDisk = MemorySealStorage();
    Future<SealMessenger> signIn(String who) async {
      final keys = SealKeyStore(storage: keyDisk);
      await keys.ensure(who);
      return SealMessenger(
          keys: keys, sessions: MemorySealStorage(), plain: plainDisk);
    }

    final first = await signIn('anna');
    await first.rememberSent(7, 101, 0, 'siri yetu');
    expect(await first.exportPlain(), isNotEmpty);
    final second = await signIn('ben'); // no sign-out in between
    expect(await second.exportPlain(), isEmpty);
    expect(await second.textOf(7, 101), isNull);
  });

  test("the phone's unlocked texts open on the computer", () async {
    Future<SealMessenger> app() async {
      final keys = SealKeyStore(storage: MemorySealStorage());
      await keys.ensure('me');
      return SealMessenger(
          keys: keys,
          sessions: MemorySealStorage(),
          plain: MemorySealStorage());
    }

    final phone = await app();
    final computer = await app();
    await phone.rememberSent(7, 101, 0, 'Habari');
    await phone.rememberSent(7, 102, 1, 'Nimefika (imehaririwa)');
    await phone.rememberSent(9, 300, 0, 'Asante');
    await computer.rememberSent(7, 102, 2, 'newer here');

    final link = await XKeys.generate();
    final pkg = await sealHandover(link.public,
        utf8.encode(jsonEncode({'v': 1, 'plain': await phone.exportPlain()})));
    final body = jsonDecode(utf8.decode(await openHandover(link, pkg)))
        as Map<String, dynamic>;
    final added = await computer
        .importPlain((body['plain'] as Map).cast<String, dynamic>());
    expect(added, 2);
    expect(await computer.textOf(7, 101), 'Habari');
    expect(await computer.textOf(7, 102), 'newer here',
        reason: 'a newer revision wins');
    expect(await computer.textOf(9, 300), 'Asante');
    // A sealed message from the server now opens from the hand-over.
    final r = await computer.open({
      'id': 300,
      'sender_id': 9,
      'receiver_id': 1,
      'e2ee': 1,
      'e2ee_rev': 0,
      'envelopes': '{}',
    }, 1);
    expect(r.text, 'Asante');
  });
}
