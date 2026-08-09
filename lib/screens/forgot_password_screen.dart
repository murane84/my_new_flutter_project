import 'dart:async';
import 'package:flutter/material.dart';

import 'api_service.dart';
import '../utils/toast_helper.dart';

/// Recover a forgotten password two ways:
///   • Email code  — the backend emails a 6-digit code (works for everyone).
///   • Authenticator — a current Google Authenticator (TOTP) code (only for
///     users who enrolled 2FA in Profile → Security).
/// Both end the same way: enter the code + a new password.
enum _Method { email, authenticator }

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _newPw = TextEditingController();
  final _confirmPw = TextEditingController();

  _Method _method = _Method.email;
  bool _busy = false; // reset submit in progress
  bool _sending = false; // send-code request in progress
  bool _codeSent = false; // an email code has been sent at least once
  bool _obscure = true;
  int _resendIn = 0; // cooldown seconds before another send is allowed
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _email.dispose();
    _code.dispose();
    _newPw.dispose();
    _confirmPw.dispose();
    super.dispose();
  }

  bool get _emailLooksValid {
    final e = _email.text.trim();
    return e.isNotEmpty && e.contains('@') && e.contains('.');
  }

  void _startCooldown() {
    _timer?.cancel();
    setState(() => _resendIn = 30);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _resendIn = _resendIn <= 1 ? 0 : _resendIn - 1);
      if (_resendIn == 0) t.cancel();
    });
  }

  Future<void> _sendCode() async {
    if (!_emailLooksValid) {
      showToast(context, 'Enter your email first.', type: ToastType.error);
      return;
    }
    setState(() => _sending = true);
    final res = await ApiService().requestEmailResetCode(_email.text.trim());
    if (!mounted) return;
    setState(() {
      _sending = false;
      _codeSent = true;
    });
    _startCooldown();
    showToast(
      context,
      res['message'] ?? 'If that email is registered, a code was sent.',
      type: ToastType.success,
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_method == _Method.email && !_codeSent) {
      showToast(context, 'Tap "Send code" first.', type: ToastType.error);
      return;
    }
    setState(() => _busy = true);
    final Map<String, dynamic> res;
    if (_method == _Method.email) {
      res = await ApiService().resetPasswordWithEmailCode(
        email: _email.text.trim(),
        code: _code.text.trim(),
        newPassword: _newPw.text,
      );
    } else {
      res = await ApiService().resetPasswordWithTotp(
        email: _email.text.trim(),
        code: _code.text.trim(),
        newPassword: _newPw.text,
      );
    }
    if (!mounted) return;
    setState(() => _busy = false);

    if (res['success'] == true) {
      showToast(context, 'Password updated. Sign in with your new password.',
          type: ToastType.success);
      Navigator.pop(context, _email.text.trim()); // pre-fill login email
    } else {
      showToast(context, res['message'] ?? 'Could not reset password.',
          type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final emailMode = _method == _Method.email;
    // In email mode the code + password fields appear after a code is sent; in
    // authenticator mode they're always shown.
    final showResetFields = !emailMode || _codeSent;

    return Scaffold(
      appBar: AppBar(title: const Text('Reset password')),
      body: SafeArea(
        child: Stack(
          children: [
            // Faint, centred logo watermark sitting behind the form. Purely
            // decorative — IgnorePointer so it never intercepts taps, and low
            // opacity so it reads as a watermark, not content.
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: Opacity(
                    opacity: 0.06,
                    child: Image.asset(
                      'assets/images/logo.png',
                      width: MediaQuery.of(context).size.width * 0.6,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
            ),
            SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Method picker
                SegmentedButton<_Method>(
                  segments: const [
                    ButtonSegment(
                      value: _Method.email,
                      icon: Icon(Icons.email_outlined),
                      label: Text('Email code'),
                    ),
                    ButtonSegment(
                      value: _Method.authenticator,
                      icon: Icon(Icons.shield_outlined),
                      label: Text('Authenticator'),
                    ),
                  ],
                  selected: {_method},
                  onSelectionChanged: (s) => setState(() {
                    _method = s.first;
                    _code.clear();
                    // Leaving/entering email mode resets the send step.
                    _codeSent = false;
                    _timer?.cancel();
                    _resendIn = 0;
                  }),
                ),
                const SizedBox(height: 18),

                // Explainer
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: scheme.primary.withAlpha(20),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: scheme.primary.withAlpha(60)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                          emailMode
                              ? Icons.mark_email_read_outlined
                              : Icons.shield_outlined,
                          color: scheme.primary,
                          size: 22),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          emailMode
                              ? 'We\'ll email a 6-digit code to your registered '
                                  'address. Enter it below with a new password.'
                              : 'Enter the current 6-digit code from your Google '
                                  'Authenticator app. This only works if you set '
                                  'up two-factor earlier (Profile → Security).',
                          style: TextStyle(
                              fontSize: 12.5,
                              height: 1.4,
                              color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),

                // Email (always)
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  onChanged: (_) => setState(() {}), // refresh Send-code enable
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    prefixIcon: Icon(Icons.email_outlined),
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Enter your email'
                      : null,
                ),

                // Email mode: Send / Resend code
                if (emailMode) ...[
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 46,
                    child: OutlinedButton.icon(
                      onPressed: (_sending || _resendIn > 0 || !_emailLooksValid)
                          ? null
                          : _sendCode,
                      icon: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2.4),
                            )
                          : Icon(_codeSent
                              ? Icons.refresh_rounded
                              : Icons.send_rounded),
                      label: Text(
                        _resendIn > 0
                            ? 'Resend in ${_resendIn}s'
                            : _codeSent
                                ? 'Resend code'
                                : 'Send code',
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: scheme.primary,
                        side: BorderSide(color: scheme.primary.withAlpha(120)),
                      ),
                    ),
                  ),
                ],

                // Code + new password (after code sent, or always for TOTP)
                if (showResetFields) ...[
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _code,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.next,
                    maxLength: 6,
                    decoration: InputDecoration(
                      labelText: emailMode
                          ? 'Email code'
                          : 'Authenticator code',
                      hintText: '6-digit code',
                      prefixIcon: const Icon(Icons.pin_outlined),
                      border: const OutlineInputBorder(),
                      counterText: '',
                    ),
                    validator: (v) {
                      final digits =
                          (v ?? '').replaceAll(RegExp(r'[^0-9]'), '');
                      return digits.length < 6
                          ? 'Enter the 6-digit code'
                          : null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _newPw,
                    obscureText: _obscure,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: 'New password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(_obscure
                            ? Icons.visibility_off
                            : Icons.visibility),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                    validator: (v) => (v == null || v.length < 6)
                        ? 'At least 6 characters'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _confirmPw,
                    obscureText: _obscure,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _busy ? null : _submit(),
                    decoration: const InputDecoration(
                      labelText: 'Confirm new password',
                      prefixIcon: Icon(Icons.lock_outline),
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        v != _newPw.text ? 'Passwords don\'t match' : null,
                  ),
                  const SizedBox(height: 26),
                  SizedBox(
                    height: 50,
                    child: FilledButton(
                      onPressed: _busy ? null : _submit,
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
                          : const Text('Reset password',
                              style: TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ],
            ),
          ),
            ),
          ],
        ),
      ),
    );
  }
}
