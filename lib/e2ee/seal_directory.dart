import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../screens/token_helper.dart';
import '../utils/app_config.dart';
import '../utils/net.dart' as http;
import 'seal_keystore.dart';
import 'seal_x3dh.dart';

/// One friend device's bundle as the server returns it.
class SealDeviceBundle {
  SealDeviceBundle(this.userId, this.deviceId, this.bundle);
  final int userId;
  final String deviceId;
  final PreKeyBundle bundle;
}

/// One device of a person, as listed by the key directory.
class SealPeerDevice {
  SealPeerDevice(this.deviceId, this.ikSig);
  final String deviceId;
  final String ikSig; // base64 Ed25519 identity
}

/// What the messenger needs from the key directory (a fake in tests).
abstract class SealKeyDirectory {
  /// Live devices of [userId] (null = couldn't ask).
  Future<List<SealPeerDevice>?> devicesOf(int userId);

  /// Bundles for [userId]'s devices (one-time prekeys get spent).
  Future<List<SealDeviceBundle>?> bundlesFor(int userId, {String? deviceId});
}

/// Keeps this device's public keys on the server's key directory and
/// fetches friends' bundles. Best-effort: nothing here ever blocks a chat.
class SealDirectory implements SealKeyDirectory {
  SealDirectory._();
  static final SealDirectory instance = SealDirectory._();

  /// Refill one-time prekeys below this; top up to [opkTarget].
  static const int opkLow = 20;
  static const int opkTarget = 100;

  SealKeyStore get keys => SealKeyStore.instance;
  bool _syncing = false;

  static String? ownerOf(String? jwt) {
    if (jwt == null) return null;
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      final body = jsonDecode(
              utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))))
          as Map<String, dynamic>;
      final sub = body['sub'];
      return sub?.toString();
    } catch (_) {
      return null;
    }
  }

  String get _platform {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.macOS:
        return 'macos';
      default:
        return 'other';
    }
  }

  Future<Map<String, String>?> _headers() async {
    final t = await getToken();
    if (t == null) return null;
    return {'Authorization': 'Bearer $t', 'Content-Type': 'application/json'};
  }

  /// Register / refresh this device and keep one-time prekeys topped up.
  /// Call when the signed-in home mounts.
  Future<void> sync() async {
    if (_syncing) return;
    _syncing = true;
    try {
      final h = await _headers();
      final owner = ownerOf(h?['Authorization']?.substring(7));
      if (h == null || owner == null) return;
      await keys.ensure(owner);
      final rotated = await keys.rotateSpkIfDue();
      final base = await AppConfig.baseUrl;
      final spk = keys.currentSpk;
      if (rotated || keys.registeredSpkId != spk.id) {
        final id = keys.identity;
        final r = await http.put(Uri.parse('$base/e2ee/device'),
            headers: h,
            body: jsonEncode({
              'device_id': keys.deviceId,
              'ik_sig': base64Encode(id.sig.public),
              'ik_dh': base64Encode(id.dh.public),
              'ik_dh_sig': base64Encode(id.dhSig),
              'spk_id': spk.id,
              'spk': base64Encode(spk.keys.public),
              'spk_sig': base64Encode(spk.sig),
              'platform': _platform,
            }));
        if (r.statusCode != 200) return;
        await keys.markRegistered(spk.id);
      }
      final c = await http.get(
          Uri.parse('$base/e2ee/prekeys/count'
              '?device_id=${Uri.encodeQueryComponent(keys.deviceId)}'),
          headers: h);
      if (c.statusCode == 404) {
        // The server forgot this device (removed as stale): register again.
        await keys.markRegistered(0);
        return;
      }
      if (c.statusCode != 200) return;
      final have = (jsonDecode(c.body) as Map<String, dynamic>)['count'] as int;
      if (have >= opkLow) return;
      final fresh = await keys.addOpks(opkTarget - have);
      for (var i = 0; i < fresh.length; i += 100) {
        final part = fresh.sublist(i, (i + 100).clamp(0, fresh.length));
        await http.post(Uri.parse('$base/e2ee/prekeys'),
            headers: h,
            body: jsonEncode({
              'device_id': keys.deviceId,
              'keys': [
                for (final k in part)
                  {'id': k.id, 'pub': base64Encode(k.keys.public)}
              ],
            }));
      }
    } catch (e) {
      debugPrint('Seal sync: $e');
    } finally {
      _syncing = false;
    }
  }

  @override
  Future<List<SealPeerDevice>?> devicesOf(int userId) async {
    try {
      final h = await _headers();
      if (h == null) return null;
      final base = await AppConfig.baseUrl;
      final r = await http.get(Uri.parse('$base/e2ee/devices/$userId'),
          headers: h);
      if (r.statusCode != 200) return null;
      final list = (jsonDecode(r.body) as Map<String, dynamic>)['devices']
          as List;
      return [
        for (final d in list.cast<Map<String, dynamic>>())
          SealPeerDevice(d['device_id'] as String, d['ik_sig'] as String)
      ];
    } catch (e) {
      debugPrint('Seal devices: $e');
      return null;
    }
  }

  /// Bundles for every live device of [userId] (your own id → your other
  /// devices). Each call spends one of their one-time prekeys per device,
  /// so fetch only when starting a session. Null when unreachable.
  @override
  Future<List<SealDeviceBundle>?> bundlesFor(int userId,
      {String? deviceId}) async {
    try {
      final h = await _headers();
      if (h == null) return null;
      final base = await AppConfig.baseUrl;
      final q = deviceId == null
          ? ''
          : '?device_id=${Uri.encodeQueryComponent(deviceId)}';
      final r = await http.get(Uri.parse('$base/e2ee/bundles/$userId$q'),
          headers: h);
      if (r.statusCode != 200) return null;
      final list = (jsonDecode(r.body) as Map<String, dynamic>)['bundles']
          as List;
      return [
        for (final b in list.cast<Map<String, dynamic>>())
          if (b['device_id'] != keys.deviceIdOrNull)
            SealDeviceBundle(userId, b['device_id'] as String,
                PreKeyBundle.fromJson(b))
      ];
    } catch (e) {
      debugPrint('Seal bundles: $e');
      return null;
    }
  }

  /// Sign-out: take this device off the directory and forget its keys
  /// (call while the session token is still valid).
  Future<void> signOut() async {
    try {
      await keys.load();
      final h = await _headers();
      final dev = keys.deviceIdOrNull;
      if (h != null && dev != null) {
        final base = await AppConfig.baseUrl;
        await http.delete(
            Uri.parse('$base/e2ee/device/${Uri.encodeComponent(dev)}'),
            headers: h);
      }
    } catch (_) {/* best-effort */}
    await keys.wipe();
  }
}
