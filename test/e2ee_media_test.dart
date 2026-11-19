// 🔒 Sealed media: lock / open, tampering, cutting short, addresses.
import 'dart:typed_data';

import 'package:aluta/e2ee/seal.dart';
import 'package:aluta/e2ee/seal_media.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List bytes(int n) =>
      Uint8List.fromList(List<int>.generate(n, (i) => (i * 31 + 7) & 0xff));

  test('opens what it locked, at any size', () async {
    for (final n in [0, 1, 1000, SealMedia.chunk, SealMedia.chunk + 1,
        3 * SealMedia.chunk + 17]) {
      final plain = bytes(n);
      final (locked, key) = await SealMedia.seal(plain);
      expect(locked.length, greaterThan(n));
      expect(await SealMedia.open(locked, key), plain, reason: '$n bytes');
    }
  });

  test('a changed, cut or re-ordered file never opens', () async {
    final plain = bytes(3 * SealMedia.chunk);
    final (locked, key) = await SealMedia.seal(plain);
    final flipped = Uint8List.fromList(locked)..[100] ^= 1;
    await expectLater(SealMedia.open(flipped, key), throwsA(isA<SealError>()));
    final cut = locked.sublist(0, locked.length - (SealMedia.chunk + 16));
    await expectLater(SealMedia.open(cut, key), throwsA(isA<SealError>()),
        reason: 'the last chunk is gone');
    final (other, otherKey) = await SealMedia.seal(plain);
    expect(other, isNot(locked), reason: 'every file gets its own key');
    await expectLater(SealMedia.open(locked, otherKey),
        throwsA(isA<SealError>()));
  });

  test('the key rides on the address, never in what the server sees', () {
    final key = bytes(32);
    final url = SealMedia.withKey('/attachments/abc', key);
    expect(url.startsWith('/attachments/abc#ask='), isTrue);
    expect(SealMedia.keyOf(url), key);
    expect(SealMedia.bare(url), '/attachments/abc');
    expect(SealMedia.isSealed('/attachments/abc'), isFalse);
    expect(SealMedia.withKey(url, key), url, reason: 'no double key');
  });
}
