// Aluta Seal messenger: two people, three devices, a fake key directory.
import 'dart:convert';

import 'package:aluta/e2ee/seal.dart';
import 'package:aluta/e2ee/seal_directory.dart';
import 'package:aluta/e2ee/seal_keystore.dart';
import 'package:aluta/e2ee/seal_messenger.dart';
import 'package:flutter_test/flutter_test.dart';

const alice = 1, bob = 2, carol = 3;

class _Dev {
  _Dev(this.uid, this.keys, this.app);
  final int uid;
  final SealKeyStore keys;
  final SealMessenger app;
}

/// Plays the server: device list + bundles (each one-time prekey once).
class _FakeDirectory implements SealKeyDirectory {
  final Map<int, List<_Dev>> people = {};
  final Map<String, List<OneTimePreKey>> unspent = {};

  @override
  Future<List<SealPeerDevice>?> devicesOf(int userId) async => [
        for (final d in people[userId] ?? const <_Dev>[])
          SealPeerDevice(
              d.keys.deviceId, base64Encode(d.keys.identity.sig.public))
      ];

  @override
  Future<List<SealDeviceBundle>?> bundlesFor(int userId,
      {String? deviceId}) async {
    final out = <SealDeviceBundle>[];
    for (final d in people[userId] ?? const <_Dev>[]) {
      if (deviceId != null && d.keys.deviceId != deviceId) continue;
      final pool = unspent[d.keys.deviceId] ?? [];
      final opk = pool.isEmpty ? null : pool.removeAt(0);
      final id = d.keys.identity;
      out.add(SealDeviceBundle(
          userId,
          d.keys.deviceId,
          PreKeyBundle(
              ikSig: id.sig.public,
              ikDh: id.dh.public,
              ikDhSig: id.dhSig,
              spkId: d.keys.currentSpk.id,
              spk: d.keys.currentSpk.keys.public,
              spkSig: d.keys.currentSpk.sig,
              opkId: opk?.id,
              opk: opk?.keys.public)));
    }
    return out;
  }
}

