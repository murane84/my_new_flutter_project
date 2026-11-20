// 🔒 Server backup: locked on the phone with a recovery key only you hold.
import 'dart:convert';

import 'package:aluta/services/local_backup_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final svc = LocalBackupService.instance;

  test('a recovery key reads back the same, however it is typed', () {
    final key = svc.newRecoveryKey();
    expect(key, hasLength(32));
    final shown = LocalBackupService.formatRecoveryKey(key);
    expect(shown.replaceAll('-', ''), hasLength(64));
    expect(LocalBackupService.parseRecoveryKey(shown), key);
    expect(
        LocalBackupService.parseRecoveryKey(
            ' ${shown.toUpperCase().replaceAll('-', ' ')} '),
        key);
    expect(LocalBackupService.parseRecoveryKey('abcd-1234'), isNull);
  });

  test('only the recovery key opens the server copy', () async {
    final key = svc.newRecoveryKey();
    final plain = utf8.encode('{"magic":"ALUTABAK1","data":{}}');
    final blob = await svc.lockForCloud(plain, key);
    expect(utf8.decode(blob.sublist(0, 4)), 'ACB1');
    expect(String.fromCharCodes(blob).contains('ALUTABAK1'), isFalse,
        reason: 'the server sees locked bytes only');
    expect(await svc.openFromCloud(blob, key), plain);
    await expectLater(
        svc.openFromCloud(blob, svc.newRecoveryKey()), throwsException);
    final cut = [...blob]..[20] ^= 1;
    await expectLater(svc.openFromCloud(cut, key), throwsException);
  });
}
