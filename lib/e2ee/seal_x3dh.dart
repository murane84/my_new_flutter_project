import 'dart:convert';
import 'dart:typed_data';

import 'seal_primitives.dart';

/// One device's long-term identity: an Ed25519 key (the trust anchor shown
/// as the safety number) and an X25519 key for X3DH, whose public part is
/// signed by the Ed25519 key so the pair can't be split.
class SealIdentity {
  SealIdentity(this.sig, this.dh, this.dhSig);
  final EdKeys sig;
  final XKeys dh;
  final Uint8List dhSig;

  static Future<SealIdentity> generate(
      {List<int>? sigSeed, List<int>? dhSeed}) async {
    final sig = await EdKeys.generate(sigSeed);
    final dh = await XKeys.generate(dhSeed);
    final dhSig =
        await sig.sign(sealConcat([SealSpec.ikDhSigPrefix, dh.public]));
    return SealIdentity(sig, dh, dhSig);
  }

  Map<String, dynamic> toJson() =>
      {'sig': sig.toJson(), 'dh': dh.toJson(), 'dhSig': base64Encode(dhSig)};
  static SealIdentity fromJson(Map<String, dynamic> j) => SealIdentity(
      EdKeys.fromJson(j['sig'] as Map<String, dynamic>),
      XKeys.fromJson(j['dh'] as Map<String, dynamic>),
      base64Decode(j['dhSig'] as String));
}

/// A medium-term prekey, rotated about weekly; its public part is signed
/// by the identity key.
class SignedPreKey {
  SignedPreKey(this.id, this.keys, this.sig, this.createdAt);
  final int id;
  final XKeys keys;
  final Uint8List sig;
  final DateTime createdAt;

  static Future<SignedPreKey> generate(SealIdentity me, int id,
      {List<int>? seed, DateTime? now}) async {
    final keys = await XKeys.generate(seed);
    final sig =
        await me.sig.sign(sealConcat([SealSpec.spkSigPrefix, keys.public]));
    return SignedPreKey(id, keys, sig, now ?? DateTime.now());
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'keys': keys.toJson(),
        'sig': base64Encode(sig),
        'at': createdAt.millisecondsSinceEpoch,
      };
  static SignedPreKey fromJson(Map<String, dynamic> j) => SignedPreKey(
      j['id'] as int,
      XKeys.fromJson(j['keys'] as Map<String, dynamic>),
      base64Decode(j['sig'] as String),
      DateTime.fromMillisecondsSinceEpoch(j['at'] as int));
}

/// A single-use prekey; the server hands each one out once.
class OneTimePreKey {
  OneTimePreKey(this.id, this.keys);
  final int id;
  final XKeys keys;

  static Future<OneTimePreKey> generate(int id, {List<int>? seed}) async =>
      OneTimePreKey(id, await XKeys.generate(seed));

  Map<String, dynamic> toJson() => {'id': id, 'keys': keys.toJson()};
  static OneTimePreKey fromJson(Map<String, dynamic> j) => OneTimePreKey(
      j['id'] as int, XKeys.fromJson(j['keys'] as Map<String, dynamic>));
}

/// What the server returns for one of the other person's devices.
class PreKeyBundle {
  PreKeyBundle({
    required this.ikSig,
    required this.ikDh,
    required this.ikDhSig,
    required this.spkId,
    required this.spk,
    required this.spkSig,
    this.opkId,
    this.opk,
  });
  final Uint8List ikSig;
  final Uint8List ikDh;
  final Uint8List ikDhSig;
  final int spkId;
  final Uint8List spk;
  final Uint8List spkSig;
  final int? opkId;
  final Uint8List? opk;

  static PreKeyBundle fromJson(Map<String, dynamic> j) => PreKeyBundle(
        ikSig: base64Decode(j['ik_sig'] as String),
        ikDh: base64Decode(j['ik_dh'] as String),
        ikDhSig: base64Decode(j['ik_dh_sig'] as String),
        spkId: j['spk_id'] as int,
        spk: base64Decode(j['spk'] as String),
        spkSig: base64Decode(j['spk_sig'] as String),
        opkId: j['opk_id'] as int?,
        opk: j['opk'] == null ? null : base64Decode(j['opk'] as String),
      );
}

