import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'seal_directory.dart';
import 'seal_keystore.dart';
import 'seal_primitives.dart';
import 'seal_scope.dart';

/// 🔒 Listen Together: the room's Chat & reactions lines, end to end.
///
/// The song already travels phone-to-phone (WebRTC). Chat lines and GIF
/// reactions go through the session socket, so they are sealed with a key
/// for this one session: the HOST makes it and gives each guest's devices a
/// copy (wrapped to the device's identity, signed by the host's device — the
/// same copies as Our Space keys) over the socket, addressed to that guest.
/// A line is "🔒r1.{base64url(nonce ‖ AES-256-GCM ‖ tag)}", aad
/// "AlutaLive v1|{session}". Nothing is kept: the key dies with the session.
///
/// A guest on an older Aluta can't take a key: the host then tells the room
/// to speak plainly until that guest leaves (like chats with an older app).
class SealRoom {
  SealRoom(this.session, {SealKeyStore? keys, SealKeyDirectory? directory})
      : _keys = keys ?? SealKeyStore.instance,
        _dir = directory ?? SealDirectory.instance;

  final String session;
  final SealKeyStore _keys;
  final SealKeyDirectory _dir;

  static const String prefix = '🔒r1.';
  static const String waiting = '🔒 …';

  Uint8List? _key;

  /// Whether lines are sealed in this room (the host's call).
  bool sealedRoom = true;

  /// HOST: guests who can't take a key (older Aluta).
  final Set<int> keyless = {};

  bool get hasKey => _key != null;
  String get _scope => 'live:$session';
  List<int> get _aad => utf8.encode('AlutaLive v1|$session');

  static bool isSealed(Object? v) => v is String && v.startsWith(prefix);

  /// HOST: make the room's key (once). False when this device has no
  /// end-to-end keys (then the room speaks plainly).
  Future<bool> ensureHostKey() async {
    if (_key != null) return true;
    await _keys.load();
    if (!_keys.isReady) return false;
    _key = sealRandomBytes(32);
    return true;
  }

  Future<String> seal(String text) async {
    final k = _key;
    if (k == null) throw SealError('no room key');
    final nonce = sealRandomBytes(12);
    final box = await AesGcm.with256bits().encrypt(utf8.encode(text),
        secretKey: SecretKey(k), nonce: nonce, aad: _aad);
    return prefix +
        base64Url
            .encode(sealConcat([nonce, box.cipherText, box.mac.bytes]))
            .replaceAll('=', '');
  }

  Future<String> open(String sealed) async {
    final k = _key;
    if (k == null) throw SealError('no room key');
    try {
      final raw = base64Url
          .decode(base64Url.normalize(sealed.substring(prefix.length)));
      final clear = await AesGcm.with256bits().decrypt(
          SecretBox(raw.sublist(12, raw.length - 16),
              nonce: raw.sublist(0, 12),
              mac: Mac(raw.sublist(raw.length - 16))),
          secretKey: SecretKey(k),
          aad: _aad);
      return utf8.decode(clear);
    } catch (_) {
      throw SealError('line could not be unlocked');
    }
  }

  /// HOST: the `room_key` message for guest [uid] (every device of theirs),
  /// or null when they can't take one (no keys — an older Aluta) or the
  /// directory can't be reached.
  Future<Map<String, dynamic>?> keyMessageFor(int uid, int myUid) async {
    if (!await ensureHostKey()) return null;
    final devices = await _dir.devicesOf(uid);
    if (devices == null || devices.isEmpty) return null;
    final copies = <String, String>{};
    for (final d in devices) {
      try {
        if (d.ikDh == null || d.ikDhSig == null) continue;
        final ikSig = base64Decode(d.ikSig);
        final ikDh = base64Decode(d.ikDh!);
        if (!await sealVerify(ikSig,
            sealConcat([SealSpec.ikDhSigPrefix, ikDh]),
            base64Decode(d.ikDhSig!))) {
          continue;
        }
        copies[d.deviceId] = await SealScope.wrap(
            me: _keys.identity,
            recipIkDh: ikDh,
            recipIkSig: ikSig,
            scope: _scope,
            epoch: 1,
            scopeKey: _key!);
      } catch (_) {}
    }
    if (copies.isEmpty) return null;
    return {
      'type': 'room_key',
      'to': uid,
      'from': myUid,
      'from_device': _keys.deviceId,
      'keys': copies,
    };
  }

  /// GUEST: take the key from a `room_key` message — only from [hostId],
  /// and only a copy signed by one of the host's devices. True on success.
  Future<bool> takeKey(Map<String, dynamic> msg, int? hostId) async {
    try {
      if (hostId == null || msg['from'] != hostId) return false;
      await _keys.load();
      if (!_keys.isReady) return false;
      final copy = (msg['keys'] as Map?)?[_keys.deviceId];
      if (copy is! String) return false;
      final fromDevice = msg['from_device'];
      final hostDevices = await _dir.devicesOf(hostId);
      SealPeerDevice? sender;
      for (final d in hostDevices ?? const <SealPeerDevice>[]) {
        if (d.deviceId == fromDevice) sender = d;
      }
      if (sender == null) return false;
      _key = await SealScope.unwrap(
          me: _keys.identity,
          blob: copy,
          senderIkSig: base64Decode(sender.ikSig),
          scope: _scope,
          epoch: 1);
      return true;
    } catch (e) {
      debugPrint('Seal room key: $e');
      return false;
    }
  }
}
