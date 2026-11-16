// Aluta Seal v1 — the Dart core must match the Python reference
// (tool/e2ee/aluta_seal_ref.py) byte for byte, plus the RFC vectors for the
// primitives underneath.
import 'dart:convert';
import 'dart:typed_data';

import 'package:aluta/e2ee/seal.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _h(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16)
    ]);
String _x(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

class _V {
  const _V(this.from, this.text, this.header, this.ct);
  final String from;
  final String text;
  final String header;
  final String ct;
}

const _seeds = <String, String>{
  'bob-ik-sig': '26a6e19bf009d1a7967e73b5541bf9ff1fddd91dc53c73c4a62f679adc21df34',
  'bob-ik-dh': '7cb3fd6cb52e86094373d47430f53467462c073f1cfecb0d6d7d8b0e5e07534b',
  'bob-spk': '784966ac1f8e6cc9ca2e9246c2e801b870dd28d20f9ddf0bec8600c9e9263f02',
  'bob-opk-1': 'd25b3e516ab67a124f52d1c252cbb7c3000e3b4129d6b4f10b805545824b710c',
  'alice-ik-sig': 'd0dfe54b28f00c4d6a45dd770cdb641bf7d57bf7a1c135fdfb0321fbc8208d7f',
  'alice-ik-dh': 'c79272e3a9388247c9f57ca66c26314a75f5a6202308057df16dae28bc5a27e0',
  'alice-ek': '09f93c097a255dd07e5007c5ca68237640b2a92d9ba91e66a34abafbffbca572',
  'alice-ratchet-1': 'baa7d6afdce76a8f5a03f1d72b0e840a77b5718afcde58716cf952c7961a9613',
  'bob-ratchet-1': '25b42be3ac4e6bde779823470007f3adca98e830bece5b9cb23f7d5adedc28c2',
  'alice-ratchet-2': '01e7a6350147f276cef1bb63c1dafd4a0765d41761448a3c6e95233199c650db',
  'bob-ratchet-2': '307a358e69915d592acca1bfab3fbe3a138c5cb70dabd052d16057ff724a210a',
};
const _pub = <String, String>{
  'bob_sig': '4ba84bc6d8afa13b2ba7499b85b5c7c5d3e904b23551ea7c6bba1f2086695b66',
  'bob_ikdh': '273117207ba1befb651516c89c14536d9073cda35a515de1bb8765cc644ce742',
  'bob_spk': '5db1ed082e7248349adc6f5dc575c64cbf154ed4b184fc206b0f150c1164d357',
  'bob_opk': '47af26a7cfb8a5e10ed2934d26dbace0e52775f4ea1a9445c8edd042793fdc09',
  'alice_sig': '81f3a8a7888e9bebacdc1b76b4ad3803719bf6a0e1fa8b608cc968424e0f9d88',
  'alice_ikdh': 'f2cb647da575266f1e8f7de811301206b7413ba44d38508e1e6746f6d718d27a',
  'alice_ek': '8eca87c3f8dafdcb4e7005bcabe175e8590d8822d5f8feb6613e2a2466d86855',
};
const _spkSig = '756114da1ca4068bd8e91a6403c63ab3a12903b150063c5257d18709e4a17732bdf82e229be58a4d344cf47868cf1ceec902296f11ee6fc479fb486ceca8c200';
const _ikDhSig = '3e983b27f4c09cca67f832801ab6e982e7af641882342e8767698633682b9f2173859b7ef9a221d3ef5999e230f3d4c187bb25f409ca0f8a741607422a647709';
const _sk = 'ef56b8723188d1c601d76851c5014f6a66b8783f8a88f65968bcfc1597c57613';
const _skNoOpk = '4e9ac776dffb04f086478a830c59deb50b9f6abcad603fef654f8a93e8420bed';
const _msgs = <_V>[
    _V("A", "Habari za jioni? 🎶",
        'f0ee8e2c017bc4345db9e6257b111a1437aac39dfa7668ae816bb257a2381e520000000000000000',
        '7de926e65b72ba2af61090476149ae311cc378325ef20cbf66eda822a9f65053e26b966170'),
    _V("A", "Twende tuisikilize pamoja",
        'f0ee8e2c017bc4345db9e6257b111a1437aac39dfa7668ae816bb257a2381e520000000000000001',
        'c96871cce745acd72739c1ac38a081e0ddb3412fa8070cac778db151420e780f06b933aee9d7077c13'),
    _V("B", "Ndiyo! saa mbili usiku",
        'f4382fb3e1cccfaeda49283b9dae8271488cd712fd143aa56c2064020587bc0c0000000000000000',
        '468736c081d93f9ebb0e1228403f8b1bc51306018468654379903670e445c48035265e74d105'),
    _V("A", "ya kwanza",
        '2bddcbfc524a86efb3a73e4996f7408b5b30aa1b2b95fa12c13296032c17ae1b0000000200000000',
        'fe7809eda6ba5060b8c2e501d5f5bd65d13d679e18203ec74b'),
    _V("A", "ya pili",
        '2bddcbfc524a86efb3a73e4996f7408b5b30aa1b2b95fa12c13296032c17ae1b0000000200000001',
        '4ae9a884ad008297c9b9a325ddffede3b7a21cae2417b5'),
];

Uint8List _seed(String k) => _h(_seeds[k]!);

SealKeySource _queue(List<String> names) {
  final q = [...names];
  return () => XKeys.generate(_seed(q.removeAt(0)));
}

void main() {
  group('RFC vectors', () {
    test('X25519 (RFC 7748 §6.1)', () async {
      final a = await XKeys.generate(_h(
          '77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a'));
      final b = await XKeys.generate(_h(
          '5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb'));
      expect(_x(a.public),
          '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a');
      expect(_x(b.public),
          'de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f');
      expect(_x(await a.dh(b.public)),
          '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742');
      expect(_x(await b.dh(a.public)), _x(await a.dh(b.public)));
    });

    test('HKDF-SHA256 (RFC 5869 case 1)', () async {
      final okm = await sealHkdf(List<int>.generate(13, (i) => i),
          List<int>.filled(22, 0x0b), List<int>.generate(10, (i) => 0xf0 + i), 42);
      expect(_x(okm),
          '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf'
          '34007208d5b887185865');
    });

    test('Ed25519 (RFC 8032 test 1)', () async {
      final k = await EdKeys.generate(_h(
          '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'));
      expect(_x(k.public),
          'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a');
      final sig = await k.sign(const []);
      expect(_x(sig),
          'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155'
          '5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b');
      expect(await sealVerify(k.public, const [], sig), isTrue);
      expect(await sealVerify(k.public, const [1], sig), isFalse);
    });

    test('a low-order public key is refused', () async {
      final a = await XKeys.generate();
      await expectLater(a.dh(Uint8List(32)), throwsA(isA<SealError>()));
    });
  });

  group('Python reference', () {
    late SealIdentity bob, alice;
    late SignedPreKey spk;
    late OneTimePreKey opk;
    late PreKeyBundle bundle;

    setUp(() async {
      bob = await SealIdentity.generate(
          sigSeed: _seed('bob-ik-sig'), dhSeed: _seed('bob-ik-dh'));
      alice = await SealIdentity.generate(
          sigSeed: _seed('alice-ik-sig'), dhSeed: _seed('alice-ik-dh'));
      spk = await SignedPreKey.generate(bob, 1, seed: _seed('bob-spk'));
      opk = await OneTimePreKey.generate(7, seed: _seed('bob-opk-1'));
      bundle = PreKeyBundle(
          ikSig: bob.sig.public,
          ikDh: bob.dh.public,
          ikDhSig: bob.dhSig,
          spkId: spk.id,
          spk: spk.keys.public,
          spkSig: spk.sig,
          opkId: opk.id,
          opk: opk.keys.public);
    });

    test('keys and signatures match', () async {
      expect(_x(bob.sig.public), _pub['bob_sig']);
      expect(_x(bob.dh.public), _pub['bob_ikdh']);
      expect(_x(spk.keys.public), _pub['bob_spk']);
      expect(_x(opk.keys.public), _pub['bob_opk']);
      expect(_x(alice.sig.public), _pub['alice_sig']);
      expect(_x(alice.dh.public), _pub['alice_ikdh']);
      expect(_x(spk.sig), _spkSig);
      expect(_x(bob.dhSig), _ikDhSig);
    });

    test('X3DH secret, with and without a one-time prekey', () async {
      final a = await x3dhInitiate(alice, bundle,
          ephemeralSeed: _seed('alice-ek'));
      expect(_x(a.sk), _sk);
      expect(_x(a.info.ek), _pub['alice_ek']);
      expect(_x(a.ad), '${_pub['alice_sig']}${_pub['bob_sig']}');
      final b = await x3dhRespond(bob, a.info, spk, opk);
      expect(_x(b.sk), _sk);
      expect(_x(b.ad), _x(a.ad));
      final noOpk = PreKeyBundle(
          ikSig: bundle.ikSig,
          ikDh: bundle.ikDh,
          ikDhSig: bundle.ikDhSig,
          spkId: bundle.spkId,
          spk: bundle.spk,
          spkSig: bundle.spkSig);
      final c = await x3dhInitiate(alice, noOpk,
          ephemeralSeed: _seed('alice-ek'));
      expect(_x(c.sk), _skNoOpk);
      expect(c.info.opkId, isNull);
      expect(_x((await x3dhRespond(bob, c.info, spk, null)).sk), _skNoOpk);
    });

    test('the conversation matches byte for byte', () async {
      final a = await SealSession.start(alice, bundle,
          ephemeralSeed: _seed('alice-ek'),
          keys: _queue(['alice-ratchet-1', 'alice-ratchet-2']));
      final bobKeys = _queue(['bob-ratchet-1', 'bob-ratchet-2']);

      Future<SealEnvelope> send(SealSession s, _V v) async {
        final e = await s.encrypt(utf8.encode(v.text));
        expect(_x(e.message.header), v.header, reason: v.text);
        expect(_x(e.message.body), v.ct, reason: v.text);
        // Through the wire format and back.
        return SealEnvelope.fromBase64(e.toBase64());
      }

      final e0 = await send(a, _msgs[0]);
      final e1 = await send(a, _msgs[1]);
      expect(e0.isPreKey, isTrue);
      expect(e1.isPreKey, isTrue, reason: 'until Bob answers');
      final (b, t0) = await SealSession.accept(bob, e0, spk, opk, keys: bobKeys);
      expect(utf8.decode(t0), _msgs[0].text);
      expect(utf8.decode(await b.decrypt(e1)), _msgs[1].text);

      final e2 = await send(b, _msgs[2]);
      expect(e2.isPreKey, isFalse);
      expect(utf8.decode(await a.decrypt(e2)), _msgs[2].text);

      final e3 = await send(a, _msgs[3]);
      final e4 = await send(a, _msgs[4]);
      expect(e3.isPreKey, isFalse, reason: 'Bob answered');
      expect(utf8.decode(await b.decrypt(e4)), _msgs[4].text);
      expect(utf8.decode(await b.decrypt(e3)), _msgs[3].text);
    });
  });

  group('Safety', () {
    Future<(SealSession, SealSession)> pair() async {
      final bob = await SealIdentity.generate();
      final alice = await SealIdentity.generate();
      final spk = await SignedPreKey.generate(bob, 3);
      final opk = await OneTimePreKey.generate(9);
      final a = await SealSession.start(
          alice,
          PreKeyBundle(
              ikSig: bob.sig.public,
              ikDh: bob.dh.public,
              ikDhSig: bob.dhSig,
              spkId: spk.id,
              spk: spk.keys.public,
              spkSig: spk.sig,
              opkId: opk.id,
              opk: opk.keys.public));
      final (b, _) = await SealSession.accept(
          bob, await a.encrypt(utf8.encode('hi')), spk, opk);
      return (a, b);
    }

    test('a forged signed prekey is refused', () async {
      final bob = await SealIdentity.generate();
      final mallory = await SealIdentity.generate();
      final spk = await SignedPreKey.generate(mallory, 1);
      final alice = await SealIdentity.generate();
      await expectLater(
          x3dhInitiate(
              alice,
              PreKeyBundle(
                  ikSig: bob.sig.public,
                  ikDh: bob.dh.public,
                  ikDhSig: bob.dhSig,
                  spkId: 1,
                  spk: spk.keys.public,
                  spkSig: spk.sig)),
          throwsA(isA<SealError>()));
    });

    test('a tampered message fails and leaves the session working',
        () async {
      final (a, b) = await pair();
      final good = await a.encrypt(utf8.encode('nakupenda'));
      final raw = good.encode();
      raw[raw.length - 20] ^= 1;
      await expectLater(
          b.decrypt(SealEnvelope.decode(raw)), throwsA(isA<SealError>()));
      final hdr = good.encode();
      hdr[hdr.length - good.message.body.length - 1] ^= 1; // header n
      await expectLater(
          b.decrypt(SealEnvelope.decode(hdr)), throwsA(isA<SealError>()));
      expect(utf8.decode(await b.decrypt(good)), 'nakupenda');
    });

    test('a replayed message is refused', () async {
      final (a, b) = await pair();
      final e = await a.encrypt(utf8.encode('once'));
      await b.decrypt(e);
      await expectLater(b.decrypt(e), throwsA(isA<SealError>()));
    });

    test('sessions survive being saved and loaded mid-conversation',
        () async {
      var (a, b) = await pair();
      for (var i = 0; i < 6; i++) {
        final late1 = await a.encrypt(utf8.encode('late $i'));
        final m = await a.encrypt(utf8.encode('a$i'));
        expect(utf8.decode(await b.decrypt(m)), 'a$i');
        a = SealSession.fromJson(
            jsonDecode(jsonEncode(a.toJson())) as Map<String, dynamic>);
        b = SealSession.fromJson(
            jsonDecode(jsonEncode(b.toJson())) as Map<String, dynamic>);
        expect(utf8.decode(await b.decrypt(late1)), 'late $i');
        final r = await b.encrypt(utf8.encode('b$i'));
        expect(utf8.decode(await a.decrypt(r)), 'b$i');
      }
    });

    test('too large a gap is refused', () async {
      final (a, b) = await pair();
      final first = await a.encrypt(utf8.encode('x'));
      await b.decrypt(first);
      SealEnvelope? last;
      for (var i = 0; i < SealSpec.maxSkip + 2; i++) {
        last = await a.encrypt(const [1]);
      }
      await expectLater(b.decrypt(last!), throwsA(isA<SealError>()));
    });

    test('a malformed envelope is a SealError', () {
      expect(() => SealEnvelope.decode(const [1]), throwsA(isA<SealError>()));
      expect(() => SealEnvelope.decode(const [9, 1]), throwsA(isA<SealError>()));
      expect(() => SealEnvelope.fromBase64('%%'), throwsA(isA<SealError>()));
    });
  });
}