/// The X3DH facts the first message carries so the other side can build
/// the same session.
class PreKeyInfo {
  PreKeyInfo({
    required this.ikSig,
    required this.ikDh,
    required this.ikDhSig,
    required this.ek,
    required this.spkId,
    this.opkId,
  });
  final Uint8List ikSig;
  final Uint8List ikDh;
  final Uint8List ikDhSig;
  final Uint8List ek;
  final int spkId;
  final int? opkId;

  Map<String, dynamic> toJson() => {
        'ikSig': base64Encode(ikSig),
        'ikDh': base64Encode(ikDh),
        'ikDhSig': base64Encode(ikDhSig),
        'ek': base64Encode(ek),
        'spk': spkId,
        'opk': opkId,
      };
  static PreKeyInfo fromJson(Map<String, dynamic> j) => PreKeyInfo(
        ikSig: base64Decode(j['ikSig'] as String),
        ikDh: base64Decode(j['ikDh'] as String),
        ikDhSig: base64Decode(j['ikDhSig'] as String),
        ek: base64Decode(j['ek'] as String),
        spkId: j['spk'] as int,
        opkId: j['opk'] as int?,
      );
}

/// Result of X3DH: the shared secret, the associated data (initiator's
/// identity ‖ responder's identity), and the facts to send along.
class X3dhResult {
  X3dhResult(this.sk, this.ad, this.info);
  final Uint8List sk;
  final Uint8List ad;
  final PreKeyInfo info;
}

Future<Uint8List> _deriveSk(List<Uint8List> dhs) => sealHkdf(sealZeros(32),
    sealConcat([List<int>.filled(32, 0xff), ...dhs]), SealSpec.infoX3dh, 32);

/// Alice's side: check Bob's signatures, then derive the session secret.
/// [ephemeralSeed] is for test vectors only.
Future<X3dhResult> x3dhInitiate(SealIdentity me, PreKeyBundle bob,
    {List<int>? ephemeralSeed}) async {
  if (!await sealVerify(bob.ikSig,
      sealConcat([SealSpec.ikDhSigPrefix, bob.ikDh]), bob.ikDhSig)) {
    throw SealError('identity key signature');
  }
  if (!await sealVerify(
      bob.ikSig, sealConcat([SealSpec.spkSigPrefix, bob.spk]), bob.spkSig)) {
    throw SealError('signed prekey signature');
  }
  final ek = await XKeys.generate(ephemeralSeed);
  final dhs = <Uint8List>[
    await me.dh.dh(bob.spk),
    await ek.dh(bob.ikDh),
    await ek.dh(bob.spk),
    if (bob.opk != null) await ek.dh(bob.opk!),
  ];
  return X3dhResult(
      await _deriveSk(dhs),
      sealConcat([me.sig.public, bob.ikSig]),
      PreKeyInfo(
        ikSig: me.sig.public,
        ikDh: me.dh.public,
        ikDhSig: me.dhSig,
        ek: ek.public,
        spkId: bob.spkId,
        opkId: bob.opk != null ? bob.opkId : null,
      ));
}

/// Bob's side, from the first message's [info] and his own private keys
/// (the caller looks up [spk] / [opk] by the ids in [info] and deletes the
/// one-time prekey after a successful decrypt).
Future<X3dhResult> x3dhRespond(SealIdentity me, PreKeyInfo info,
    SignedPreKey spk, OneTimePreKey? opk) async {
  if (!await sealVerify(info.ikSig,
      sealConcat([SealSpec.ikDhSigPrefix, info.ikDh]), info.ikDhSig)) {
    throw SealError('identity key signature');
  }
  if (spk.id != info.spkId) throw SealError('signed prekey');
  if (info.opkId != null && opk?.id != info.opkId) {
    throw SealError('one-time prekey');
  }
  final dhs = <Uint8List>[
    await spk.keys.dh(info.ikDh),
    await me.dh.dh(info.ek),
    await spk.keys.dh(info.ek),
    if (info.opkId != null) await opk!.keys.dh(info.ek),
  ];
  return X3dhResult(
      await _deriveSk(dhs), sealConcat([info.ikSig, me.sig.public]), info);
}
