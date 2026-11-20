import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../e2ee/seal_directory.dart';
import '../e2ee/seal_keystore.dart';
import '../e2ee/seal_messenger.dart';
import '../e2ee/seal_space.dart';
import '../screens/token_helper.dart';
import '../utils/app_config.dart';
import '../utils/net.dart' as http;

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
      // 🔒 Which groups were sealed (never written to in the clear again).
      k.startsWith('aluta_group_sealed_') ||
      k == 'cached_friends_v1' ||
      k == 'cached_groups_v1' ||
      k == 'cached_spaces_v1';

  /// Produce the encrypted backup as a UTF-8 string (write it to a .alutabak
  /// file and let the user save/share it). Throws if [passphrase] is empty.
  /// The shortest passphrase accepted: the file now carries the keys to
  /// your encrypted chats, so it must hold up to guessing.
  static const int minPassphrase = 8;

  /// The backup's contents (before locking): the cached chats / Our Space
  /// and, 🔒, the encrypted chats' own memory and keys.
  Future<List<int>> _payload() async {
    final prefs = await SharedPreferences.getInstance();
    final data = <String, Object>{};
    for (final k in prefs.getKeys()) {
      if (_isBackupKey(k)) {
        final v = prefs.get(k); // text, or a flag (sealed groups)
        if (v is String) {
          data[k] = v;
        } else if (v is bool) {
          data[k] = v;
        }
      }
    }
    // 🔒 The encrypted chats' own memory: the opened 1:1 texts (with their
    // photos' / files' keys) and the Our Space / group keys — so a reinstall
    // reads everything again, not just the cached copy.
    Map<String, dynamic>? seal;
    try {
      seal = {
        'plain': await SealMessenger.instance.exportPlain(),
        'scopes': await SealSpace.instance.exportKeys(),
      };
    } catch (_) {/* keys not set up here: the chats still go */}
    return utf8.encode(jsonEncode({
      'magic': _magic,
      'created_at': DateTime.now().toIso8601String(),
      'count': data.length,
      'data': data,
      'seal': ?seal,
    }));
  }

  Future<String> createBackup(String passphrase) async {
    if (passphrase.trim().length < minPassphrase) {
      throw Exception('Passphrase too short');
    }
    final plain = await _payload();
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
    return _apply(clear);
  }

  /// Put a backup's contents back on this device. Returns how many items.
  Future<int> _apply(List<int> clear) async {
    final obj = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    if (obj['magic'] != _magic) {
      throw Exception('Not an Aluta backup');
    }
    final data = (obj['data'] as Map).cast<String, dynamic>();
    final prefs = await SharedPreferences.getInstance();
    var n = 0;
    for (final e in data.entries) {
      if (e.key.startsWith('aluta_group_sealed_')) {
        await prefs.setBool(e.key, e.value == true || e.value == 'true');
      } else if (e.key.startsWith('chat_cache_')) {
        // A chat already on this phone keeps what's newer here: the backup
        // only adds what's missing (restoring never loses messages).
        await prefs.setString(
            e.key, _mergeChat(prefs.getString(e.key), e.value.toString()));
      } else {
        await prefs.setString(e.key, e.value.toString());
      }
      n++;
    }
    // 🔒 Filed under THIS install's keys (a reinstall made new ones).
    final seal = obj['seal'];
    if (seal is Map) {
      try {
        final owner = SealDirectory.ownerOf(await getToken());
        if (owner != null) await SealKeyStore.instance.ensure(owner);
        final p = seal['plain'];
        if (p is Map) {
          n += await SealMessenger.instance
              .importPlain(p.cast<String, dynamic>());
        }
        final s = seal['scopes'];
        if (s is Map) {
          await SealSpace.instance.importKeys(s.cast<String, dynamic>());
        }
      } catch (_) {/* the chats' cached copy is back either way */}
    }
    return n;
  }

  // ── 🔒 Backup on the server, locked with a recovery key ───────────────
  //
  // The same contents as the file, locked on this device with a key derived
  // from a random 256-bit RECOVERY KEY (shown once; the person keeps it).
  // The server stores only the locked bytes and can't open them — there is
  // no short PIN to guess. This device keeps the recovery key (secure
  // storage) so later backups go up without asking again.

  static final List<int> _cloudMagic = ascii.encode('ACB1');
  static final List<int> _cloudInfo = utf8.encode('AlutaCloudBackup v1');

  SealStorage get _secure => SealKeyStore.platformStorage();
  /// Per signed-in person (another account on this phone never sees it).
  Future<String> _slot() async => slotFor(
      (await SharedPreferences.getInstance()).getString('my_user_id') ?? 'x');

  static String slotFor(String uid) => 'aluta_cloud_backup_key_$uid';

  /// A new recovery key: 32 random bytes.
  List<int> newRecoveryKey() => _randomBytes(32);

  /// "a1b2-c3d4-…" — 64 hex characters in groups of four.
  static String formatRecoveryKey(List<int> key) {
    final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return [
      for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4)
    ].join('-');
  }

  /// Read a typed / pasted recovery key (spaces, dashes, case ignored).
  static List<int>? parseRecoveryKey(String text) {
    final hex = text.toLowerCase().replaceAll(RegExp(r'[^0-9a-f]'), '');
    if (hex.length != 64) return null;
    return [
      for (var i = 0; i < 64; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)
    ];
  }

  Future<SecretKey> _cloudKey(List<int> recovery) => Hkdf(
          hmac: Hmac.sha256(), outputLength: 32)
      .deriveKey(secretKey: SecretKey(recovery), info: _cloudInfo, nonce: const []);

  /// Lock [plain] for the server: "ACB1" ‖ nonce(12) ‖ ciphertext ‖ tag(16).
  Future<List<int>> lockForCloud(List<int> plain, List<int> recovery) async {
    final nonce = _randomBytes(12);
    final box = await AesGcm.with256bits().encrypt(plain,
        secretKey: await _cloudKey(recovery), nonce: nonce, aad: _cloudMagic);
    return [..._cloudMagic, ...nonce, ...box.cipherText, ...box.mac.bytes];
  }

  /// Open a locked server backup; throws on a wrong key / damaged backup.
  Future<List<int>> openFromCloud(List<int> blob, List<int> recovery) async {
    if (blob.length < 4 + 12 + 16 ||
        String.fromCharCodes(blob.sublist(0, 4)) != 'ACB1') {
      throw Exception('Not an Aluta backup');
    }
    final nonce = blob.sublist(4, 16);
    final ct = blob.sublist(16, blob.length - 16);
    final mac = Mac(blob.sublist(blob.length - 16));
    try {
      return await AesGcm.with256bits().decrypt(
          SecretBox(ct, nonce: nonce, mac: mac),
          secretKey: await _cloudKey(recovery),
          aad: _cloudMagic);
    } catch (_) {
      throw Exception('That recovery key doesn’t open this backup');
    }
  }

  /// The recovery key this device keeps (null: server backup not set up
  /// here).
  Future<List<int>?> savedRecoveryKey() async {
    final v = await _secure.read(await _slot());
    return v == null ? null : parseRecoveryKey(v);
  }

  Future<void> _saveRecoveryKey(List<int> key) async =>
      _secure.write(await _slot(), formatRecoveryKey(key));

  Future<void> forgetRecoveryKey() async => _secure.delete(await _slot());

  Future<Map<String, String>?> _auth() async {
    final t = await getToken();
    return t == null
        ? null
        : {'Authorization': 'Bearer $t', 'Content-Type': 'application/json'};
  }

  /// {exists, size, updated_at} of the server copy, or null when unknown.
  Future<Map<String, dynamic>?> cloudInfo() async {
    final h = await _auth();
    if (h == null) return null;
    try {
      final r = await http.get(
          Uri.parse('${await AppConfig.baseUrl}/e2ee/backup/info'),
          headers: h);
      if (r.statusCode != 200) return null;
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Back up to the server now with [recovery] (or the key this device
  /// keeps), and keep that key here for next time. Throws on failure.
  Future<void> cloudBackupNow({List<int>? recovery}) async {
    final key = recovery ?? await savedRecoveryKey();
    if (key == null) throw Exception('Set up server backup first');
    final h = await _auth();
    if (h == null) throw Exception('Not signed in');
    final blob = await lockForCloud(await _payload(), key);
    final r = await http.put(
        Uri.parse('${await AppConfig.baseUrl}/e2ee/backup'),
        headers: h,
        body: jsonEncode({'blob': base64Encode(blob)}));
    if (r.statusCode == 413) throw Exception('Backup too large');
    if (r.statusCode != 200) throw Exception('Couldn’t reach the server');
    await _saveRecoveryKey(key);
  }

  /// Restore from the server copy with [recovery]. Returns items restored.
  Future<int> cloudRestore(List<int> recovery) async {
    final h = await _auth();
    if (h == null) throw Exception('Not signed in');
    final r = await http.get(
        Uri.parse('${await AppConfig.baseUrl}/e2ee/backup'), headers: h);
    if (r.statusCode == 404) throw Exception('No backup on the server');
    if (r.statusCode != 200) throw Exception('Couldn’t reach the server');
    final blob = base64Decode(
        (jsonDecode(r.body) as Map<String, dynamic>)['blob'] as String);
    final n = await _apply(await openFromCloud(blob, recovery));
    await _saveRecoveryKey(recovery); // later backups from this device
    return n;
  }

  /// Remove the server copy and this device's recovery key.
  Future<void> cloudDelete() async {
    final h = await _auth();
    if (h == null) return;
    await http.delete(Uri.parse('${await AppConfig.baseUrl}/e2ee/backup'),
        headers: h);
    await forgetRecoveryKey();
  }

  /// One chat's cached messages: this phone's copy wins, the backup fills
  /// in the rest (newest first, as the chat keeps them).
  static String _mergeChat(String? here, String backup) {
    if (here == null || here.isEmpty) return backup;
    try {
      final mine = (jsonDecode(here) as List).cast<Map<String, dynamic>>();
      final theirs = (jsonDecode(backup) as List).cast<Map<String, dynamic>>();
      final ids = {for (final m in mine) '${m['id']}'};
      final all = [
        ...mine,
        for (final m in theirs)
          if (!ids.contains('${m['id']}')) m
      ];
      int idOf(Map<String, dynamic> m) =>
          m['id'] is int ? m['id'] as int : int.tryParse('${m['id']}') ?? 0;
      all.sort((a, b) => idOf(b).compareTo(idOf(a)));
      return jsonEncode(all.length > 3000 ? all.take(3000).toList() : all);
    } catch (_) {
      return here; // never trade a working chat for a broken merge
    }
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
