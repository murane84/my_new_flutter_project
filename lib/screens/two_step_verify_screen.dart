import 'dart:async';

import 'package:flutter/material.dart';

import 'api_service.dart';
import '../utils/toast_helper.dart';
import '../utils/brand_theme.dart';

/// Second step of a two-step sign-in: the password was accepted, now the linked
/// Ozilane Key phone must approve. Shows the match number and polls until the
/// phone approves; offers an offline/backup code when the phone can't, and a
/// "trust this device" option to skip this next time.
///
/// Pops {'signedIn': true, 'username': ...} on success.
class TwoStepVerifyScreen extends StatefulWidget {
  const TwoStepVerifyScreen({
    super.key,
    required this.email,
    required this.password,
    required this.challengeId,
    this.matchNumber,
  });

  final String email;
  final String password;
  final String challengeId;
  final int? matchNumber;

  @override
  State<TwoStepVerifyScreen> createState() => _TwoStepVerifyScreenState();
}

class _TwoStepVerifyScreenState extends State<TwoStepVerifyScreen> {
  final _api = ApiService();
  final _code = TextEditingController();

  Timer? _poll;
  bool _busy = false;
  bool _trust = false;
  String _fallback = 'none'; // none | totp | backup

  @override
  void initState() {
    super.initState();
    _startPolling();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _code.dispose();
    super.dispose();
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 3), (t) async {
      final st = await _api.ozSignInStatus(widget.challengeId);
      if (!mounted) return;
      if (st == 'APPROVED') {
        t.cancel();
        await _complete();
      } else if (st == 'DENIED' || st == 'EXPIRED') {
        t.cancel();
        if (!mounted) return;
        showToast(
            context,
            st == 'DENIED'
                ? 'The sign-in was declined on your phone.'
                : 'The request expired — sign in again.',
            type: ToastType.error);
        Navigator.pop(context);
      }
    });
  }

  Future<void> _complete() async {
    setState(() => _busy = true);
    final res =
        await _api.ozSignInComplete(widget.challengeId, trust: _trust);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res['success'] == true) {
      Navigator.pop(context, {'signedIn': true, 'username': res['username']});
    } else {
      showToast(context,
          (res['message'] ?? 'Could not complete sign-in.').toString(),
          type: ToastType.error);
      Navigator.pop(context);
    }
  }

  Future<void> _completeWithCode() async {
    if (_code.text.trim().isEmpty) {
      showToast(context, 'Enter the code.', type: ToastType.error);
      return;
    }
    setState(() => _busy = true);
    final res = await _api.ozTwoStepCode(
      email: widget.email,
      password: widget.password,
      code: _code.text.trim(),
      kind: _fallback == 'backup' ? 'backup' : 'totp',
      trust: _trust,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (res['success'] == true) {
      _poll?.cancel();
      Navigator.pop(context, {'signedIn': true, 'username': res['username']});
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
          appBar: AppBar(title: const Text('Approve sign-in')),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              child: _fallback == 'none'
                  ? _approveView(scheme)
                  : _codeView(scheme),
            ),
          ),
        );
      }),
    );
  }

  Widget _trustTile(ColorScheme scheme) {
    return CheckboxListTile(
      value: _trust,
      onChanged: (v) => setState(() => _trust = v ?? false),
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title: const Text('Trust this device for 30 days'),
      subtitle: Text('Skip phone approval here next time.',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
    );
  }

  Widget _approveView(ColorScheme scheme) {
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
              widget.matchNumber?.toString().padLeft(2, '0') ?? '—',
              style: TextStyle(
                  fontSize: 52,
                  fontWeight: FontWeight.w800,
                  color: scheme.primary),
            ),
          ),
        ),
        const SizedBox(height: 22),
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
        const SizedBox(height: 10),
        _trustTile(scheme),
        const SizedBox(height: 6),
        Center(
          child: TextButton(
            onPressed: () => setState(() => _fallback = 'totp'),
            child: const Text('Phone offline? Use a code'),
          ),
        ),
        Center(
          child: TextButton(
            onPressed: () {
              _poll?.cancel();
              Navigator.pop(context);
            },
            child: const Text('Cancel'),
          ),
        ),
      ],
    );
  }

  Widget _codeView(ColorScheme scheme) {
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
          controller: _code,
          keyboardType: isTotp ? TextInputType.number : TextInputType.text,
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
        const SizedBox(height: 8),
        _trustTile(scheme),
        const SizedBox(height: 10),
        SizedBox(
          height: 50,
          child: FilledButton(
            onPressed: _busy ? null : _completeWithCode,
            style: FilledButton.styleFrom(
              backgroundColor: scheme.primary,
              foregroundColor: Colors.white,
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: _busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5, color: Colors.white))
                : const Text('Sign in',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: TextButton(
            onPressed: () => setState(() => _fallback = 'none'),
            child: const Text('Back to phone approval'),
          ),
        ),
      ],
    );
  }
}
