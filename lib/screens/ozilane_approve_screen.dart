import 'dart:async';

import 'package:flutter/material.dart';

import 'api_service.dart';
import '../utils/toast_helper.dart';
import '../utils/brand_theme.dart';
import '../utils/readable.dart';

enum OzMode { signIn, recover }

/// "Approve on Ozilane Key" — one screen for both passwordless sign-in and
/// password recovery. The user enters their identifier, a match number appears,
/// they type it + fingerprint on their phone, and we poll until approved. For
/// recovery, offline codes and paper backup codes are offered as fallbacks when
/// the phone has no signal.
///
/// Returns via Navigator.pop:
///   • sign-in success  → {'signedIn': true, 'username': ..., 'email': ...}
///   • recovery success → {'recovered': true, 'email': ...}
class OzilaneApproveScreen extends StatefulWidget {
  const OzilaneApproveScreen({
    super.key,
    required this.mode,
    this.initialIdentifier,
  });

  final OzMode mode;
  final String? initialIdentifier;

  @override
  State<OzilaneApproveScreen> createState() => _OzilaneApproveScreenState();
}

class _OzilaneApproveScreenState extends State<OzilaneApproveScreen> {
  final _api = ApiService();
  final _id = TextEditingController();
  final _code = TextEditingController();
  final _newPw = TextEditingController();
  final _confirmPw = TextEditingController();

  // identifier | waiting | approved
  String _phase = 'identifier';
  String _fallback = 'none'; // none | totp | backup  (recover only)
  bool _busy = false;
  bool _obscure = true;

  String? _challengeId;
  int? _matchNumber;
  Timer? _poll;

  bool get _isSignIn => widget.mode == OzMode.signIn;

  @override
  void initState() {
    super.initState();
    _id.text = widget.initialIdentifier ?? '';
  }

  @override
  void dispose() {
    _poll?.cancel();
    _id.dispose();
    _code.dispose();
    _newPw.dispose();
    _confirmPw.dispose();
    super.dispose();
  }

  bool _pwOk() {
    if (_newPw.text.length < 6) {
      showToast(context, 'New password must be at least 6 characters.',
          type: ToastType.error);
      return false;
    }
    if (_newPw.text != _confirmPw.text) {
      showToast(context, 'Passwords don\'t match.', type: ToastType.error);
      return false;
    }
    return true;
  }

