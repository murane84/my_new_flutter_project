import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Encrypted, device-held backup of the app's LOCAL data.
///
/// The server stores almost nothing long-term (delivered chats are purged), so
/// this is how a user carries their history to a new device or recovers after a
/// reinstall — without the server holding it. The backup is a single text file:
/// a JSON envelope wrapping AES-256-GCM ciphertext, with the key derived from
/// the user's own passphrase (PBKDF2-HMAC-SHA256). Only someone with the
/// passphrase can read it — not the server, not us.
class LocalBackupService {
  LocalBackupService._();
  static final LocalBackupService instance = LocalBackupService._();

  static const String _magic = 'ALUTABAK1';

  /// The SharedPreferences keys that hold cached user content worth carrying.
  bool _isBackupKey(String k) =>
      k.startsWith('chat_cache_') ||
      k.startsWith('space_full_') ||
      k == 'cached_friends_v1' ||
      k == 'cached_groups_v1' ||
      k == 'cached_spaces_v1';

  /// Produce the encrypted backup as a UTF-8 string (write it to a .alutabak
  /// file and let the user save/share it). Throws if [passphrase] is empty.
  Future<String> createBackup(String passphrase) async {
    if (passphrase.trim().length < 4) {
      throw Exception('Passphrase too short');
    }
    final prefs = await SharedPreferences.getInstance();
    final data = <String, String>{};
    for (final k in prefs.getKeys()) {
      if (_isBackupKey(k)) {
        final v = prefs.getString(k);
        if (v != null) data[k] = v;
      }
    }
    final plain = utf8.encode(jsonEncode({
      'magic': _magic,
      'created_at': DateTime.now().toIso8601String(),
      'count': data.length,
      'data': data,
    }));
    final salt = _randomBytes(16);
    final nonce = _randomBytes(12);
    final key = await _deriveKey(passphrase, salt);
    final algo = AesGcm.with256bits();
    final box = await algo.encrypt(plain, secretKey: key, nonce: nonce);
    return jsonEncode({
      'v': 1,
      'app': 'aluta',
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
      'mac': base64Encode(box.mac.bytes),
      'ct': base64Encode(box.cipherText),
    });
  }

  /// Decrypt [content] with [passphrase] and merge it back into local storage.
  /// Returns how many entries were restored. Throws on a wrong passphrase or a
  /// corrupt / foreign file.
  Future<int> restoreBackup(String content, String passphrase) async {
    Map<String, dynamic> env;
    try {
      env = jsonDecode(content) as Map<String, dynamic>;
    } catch (_) {
      throw Exception('Not a valid backup file');
    }
    if (env['app'] != 'aluta' || env['ct'] == null) {
      throw Exception('Not an Aluta backup file');
    }
    final salt = base64Decode(env['salt'] as String);
    final nonce = base64Decode(env['nonce'] as String);
    final mac = Mac(base64Decode(env['mac'] as String));
    final ct = base64Decode(env['ct'] as String);
    final key = await _deriveKey(passphrase, salt);
    final algo = AesGcm.with256bits();
    List<int> clear;
    try {
      clear = await algo.decrypt(
        SecretBox(ct, nonce: nonce, mac: mac),
        secretKey: key,
      );
    } catch (_) {
      throw Exception('Wrong passphrase or corrupted file');
    }
    final obj = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    if (obj['magic'] != _magic) {
      throw Exception('Not an Aluta backup');
    }
    final data = (obj['data'] as Map).cast<String, dynamic>();
    final prefs = await SharedPreferences.getInstance();
    var n = 0;
    for (final e in data.entries) {
      await prefs.setString(e.key, e.value.toString());
      n++;
    }
    return n;
  }

  Future<SecretKey> _deriveKey(String pass, List<int> salt) async {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 120000,
      bits: 256,
    );
    return kdf.deriveKeyFromPassword(
        password: utf8.decode(utf8.encode(pass)), nonce: salt);
  }

  List<int> _randomBytes(int n) {
    final r = Random.secure();
    return List<int>.generate(n, (_) => r.nextInt(256));
  }
}
