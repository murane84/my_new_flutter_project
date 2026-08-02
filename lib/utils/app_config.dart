import 'dart:io';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Smart server-IP discovery.
///
/// Priority order (first match wins, each verified with /health):
///   1. Release mode → _prodUrl
///   2. --dart-define=SERVER_IP=x.x.x.x  (build-time override, trusted)
///   3. Manual in-app override from SharedPreferences (verified first)
///   4. Session memory cache (already verified this run)
///   5. Auto-detect:
///        • Desktop: local NIC IP = server IP
///        • Android/iOS: parallel subnet probe
///   6. Fallback: localhost
///
/// Key behaviour: stored IPs are always verified before use. If they don't
/// respond (e.g. WiFi changed), discovery runs again automatically.
class AppConfig {
  // Production backend (Railway). Override at build time without editing code:
  //   flutter build apk --dart-define=PROD_URL=https://your-app.up.railway.app
  // Otherwise update the default below to your Railway domain after deploying.
  static const String _prodUrl =
      String.fromEnvironment('PROD_URL',
          defaultValue: 'https://REPLACE-WITH-YOUR-RAILWAY-DOMAIN.up.railway.app');
  static const int    port          = 8000;
  static const String tokenKey      = 'access_token';
  static const String _prefKey      = 'server_ip_override';

  // --dart-define=SERVER_IP=192.168.x.x
  static const String _buildTimeIp =
      String.fromEnvironment('SERVER_IP', defaultValue: '');

  // In-process cache — cleared by clearSessionCache() on network change
  static String? _cachedIp;

  // ── Public API ────────────────────────────────────────────────────────────

  static Future<String> get baseUrl async {
    if (kReleaseMode) return _prodUrl;
    return 'http://${await _resolveIp()}:$port';
  }

  static Future<String> get wsBaseUrl async {
    if (kReleaseMode) {
      // Derive the WebSocket URL from the production URL so there is a single
      // source of truth: https:// -> wss://, http:// -> ws://
      return _prodUrl
          .replaceFirst('https://', 'wss://')
          .replaceFirst('http://', 'ws://');
    }
    return 'ws://${await _resolveIp()}:$port';
  }

  static String? get cachedIp => _cachedIp;

  /// Call this when the network interface changes (connectivity_plus event).
  /// Clears the in-process cache so the next request re-validates the IP.
  static void clearSessionCache() {
    _cachedIp = null;
  }

  /// Manually pin a server IP and save it (called from Settings UI).
  static Future<void> setManualIp(String ip) async {
    _cachedIp = ip.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, _cachedIp!);
  }

  /// Wipe both memory cache and stored preference → next call re-discovers.
  static Future<void> resetDiscovery() async {
    _cachedIp = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey);
  }

  static Future<bool> probeIp(String ip) => _isAlutaServer(ip);

  // ── Internal resolution ───────────────────────────────────────────────────

  static Future<String> _resolveIp() async {
    // 1. Build-time compile flag — always trusted, no probe needed.
    if (_buildTimeIp.isNotEmpty) {
      _cachedIp ??= _buildTimeIp;
      return _buildTimeIp;
    }

    // 2. In-process session cache — verified ONCE per session.
    //    Re-set to null by clearSessionCache() when network changes.
    //    NOT re-probed on every call — that would add 500ms to every request.
    if (_cachedIp != null) return _cachedIp!;

    final prefs = await SharedPreferences.getInstance();

    // 3. Stored preference — probe ONCE at start of session to verify
    //    it's still reachable (catches WiFi changes between app launches).
    final stored = prefs.getString(_prefKey);
    if (stored != null && stored.isNotEmpty) {
      if (await _isAlutaServer(stored)) {
        _cachedIp = stored;
        return stored;
      }
      // Stored IP unreachable (WiFi changed?) → clear and re-discover.
      await prefs.remove(_prefKey);
    }

    // 4. Auto-discover (NIC scan on desktop, subnet probe on Android).
    final found = await _autoDetect();
    _cachedIp = found ?? 'localhost';
    if (found != null) await prefs.setString(_prefKey, found);
    return _cachedIp!;
  }

  // ── Desktop: own NIC IP = server IP ──────────────────────────────────────

  static bool get _isDesktop => !Platform.isAndroid && !Platform.isIOS;

  static Future<String?> _autoDetect() =>
      _isDesktop ? _localLanIp() : _discoverOnSubnet();

  static Future<String?> _localLanIp() async {
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in ifaces) {
        final name = iface.name.toLowerCase();
        if (name.contains('loopback') ||
            name.contains('vmware') ||
            name.contains('vethernet') ||
            name.contains('docker') ||
            name.contains('virtualbox')) { continue; }
        for (final addr in iface.addresses) {
          if (_isPrivate(addr.address)) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  // ── Mobile: parallel subnet probe ─────────────────────────────────────────

  static Future<String?> _discoverOnSubnet() async {
    String? deviceIp;
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      outer:
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (_isPrivate(addr.address)) {
            deviceIp = addr.address;
            break outer;
          }
        }
      }
    } catch (_) {}

    if (deviceIp == null) return null;

    final parts = deviceIp.split('.');
    if (parts.length != 4) return null;
    final subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
    // Skip own address
    final ownLast = int.tryParse(parts[3]) ?? -1;

    // Scan in priority order: gateway first, then common PC ranges.
    final candidates = <int>[
      1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
      254, 253, 252, 251, 250,
      ...List.generate(40, (i) => i + 11),   // 11–50
      ...List.generate(55, (i) => i + 100),  // 100–154
    ].where((n) => n != ownLast).toList();

    const batchSize = 20;
    for (int i = 0; i < candidates.length; i += batchSize) {
      final batch = candidates.skip(i).take(batchSize);
      final futures = batch.map((last) async {
        final ip = '$subnet.$last';
        return (await _isAlutaServer(ip)) ? ip : null;
      });
      final found = (await Future.wait(futures)).whereType<String>().firstOrNull;
      if (found != null) return found;
    }
    return null;
  }

  // ── /health probe ─────────────────────────────────────────────────────────

  static Future<bool> _isAlutaServer(String ip) async {
    try {
      final res = await http
          .get(Uri.parse('http://$ip:$port/health'))
          .timeout(const Duration(milliseconds: 500));
      return res.statusCode == 200 && res.body.contains('aluta');
    } catch (_) {
      return false;
    }
  }

  static bool _isPrivate(String ip) =>
      ip.startsWith('192.168.') ||
      ip.startsWith('10.') ||
      RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip);
}
