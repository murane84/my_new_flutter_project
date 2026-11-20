import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show compute;

import 'seal_primitives.dart';

/// 🔒 Aluta Seal media v1: a photo, video, voice note or file is locked on
/// the phone BEFORE it is uploaded; the server only ever stores the locked
/// bytes. Its key travels inside the sealed message (end to end, like the
/// text), so only the two people's devices can open it.
///
/// Format: "ASM1" ‖ prefix(8) ‖ chunk₀ ‖ chunk₁ ‖ … where every chunk is
/// AES-256-GCM over ≤ 64 KiB with nonce = prefix ‖ index (4 bytes, big
/// endian) and aad = "ASM1" ‖ index ‖ last-flag — so chunks can't be
/// reordered, dropped or the file cut short without the open failing.
///
/// In the app the key rides on the media address as a fragment
/// (`/attachments/ID#ask=KEY`): fragments are never sent to a server,
/// and every place that shows media by address can open it (see
/// [SealMedia.keyOf] and the media cache).
class SealMedia {
  SealMedia._();

  static const List<int> magic = [0x41, 0x53, 0x4D, 0x31]; // "ASM1"
  static const int chunk = 64 * 1024;
  static const int _tag = 16;
  static const String fragment = '#ask=';

  /// Sealed media is meant for the two people: the server's size check uses
  /// this content type (with the real kind in the upload's `kind`).
  static const String uploadMime = 'application/x-aluta-sealed';

  /// Up to this size a file is locked in memory; a larger one is locked
  /// and opened piece by piece through a file on disk ([sealFile] /
  /// [openFile]), so a big video never needs two copies in memory.
  static const int maxBytes = 100 * 1024 * 1024;

  /// What every device must be able to open for a [kind] file of [size]
  /// bytes (the directory's caps): "m1" photos, videos, voice notes and
  /// files up to [maxBytes]; "m2" songs and bigger files (an older Aluta
  /// would get a song it can't play, or a file too big for its memory).
  static String capFor(String kind, int size) =>
      kind == 'song' || size > maxBytes ? 'm2' : 'm1';

  /// Kinds whose bytes are locked on the phone before upload.
  static const List<String> kinds = ['image', 'video', 'audio', 'file', 'song'];

  static final _gcm = AesGcm.with256bits();

  static List<int> _aad(int index, bool last) => [
        ...magic,
        (index >> 24) & 0xff,
        (index >> 16) & 0xff,
        (index >> 8) & 0xff,
        index & 0xff,
        last ? 1 : 0,
      ];

  static List<int> _nonce(List<int> prefix, int index) => [
        ...prefix,
        (index >> 24) & 0xff,
        (index >> 16) & 0xff,
        (index >> 8) & 0xff,
        index & 0xff,
      ];

  /// Lock [plain] with a fresh key: (locked bytes, key).
  static Future<(Uint8List, Uint8List)> seal(List<int> plain,
      {List<int>? key, List<int>? prefix}) async {
    final k = Uint8List.fromList(key ?? sealRandomBytes(32));
    final p = prefix ?? sealRandomBytes(8);
    final secret = SecretKey(k);
    final n = plain.isEmpty ? 1 : (plain.length + chunk - 1) ~/ chunk;
    final out = BytesBuilder(copy: false)
      ..add(magic)
      ..add(p);
    for (var i = 0; i < n; i++) {
      final start = i * chunk;
      final end = (start + chunk).clamp(0, plain.length);
      final box = await _gcm.encrypt(plain.sublist(start, end),
          secretKey: secret, nonce: _nonce(p, i), aad: _aad(i, i == n - 1));
      out
        ..add(box.cipherText)
        ..add(box.mac.bytes);
    }
    return (out.toBytes(), k);
  }

  /// Open locked bytes with [key]; throws [SealError] if they were changed,
  /// cut short, or locked with another key.
  static Future<Uint8List> open(List<int> sealed, List<int> key) async {
    if (sealed.length < 12 + _tag) throw SealError('media too short');
    for (var i = 0; i < 4; i++) {
      if (sealed[i] != magic[i]) throw SealError('not sealed media');
    }
    final p = sealed.sublist(4, 12);
    final secret = SecretKey(key);
    final body = sealed.length - 12;
    const full = chunk + _tag;
    final n = (body + full - 1) ~/ full;
    final out = BytesBuilder(copy: false);
    try {
      for (var i = 0; i < n; i++) {
        final start = 12 + i * full;
        final end = (start + full).clamp(0, sealed.length);
        if (end - start < _tag) throw SealError('media cut short');
        final ct = sealed.sublist(start, end - _tag);
        final mac = sealed.sublist(end - _tag, end);
        out.add(await _gcm.decrypt(SecretBox(ct, nonce: _nonce(p, i), mac: Mac(mac)),
            secretKey: secret, aad: _aad(i, i == n - 1)));
      }
    } on SealError {
      rethrow;
    } catch (_) {
      throw SealError('media could not be unlocked');
    }
    return out.toBytes();
  }

