// Aluta Seal — reactions sealed the same way every time (SealScope.sealFixed).
//
// A reaction in Our Space is sealed with a nonce taken from the key and the
// emoji (a synthetic IV): the server can match a toggle and count reactions,
// but can't tell which emoji. These pin that behaviour down.
import 'dart:typed_data';

import 'package:aluta/e2ee/seal_scope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final key = Uint8List.fromList(List.generate(32, (i) => i));
  final other = Uint8List.fromList(List.generate(32, (i) => 255 - i));
  const scope = '3,7';

  test('the same emoji seals to the same string', () async {
    final a = await SealScope.sealFixed(key, scope, 1, '❤️');
    final b = await SealScope.sealFixed(key, scope, 1, '❤️');
    expect(a, b);
    expect(SealScope.isSealed(a), isTrue);
    expect(a.contains('❤️'), isFalse);
  });

  test('different emoji, keys or epochs seal differently', () async {
    final heart = await SealScope.sealFixed(key, scope, 1, '❤️');
    expect(await SealScope.sealFixed(key, scope, 1, '😂'), isNot(heart));
    expect(await SealScope.sealFixed(other, scope, 1, '❤️'), isNot(heart));
    expect(await SealScope.sealFixed(key, scope, 2, '❤️'), isNot(heart));
  });

  test('it opens like any sealed field, only with its key', () async {
    final s = await SealScope.sealFixed(key, scope, 1, '🔥');
    expect(await SealScope.open(key, s), '🔥');
    expect(SealScope.open(other, s), throwsA(anything));
  });

  test('an ordinary seal stays random', () async {
    final a = await SealScope.seal(key, scope, 1, '❤️');
    final b = await SealScope.seal(key, scope, 1, '❤️');
    expect(a, isNot(b));
  });
}
