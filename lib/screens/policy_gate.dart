import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api_service.dart';
import '../utils/app_config.dart';

/// A blocking "read & agree" consent gate for the Privacy Policy + Terms of Use.
///
/// Shown after sign-in whenever the server reports the user hasn't accepted the
/// current policy version (a fresh account, or an existing user after we bump
/// the policy). It cannot be dismissed by tapping away or the back button — the
/// only ways out are to tick the box and agree (recorded on the server) or to
/// sign out. Both documents open in the browser from the links inside.
///
/// Returns true once accepted; returns false if the user chooses to sign out
/// (in which case [onLogout] has already run).
Future<bool> showPolicyGate(
  BuildContext context, {
  required Map<String, dynamic> status,
  required Future<void> Function() onLogout,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PolicyGateDialog(status: status, onLogout: onLogout),
  );
  return result ?? false;
}

class _PolicyGateDialog extends StatefulWidget {
  final Map<String, dynamic> status;
  final Future<void> Function() onLogout;

  const _PolicyGateDialog({required this.status, required this.onLogout});

  @override
  State<_PolicyGateDialog> createState() => _PolicyGateDialogState();
}

class _PolicyGateDialogState extends State<_PolicyGateDialog> {
  bool _agreed = false;
  bool _busy = false;
  String? _base;

  int get _version =>
      (widget.status['current_version'] as num?)?.toInt() ?? 1;
  bool get _isUpdate => widget.status['is_update'] == true;
  String get _summary => (widget.status['summary'] as String?)?.trim() ?? '';
  String get _effectiveDate =>
      (widget.status['effective_date'] as String?) ?? '';
  String get _privacyPath =>
      (widget.status['privacy_url'] as String?) ?? '/privacy';
  String get _termsPath => (widget.status['terms_url'] as String?) ?? '/terms';

  @override
  void initState() {
    super.initState();
    AppConfig.baseUrl.then((b) {
      if (mounted) setState(() => _base = b);
    });
  }

  Future<void> _open(String path) async {
    final base = _base ?? await AppConfig.baseUrl;
    // Only app-relative doc paths ("/privacy", "/terms") get the API origin
    // prefixed; anything with its own scheme (mailto:, https:) is used as-is.
    final url = path.startsWith('/') ? '$base$path' : path;
    try {
      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok && mounted) _snack('Couldn’t open $url');
    } catch (_) {
      if (mounted) _snack('Couldn’t open $url');
    }
  }

  Future<void> _accept() async {
    if (!_agreed || _busy) return;
    setState(() => _busy = true);
    final ok = await ApiService().acceptPolicy(_version);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    } else {
      setState(() => _busy = false);
      _snack('Couldn’t save your consent — check your connection and try again.');
    }
  }

  Future<void> _logout() async {
    if (_busy) return;
    Navigator.pop(context, false);
    await widget.onLogout();
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      // Non-dismissible: agreeing or signing out are the only ways forward.
      canPop: false,
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460, maxHeight: 620),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: scheme.primary.withAlpha(28),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.verified_user_rounded,
                          color: scheme.primary, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _isUpdate
                            ? 'We’ve updated our terms'
                            : 'Welcome to Aluta',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
                if (_effectiveDate.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Effective $_effectiveDate · v$_version',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _summary.isNotEmpty
                              ? _summary
                              : 'Please review and accept Aluta’s Privacy Policy '
                                  'and Terms of Use to continue.',
                          style: TextStyle(
                            fontSize: 14.5,
                            height: 1.5,
                            color: scheme.onSurface.withAlpha(230),
                          ),
                        ),
                        const SizedBox(height: 16),
                        _DocLink(
                          icon: Icons.privacy_tip_rounded,
                          label: 'Read the Privacy Policy',
                          onTap: () => _open(_privacyPath),
                        ),
                        const SizedBox(height: 10),
                        _DocLink(
                          icon: Icons.gavel_rounded,
                          label: 'Read the Terms of Use',
                          onTap: () => _open(_termsPath),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: _busy ? null : () => setState(() => _agreed = !_agreed),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Checkbox(
                          value: _agreed,
                          onChanged: _busy
                              ? null
                              : (v) => setState(() => _agreed = v ?? false),
                          activeColor: scheme.primary,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 11),
                            child: Text(
                              'I have read and agree to the Privacy Policy '
                              'and Terms of Use.',
                              style: TextStyle(
                                fontSize: 13.5,
                                height: 1.4,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: (_agreed && !_busy) ? _accept : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Agree & Continue'),
                  ),
                ),
                Center(
                  child: TextButton(
                    onPressed: _busy ? null : _logout,
                    child: Text(
                      'Not now — sign out',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ),
                Center(
                  child: TextButton(
                    onPressed: _busy
                        ? null
                        : () => _open('mailto:support@ozilane.com'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      minimumSize: const Size(0, 0),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      'Questions? support@ozilane.com',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A tappable, outlined row that opens one of the legal documents, with a
/// trailing "opens externally" glyph so it's clearly a link.
class _DocLink extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _DocLink({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.onSurface,
        side: BorderSide(color: scheme.outlineVariant),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        alignment: Alignment.centerLeft,
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          Icon(Icons.open_in_new_rounded,
              size: 16, color: scheme.onSurfaceVariant),
        ],
      ),
    );
  }
}
