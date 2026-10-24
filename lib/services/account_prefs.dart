import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../screens/api_service.dart';

/// Look-and-feel preferences that follow the ACCOUNT (reinstall / new phone):
/// theme mode + accent, message-bubble colours, Moments & nudges toggles,
/// message tones / typing ticks, status videos on Wi-Fi only.
///
/// The phone's own copy always paints first; [sync] runs in the background
/// after sign-in and only then (if the account copy is newer) rewrites the
/// local prefs and asks each owner to reload. Newest change wins. Owners call
/// [touch] after saving, which uploads ~3 s after the last change.
/// (Chat wallpapers have their own copy — see utils/chat_background.dart.)
class AccountPrefs {
  AccountPrefs._();

  static const String _settingKey = 'app_prefs';
  static const String _kRev = 'account_prefs_rev_v1';

  /// The synced SharedPreferences keys (values copied as-is, type kept).
  static const List<String> keys = [
    // ThemeProvider
    'themeModeStr', 'isDarkMode', 'accentColor',
    // utils/bubble_theme.dart
    'bubble_custom_v1', 'bubble_sent_color_v1', 'bubble_recv_color_v1',
    // services/moment_prefs.dart
    'moments_welcome_on', 'moments_rituals_on', 'glow_daily_on',
    // services/keystroke_sounds.dart
    'keystroke_sounds', 'message_tones',
    // Appearance → status videos
    'status_dl_videos_wifi',
  ];

  static final List<FutureOr<void> Function()> _reloaders = [];
  static Timer? _push;
  static bool _restoring = false;

  /// Run [fn] after a newer account copy was written into local prefs, so
  /// the owner re-reads its values.
  static void onRestore(FutureOr<void> Function() fn) => _reloaders.add(fn);

  /// A synced preference just changed locally → upload soon.
  static void touch() {
    if (_restoring) return;
    final rev = DateTime.now().millisecondsSinceEpoch;
    SharedPreferences.getInstance()
        .then((p) => p.setInt(_kRev, rev))
        .catchError((_) => false);
    _push?.cancel();
    _push = Timer(const Duration(seconds: 3), () => _upload(rev));
  }

  static Future<Map<String, dynamic>> _snapshot() async {
    final p = await SharedPreferences.getInstance();
    final out = <String, dynamic>{};
    for (final k in keys) {
      final v = p.get(k);
      if (v is bool) {
        out[k] = {'t': 'b', 'v': v};
      } else if (v is int) {
        out[k] = {'t': 'i', 'v': v};
      } else if (v is double) {
        out[k] = {'t': 'd', 'v': v};
      } else if (v is String) {
        out[k] = {'t': 's', 'v': v};
      }
    }
    return out;
  }

  static Future<void> _upload(int rev) async {
    try {
      await ApiService().putSetting(_settingKey, rev, await _snapshot());
    } catch (_) {}
  }

  /// Reconcile with the account copy (unawaited, after sign-in).
  static Future<void> sync() async {
    try {
      final p = await SharedPreferences.getInstance();
      final localRev = p.getInt(_kRev) ?? 0;
      final remote = await ApiService().getSetting(_settingKey);
      if (remote == null) return; // offline — next launch
      final data = remote.data;
      if (remote.rev > localRev && data is Map) {
        _restoring = true;
        try {
          for (final e in data.entries) {
            final k = e.key.toString();
            final box = e.value;
            if (!keys.contains(k) || box is! Map) continue;
            final v = box['v'];
            switch (box['t']) {
              case 'b':
                if (v is bool) await p.setBool(k, v);
              case 'i':
                if (v is num) await p.setInt(k, v.toInt());
              case 'd':
                if (v is num) await p.setDouble(k, v.toDouble());
              case 's':
                if (v is String) await p.setString(k, v);
            }
          }
          await p.setInt(_kRev, remote.rev);
          for (final fn in _reloaders) {
            try {
              await fn();
            } catch (_) {}
          }
        } finally {
          _restoring = false;
        }
      } else if (localRev > remote.rev) {
        await _upload(localRev);
      } else if (localRev == 0 && remote.rev == 0) {
        // Set up before account backup existed → back it up once now, if
        // anything was actually customised.
        final snap = await _snapshot();
        if (snap.isNotEmpty) {
          final rev = DateTime.now().millisecondsSinceEpoch;
          await p.setInt(_kRev, rev);
          await _upload(rev);
        }
      }
    } catch (_) {}
  }
}
