import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api_service.dart';
import '../utils/toast_helper.dart';

/// Link (or unlink) an Ozilane Key phone to this Aluta account.
///
/// Linking lets the user recover a forgotten password — or sign in with no
/// password at all — by approving on their phone, with offline codes and backup
/// codes as fallbacks. The pairing QR carries the Ozilane pairing URL (which the
/// Ozilane Key app scans); on the same device, "Open in Ozilane Key" fires the
/// ozkey:// deep link instead.
class LinkOzilaneScreen extends StatefulWidget {
  const LinkOzilaneScreen({super.key});

  @override
  State<LinkOzilaneScreen> createState() => _LinkOzilaneScreenState();
}

class _LinkOzilaneScreenState extends State<LinkOzilaneScreen> {
  final _api = ApiService();
  final _backup = TextEditingController();

  // loading | unavailable | notLinked | pairing | linked
  String _state = 'loading';
  bool _busy = false;
  bool _needProof = false; // account had a phone → a backup code is required

  Map<String, dynamic> _status = const {};
  String? _enrollmentId;
  String? _pairingUrl; // https://auth.ozilane.com/app/pair#… (QR + scan)
  String? _pairingUri; // ozkey://pair?… (same-device deep link)
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _backup.dispose();
    super.dispose();
  }

  Future<void> _loadStatus() async {
    final s = await _api.ozilaneStatus();
    if (!mounted) return;
    setState(() {
      _status = s;
      if (s['configured'] == false) {
        _state = 'unavailable';
      } else if (s['enrolled'] == true) {
        _state = 'linked';
      } else {
        _state = 'notLinked';
      }
    });
  }

  Future<void> _startLink() async {
    setState(() => _busy = true);
    final res = await _api.ozilaneLinkStart(
        backupCode: _needProof ? _backup.text.trim() : null);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res['success'] == true) {
      setState(() {
        _enrollmentId = res['enrollmentId']?.toString();
        _pairingUrl = res['pairingUrl']?.toString();
        _pairingUri = res['pairingUri']?.toString();
        _needProof = false;
        _state = 'pairing';
      });
      _startPolling();
    } else {
      final msg = (res['message'] ?? 'Could not start linking.').toString();
      // An account that has had a phone needs a backup code to re-link.
      if (msg.toLowerCase().contains('backup code') ||
          msg.toLowerCase().contains('already had a phone')) {
        setState(() => _needProof = true);
      }
      showToast(context, msg, type: ToastType.error);
    }
  }

  void _startPolling() {
    _poll?.cancel();
    final id = _enrollmentId;
    if (id == null) return;
    _poll = Timer.periodic(const Duration(seconds: 3), (t) async {
      final r = await _api.ozilaneLinkStatus(id);
      if (!mounted) return;
      final st = (r['status'] ?? '').toString();
      if (st == 'ACTIVE') {
        t.cancel();
        showToast(context, 'Phone linked 🎉', type: ToastType.success);
        await _loadStatus();
      } else if (st == 'EXPIRED' || st == 'REVOKED') {
        t.cancel();
        if (!mounted) return;
        setState(() => _state = 'notLinked');
        showToast(context, 'That pairing expired — try again.',
            type: ToastType.info);
      }
    });
  }

  Future<void> _openInApp() async {
    final link = _pairingUri ?? _pairingUrl;
    if (link == null) return;
    try {
      final ok = await launchUrl(Uri.parse(link),
          mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        showToast(context, 'No Ozilane Key app found on this device.',
            type: ToastType.info);
      }
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not open Ozilane Key.',
            type: ToastType.error);
      }
    }
  }

  Future<void> _unlink() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unlink this phone?'),
        content: const Text(
            'You will no longer be able to approve password resets or sign in '
            'from this phone until you link it again.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Unlink')),
        ],
      ),
    );
    if (yes != true) return;
    setState(() => _busy = true);
    final ok = await _api.ozilaneUnlink();
    if (!mounted) return;
    setState(() => _busy = false);
    showToast(context, ok ? 'Phone unlinked.' : 'Could not unlink.',
        type: ok ? ToastType.success : ToastType.error);
    if (ok) _loadStatus();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Ozilane Key')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          child: switch (_state) {
            'loading' => const Padding(
                padding: EdgeInsets.only(top: 80),
                child: Center(child: CircularProgressIndicator()),
              ),
            'unavailable' => _unavailableView(scheme),
            'linked' => _linkedView(scheme),
            'pairing' => _pairingView(scheme),
            _ => _notLinkedView(scheme),
          },
        ),
      ),
    );
  }

  Widget _intro(ColorScheme scheme, IconData icon, String title, String body) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(icon, size: 54, color: scheme.primary),
        const SizedBox(height: 14),
        Text(title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Text(body,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 13.5, height: 1.45, color: scheme.onSurfaceVariant)),
      ],
    );
  }

  Widget _unavailableView(ColorScheme scheme) => _intro(
        scheme,
        Icons.info_outline_rounded,
        'Not available yet',
        'Ozilane Key sign-in isn\'t set up on the server yet. You can still '
            'recover your password by email or authenticator code.',
      );

  Widget _notLinkedView(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _intro(
          scheme,
          Icons.phonelink_lock_rounded,
          'Link your phone',
          'Link Ozilane Key so you can reset a forgotten password — or sign in '
              'with no password — just by approving on your phone. It also gives '
              'you offline codes and backup codes if you ever lose signal.',
        ),
        const SizedBox(height: 24),
        if (_needProof) ...[
          Text('This account had a phone before. Enter one of your backup '
              'codes to link a new one:',
              style: TextStyle(
                  fontSize: 12.5, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 10),
          TextField(
            controller: _backup,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Backup code',
              hintText: 'K7QM2-XW9TB',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
        ],
        SizedBox(
          height: 50,
          child: FilledButton.icon(
            onPressed: _busy ? null : _startLink,
            icon: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5, color: Colors.white))
                : const Icon(Icons.qr_code_2_rounded),
            label: Text(_needProof ? 'Link with backup code' : 'Link a phone'),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.primary,
              foregroundColor: Colors.white,
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _pairingView(ColorScheme scheme) {
    final url = _pairingUrl ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Scan with Ozilane Key',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface)),
        const SizedBox(height: 6),
        Text('Open Ozilane Key on your phone, tap Scan, and point it here.',
            style:
                TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 16),
        Center(
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: scheme.primary.withAlpha(60)),
            ),
            child: url.isEmpty
                ? const SizedBox(
                    width: 220,
                    height: 220,
                    child: Center(child: Text('QR unavailable')))
                : QrImageView(
                    data: url,
                    version: QrVersions.auto,
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                    size: 220,
                    backgroundColor: Colors.white,
                  ),
          ),
        ),
        const SizedBox(height: 18),
        OutlinedButton.icon(
          onPressed: _openInApp,
          icon: const Icon(Icons.open_in_new_rounded, size: 18),
          label: const Text('Open in Ozilane Key (this device)'),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: url.isEmpty
              ? null
              : () {
                  Clipboard.setData(ClipboardData(text: url));
                  showToast(context, 'Pairing link copied',
                      type: ToastType.info);
                },
          icon: const Icon(Icons.link_rounded, size: 18),
          label: const Text('Copy pairing link'),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2.2)),
            const SizedBox(width: 12),
            Text('Waiting for your phone…',
                style:
                    TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ],
        ),
        const SizedBox(height: 14),
        Center(
          child: TextButton(
            onPressed: () {
              _poll?.cancel();
              setState(() => _state = 'notLinked');
            },
            child: const Text('Cancel'),
          ),
        ),
      ],
    );
  }

  Widget _linkedView(ColorScheme scheme) {
    final label = (_status['deviceLabel'] ?? 'Your phone').toString();
    final codesLeft = (_status['backupCodesLeft'] as num?)?.toInt();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.verified_user_rounded,
                color: Colors.green, size: 30),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Phone linked',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  Text(label,
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.primary.withAlpha(16),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: scheme.primary.withAlpha(50)),
          ),
          child: Text(
            'You can now reset your password or sign in by approving on this '
            'phone. On the sign-in screen, tap "Approve on Ozilane Key".'
            '${codesLeft != null ? '\n\nBackup codes left: $codesLeft' : ''}',
            style: TextStyle(
                fontSize: 13, height: 1.4, color: scheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 22),
        OutlinedButton.icon(
          onPressed: _busy ? null : _unlink,
          style: OutlinedButton.styleFrom(
            foregroundColor: scheme.error,
            side: BorderSide(color: scheme.error.withAlpha(120)),
          ),
          icon: const Icon(Icons.link_off_rounded, size: 18),
          label: const Text('Unlink this phone'),
        ),
      ],
    );
  }
}
