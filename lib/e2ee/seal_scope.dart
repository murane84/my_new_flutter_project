import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'seal_primitives.dart';
import 'seal_x3dh.dart';

/// 🔒 Our Space sealing (end-to-end encryption, Phase 6).
///
/// Everything a group of people share in Our Space — moments, comments,
/// diary entries and letters, answers, dedication notes, capsules, playlist
/// memos — is sealed with ONE key for that group: the **scope** is the sorted
/// user ids of its members ("3,7" for a couple). The key lives only on their
/// devices; the server keeps one copy of it per device, each wrapped to that
/// device's identity and signed by the device that wrapped it.
///
/// A sealed text field is a plain string the server stores as-is:
///   `🔒s1.{scope}.{epoch}.{base64url(nonce ‖ AES-256-GCM ‖ tag)}`
/// with aad `AlutaSpace v1|{scope}|{epoch}`, so it names its own key and
/// can't be moved to another group.
class SealScope {
  SealScope._();

  static const String prefix = '🔒s1.';
  static final List<int> _wrapLabel = ascii.encode('AlutaSeal ScopeKey v1');
  static const int typeScopeKey = 5;

  /// The scope of a group of people (order and repeats don't matter).
  static String of(Iterable<int> userIds) =>
      (userIds.toSet().toList()..sort()).join(',');

  /// Its members, or null when [scope] isn't one.
  static List<int>? membersOf(String scope) {
    final parts = scope.split(',');
    final ids = <int>[];
    for (final p in parts) {
      final v = int.tryParse(p);
      if (v == null || v <= 0) return null;
      ids.add(v);
    }
    return ids.length < 2 || of(ids) != scope ? null : ids;
  }

  /// A NAMED scope: a key that belongs to something rather than to a list
  /// of ids — `g:<conversation id>` (a group chat of more than 32) or
  /// `s:<user id>` (that person's Stories). The server says who belongs.
  static String group(int conversationId) => 'g:$conversationId';

  /// A member-list scope holds at most this many (bigger: a named one).
  static const int maxListMembers = 32;
  static String story(int userId) => 's:$userId';

  static bool isNamed(String scope) {
    if (scope.length < 3 || scope[1] != ':') return false;
    if (scope[0] != 'g' && scope[0] != 's') return false;
    final n = int.tryParse(scope.substring(2));
    return n != null && n > 0 && '$n' == scope.substring(2);
  }

  /// A scope this format knows: a member list, or a named one.
  static bool isScope(String scope) =>
      membersOf(scope) != null || isNamed(scope);

  static bool isSealed(Object? v) => v is String && v.startsWith(prefix);

  /// (scope, epoch) a sealed field names, or null.
  static (String, int)? keyOf(String sealed) {
    if (!sealed.startsWith(prefix)) return null;
    final parts = sealed.substring(prefix.length).split('.');
    if (parts.length != 3) return null;
    final epoch = int.tryParse(parts[1]);
    if (epoch == null || epoch <= 0 || !isScope(parts[0])) {
      return null;
    }
    return (parts[0], epoch);
  }

  static List<int> _aad(String scope, int epoch) =>
      utf8.encode('AlutaSpace v1|$scope|$epoch');

  /// Seal one text field. [nonce] is for test vectors only.
  static Future<String> seal(
      List<int> key, String scope, int epoch, String text,
      {List<int>? nonce}) async {
    final n = nonce ?? sealRandomBytes(12);
    final box = await AesGcm.with256bits().encrypt(utf8.encode(text),
        secretKey: SecretKey(key), nonce: n, aad: _aad(scope, epoch));
    final body = base64Url
        .encode(sealConcat([n, box.cipherText, box.mac.bytes]))
        .replaceAll('=', '');
    return '$prefix$scope.$epoch.$body';
  }

  /// Seal [text] the same way every time for this key (a reaction emoji):
  /// the nonce comes from the key and the text (a synthetic IV), so equal
  /// emoji give equal sealed strings — the server can match a toggle and
  /// count reactions without learning which emoji they are. Only for short
  /// values where "these two are the same" is fine to show.
  static Future<String> sealFixed(
      List<int> key, String scope, int epoch, String text) async {
    final mac = await sealHmac(
        key, utf8.encode('AlutaSpace fixed v1|$scope|$epoch|$text'));
    return seal(key, scope, epoch, text, nonce: mac.sublist(0, 12));
  }

