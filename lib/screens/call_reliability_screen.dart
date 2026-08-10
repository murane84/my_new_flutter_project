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

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

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
    bool battery = true;
    try {
      battery = await Permission.ignoreBatteryOptimizations.isGranted;
    } catch (_) {/* older OS */}
    if (!mounted) return;
    setState(() {
      _notifs = notifs;
      _battery = battery;
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
    final res = await askFullScreenIntentPermission();
    if (mounted) setState(() => _fullScreen = res ?? true);
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
}