void main() {
  late _FakeDirectory dir;
  var now = DateTime(2026, 11, 16, 21);
  var nextId = 100;

  Future<_Dev> device(int uid, String name) async {
    final keys = SealKeyStore(storage: MemorySealStorage(), clock: () => now);
    await keys.ensure('user$uid');
    final app = SealMessenger(
        keys: keys,
        directory: dir,
        sessions: MemorySealStorage(),
        plain: MemorySealStorage(),
        clock: () => now);
    final d = _Dev(uid, keys, app);
    dir.people.putIfAbsent(uid, () => []).add(d);
    dir.unspent[keys.deviceId] = await keys.addOpks(3);
    return d;
  }

  /// What the server stores and hands back for a sent message.
  Future<Map<String, dynamic>> send(_Dev from, int to, String text,
      {int? id, int rev = 0, String? meta}) async {
    final env = await from.app.seal(to, from.uid, text);
    final mid = id ?? nextId++;
    await from.app.rememberSent(to, mid, rev, text);
    return {
      'id': mid,
      'sender_id': from.uid,
      'receiver_id': to,
      'content': '',
      'e2ee': 1,
      'e2ee_rev': rev,
      'envelopes': jsonEncode(env),
      'meta': meta,
    };
  }

  Future<String?> read(_Dev d, Map<String, dynamic> m) async {
    final r = await d.app.open(Map<String, dynamic>.from(m), d.uid);
    return r.status == SealOpenStatus.ok ? r.text : r.status.name;
  }

  setUp(() {
    dir = _FakeDirectory();
    now = DateTime(2026, 11, 16, 21);
  });

  test('a conversation across phones and a linked computer', () async {
    final aPhone = await device(alice, 'a-phone');
    final aPc = await device(alice, 'a-pc');
    final bPhone = await device(bob, 'b-phone');

    final m1 = await send(aPhone, bob, 'Habari za jioni? 🎶');
    expect(jsonDecode(m1['envelopes'] as String), hasLength(3),
        reason: "Bob's phone, Alice's computer, the phone's own copy");
    expect(await read(bPhone, m1), 'Habari za jioni? 🎶');
    expect(await read(bPhone, m1), 'Habari za jioni? 🎶',
        reason: 'reopening never decrypts twice');
    expect(await read(aPc, m1), 'Habari za jioni? 🎶');
    expect(await read(aPhone, m1), 'Habari za jioni? 🎶',
        reason: 'my own sent text is remembered');

    for (var i = 0; i < 5; i++) {
      final r = await send(bPhone, alice, 'jibu $i');
      expect(await read(aPhone, r), 'jibu $i');
      expect(await read(aPc, r), 'jibu $i');
      final a = await send(i.isEven ? aPhone : aPc, bob, 'swali $i');
      expect(await read(bPhone, a), 'swali $i');
    }
  });

  test('late and out-of-order messages, read twice at once', () async {
    final a = await device(alice, 'a');
    final b = await device(bob, 'b');
    final first = await send(a, bob, 'kwanza');
    final second = await send(a, bob, 'pili');
    final both = await Future.wait([read(b, second), read(b, second)]);
    expect(both, ['pili', 'pili']);
    expect(await read(b, first), 'kwanza');
  });

  test('a notification peek leaves the chat able to open it', () async {
    final a = await device(alice, 'a');
    final b = await device(bob, 'b');
    final m = await send(a, bob, 'nakupenda');
    final p = await b.app.peek(Map<String, dynamic>.from(m), bob);
    expect(p.text, 'nakupenda');
    expect(await read(b, m), 'nakupenda');
    final m2 = await send(a, bob, 'tena');
    expect((await b.app.peek(Map<String, dynamic>.from(m2), bob)).text,
        'tena');
    expect(await read(b, m2), 'tena');
  });

  test('an edit is a new revision', () async {
    final a = await device(alice, 'a');
    final b = await device(bob, 'b');
    final m = await send(a, bob, 'saa mbili');
    expect(await read(b, m), 'saa mbili');
    final edited = await send(a, bob, 'saa tatu', id: m['id'] as int, rev: 1);
    expect(await read(b, edited), 'saa tatu');
    expect(await read(a, edited), 'saa tatu');
  });

  test('a friend on an older Aluta gets plain text', () async {
    final a = await device(alice, 'a');
    expect(() => a.app.seal(carol, alice, 'hi'),
        throwsA(isA<SealNotSupported>()));
  });

  test('a tampered copy fails, the next one still opens', () async {
    final a = await device(alice, 'a');
    final b = await device(bob, 'b');
    final m = await send(a, bob, 'x');
    final env = jsonDecode(m['envelopes'] as String) as Map<String, dynamic>;
    final key = '$bob:${b.keys.deviceId}';
    final raw = base64Decode(env[key] as String);
    raw[raw.length - 3] ^= 1;
    env[key] = base64Encode(raw);
    expect(await read(b, {...m, 'envelopes': jsonEncode(env)}), 'failed');
    expect(await read(b, await send(a, bob, 'y')), 'y');
  });

  test('my morning message opens from the hold', () async {
    final a = await device(alice, 'a');
    await device(bob, 'b');
    await a.app.rememberHeld(bob, 7, 'Habari ya asubuhi ☀️');
    final m = await send(a, bob, 'Habari ya asubuhi ☀️');
    final delivered = {...m, 'id': 555, 'meta': '{"held":7}'};
    expect(await read(a, delivered), 'Habari ya asubuhi ☀️');
  });

  test('a reinstalled phone gets a fresh session', () async {
    final a = await device(alice, 'a');
    final b1 = await device(bob, 'b');
    expect(await read(b1, await send(a, bob, 'kabla')), 'kabla');
    dir.people[bob]!.clear();
    final b2 = await device(bob, 'b-new');
    now = now.add(const Duration(minutes: 2)); // device list refreshes
    final m = await send(a, bob, 'baada');
    expect(await read(b2, m), 'baada');
    expect(jsonDecode(m['envelopes'] as String), hasLength(2),
        reason: "Bob's new phone + Alice's own copy");
  });

  test('my own copy reopens from the server after the app forgot it',
      () async {
    final a = await device(alice, 'a');
    final b = await device(bob, 'b');
    final m = await send(a, bob, 'nimefika');
    final again = SealMessenger(
        keys: a.keys,
        directory: dir,
        sessions: MemorySealStorage(),
        plain: MemorySealStorage());
    final r = await again.open(Map<String, dynamic>.from(m), alice);
    expect(r.text, 'nimefika');
    expect(await read(b, m), 'nimefika');
  });

  test('both start at the same moment and still settle', () async {
    final a = await device(alice, 'a');
    final b = await device(bob, 'b');
    // Neither has heard from the other: two sessions cross in flight.
    final fromA = await send(a, bob, 'mambo');
    final fromB = await send(b, alice, 'poa');
    expect(await read(b, fromA), 'mambo');
    expect(await read(a, fromB), 'poa');
    for (var i = 0; i < 4; i++) {
      final x = await send(a, bob, 'a$i');
      final y = await send(b, alice, 'b$i');
      expect(await read(b, x), 'a$i');
      expect(await read(a, y), 'b$i');
    }
  });

  test('the same first message delivered twice does not break the chat',
      () async {
    final a = await device(alice, 'a');
    final b = await device(bob, 'b');
    final first = await send(a, bob, 'kwanza');
    expect(await read(b, first), 'kwanza');
    // Seen again under another id (nothing remembered for it): it can't
    // open twice, and the session that works must survive.
    expect(await read(b, {...first, 'id': 999}), 'failed');
    final reply = await send(b, alice, 'jibu');
    expect(await read(a, reply), 'jibu');
    final next = await send(a, bob, 'pili');
    expect(await read(b, next), 'pili');
  });

  test('another account on the same phone never reuses its sessions',
      () async {
    final keyDisk = MemorySealStorage();
    final sessDisk = MemorySealStorage();
    Future<_Dev> signIn(int uid) async {
      final keys = SealKeyStore(storage: keyDisk, clock: () => now);
      await keys.ensure('user$uid');
      final app = SealMessenger(
          keys: keys,
          directory: dir,
          sessions: sessDisk,
          plain: MemorySealStorage(),
          clock: () => now);
      final d = _Dev(uid, keys, app);
      dir.people.putIfAbsent(uid, () => []).add(d);
      dir.unspent[keys.deviceId] = await keys.addOpks(3);
      return d;
    }

    final b = await device(bob, 'b');
    final a = await signIn(alice);
    expect(await read(b, await send(a, bob, 'kutoka alice')), 'kutoka alice');
    // Carol signs in on Alice's phone (no sign-out in between).
    final c = await signIn(carol);
    expect(c.keys.deviceId, isNot(a.keys.deviceId));
    expect(await read(b, await send(c, bob, 'kutoka carol')), 'kutoka carol');
  });

  test('a message for another device says so', () async {
    final a = await device(alice, 'a');
    await device(bob, 'b');
    final m = await send(a, bob, 'x');
    final newcomer = await device(bob, 'b-late');
    expect(await read(newcomer, m), 'noKey');
  });
}
