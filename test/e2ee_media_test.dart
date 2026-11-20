// 🔒 Sealed media: lock / open, tampering, cutting short, addresses.
import 'dart:io';
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

  test('a big file locks and opens piece by piece, same format', () async {
    final dir = await Directory.systemTemp.createTemp('seal_media');
    try {
      for (final n in [0, 5, SealMedia.chunk, 2 * SealMedia.chunk + 9]) {
        final plain = bytes(n);
        final src = File('${dir.path}/p$n')..writeAsBytesSync(plain);
        final locked = '${dir.path}/l$n';
        final key = await SealMedia.sealFile(src.path, locked);
        final lockedBytes = File(locked).readAsBytesSync();
        // Opens in memory too (a phone that got it small enough).
        expect(await SealMedia.open(lockedBytes, key), plain, reason: '$n');
        final out = '${dir.path}/o$n';
        await SealMedia.openFile(locked, out, key);
        expect(File(out).readAsBytesSync(), plain, reason: '$n from file');
        // And one locked in memory opens file to file.
        final (mem, k2) = await SealMedia.seal(plain);
        File('${dir.path}/m$n').writeAsBytesSync(mem);
        await SealMedia.openFile('${dir.path}/m$n', '${dir.path}/mo$n', k2);
        expect(File('${dir.path}/mo$n').readAsBytesSync(), plain);
      }
      // Changed bytes: fails, and leaves nothing opened behind.
      final plain = bytes(2 * SealMedia.chunk);
      File('${dir.path}/p').writeAsBytesSync(plain);
      final key = await SealMedia.sealFile('${dir.path}/p', '${dir.path}/l');
      final bad = File('${dir.path}/l').readAsBytesSync()..[40] ^= 1;
      File('${dir.path}/l').writeAsBytesSync(bad);
      await expectLater(
          SealMedia.openFile('${dir.path}/l', '${dir.path}/o', key),
          throwsA(isA<SealError>()));
      expect(File('${dir.path}/o').existsSync(), isFalse);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('songs and big files need the newer Aluta (m2)', () {
    expect(SealMedia.capFor('image', 10), 'm1');
    expect(SealMedia.capFor('file', SealMedia.maxBytes), 'm1');
    expect(SealMedia.capFor('file', SealMedia.maxBytes + 1), 'm2');
    expect(SealMedia.capFor('song', 10), 'm2');
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
