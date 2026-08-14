import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';

import 'api_service.dart';
import 'home_page.dart';
import '../services/contact_names.dart';
import '../utils/toast_helper.dart';
import '../utils/popup_shell.dart';

/// A friendly label + platform tag for THIS device (used when it links itself).
({String label, String platform}) _describeThisDevice() {
  if (kIsWeb) return (label: 'Web browser', platform: 'web');
  if (Platform.isWindows) return (label: 'Windows PC', platform: 'windows');
  if (Platform.isMacOS) return (label: 'Mac', platform: 'macos');
  if (Platform.isLinux) return (label: 'Linux PC', platform: 'linux');
  if (Platform.isAndroid) return (label: 'Android device', platform: 'android');
  if (Platform.isIOS) return (label: 'iPhone/iPad', platform: 'ios');
  return (label: 'Computer', platform: 'desktop');
}

// QR payload wrapper so the phone scanner only reacts to Aluta link codes.
const String _linkPrefix = 'aluta://link/';

// ─────────────────────────────────────────────────────────────────────────────
// DESKTOP: show a QR + short code; poll until the phone approves, then sign in.
// ─────────────────────────────────────────────────────────────────────────────

class DesktopQrLoginScreen extends StatefulWidget {
  const DesktopQrLoginScreen({super.key});

  @override
  State<DesktopQrLoginScreen> createState() => _DesktopQrLoginScreenState();
}

enum _QrState { loading, ready, expired, error }

class _DesktopQrLoginScreenState extends State<DesktopQrLoginScreen> {
  _QrState _state = _QrState.loading;
  String _code = '';
  String _pairCode = '';
  Timer? _poll;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    _create();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _create() async {
    _poll?.cancel();
    setState(() => _state = _QrState.loading);
    final me = _describeThisDevice();
    final link = await ApiService()
        .createLoginLink(label: me.label, platform: me.platform);
    if (!mounted) return;
    if (link == null || (link['code'] ?? '').toString().isEmpty) {
      setState(() => _state = _QrState.error);
      return;
    }
    setState(() {
      _code = link['code'].toString();
      _pairCode = (link['pair_code'] ?? '').toString();
      _state = _QrState.ready;
    });
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
  }

  Future<void> _tick() async {
    if (_finishing || _code.isEmpty) return;
    final r = await ApiService().pollLoginLink(_code);
    if (!mounted || r == null) return;
    final status = (r['status'] ?? '').toString();
    if (status == 'approved') {
      _finishing = true;
      _poll?.cancel();
      await _finish(r);
    } else if (status == 'expired') {
      _poll?.cancel();
      setState(() => _state = _QrState.expired);
    }
  }

  Future<void> _finish(Map<String, dynamic> r) async {
    // Tokens were already saved by pollLoginLink(). Persist the session flags,
    // pull this account's saved contact names, then enter the app.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isLoggedIn', true);
    await prefs.setString('username', (r['username'] ?? '').toString());
    // Desktop personalisation: pull the phone-uploaded saved-name map.
    ContactNames.instance.refresh();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      PageRouteBuilder(
        pageBuilder: (ctx, anim, sanim) => const HomePage(),
        transitionsBuilder: (ctx, anim, sanim, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 300),
      ),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Log in with your phone')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Scan this code with the Aluta app on your phone',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface),
                ),
                const SizedBox(height: 6),
                Text(
                  'On your phone: open the menu (⋮) → “Link a computer”, then scan.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12.5, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 22),
                _qrArea(scheme),
                const SizedBox(height: 22),
                if (_state == _QrState.ready) ...[
                  Text('Can’t scan? Enter this code on your phone:',
                      style: TextStyle(
                          fontSize: 12.5, color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 12),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(14),
                      border:
                          Border.all(color: scheme.primary.withAlpha(90)),
                    ),
                    child: Text(
                      _spaced(_pairCode),
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: scheme.primary),
                      ),
                      const SizedBox(width: 10),
                      Text('Waiting for your phone…',
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _qrArea(ColorScheme scheme) {
    switch (_state) {
      case _QrState.loading:
        return const SizedBox(
            height: 240,
            child: Center(child: CircularProgressIndicator()));
      case _QrState.error:
        return _retry(scheme, 'Couldn’t reach the server. Check your connection.');
      case _QrState.expired:
        return _retry(scheme, 'This code expired. Generate a new one.');
      case _QrState.ready:
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: scheme.primary.withAlpha(60)),
          ),
          child: QrImageView(
            data: '$_linkPrefix$_code',
            version: QrVersions.auto,
            size: 220,
            backgroundColor: Colors.white,
            // eyeStyle/dataModuleStyle default to black — high contrast to scan.
          ),
        );
    }
  }

  Widget _retry(ColorScheme scheme, String msg) {
    return SizedBox(
      height: 240,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.qr_code_2_rounded, size: 54, color: scheme.outline),
          const SizedBox(height: 12),
          Text(msg,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _create,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('New code'),
          ),
        ],
      ),
    );
  }

  String _spaced(String s) =>
      s.length == 8 ? '${s.substring(0, 4)} ${s.substring(4)}' : s;
}

