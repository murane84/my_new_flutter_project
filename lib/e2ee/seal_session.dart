import 'dart:convert';
import 'dart:typed_data';

import 'seal_primitives.dart';
import 'seal_ratchet.dart';
import 'seal_x3dh.dart';

/// Wire format of one encrypted message to one device (base64 in the API):
///
///   version (1) ‖ type (1)
///   [type 2 only] ikSig (32) ‖ ikDh (32) ‖ ikDhSig (64) ‖ ek (32) ‖
///                 spkId (u32 BE) ‖ opkId (u32 BE, 0xFFFFFFFF = none)
///   header (40) ‖ ciphertext ‖ tag (16)
class SealEnvelope {
  SealEnvelope(this.message, {this.preKey});
  static const int typeMessage = 1;
  static const int typePreKey = 2;
  static const int _noOpk = 0xFFFFFFFF;
  static const int _preKeyLength = 32 + 32 + 64 + 32 + 4 + 4;

  final SealMessage message;

  /// Present until the other side has answered (so a lost first message
  /// can't strand the session).
  final PreKeyInfo? preKey;

  bool get isPreKey => preKey != null;

  Uint8List encode() {
    final p = preKey;
    final b = BytesBuilder(copy: false)
      ..addByte(SealSpec.version)
      ..addByte(p == null ? typeMessage : typePreKey);
    if (p != null) {
      final ids = ByteData(8)
        ..setUint32(0, p.spkId)
        ..setUint32(4, p.opkId ?? _noOpk);
      b
        ..add(p.ikSig)
        ..add(p.ikDh)
        ..add(p.ikDhSig)
        ..add(p.ek)
        ..add(ids.buffer.asUint8List());
    }
    b
      ..add(message.header)
      ..add(message.body);
    return b.toBytes();
  }

  String toBase64() => base64Encode(encode());

  static SealEnvelope decode(List<int> raw) {
    final d = Uint8List.fromList(raw);
    if (d.length < 2 || d[0] != SealSpec.version) throw SealError('version');
    var at = 2;
    PreKeyInfo? pre;
    if (d[1] == typePreKey) {
      if (d.length < at + _preKeyLength) throw SealError('short envelope');
      Uint8List take(int n) {
        final v = d.sublist(at, at + n);
        at += n;
        return v;
      }

      final ikSig = take(32);
      final ikDh = take(32);
      final ikDhSig = take(64);
      final ek = take(32);
      final ids = ByteData.sublistView(take(8));
      final opk = ids.getUint32(4);
      pre = PreKeyInfo(
          ikSig: ikSig,
          ikDh: ikDh,
          ikDhSig: ikDhSig,
          ek: ek,
          spkId: ids.getUint32(0),
          opkId: opk == _noOpk ? null : opk);
    } else if (d[1] != typeMessage) {
      throw SealError('type');
    }
    if (d.length < at + SealSpec.headerLength + 16) {
      throw SealError('short envelope');
    }
    return SealEnvelope(
        SealMessage(d.sublist(at, at + SealSpec.headerLength),
            d.sublist(at + SealSpec.headerLength)),
        preKey: pre);
  }

  static SealEnvelope fromBase64(String s) {
    try {
      return decode(base64Decode(s));
    } on FormatException {
      throw SealError('not base64');
    }
  }
}

/// A 1:1 session between this device and one device of a friend.
class SealSession {
  SealSession._(this.ratchet, this._pending, this.theirIdentity, this.sid);

  final SealRatchet ratchet;

  /// Tells two sessions with the same device apart (both sides may start
  /// one at the same moment; the store keeps the last few).
  final String sid;
  PreKeyInfo? _pending;

  /// The friend device's Ed25519 identity key (for the safety number and to
  /// notice a key change).
  final Uint8List theirIdentity;

  /// Alice: start from Bob's bundle. Messages carry the X3DH facts until
  /// Bob answers.
  static Future<SealSession> start(SealIdentity me, PreKeyBundle bundle,
      {List<int>? ephemeralSeed, SealKeySource? keys}) async {
    final x = await x3dhInitiate(me, bundle, ephemeralSeed: ephemeralSeed);
    final r =
        await SealRatchet.initiator(x.sk, x.ad, bundle.spk, keys: keys);
    return SealSession._(r, x.info, bundle.ikSig, _newSid());
  }

  /// Bob: build the session from Alice's first message and open it.
  /// The caller deletes the used one-time prekey afterwards.
  static Future<(SealSession, Uint8List)> accept(
      SealIdentity me,
      SealEnvelope first,
      SignedPreKey spk,
      OneTimePreKey? opk,
      {SealKeySource? keys}) async {
    final info = first.preKey;
    if (info == null) throw SealError('not a first message');
    final x = await x3dhRespond(me, info, spk, opk);
    final r = SealRatchet.responder(x.sk, x.ad, spk.keys, keys: keys);
    final s = SealSession._(r, null, info.ikSig, _newSid());
    final clear = await r.decrypt(first.message.header, first.message.body);
    return (s, clear);
  }

  Future<SealEnvelope> encrypt(List<int> plain) async =>
      SealEnvelope(await ratchet.encrypt(plain), preKey: _pending);

  Future<Uint8List> decrypt(SealEnvelope env) async {
    final pre = env.preKey;
    if (pre != null && !sealBytesEqual(pre.ikSig, theirIdentity)) {
      throw SealError('identity changed');
    }
    final out = await ratchet.decrypt(env.message.header, env.message.body);
    _pending = null;
    return out;
  }

  static String _newSid() => base64Encode(sealRandomBytes(9));

  Map<String, dynamic> toJson() => {
        'r': ratchet.toJson(),
        'pre': _pending?.toJson(),
        'id': base64Encode(theirIdentity),
        'sid': sid,
      };

  static SealSession fromJson(Map<String, dynamic> j, {SealKeySource? keys}) =>
      SealSession._(
          SealRatchet.fromJson(j['r'] as Map<String, dynamic>, keys: keys),
          j['pre'] == null
              ? null
              : PreKeyInfo.fromJson(j['pre'] as Map<String, dynamic>),
          base64Decode(j['id'] as String),
          j['sid'] as String? ?? 'first');
}