  /// Open a sealed field with its scope key.
  static Future<String> open(List<int> key, String sealed) async {
    final k = keyOf(sealed);
    if (k == null) throw SealError('not a sealed field');
    final b64 = sealed.substring(sealed.lastIndexOf('.') + 1);
    final List<int> raw;
    try {
      raw = base64Url.decode(base64Url.normalize(b64));
    } on FormatException {
      throw SealError('bad field');
    }
    if (raw.length < 12 + 16) throw SealError('bad field');
    try {
      final clear = await AesGcm.with256bits().decrypt(
          SecretBox(raw.sublist(12, raw.length - 16),
              nonce: raw.sublist(0, 12),
              mac: Mac(raw.sublist(raw.length - 16))),
          secretKey: SecretKey(key),
          aad: _aad(k.$1, k.$2));
      return utf8.decode(clear);
    } catch (_) {
      throw SealError('field could not be unlocked');
    }
  }

  static List<int> _sigMessage(String scope, int epoch, List<int> recipIkSig,
      List<int> eph, List<int> nonce, List<int> ct) {
    final e = ByteData(4)..setUint32(0, epoch);
    return sealConcat([
      _wrapLabel,
      utf8.encode(scope),
      const [0],
      e.buffer.asUint8List(),
      recipIkSig,
      eph,
      nonce,
      ct,
    ]);
  }

  /// Wrap [scopeKey] for one device (its X25519 identity [recipIkDh] and
  /// Ed25519 identity [recipIkSig]), signed by this device ([me]).
  /// Blob: version ‖ 5 ‖ eph (32) ‖ nonce (12) ‖ ct+tag (48) ‖ sig (64).
  static Future<String> wrap({
    required SealIdentity me,
    required List<int> recipIkDh,
    required List<int> recipIkSig,
    required String scope,
    required int epoch,
    required List<int> scopeKey,
  }) async {
    final eph = await XKeys.generate();
    final k = await sealHkdf(sealZeros(32), await eph.dh(recipIkDh),
        sealConcat([_wrapLabel, recipIkDh, eph.public]), 32);
    final nonce = sealRandomBytes(12);
    final box = await AesGcm.with256bits().encrypt(scopeKey,
        secretKey: SecretKey(k),
        nonce: nonce,
        aad: utf8.encode('AlutaSeal ScopeKey v1|$scope|$epoch'));
    final ct = sealConcat([box.cipherText, box.mac.bytes]);
    final sig = await me.sig
        .sign(_sigMessage(scope, epoch, recipIkSig, eph.public, nonce, ct));
    return base64Encode(sealConcat([
      [SealSpec.version, typeScopeKey],
      eph.public,
      nonce,
      ct,
      sig,
    ]));
  }

  /// Unwrap a scope key meant for this device ([me]); [senderIkSig] is the
  /// identity of the device that wrapped it (from the key directory) — the
  /// signature must be theirs.
  static Future<Uint8List> unwrap({
    required SealIdentity me,
    required String blob,
    required List<int> senderIkSig,
    required String scope,
    required int epoch,
  }) async {
    final List<int> raw;
    try {
      raw = base64Decode(blob);
    } on FormatException {
      throw SealError('bad key copy');
    }
    if (raw.length != 2 + 32 + 12 + 48 + 64 ||
        raw[0] != SealSpec.version ||
        raw[1] != typeScopeKey) {
      throw SealError('bad key copy');
    }
    final eph = raw.sublist(2, 34);
    final nonce = raw.sublist(34, 46);
    final ct = raw.sublist(46, 94);
    final sig = raw.sublist(94);
    if (!await sealVerify(senderIkSig,
        _sigMessage(scope, epoch, me.sig.public, eph, nonce, ct), sig)) {
      throw SealError('key copy not signed by a member');
    }
    final k = await sealHkdf(sealZeros(32), await me.dh.dh(eph),
        sealConcat([_wrapLabel, me.dh.public, eph]), 32);
    try {
      final key = await AesGcm.with256bits().decrypt(
          SecretBox(ct.sublist(0, 32), nonce: nonce, mac: Mac(ct.sublist(32))),
          secretKey: SecretKey(k),
          aad: utf8.encode('AlutaSeal ScopeKey v1|$scope|$epoch'));
      return Uint8List.fromList(key);
    } catch (_) {
      throw SealError('key copy could not be unlocked');
    }
  }
}
