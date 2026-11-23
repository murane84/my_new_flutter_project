// 🔒 Named scopes: a big group's key ("g:<id>") and a person's Stories key
// ("s:<id>") use the same sealed-field format as member-list scopes.
import 'package:aluta/e2ee/seal.dart';
import 'package:aluta/e2ee/seal_scope.dart';
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
}
