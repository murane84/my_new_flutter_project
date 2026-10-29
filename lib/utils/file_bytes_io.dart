import 'dart:io';

import 'package:flutter/services.dart';

const _media = MethodChannel('aluta/downloads');

/// Reads a local file. On Android, songs in shared storage can be visible to
/// the player (MediaStore content uri) yet refused to a plain File read —
/// Android 10's scoped storage and some EMUI / OEM builds do this. Then the
/// bytes come through MediaStore natively instead, so sharing a song or
/// hosting Listen Together works on those phones too.
Future<List<int>> readFileBytes(String path) async {
  if (Platform.isAndroid && path.startsWith('content://')) {
    final b = await _media.invokeMethod<Object?>('readMedia', {'path': path});
    if (b is! List<int>) throw FileSystemException('Unreadable media', path);
    return b;
  }
  try {
    return await File(path).readAsBytes();
  } on FileSystemException {
    if (!Platform.isAndroid) rethrow;
    Object? b;
    try {
      b = await _media.invokeMethod<Object?>('readMedia', {'path': path});
    } catch (_) {}
    if (b is! List<int> || b.isEmpty) rethrow;
    return b;
  }
}