  /// [seal] off the UI thread (a video can be large).
  static Future<(Uint8List, Uint8List)> sealInBackground(List<int> plain) =>
      compute(_sealIsolate, Uint8List.fromList(plain));

  /// [open] off the UI thread.
  static Future<Uint8List> openInBackground(List<int> sealed, List<int> key) =>
      compute(_openIsolate, (Uint8List.fromList(sealed), Uint8List.fromList(key)));

  /// Lock the file at [src] into [dst] piece by piece (same format as
  /// [seal]) off the UI thread; returns the key. Phones and computers
  /// only (the web has no files).
  static Future<Uint8List> sealFile(String src, String dst) async {
    final key = Uint8List.fromList(sealRandomBytes(32));
    final prefix = Uint8List.fromList(sealRandomBytes(8));
    await compute(_sealFileIsolate, (src, dst, key, prefix));
    return key;
  }

  /// Open the locked file at [src] into [dst] piece by piece off the UI
  /// thread. Throws [SealError] (and leaves no [dst]) when it was changed,
  /// cut short or locked with another key.
  static Future<void> openFile(String src, String dst, List<int> key) async {
    final k = Uint8List.fromList(key);
    try {
      await compute(_openFileIsolate, (src, dst, k));
    } catch (e) {
      try {
        final f = File(dst);
        if (await f.exists()) await f.delete();
      } catch (_) {}
      throw e is SealError ? e : SealError('media could not be unlocked');
    }
  }

  static Future<void> _sealFileNow(
      String src, String dst, Uint8List key, Uint8List prefix) async {
    final inF = await File(src).open();
    final out = await File(dst).open(mode: FileMode.write);
    try {
      final len = await inF.length();
      final n = len == 0 ? 1 : (len + chunk - 1) ~/ chunk;
      final secret = SecretKey(key);
      await out.writeFrom(magic);
      await out.writeFrom(prefix);
      for (var i = 0; i < n; i++) {
        final part = await inF.read(chunk);
        final box = await _gcm.encrypt(part,
            secretKey: secret,
            nonce: _nonce(prefix, i),
            aad: _aad(i, i == n - 1));
        await out.writeFrom(box.cipherText);
        await out.writeFrom(box.mac.bytes);
      }
      await out.flush();
    } finally {
      await inF.close();
      await out.close();
    }
  }

  static Future<void> _openFileNow(
      String src, String dst, Uint8List key) async {
    final inF = await File(src).open();
    final out = await File(dst).open(mode: FileMode.write);
    try {
      final len = await inF.length();
      if (len < 12 + _tag) throw SealError('media too short');
      final head = await inF.read(12);
      for (var i = 0; i < 4; i++) {
        if (head[i] != magic[i]) throw SealError('not sealed media');
      }
      final p = head.sublist(4, 12);
      final secret = SecretKey(key);
      const full = chunk + _tag;
      final n = (len - 12 + full - 1) ~/ full;
      for (var i = 0; i < n; i++) {
        final box = await inF.read(full);
        if (box.length < _tag) throw SealError('media cut short');
        final ct = box.sublist(0, box.length - _tag);
        final mac = box.sublist(box.length - _tag);
        try {
          await out.writeFrom(await _gcm.decrypt(
              SecretBox(ct, nonce: _nonce(p, i), mac: Mac(mac)),
              secretKey: secret,
              aad: _aad(i, i == n - 1)));
        } catch (_) {
          throw SealError('media could not be unlocked');
        }
      }
      await out.flush();
    } finally {
      await inF.close();
      await out.close();
    }
  }

  // ── Addresses ────────────────────────────────────────────────────────────

  /// [url] with [key] attached (kept on the device; never sent anywhere).
  static String withKey(String url, List<int> key) =>
      '${bare(url)}$fragment${base64Url.encode(key).replaceAll('=', '')}';

  /// The key on a media address, or null for ordinary media.
  static Uint8List? keyOf(String? url) {
    if (url == null) return null;
    final i = url.indexOf(fragment);
    if (i < 0) return null;
    try {
      final k = base64Url.decode(base64Url.normalize(url.substring(i + fragment.length)));
      return k.length == 32 ? Uint8List.fromList(k) : null;
    } catch (_) {
      return null;
    }
  }

  static bool isSealed(String? url) => keyOf(url) != null;

  /// The address without its key (what the server knows).
  static String bare(String url) {
    final i = url.indexOf(fragment);
    return i < 0 ? url : url.substring(0, i);
  }
}

Future<(Uint8List, Uint8List)> _sealIsolate(Uint8List plain) =>
    SealMedia.seal(plain);

Future<Uint8List> _openIsolate((Uint8List, Uint8List) a) =>
    SealMedia.open(a.$1, a.$2);

Future<void> _sealFileIsolate((String, String, Uint8List, Uint8List) a) =>
    SealMedia._sealFileNow(a.$1, a.$2, a.$3, a.$4);

Future<void> _openFileIsolate((String, String, Uint8List) a) =>
    SealMedia._openFileNow(a.$1, a.$2, a.$3);
