import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'api_service.dart';
import '../utils/toast_helper.dart';

/// Set up (or turn off) authenticator-based two-factor, which doubles as the
/// password-recovery method. Enrollment is a two-step handshake:
///   1. /setup hands out a secret shown as a QR (scan into Google Authenticator)
///   2. /verify confirms the first 6-digit code and flips 2FA on
/// Once on, a forgotten password can be reset from the login screen using a
/// current authenticator code.
class TwoFactorSetupScreen extends StatefulWidget {
  const TwoFactorSetupScreen({super.key});

  @override
  State<TwoFactorSetupScreen> createState() => _TwoFactorSetupScreenState();
}

class _TwoFactorSetupScreenState extends State<TwoFactorSetupScreen> {
  bool _loading = true;
  bool _busy = false;
  bool _enabled = false;

  // Enrollment-in-progress state (after /setup, before /verify).
  String? _secret;
  String? _otpauthUri;

  final _code = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _loadStatus() async {
    final on = await ApiService().twoFactorStatus();
    if (!mounted) return;
    setState(() {
      _enabled = on;
      _loading = false;
    });
  }

  Future<void> _beginSetup() async {
    setState(() => _busy = true);
    final res = await ApiService().twoFactorSetup();
    if (!mounted) return;
    setState(() => _busy = false);
    if (res['success'] == true) {
      setState(() {
        _secret = (res['secret'] ?? '').toString();
        _otpauthUri = (res['otpauth_uri'] ?? '').toString();
      });
    } else {
      showToast(context, res['message'] ?? 'Could not start setup.',
          type: ToastType.error);
    }
  }

  Future<void> _verify() async {
    final code = _code.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (code.length < 6) {
      showToast(context, 'Enter the 6-digit code from your app.',
          type: ToastType.error);
      return;
    }
    setState(() => _busy = true);
    final res = await ApiService().twoFactorVerify(code);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res['success'] == true) {
      setState(() {
        _enabled = true;
        _secret = null;
        _otpauthUri = null;
        _code.clear();
      });
      showToast(context, 'Two-factor is on. You can now recover your password.',
          type: ToastType.success);
    } else {
      showToast(context, res['message'] ?? 'Invalid or expired code.',
          type: ToastType.error);
    }
  }

  Future<void> _disable() async {
    final proof = await _askDisableProof();
    if (proof == null) return; // cancelled
    setState(() => _busy = true);
    final res = await ApiService().twoFactorDisable(
      code: proof['code'],
      password: proof['password'],
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (res['success'] == true) {
      setState(() => _enabled = false);
      showToast(context, 'Two-factor turned off.', type: ToastType.info);
    } else {
      showToast(context, res['message'] ?? 'Could not turn off 2FA.',
          type: ToastType.error);
    }
  }

  /// Ask for a current authenticator code OR the account password to turn 2FA
  /// off. Returns {'code': ...} or {'password': ...}, or null if cancelled.
  Future<Map<String, String?>?> _askDisableProof() async {
    final codeCtrl = TextEditingController();
    final pwCtrl = TextEditingController();
    return showDialog<Map<String, String?>>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: const Text('Turn off two-factor?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Confirm with a current authenticator code, or your account '
                'password. Turning this off removes your password-recovery '
                'option.',
                style: TextStyle(
                    fontSize: 13, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: codeCtrl,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: 'Authenticator code',
                  counterText: '',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Text('— or —',
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 8),
              TextField(
                controller: pwCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Account password',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final code = codeCtrl.text.replaceAll(RegExp(r'[^0-9]'), '');
                final pw = pwCtrl.text;
                if (code.isEmpty && pw.isEmpty) {
                  Navigator.pop(ctx);
                  return;
                }
                Navigator.pop(ctx, {
                  'code': code.isEmpty ? null : code,
                  'password': pw.isEmpty ? null : pw,
                });
              },
              child: const Text('Turn off'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Two-factor authentication')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                child: _enabled
                    ? _enabledView(scheme)
                    : _secret == null
                        ? _introView(scheme)
                        : _enrollView(scheme),
              ),
      ),
    );
  }

  // ── 2FA already on ──────────────────────────────────────────────────────
  Widget _enabledView(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.green.withAlpha(28),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.green.withAlpha(90)),
          ),
          child: Row(
            children: [
              const Icon(Icons.verified_user_rounded,
                  color: Colors.green, size: 26),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Two-factor is on. If you ever forget your password, tap '
                  '"Forgot password?" on the sign-in screen and enter a code '
                  'from your authenticator app.',
                  style: TextStyle(
                      fontSize: 13, color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: _busy ? null : _disable,
          icon: const Icon(Icons.no_encryption_gmailerrorred_outlined),
          label: const Text('Turn off two-factor'),
          style: OutlinedButton.styleFrom(
            foregroundColor: scheme.error,
            side: BorderSide(color: scheme.error.withAlpha(120)),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ],
    );
  }

  // ── Intro (not set up yet) ──────────────────────────────────────────────
  Widget _introView(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.shield_moon_outlined, size: 56, color: scheme.primary),
        const SizedBox(height: 16),
        const Text(
          'Protect your account',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        Text(
          'Link Google Authenticator (or any TOTP app) to Aluta. It gives you '
          'a way back in if you ever forget your password — you\'ll just enter '
          'a 6-digit code from the app.',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 13.5, height: 1.45, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 28),
        SizedBox(
          height: 50,
          child: FilledButton.icon(
            onPressed: _busy ? null : _beginSetup,
            icon: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5, color: Colors.white),
                  )
                : const Icon(Icons.qr_code_2_rounded),
            label: const Text('Set up authenticator'),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Enrollment (QR + verify) ────────────────────────────────────────────
  Widget _enrollView(ColorScheme scheme) {
    final uri = _otpauthUri ?? '';
    final secret = _secret ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '1. Scan this QR in Google Authenticator',
          style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface),
        ),
        const SizedBox(height: 14),
        Center(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: scheme.primary.withAlpha(60)),
            ),
            child: uri.isEmpty
                ? const SizedBox(
                    width: 200,
                    height: 200,
                    child: Center(child: Text('QR unavailable')),
                  )
                : QrImageView(
                    data: uri,
                    version: QrVersions.auto,
                    size: 200,
                    backgroundColor: Colors.white,
                  ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Can\'t scan? Enter this key manually:',
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        InkWell(
          onTap: () {
            Clipboard.setData(ClipboardData(text: secret));
            showToast(context, 'Setup key copied', type: ToastType.info);
          },
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withAlpha(120),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(
                    secret,
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        letterSpacing: 1.2),
                  ),
                ),
                Icon(Icons.copy_rounded,
                    size: 18, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          '2. Enter the 6-digit code it shows',
          style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _code,
          keyboardType: TextInputType.number,
          maxLength: 6,
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 22, letterSpacing: 8, fontWeight: FontWeight.w600),
          decoration: const InputDecoration(
            hintText: '000000',
            counterText: '',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          height: 50,
          child: FilledButton(
            onPressed: _busy ? null : _verify,
            style: FilledButton.styleFrom(
              backgroundColor: scheme.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: _busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5, color: Colors.white),
                  )
                : const Text('Verify & turn on',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _secret = null;
                    _otpauthUri = null;
                    _code.clear();
                  }),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
