// Checking a chat's encryption together: the safety code.
import 'package:aluta/e2ee/seal_directory.dart';
import 'package:aluta/e2ee/seal_verify.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Dir implements SealKeyDirectory {
  final Map<int, List<String>> keys = {};

  @override
  Future<List<SealPeerDevice>?> devicesOf(int userId) async => [
        for (final (i, k) in (keys[userId] ?? const <String>[]).indexed)
          SealPeerDevice('d$userId-$i', k)
      ];

  @override
  Future<List<SealDeviceBundle>?> bundlesFor(int userId,
          {String? deviceId}) async =>
      const [];
}

void main() {
  test('both phones see the same 60 digits', () async {
    final a = await SealVerify.pairCode(7, ['kA'], 42, ['kB1', 'kB2']);
    final b = await SealVerify.pairCode(42, ['kB2', 'kB1'], 7, ['kA']);
    expect(a, b);
    expect(a.length, 60);
    expect(RegExp(r'^\d{60}$').hasMatch(a), isTrue);
    expect(SealVerify.groups(a), hasLength(12));
  });

  test('a new device or a reinstall changes the code', () async {
    final before = await SealVerify.pairCode(7, ['kA'], 42, ['kB']);
    expect(await SealVerify.pairCode(7, ['kA'], 42, ['kB', 'pc']),
        isNot(before));
    expect(await SealVerify.pairCode(7, ['kA2'], 42, ['kB']), isNot(before));
    expect(await SealVerify.pairCode(7, ['kA'], 43, ['kB']), isNot(before),
        reason: 'another person, another code');
  });

  test('scanning: match, mismatch, someone else', () async {
    final code = await SealVerify.pairCode(7, ['kA'], 42, ['kB']);
    final theirs = SealVerify.qrFor(42, 7, code);
    expect(SealVerify.checkQr(theirs, 7, 42, code), isTrue);
    final other = await SealVerify.pairCode(7, ['kA'], 42, ['evil']);
    expect(SealVerify.checkQr(SealVerify.qrFor(42, 7, other), 7, 42, code),
        isFalse);
    expect(SealVerify.checkQr(SealVerify.qrFor(42, 9, code), 7, 42, code),
        isNull);
    expect(SealVerify.checkQr('aluta-link:ABCD', 7, 42, code), isNull);
  });

  test('a change note sits after the last message before it', () {
    final t = DateTime.utc(2026, 11, 20, 9);
    final c = SealCodeChange(t, mine: false);
    final m8 = t.subtract(const Duration(hours: 1));
    final m10 = t.add(const Duration(hours: 1));
    expect(SealVerify.changesBetween([c], m8, m10), [c]);
    expect(SealVerify.changesBetween([c], m8, null), [c],
        reason: 'after the newest message');
    expect(SealVerify.changesBetween([c], m10, null), isEmpty,
        reason: 'it happened before this message');
    expect(SealVerify.changesBetween([c], m8, t), [c],
        reason: 'the same moment as the newer message still counts here');
    expect(SealVerify.changesBetween([c], t, m10), isEmpty,
        reason: 'never shown twice');
  });

  test('verified until the code changes; changes are noted with whose',
      () async {
    SharedPreferences.setMockInitialValues({});
    final dir = _Dir()
      ..keys[7] = ['kA']
      ..keys[42] = ['kB'];
    final store = SealVerifyStore.instance..directory = dir;
    var st = await store.refresh(7, 42);
    expect(st.code, isNotNull);
    expect(st.verified, isFalse);
    expect(st.changes, isEmpty, reason: 'first look is not a change');
    await store.markVerified(7, 42, st.code!);
    expect((await store.refresh(7, 42)).verified, isTrue);

    dir.keys[42] = ['kB', 'their-pc']; // they linked a computer
    st = await store.refresh(7, 42);
    expect(st.verified, isFalse);
    expect(st.checkedBefore, isTrue);
    expect(st.changes.single.mine, isFalse);

    dir.keys[7] = ['kA-new']; // I reinstalled
    st = await store.refresh(7, 42);
    expect(st.changes.last.mine, isTrue);
    expect(st.changes, hasLength(2));

    // The chat and the check screen looking at once: one look, one note.
    dir.keys[42] = ['kB-new'];
    final both = await Future.wait(
        [store.refresh(7, 42), store.refresh(7, 42)]);
    expect(both[0].changes, hasLength(3));
    expect(both[1].changes, hasLength(3));
    expect((await store.refresh(7, 42)).changes, hasLength(3),
        reason: 'a later look finishes too (no look waits on itself)');

    dir.keys.remove(42); // they have no keys (or offline): no code
    st = await store.refresh(7, 42);
    expect(st.code, isNull);
    expect(st.changes, hasLength(3));
  });
}
