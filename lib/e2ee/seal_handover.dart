import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../screens/token_helper.dart';
import '../utils/app_config.dart';
import '../utils/net.dart' as http;
import 'seal_directory.dart';
import 'seal_keystore.dart';
import 'seal_messenger.dart';
import 'seal_primitives.dart';
import 'seal_space.dart';

/// 🔒 History hand-over when a computer is linked by QR.
///
/// A newly linked computer can't open sealed messages sent before it
/// existed. The computer makes a one-time key for the link (its fingerprint
/// rides in the QR code); the phone that scans it checks the key, seals the
/// texts it has unlocked to it and uploads them once; the computer collects
/// and opens them locally. The server only ever holds the sealed package.
/// See my_aluta_api/e2ee_handover.py.
class SealHandover {
  SealHandover._();
  static final SealHandover instance = SealHandover._();

  /// Bumps when a package arrived (lists can refresh their previews).
  final ValueNotifier<int> arrived = ValueNotifier<int>(0);

  /// Largest package body before sealing (base64 then stays under the
  /// server's 24 MB).
  static const int maxPlainBytes = 17 * 1024 * 1024;

  /// Each chat's [keep] newest texts ({peer: {id: [rev, text]}}).
  static Map<String, dynamic> newestOnly(Map<String, dynamic> plain, int keep) {
    final out = <String, dynamic>{};
    for (final e in plain.entries) {
      final rows = e.value;
      if (rows is! Map) continue;
      final ids = rows.keys.map((k) => int.tryParse('$k') ?? 0).toList()
        ..sort();
      out[e.key] = {
        for (final id in ids.skip(ids.length > keep ? ids.length - keep : 0))
          '$id': rows['$id'],
      };
    }
    return out;
  }

  /// Computer: how long to wait for the phone's package.
  static const Duration waitFor = Duration(minutes: 4);

  /// The fingerprint a link code carries after '~' (null: none — an older
  /// computer, or a typed pair code).
  static String? fingerprintOf(String code) {
    final i = code.lastIndexOf('~');
    return i < 0 || i == code.length - 1 ? null : code.substring(i + 1);
  }

  // ── Phone ────────────────────────────────────────────────────────────────

  /// Seal this phone's unlocked texts for the computer that showed [code]
  /// and upload them. [computerPub] (base64) came back from the server and
  /// must match the fingerprint inside the scanned code — otherwise nothing
  /// is sent. Returns true when the package went up.
  Future<bool> send({required String code, required String computerPub}) async {
    final token = await getToken();
    if (token == null) return false;
    final base = await AppConfig.baseUrl;
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
    Future<void> release() async {
      try {
        await http.post(Uri.parse('$base/e2ee/handover'),
            headers: headers, body: jsonEncode({'code': code, 'package': null}));
      } catch (_) {}
    }

    try {
      final pub = base64Decode(computerPub);
      final want = fingerprintOf(code);
      if (pub.length != 32 ||
          want == null ||
          await sealFingerprint(pub) != want) {
        await release(); // not the key on that screen: send nothing
        return false;
      }
      final plain = await SealMessenger.instance.exportPlain();
      // …and the Our Space keys this phone holds.
      final scopes = await SealSpace.instance.exportKeys();
      if (plain.isEmpty && scopes.isEmpty) {
        await release();
        return false;
      }
      // The server takes a package up to ~24 MB (base64). A very chatty
      // phone sends each chat's newest texts, as many as fit, rather than
      // nothing at all.
      var body = utf8.encode(
          jsonEncode({'v': 1, 'plain': plain, 'scopes': scopes}));
      for (final keep in const [1000, 300, 100, 30]) {
        if (body.length <= maxPlainBytes) break;
        body = utf8.encode(jsonEncode(
            {'v': 1, 'plain': newestOnly(plain, keep), 'scopes': scopes}));
      }
      final pkg = await sealHandover(pub, body);
      final r = await http.post(Uri.parse('$base/e2ee/handover'),
          headers: headers,
          body: jsonEncode({'code': code, 'package': base64Encode(pkg)}));
      if (r.statusCode == 200) return true;
      await release(); // refused (e.g. too large): don't keep it waiting
      return false;
    } catch (e) {
      debugPrint('Seal hand-over send: $e');
      await release();
      return false;
    }
  }

  // ── Computer ─────────────────────────────────────────────────────────────

  /// A fresh one-time key for a link screen.
  Future<XKeys> newLinkKey() => XKeys.generate();

  /// After signing in by QR: collect and open the phone's package (polls
  /// for up to [waitFor]). Returns how many texts arrived (0 = none).
  Future<int> receive(String code, XKeys linkKey) async {
    if (fingerprintOf(code) == null) return 0;
    final until = DateTime.now().add(waitFor);
    while (DateTime.now().isBefore(until)) {
      try {
        final token = await getToken();
        if (token == null) return 0;
        final base = await AppConfig.baseUrl;
        final r = await http
            .get(
                Uri.parse('$base/e2ee/handover')
                    .replace(queryParameters: {'code': code}),
                headers: {'Authorization': 'Bearer $token'})
            .timeout(const Duration(seconds: 30));
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body) as Map<String, dynamic>;
          final status = j['status'];
          if (status == 'none') return 0;
          if (status == 'ready') {
            // Texts are filed under this computer's own keys: make sure they
            // exist before taking the package in (sign-in may still be
            // setting them up).
            final owner = SealDirectory.ownerOf(token);
            if (owner == null) return 0;
            await SealKeyStore.instance.ensure(owner);
            final clear = await openHandover(
                linkKey, base64Decode(j['package'] as String));
            final body = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
            final n = await SealMessenger.instance
                .importPlain((body['plain'] as Map).cast<String, dynamic>());
            final scopes = body['scopes'];
            if (scopes is Map) {
              await SealSpace.instance
                  .importKeys(scopes.cast<String, dynamic>());
            }
            arrived.value++;
            return n;
          }
        }
      } catch (e) {
        debugPrint('Seal hand-over receive: $e');
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    return 0;
  }
}