// ─────────────────────────────────────────────────────────────────────────────
// MOBILE: scan the desktop QR (or type the code) to authorise the login.
// ─────────────────────────────────────────────────────────────────────────────

class DeviceLinkScanScreen extends StatefulWidget {
  const DeviceLinkScanScreen({super.key});

  @override
  State<DeviceLinkScanScreen> createState() => _DeviceLinkScanScreenState();
}

class _DeviceLinkScanScreenState extends State<DeviceLinkScanScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handling = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handling) return;
    String? raw;
    for (final b in capture.barcodes) {
      final v = b.rawValue;
      if (v != null && v.startsWith(_linkPrefix)) {
        raw = v;
        break;
      }
    }
    if (raw == null) return; // not an Aluta link QR — keep scanning
    final code = raw.substring(_linkPrefix.length);
    _handling = true;
    await _controller.stop();
    await _approve(code: code);
  }

  Future<void> _approve({String? code, String? pairCode}) async {
    final ok =
        await ApiService().approveLoginLink(code: code, pairCode: pairCode);
    if (!mounted) return;
    if (ok) {
      showToast(context, 'Computer linked — you’re signed in there now.',
          type: ToastType.success);
      Navigator.of(context).pop(true);
    } else {
      showToast(context, 'Couldn’t link — the code may have expired.',
          type: ToastType.error);
      _handling = false;
      try {
        await _controller.start();
      } catch (_) {}
    }
  }

  Future<void> _enterManually() async {
    final ctrl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Enter the code'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          maxLength: 9,
          decoration: const InputDecoration(
            hintText: 'e.g. ABCD 2345',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(
                  dctx, ctrl.text.replaceAll(' ', '').trim().toUpperCase()),
              child: const Text('Link')),
        ],
      ),
    );
    if (code != null && code.isNotEmpty) {
      await _approve(pairCode: code);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Link a computer'),
        actions: [
          IconButton(
            tooltip: 'Enter code',
            icon: const Icon(Icons.keyboard_rounded),
            onPressed: _enterManually,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                MobileScanner(
                  controller: _controller,
                  onDetect: _onDetect,
                ),
                // Simple viewfinder frame.
                Container(
                  width: 240,
                  height: 240,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white, width: 3),
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              children: [
                const Text(
                  'Point your camera at the QR code shown on the computer.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                TextButton.icon(
                  onPressed: _enterManually,
                  icon: const Icon(Icons.keyboard_rounded),
                  label: const Text('Enter code manually'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Linked devices — list the account's active sessions and sign them out.
// ─────────────────────────────────────────────────────────────────────────────

class LinkedDevicesScreen extends StatefulWidget {
  const LinkedDevicesScreen({super.key});

  @override
  State<LinkedDevicesScreen> createState() => _LinkedDevicesScreenState();
}

class _LinkedDevicesScreenState extends State<LinkedDevicesScreen> {
  List<Map<String, dynamic>> _devices = [];
  bool _loading = true;
  final Set<int> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await ApiService().listDevices();
    if (!mounted) return;
    setState(() {
      _devices = list;
      _loading = false;
    });
  }

  IconData _iconFor(String platform) {
    switch (platform) {
      case 'windows':
      case 'linux':
        return Icons.desktop_windows_rounded;
      case 'macos':
        return Icons.laptop_mac_rounded;
      case 'web':
        return Icons.public_rounded;
      case 'android':
      case 'ios':
        return Icons.smartphone_rounded;
      default:
        return Icons.devices_rounded;
    }
  }

  String _lastSeen(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final t = DateTime.tryParse(iso);
    if (t == null) return '';
    final local = t.toLocal();
    final now = DateTime.now();
    final diff = now.difference(local);
    if (diff.inMinutes < 1) return 'Active now';
    if (diff.inMinutes < 60) return 'Active ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'Active ${diff.inHours}h ago';
    return 'Last active ${DateFormat('MMM d, HH:mm').format(local)}';
  }

  Future<void> _revoke(Map<String, dynamic> d) async {
    final id = (d['id'] as num?)?.toInt();
    if (id == null) return;
    final isCurrent = d['current'] == true;
    final yes = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(isCurrent ? 'Sign out this device?' : 'Remove device?'),
        content: Text(isCurrent
            ? 'This is the device you are using now. It will be signed out.'
            : 'This device will be signed out of your account immediately.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: const Text('Sign out')),
        ],
      ),
    );
    if (yes != true) return;
    setState(() => _busy.add(id));
    final ok = await ApiService().revokeDevice(id);
    if (!mounted) return;
    setState(() => _busy.remove(id));
    if (ok) {
      showToast(context, 'Device signed out', type: ToastType.success);
      _load();
    } else {
      showToast(context, 'Could not sign out that device',
          type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppPopupShell(
      title: 'Linked devices',
      icon: Icons.devices_rounded,
      headerAction: IconButton(
        tooltip: 'Refresh',
        icon: const Icon(Icons.refresh_rounded),
        onPressed: _loading ? null : _load,
      ),
      builder: (context, isWide) => _body(scheme),
    );
  }

  Widget _body(ColorScheme scheme) {
    if (_loading) {
      return const SizedBox(
          height: 220, child: Center(child: CircularProgressIndicator()));
    }
    if (_devices.isEmpty) {
      return SizedBox(
        height: 300,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.devices_other_rounded,
                    size: 56, color: scheme.outlineVariant),
                const SizedBox(height: 12),
                Text('No linked computers',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text(
                  'Log in on a computer by scanning its QR from the '
                  'menu → “Link a computer”.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        shrinkWrap: true,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _devices.length,
        separatorBuilder: (_, _) => Divider(
            height: 1, color: scheme.outlineVariant.withAlpha(70)),
        itemBuilder: (_, i) {
          final d = _devices[i];
          final id = (d['id'] as num?)?.toInt() ?? -1;
          final platform = (d['platform'] ?? '').toString();
          final isCurrent = d['current'] == true;
          final label = (d['label'] ?? 'Device').toString();
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              child: Icon(_iconFor(platform),
                  color: scheme.onPrimaryContainer),
            ),
            title: Row(
              children: [
                Flexible(
                    child: Text(label,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600))),
                if (isCurrent) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: scheme.primary.withAlpha(30),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('This device',
                        style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: scheme.primary)),
                  ),
                ],
              ],
            ),
            subtitle: Text(_lastSeen(d['last_seen_at']?.toString()),
                style: TextStyle(
                    fontSize: 12, color: scheme.onSurfaceVariant)),
            trailing: _busy.contains(id)
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : IconButton(
                    tooltip: 'Sign out',
                    icon: Icon(Icons.logout_rounded,
                        color: scheme.error),
                    onPressed: () => _revoke(d),
                  ),
          );
        },
      ),
    );
  }
}