  Future<void> _start() async {
    final id = _id.text.trim();
    if (id.isEmpty) {
      showToast(context, 'Enter your email first.', type: ToastType.error);
      return;
    }
    setState(() => _busy = true);
    final res = _isSignIn
        ? await _api.ozSignInStart(id)
        : await _api.ozRecoverStart(id);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res['success'] == true) {
      setState(() {
        _challengeId = res['challenge_id']?.toString();
        _matchNumber = (res['match_number'] as num?)?.toInt();
        _phase = 'waiting';
      });
      _startPolling();
    } else {
      showToast(context, (res['message'] ?? 'Could not start.').toString(),
          type: ToastType.error);
    }
  }

  void _startPolling() {
    _poll?.cancel();
    final id = _challengeId;
    if (id == null) return;
    _poll = Timer.periodic(const Duration(seconds: 3), (t) async {
      final st = _isSignIn
          ? await _api.ozSignInStatus(id)
          : await _api.ozRecoverStatus(id);
      if (!mounted) return;
      if (st == 'APPROVED') {
        t.cancel();
        if (_isSignIn) {
          await _completeSignIn();
        } else {
          setState(() => _phase = 'approved');
        }
      } else if (st == 'DENIED' || st == 'EXPIRED') {
        t.cancel();
        if (!mounted) return;
        setState(() => _phase = 'identifier');
        showToast(
            context,
            st == 'DENIED'
                ? 'The request was declined on the phone.'
                : 'The request expired — try again.',
            type: ToastType.info);
      }
    });
  }

  Future<void> _completeSignIn() async {
    setState(() => _busy = true);
    final res = await _api.ozSignInComplete(_challengeId!);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res['success'] == true) {
      Navigator.pop(context, {
        'signedIn': true,
        'username': res['username'],
        'email': res['email'],
      });
    } else {
      showToast(context, (res['message'] ?? 'Could not complete sign-in.')
          .toString(), type: ToastType.error);
      setState(() => _phase = 'identifier');
    }
  }

  Future<void> _confirmRecover() async {
    if (!_pwOk()) return;
    setState(() => _busy = true);
    final res = await _api.ozRecoverConfirm(
        challengeId: _challengeId!, newPassword: _newPw.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res['success'] == true) {
      Navigator.pop(context, {'recovered': true, 'email': res['email']});
    } else {
      showToast(context, (res['message'] ?? 'Could not reset password.')
          .toString(), type: ToastType.error);
    }
  }

  Future<void> _confirmCodeFallback() async {
    final id = _id.text.trim();
    if (id.isEmpty) {
      showToast(context, 'Enter your email first.', type: ToastType.error);
      return;
    }
    if (_code.text.trim().isEmpty) {
      showToast(context, 'Enter the code.', type: ToastType.error);
      return;
    }
    if (!_pwOk()) return;
    setState(() => _busy = true);
    final res = _fallback == 'totp'
        ? await _api.ozRecoverTotp(
            identifier: id, code: _code.text.trim(), newPassword: _newPw.text)
        : await _api.ozRecoverBackup(
            identifier: id, code: _code.text.trim(), newPassword: _newPw.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res['success'] == true) {
      Navigator.pop(context, {'recovered': true, 'email': res['email']});
    } else {
      showToast(context,
          (res['message'] ?? 'Invalid or expired code.').toString(),
          type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return BrandTheme(
      child: Builder(builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return Scaffold(
          appBar: AppBar(
              title: Text(_isSignIn ? 'Sign in with phone' : 'Reset password')),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              child: _fallback != 'none'
                  ? _codeFallbackView(scheme)
                  : switch (_phase) {
                      'waiting' => _waitingView(scheme),
                      'approved' => _approvedView(scheme),
                      _ => _identifierView(scheme),
                    },
            ),
          ),
        );
      }),
    );
  }

  Widget _identifierView(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.phonelink_ring_rounded, size: 54, color: scheme.primary),
        const SizedBox(height: 14),
        Text(
          _isSignIn ? 'Sign in with Ozilane Key' : 'Reset with Ozilane Key',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        Text(
          'We\'ll ask your linked phone to approve. Open Ozilane Key, type the '
          'number we show, and confirm with your fingerprint.',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 13.5, height: 1.45, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 22),
        TextField(
          controller: _id,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: 'Email',
            prefixIcon: Icon(Icons.person_outline),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          height: 50,
          child: FilledButton.icon(
            onPressed: _busy ? null : _start,
            icon: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5, color: Colors.white))
                : const Icon(Icons.phonelink_ring_rounded),
            label: const Text('Approve on my phone'),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.primary,
              foregroundColor: readableOn(scheme.primary),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
        if (!_isSignIn) ...[
          const SizedBox(height: 14),
          Center(
            child: TextButton(
              onPressed: () => setState(() => _fallback = 'totp'),
              child: const Text('No phone signal? Use a code instead'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _waitingView(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text('Open Ozilane Key and pick this number',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 18),
        Center(
          child: Container(
            width: 120,
            height: 120,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.primary.withAlpha(22),
              shape: BoxShape.circle,
              border: Border.all(color: scheme.primary.withAlpha(90), width: 2),
            ),
            child: Text(
              _matchNumber?.toString().padLeft(2, '0') ?? '—',
              style: TextStyle(
                  fontSize: 52,
                  fontWeight: FontWeight.w800,
                  color: scheme.primary),
            ),
          ),
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2.2)),
            const SizedBox(width: 12),
            Text('Waiting for your approval…',
                style:
                    TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ],
        ),
        const SizedBox(height: 16),
        Center(
          child: TextButton(
            onPressed: () {
              _poll?.cancel();
              setState(() => _phase = 'identifier');
            },
            child: const Text('Cancel'),
          ),
        ),
      ],
    );
  }

  Widget _approvedView(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.verified_rounded, color: Colors.green, size: 26),
            const SizedBox(width: 10),
            const Expanded(
              child: Text('Approved — set a new password',
                  style:
                      TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _passwordFields(scheme),
        const SizedBox(height: 22),
        _primaryButton(scheme, 'Set new password', _confirmRecover),
      ],
    );
  }

  Widget _codeFallbackView(ColorScheme scheme) {
    final isTotp = _fallback == 'totp';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'totp', label: Text('Offline code')),
            ButtonSegment(value: 'backup', label: Text('Backup code')),
          ],
          selected: {_fallback},
          onSelectionChanged: (s) => setState(() {
            _fallback = s.first;
            _code.clear();
          }),
        ),
        const SizedBox(height: 16),
        Text(
          isTotp
              ? 'Enter the 6-digit code Ozilane Key shows for this account.'
              : 'Enter one of your one-time backup codes.',
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _id,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: 'Email',
            prefixIcon: Icon(Icons.person_outline),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _code,
          keyboardType:
              isTotp ? TextInputType.number : TextInputType.text,
          textCapitalization: isTotp
              ? TextCapitalization.none
              : TextCapitalization.characters,
          decoration: InputDecoration(
            labelText: isTotp ? 'Offline code' : 'Backup code',
            hintText: isTotp ? '000000' : 'K7QM2-XW9TB',
            prefixIcon: const Icon(Icons.pin_outlined),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        _passwordFields(scheme),
        const SizedBox(height: 22),
        _primaryButton(scheme, 'Reset password', _confirmCodeFallback),
        const SizedBox(height: 10),
        Center(
          child: TextButton(
            onPressed: () => setState(() => _fallback = 'none'),
            child: const Text('Back to phone approval'),
          ),
        ),
      ],
    );
  }

  Widget _passwordFields(ColorScheme scheme) {
    return Column(
      children: [
        TextField(
          controller: _newPw,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: 'New password',
            prefixIcon: const Icon(Icons.lock_outline),
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _confirmPw,
          obscureText: _obscure,
          decoration: const InputDecoration(
            labelText: 'Confirm new password',
            prefixIcon: Icon(Icons.lock_outline),
            border: OutlineInputBorder(),
          ),
        ),
      ],
    );
  }

  Widget _primaryButton(ColorScheme scheme, String label, VoidCallback onTap) {
    return SizedBox(
      height: 50,
      child: FilledButton(
        onPressed: _busy ? null : onTap,
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: readableOn(scheme.primary),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: _busy
            ? SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: readableOn(scheme.primary)))
            : Text(label,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      ),
    );
  }
}
