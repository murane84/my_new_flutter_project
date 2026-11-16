// 🔒 Listen Together: the room key from the host and sealed chat lines.
import 'dart:convert';

import 'package:aluta/e2ee/seal_directory.dart';
import 'package:aluta/e2ee/seal_keystore.dart';
import 'package:aluta/e2ee/seal_room.dart';
import 'package:flutter_test/flutter_test.dart';

class _Dir implements SealKeyDirectory {
  final Map<int, List<SealKeyStore>> people = {};

  @override
  Future<List<SealPeerDevice>?> devicesOf(int userId) async => [
        for (final k in people[userId] ?? const <SealKeyStore>[])
          SealPeerDevice(k.deviceId, base64Encode(k.identity.sig.public),
              ikDh: base64Encode(k.identity.dh.public),
              ikDhSig: base64Encode(k.identity.dhSig))
      ];

  @override
  Future<List<SealDeviceBundle>?> bundlesFor(int userId,
          {String? deviceId}) async =>
      const [];
}

void main() {
  late _Dir dir;

  setUp(() => dir = _Dir());

  Future<SealKeyStore> person(int uid) async {
    final k = SealKeyStore(storage: MemorySealStorage());
    await k.ensure('user$uid');
    dir.people.putIfAbsent(uid, () => []).add(k);
    return k;
  }

  test('the host gives a guest the key; lines open only in that room',
      () async {
    final hostKeys = await person(1);
    final guestKeys = await person(2);
    final host = SealRoom('s-1', keys: hostKeys, directory: dir);
    final guest = SealRoom('s-1', keys: guestKeys, directory: dir);
    final msg = await host.keyMessageFor(2, 1);
    expect(msg, isNotNull);
    expect(msg!['to'], 2);
    expect(await guest.takeKey(jsonDecode(jsonEncode(msg)), 1), isTrue);

    final line = await guest.seal('Wimbo huu ni wetu 🎶');
    expect(SealRoom.isSealed(line), isTrue);
    expect(line.contains('Wimbo'), isFalse);
    expect(await host.open(line), 'Wimbo huu ni wetu 🎶');
    expect(await guest.open(await host.seal('Asante!')), 'Asante!');

    final elsewhere = SealRoom('s-2', keys: guestKeys, directory: dir);
    expect(await elsewhere.takeKey(msg, 1), isFalse,
        reason: 'a copy for another session does not open');
  });

  test('only the host can hand out the key', () async {
    await person(1);
    final mallory = await person(3);
    final guestKeys = await person(2);
    final fake = SealRoom('s-1', keys: mallory, directory: dir);
    final msg = await fake.keyMessageFor(2, 3);
    final guest = SealRoom('s-1', keys: guestKeys, directory: dir);
    expect(await guest.takeKey(msg!, 1), isFalse,
        reason: 'from someone other than the host');
    expect(await guest.takeKey({...msg, 'from': 1}, 1), isFalse,
        reason: 'not signed by one of the host\'s devices');
  });

  test('a guest on an older Aluta gets no key', () async {
    final hostKeys = await person(1);
    final host = SealRoom('s-1', keys: hostKeys, directory: dir);
    expect(await host.keyMessageFor(9, 1), isNull);
  });
}
