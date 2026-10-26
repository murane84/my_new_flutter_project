import 'dart:convert';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/token_helper.dart';
import '../utils/app_config.dart';

/// Tells the server what this install runs on (platform, OS, app version) —
/// once per app start, after sign-in. Powers the admin panel's device split
/// (Android / Windows / Web on iPhone / …). Web builds just say "web"; the
/// server tells iPhone, Android and computer apart from the browser.
/// Best-effort: never throws, never blocks startup.
class DeviceReport {
  DeviceReport._();

  static bool _sent = false;
  static const _kInstallId = 'aluta_install_id';

  static String _platform() {
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
      case TargetPlatform.linux:
        return 'linux';
      default:
        return 'web';
    }
  }

  static Future<String> _installId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_kInstallId);
    if (id == null || id.isEmpty) {
      final r = Random.secure();
      id = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'))
          .join();
      await prefs.setString(_kInstallId, id);
    }
    return id;
  }

  static Future<String?> _osVersion() async {
    if (kIsWeb) return null;
    try {
      final info = DeviceInfoPlugin();
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final a = await info.androidInfo;
          return 'Android ${a.version.release} (SDK ${a.version.sdkInt})';
        case TargetPlatform.iOS:
          final i = await info.iosInfo;
          return 'iOS ${i.systemVersion}';
        case TargetPlatform.windows:
          final w = await info.windowsInfo;
          return w.productName;
        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  /// Send once per app run. Safe to call from every sign-in path.
  static Future<void> send() async {
    if (_sent) return;
    try {
      final token = await getToken();
      if (token == null || token.isEmpty) return;
      _sent = true;
      String? version;
      try {
        final p = await PackageInfo.fromPlatform();
        version = p.buildNumber.isEmpty
            ? p.version
            : '${p.version}+${p.buildNumber}';
      } catch (_) {}
      final body = jsonEncode({
        'install_id': await _installId(),
        'platform': _platform(),
        'os_version': await _osVersion(),
        'app_version': version,
      });
      final resp = await http
          .post(
            Uri.parse('${await AppConfig.baseUrl}/devices/report'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode >= 400) _sent = false; // try again next start
    } catch (_) {
      _sent = false;
    }
  }
}
