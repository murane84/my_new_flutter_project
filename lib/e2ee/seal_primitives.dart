import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Aluta Seal v1 — Aluta's own end-to-end encryption, built on Signal's
/// published design (X3DH + Double Ratchet) with vetted primitives from the
/// `cryptography` package (X25519, Ed25519, HKDF-SHA256, HMAC-SHA256,
/// AES-256-GCM). The byte-exact spec and the Python reference that produced
/// the test vectors live in `tool/e2ee/aluta_seal_ref.py`; any change here
/// must keep `test/e2ee_test.dart` green.
class SealSpec {
  static const int version = 1;
  static final List<int> infoX3dh = ascii.encode('AlutaSeal X3DH v1');
  static final List<int> infoRatchet = ascii.encode('AlutaSeal Ratchet v1');
  static final List<int> infoMessage = ascii.encode('AlutaSeal Message v1');
  static final List<int> spkSigPrefix = ascii.encode('AlutaSeal SPK v1');
  static final List<int> ikDhSigPrefix = ascii.encode('AlutaSeal IKDH v1');

  /// Header = ratchet public key (32) ‖ previous chain length (u32 BE) ‖
  /// message number (u32 BE).
  static const int headerLength = 40;

  /// Most message keys kept for one chain gap / in total (late or
  /// out-of-order messages).
  static const int maxSkip = 1000;
  static const int maxSkippedTotal = 2000;
}

/// Anything that makes a message unreadable: a wrong key, a tampered byte,
/// a forged signature, a malformed envelope. Callers show "Couldn't unlock
/// this message" and never the reason.
class SealError implements Exception {
  SealError(this.message);
  final String message;
  @override
  String toString() => 'SealError: $message';
}

final X25519 _x25519 = X25519();
final Ed25519 _ed25519 = Ed25519();
final Hmac _hmac = Hmac.sha256();
final AesGcm _aes = AesGcm.with256bits();
final Random _rng = Random.secure();

Uint8List sealRandomBytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (_) => _rng.nextInt(256)));

Uint8List sealZeros(int n) => Uint8List(n);

Uint8List sealConcat(List<List<int>> parts) {
  final b = BytesBuilder(copy: false);
  for (final p in parts) {
    b.add(p);
  }
  return b.toBytes();
}

bool sealBytesEqual(List<int>? a, List<int>? b) {
  if (a == null || b == null || a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

Future<Uint8List> sealHkdf(
    List<int> salt, List<int> ikm, List<int> info, int length) async {
  final k = await Hkdf(hmac: Hmac.sha256(), outputLength: length)
      .deriveKey(secretKey: SecretKey(ikm), nonce: salt, info: info);
  return Uint8List.fromList(await k.extractBytes());
}

Future<Uint8List> sealHmac(List<int> key, List<int> data) async {
  final m = await _hmac.calculateMac(data, secretKey: SecretKey(key));
  return Uint8List.fromList(m.bytes);
}

/// An X25519 key pair kept as raw bytes (easy to store, no re-derivation).
class XKeys {
  XKeys(this.private, this.public);
  final Uint8List private;
  final Uint8List public;

  /// A fresh key pair, or a fixed one from [seed] (tests only).
  static Future<XKeys> generate([List<int>? seed]) async {
    final kp = await _x25519.newKeyPairFromSeed(seed ?? sealRandomBytes(32));
    final priv = await kp.extractPrivateKeyBytes();
    final pub = await kp.extractPublicKey();
    return XKeys(Uint8List.fromList(priv), Uint8List.fromList(pub.bytes));
  }

  SimpleKeyPairData get _pair => SimpleKeyPairData(private,
      publicKey: SimplePublicKey(public, type: KeyPairType.x25519),
      type: KeyPairType.x25519);

  /// X25519(this, [theirPublic]). Rejects all-zero output (a low-order
  /// public key), as RFC 7748 §6.1 recommends.
  Future<Uint8List> dh(List<int> theirPublic) async {
    if (theirPublic.length != 32) throw SealError('bad public key');
    final Uint8List out;
    try {
      final s = await _x25519.sharedSecretKey(
          keyPair: _pair,
          remotePublicKey:
              SimplePublicKey(theirPublic, type: KeyPairType.x25519));
      out = Uint8List.fromList(await s.extractBytes());
    } catch (_) {
      throw SealError('bad public key');
    }
    if (out.every((b) => b == 0)) throw SealError('bad public key');
    return out;
  }

  Map<String, dynamic> toJson() =>
      {'k': base64Encode(private), 'p': base64Encode(public)};
  static XKeys fromJson(Map<String, dynamic> j) => XKeys(
      base64Decode(j['k'] as String), base64Decode(j['p'] as String));
}

/// An Ed25519 signing key pair (32-byte seed + public key).
class EdKeys {
  EdKeys(this.seed, this.public);
  final Uint8List seed;
  final Uint8List public;

  static Future<EdKeys> generate([List<int>? seed]) async {
    final s = Uint8List.fromList(seed ?? sealRandomBytes(32));
    final kp = await _ed25519.newKeyPairFromSeed(Uint8List.fromList(s));
    final pub = await kp.extractPublicKey();
    return EdKeys(s, Uint8List.fromList(pub.bytes));
  }

  Future<Uint8List> sign(List<int> message) async {
    final kp = SimpleKeyPairData(seed,
        publicKey: SimplePublicKey(public, type: KeyPairType.ed25519),
        type: KeyPairType.ed25519);
    final sig = await _ed25519.sign(message, keyPair: kp);
    return Uint8List.fromList(sig.bytes);
  }

  Map<String, dynamic> toJson() =>
      {'k': base64Encode(seed), 'p': base64Encode(public)};
  static EdKeys fromJson(Map<String, dynamic> j) => EdKeys(
      base64Decode(j['k'] as String), base64Decode(j['p'] as String));
}

Future<bool> sealVerify(
    List<int> publicKey, List<int> message, List<int> signature) async {
  if (publicKey.length != 32 || signature.length != 64) return false;
  try {
    return await _ed25519.verify(message,
        signature: Signature(signature,
            publicKey:
                SimplePublicKey(publicKey, type: KeyPairType.ed25519)));
  } catch (_) {
    return false;
  }
}

/// Message key → AES-256-GCM key + nonce, then seal/open with [aad].
/// Output is ciphertext ‖ 16-byte tag.
Future<Uint8List> sealAead(List<int> mk, List<int> plain, List<int> aad) async {
  final km = await sealHkdf(sealZeros(32), mk, SealSpec.infoMessage, 44);
  final box = await _aes.encrypt(plain,
      secretKey: SecretKey(km.sublist(0, 32)),
      nonce: km.sublist(32, 44),
      aad: aad);
  return sealConcat([box.cipherText, box.mac.bytes]);
}

Future<Uint8List> openAead(List<int> mk, List<int> sealed, List<int> aad) async {
  if (sealed.length < 16) throw SealError('short message');
  final km = await sealHkdf(sealZeros(32), mk, SealSpec.infoMessage, 44);
  try {
    final clear = await _aes.decrypt(
        SecretBox(sealed.sublist(0, sealed.length - 16),
            nonce: km.sublist(32, 44),
            mac: Mac(sealed.sublist(sealed.length - 16))),
        secretKey: SecretKey(km.sublist(0, 32)),
        aad: aad);
    return Uint8List.fromList(clear);
  } catch (_) {
    throw SealError('message could not be unlocked');
  }
}
