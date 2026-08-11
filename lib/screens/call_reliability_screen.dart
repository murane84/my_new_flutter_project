import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/notif_service.dart';

/// "Call reliability" — a mobile setup screen that walks the user through the
/// three OS permissions an incoming Aluta call needs in order to actually ring
/// and wake the phone when the app is closed:
///
///   1. Notifications enabled (POST_NOTIFICATIONS, Android 13+).
///   2. Ring over the lock screen (USE_FULL_SCREEN_INTENT, Android 14+).
///   3. No battery optimization (so aggressive OEMs don't defer/kill the
///      high-priority call push).
///
/// Each is shown with its current status and a one-tap fix. Android only —
/// on other platforms it explains that calls ring natively there.
class CallReliabilityScreen extends StatefulWidget {
  const CallReliabilityScreen({super.key});

  @override
  State<CallReliabilityScreen> createState() => _CallReliabilityScreenState();
}

class _CallReliabilityScreenState extends State<CallReliabilityScreen>
    with WidgetsBindingObserver {
  bool _notifs = true;
  bool? _fullScreen; // null = unknown (older OS / can't query)
  bool _battery = true;
  bool _loading = true;
  String _manufacturer = '';

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  // Manufacturers that aggressively block background launch / full-screen call
  // intents and need extra OEM toggles (Autostart, pop-up permission) the app
  // can only deep-link to — the user must flip them.
  bool get _needsOemSteps {
    const oems = [
      'xiaomi', 'redmi', 'poco', 'oppo', 'realme', 'oneplus', 'vivo', 'iqoo',
      'huawei', 'honor', 'tecno', 'infinix', 'itel', 'transsion', 'meizu',
      'asus', 'letv', 'samsung',
    ];
    return _isAndroid && oems.any(_manufacturer.contains);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check after the user comes back from a system settings screen.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    if (!_isAndroid) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final notifs = await notificationsEnabled();
    // Real OS query (via the native channel) — so this tile reflects the actual
    // grant and stops falsely reverting to "Enable" every time the screen opens.
    final fullScreen = await fullScreenIntentAllowed();
    final maker = await deviceManufacturer();
    bool battery = true;
    try {
      battery = await Permission.ignoreBatteryOptimizations.isGranted;
    } catch (_) {/* older OS */}
    if (!mounted) return;
    setState(() {
      _notifs = notifs;
      _fullScreen = fullScreen;
      _battery = battery;
      _manufacturer = maker;
      _loading = false;
    });
  }

  Future<void> _fixNotifications() async {
    await askNotificationsPermission();
    final ok = await notificationsEnabled();
    if (!ok) {
      // Permission likely permanently denied — send them to app settings.
      await openAppSettings();
    }
    await _refresh();
  }

  Future<void> _fixFullScreen() async {
    // Opens the system "Full-screen intents" settings page. When the user
    // returns, didChangeAppLifecycleState(resumed) → _refresh() re-reads the
    // real grant, so the tile reflects what they actually did (no false tick).
    await askFullScreenIntentPermission();
    await _refresh();
  }

  Future<void> _fixBattery() async {
    try {
      await Permission.ignoreBatteryOptimizations.request();
    } catch (_) {/* older OS — nothing to do */}
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Call reliability'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : !_isAndroid
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      'Incoming calls ring natively on this platform — this '
                      'setup is only needed on Android phones.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      'For Aluta calls to ring and wake your phone even when '
                      'the app is closed, enable all three below. Some phones '
                      '(Xiaomi, Oppo, Tecno, Infinix, Samsung…) also need '
                      'Aluta added to "Autostart" in their own settings.',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 16),
                    _tile(
                      scheme,
                      icon: Icons.notifications_active_rounded,
                      title: 'Notifications',
                      subtitle:
                          'Allow Aluta to show call and message notifications.',
                      ok: _notifs,
                      onFix: _fixNotifications,
                    ),
                    _tile(
                      scheme,
                      icon: Icons.phonelink_ring_rounded,
                      title: 'Ring over the lock screen',
                      subtitle:
                          'Show the full-screen incoming-call screen even when '
                          'the phone is locked (Android 14+).',
                      ok: _fullScreen,
                      onFix: _fixFullScreen,
                    ),
                    _tile(
                      scheme,
                      icon: Icons.battery_saver_rounded,
                      title: 'Ignore battery optimization',
                      subtitle:
                          'Stop the system from delaying or blocking incoming '
                          'call alerts to save power.',
                      ok: _battery,
                      onFix: _fixBattery,
                    ),
                    // OEM-specific steps (Xiaomi/Oppo/Vivo/Tecno…). These can't
                    // be checked or toggled by the app — only deep-linked — so
                    // they're guided "open settings" actions, not status tiles.
                    if (_needsOemSteps) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Your phone (${_manufacturer.isEmpty ? 'this brand' : _manufacturer}) '
                        'needs two extra toggles turned on by hand for calls to '
                        'ring when Aluta is closed:',
                        style: TextStyle(
                            color: scheme.onSurfaceVariant, fontSize: 12.5),
                      ),
                      const SizedBox(height: 10),
                      _oemTile(
                        scheme,
                        icon: Icons.rocket_launch_rounded,
                        title: 'Autostart',
                        subtitle:
                            'Let Aluta start on its own so a call can wake it. '
                            'Opens your phone’s Autostart list — find Aluta '
                            'and turn it ON.',
                        onOpen: openAutostartSettings,
                      ),
                      _oemTile(
                        scheme,
                        icon: Icons.open_in_new_rounded,
                        title: 'Show over lock screen / pop-up',
                        subtitle:
                            'Allow Aluta to display over the lock screen while in '
                            'the background. Opens the permission screen — enable '
                            '“Display pop-up windows while running in the '
                            'background” (and “Show on lock screen”).',
                        onOpen: openPopupPermissionSettings,
                      ),
                    ],
                    const SizedBox(height: 8),
                    Center(
                      child: TextButton.icon(
                        onPressed: _refresh,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Re-check'),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _tile(
    ColorScheme scheme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool? ok,
    required VoidCallback onFix,
  }) {
    // ok == null → unknown status (show a neutral "Enable" action).
    final isOk = ok == true;
    final statusColor = isOk
        ? Colors.green
        : (ok == null ? scheme.onSurfaceVariant : scheme.error);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: scheme.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 15),
                        ),
                      ),
                      Icon(
                        isOk
                            ? Icons.check_circle_rounded
                            : Icons.error_outline_rounded,
                        size: 18,
                        color: statusColor,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                        color: scheme.onSurfaceVariant, fontSize: 13),
                  ),
                  if (!isOk)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: onFix,
                        child: Text(ok == null ? 'Enable' : 'Fix'),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // A guided OEM step: no status (the app can't read OEM toggles), just an
  // "Open settings" action that deep-links to the right screen.
  Widget _oemTile(
    ColorScheme scheme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Future<void> Function() onOpen,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: scheme.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                        color: scheme.onSurfaceVariant, fontSize: 13),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => onOpen(),
                      icon: const Icon(Icons.settings_rounded, size: 16),
                      label: const Text('Open settings'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
