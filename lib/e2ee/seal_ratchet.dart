import 'dart:convert';
import 'dart:typed_data';

import 'seal_primitives.dart';

/// Where new ratchet key pairs come from (random in the app, fixed seeds in
/// the test vectors).
typedef SealKeySource = Future<XKeys> Function();

Future<XKeys> _randomKeys() => XKeys.generate();

/// One encrypted message: the clear header and the sealed body.
class SealMessage {
  SealMessage(this.header, this.body);
  final Uint8List header;
  final Uint8List body;
}

Uint8List _header(List<int> dh, int pn, int n) {
  final h = Uint8List(SealSpec.headerLength)..setRange(0, 32, dh);
  ByteData.sublistView(h)
    ..setUint32(32, pn)
    ..setUint32(36, n);
  return h;
}

/// The Double Ratchet (Signal spec rev. 1, with Aluta Seal constants):
/// a fresh key for every message, forward secrecy, and self-healing after a
/// key leak once both sides have sent again.
class SealRatchet {
  SealRatchet._(this.ad, this._dhs, this._dhr, this._rk, this._cks, this._ckr,
      this._ns, this._nr, this._pn, this._skipped, this._keys);

  /// Associated data bound into every message: initiator identity ‖
  /// responder identity.
  final Uint8List ad;
  XKeys _dhs;
  Uint8List? _dhr;
  Uint8List _rk;
  Uint8List? _cks;
  Uint8List? _ckr;
  int _ns;
  int _nr;
  int _pn;
  final Map<String, Uint8List> _skipped;
  final SealKeySource _keys;

  /// The side that ran X3DH first; can send straight away.
  static Future<SealRatchet> initiator(
      Uint8List sk, Uint8List ad, Uint8List theirSpk,
      {SealKeySource? keys}) async {
    final src = keys ?? _randomKeys;
    final dhs = await src();
    final r = SealRatchet._(ad, dhs, theirSpk, sk, null, null, 0, 0, 0,
        <String, Uint8List>{}, src);
    final o = await _kdfRk(sk, await dhs.dh(theirSpk));
    r._rk = o.$1;
    r._cks = o.$2;
    return r;
  }

  /// The side that received the first message; sends after its first
  /// successful [decrypt].
  static SealRatchet responder(Uint8List sk, Uint8List ad, XKeys ourSpk,
          {SealKeySource? keys}) =>
      SealRatchet._(ad, ourSpk, null, sk, null, null, 0, 0, 0,
          <String, Uint8List>{}, keys ?? _randomKeys);

  bool get canSend => _cks != null;

  static Future<(Uint8List, Uint8List)> _kdfRk(
      List<int> rk, List<int> dhOut) async {
    final o = await sealHkdf(rk, dhOut, SealSpec.infoRatchet, 64);
    return (o.sublist(0, 32), o.sublist(32, 64));
  }

  /// (next chain key, message key)
  static Future<(Uint8List, Uint8List)> _kdfCk(List<int> ck) async =>
      (await sealHmac(ck, const [2]), await sealHmac(ck, const [1]));

  Future<SealMessage> encrypt(List<int> plain) async {
    final ck = _cks;
    if (ck == null) throw SealError('no sending chain yet');
    final o = await _kdfCk(ck);
    _cks = o.$1;
    final h = _header(_dhs.public, _pn, _ns);
    _ns++;
    return SealMessage(h, await sealAead(o.$2, plain, sealConcat([ad, h])));
  }

  /// Opens a message. The state only changes when the message really opens,
  /// so a forged or broken message can't knock the session out of step.
  Future<Uint8List> decrypt(Uint8List header, Uint8List body) async {
    if (header.length != SealSpec.headerLength) throw SealError('header');
    final s = _copy();
    final out = await s._decrypt(header, body);
    _dhs = s._dhs;
    _dhr = s._dhr;
    _rk = s._rk;
    _cks = s._cks;
    _ckr = s._ckr;
    _ns = s._ns;
    _nr = s._nr;
    _pn = s._pn;
    _skipped
      ..clear()
      ..addAll(s._skipped);
    return out;
  }

  Future<Uint8List> _decrypt(Uint8List h, Uint8List body) async {
    final dh = h.sublist(0, 32);
    final bd = ByteData.sublistView(h);
    final pn = bd.getUint32(32);
    final n = bd.getUint32(36);
    final aad = sealConcat([ad, h]);
    final skippedKey = _skipKey(dh, n);
    final mk0 = _skipped.remove(skippedKey);
    if (mk0 != null) return openAead(mk0, body, aad);
    if (!sealBytesEqual(dh, _dhr)) {
      await _skip(pn);
      _pn = _ns;
      _ns = 0;
      _nr = 0;
      _dhr = dh;
      final a = await _kdfRk(_rk, await _dhs.dh(dh));
      _rk = a.$1;
      _ckr = a.$2;
      _dhs = await _keys();
      final b = await _kdfRk(_rk, await _dhs.dh(dh));
      _rk = b.$1;
      _cks = b.$2;
    }
    await _skip(n);
    final o = await _kdfCk(_ckr!);
    _ckr = o.$1;
    _nr++;
    return openAead(o.$2, body, aad);
  }

  Future<void> _skip(int until) async {
    final ck0 = _ckr;
    if (ck0 == null) return;
    if (until - _nr > SealSpec.maxSkip) throw SealError('too many skipped');
    var ck = ck0;
    while (_nr < until) {
      final o = await _kdfCk(ck);
      ck = o.$1;
      _skipped[_skipKey(_dhr!, _nr)] = o.$2;
      _nr++;
    }
    _ckr = ck;
    while (_skipped.length > SealSpec.maxSkippedTotal) {
      _skipped.remove(_skipped.keys.first);
    }
  }

  static String _skipKey(List<int> dh, int n) => '${base64Encode(dh)}|$n';

  SealRatchet _copy() => SealRatchet._(ad, _dhs, _dhr, _rk, _cks, _ckr, _ns,
      _nr, _pn, Map<String, Uint8List>.of(_skipped), _keys);

  static String? _b(Uint8List? v) => v == null ? null : base64Encode(v);
  static Uint8List? _u(Object? v) => v == null ? null : base64Decode(v as String);

  Map<String, dynamic> toJson() => {
        'v': SealSpec.version,
        'ad': base64Encode(ad),
        'dhs': _dhs.toJson(),
        'dhr': _b(_dhr),
        'rk': base64Encode(_rk),
        'cks': _b(_cks),
        'ckr': _b(_ckr),
        'ns': _ns,
        'nr': _nr,
        'pn': _pn,
        'skipped': {
          for (final e in _skipped.entries) e.key: base64Encode(e.value)
        },
      };

  static SealRatchet fromJson(Map<String, dynamic> j, {SealKeySource? keys}) =>
      SealRatchet._(
        base64Decode(j['ad'] as String),
        XKeys.fromJson(j['dhs'] as Map<String, dynamic>),
        _u(j['dhr']),
        base64Decode(j['rk'] as String),
        _u(j['cks']),
        _u(j['ckr']),
        j['ns'] as int,
        j['nr'] as int,
        j['pn'] as int,
        {
          for (final e in (j['skipped'] as Map<String, dynamic>).entries)
            e.key: base64Decode(e.value as String)
        },
        keys ?? _randomKeys,
      );
}
