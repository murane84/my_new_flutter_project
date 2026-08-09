import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl_phone_field/intl_phone_field.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';
import 'api_service.dart';
import 'token_helper.dart' show mediaAuthHeaders;
import 'auth_page.dart';
import 'two_factor_setup_screen.dart';
import '../services/biometric_service.dart';
import '../utils/toast_helper.dart';
import '../utils/popup_shell.dart';
import '../utils/app_config.dart';

/// Profile popup: edit username / phone / password (email is fixed), or
/// permanently delete the account and wipe all data from the server. Rendered
/// as a top-anchored popup UNDER the Aluta header (never covering it), and it
/// lays fields out in columns on desktop so it fits without scrolling.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _phone = TextEditingController();
  final _currentPw = TextEditingController();
  final _newPw = TextEditingController();
  final _confirmPw = TextEditingController();

  String _email = '';
  String _origUsername = '';
  String _origPhone = '';
  String _avatarUrl = ''; // relative (/attachments/<id>) or empty
  String _origAvatar = '';
  String _apiBase = '';
  bool _uploadingAvatar = false;
  bool _loading = true;
  bool _saving = false;
  bool _obscureCur = true;
  bool _obscureNew = true;
  bool _obscureConf = true;
  bool _bioAvailable = false;
  bool _bioOn = false;
  bool _twoFAOn = false;

  @override
  void initState() {
    super.initState();
    // Rebuild on any edit so the live match indicator and the Save button's
    // enabled state (only when something actually changed) stay in sync.
    for (final c in [_username, _phone, _currentPw, _newPw, _confirmPw]) {
      c.addListener(_rebuild);
    }
    AppConfig.baseUrl.then((b) {
      if (mounted) setState(() => _apiBase = b);
    });
    _load();
    _loadBio();
    _load2fa();
  }

  Future<void> _load2fa() async {
    final on = await ApiService().twoFactorStatus();
    if (mounted) setState(() => _twoFAOn = on);
  }

  Future<void> _loadBio() async {
    final avail = await BiometricService.instance.isAvailable();
    final on = await BiometricService.instance.isEnabled();
    if (mounted) {
      setState(() {
        _bioAvailable = avail;
        _bioOn = on;
      });
    }
  }

  Future<void> _toggleBio(bool want) async {
    // Require a successful biometric / device-credential check to change the
    // setting either way — so a passer-by can't silently turn the lock off.
    final ok = await BiometricService.instance.authenticate(
      want
          ? 'Confirm to enable quick unlock'
          : 'Confirm to turn off quick unlock',
    );
    if (!ok) {
      if (mounted) {
        showToast(context, 'Authentication failed', type: ToastType.error);
      }
      return;
    }
    if (want) {
      await BiometricService.instance.enable(_email);
    } else {
      await BiometricService.instance.disable();
    }
    if (!mounted) return;
    setState(() => _bioOn = want);
    showToast(
      context,
      want ? 'Quick unlock enabled' : 'Quick unlock turned off',
      type: ToastType.success,
    );
  }

  String? get _fullAvatar {
    if (_avatarUrl.isEmpty) return null;
    return _avatarUrl.startsWith('http') ? _avatarUrl : '$_apiBase$_avatarUrl';
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  // True only when the user has actually changed something worth saving.
  bool get _hasChanges =>
      _username.text.trim() != _origUsername ||
      _phone.text.trim() != _origPhone ||
      _avatarUrl != _origAvatar ||
      _currentPw.text.isNotEmpty ||
      _newPw.text.isNotEmpty ||
      _confirmPw.text.isNotEmpty;

  Future<void> _load() async {
    final data = await ApiService().getUserData();
    if (!mounted) return;
    setState(() {
      _email = data['email']?.toString() ?? '';
      _origUsername = data['username']?.toString() ?? '';
      _origPhone = data['phone']?.toString() ?? '';
      _origAvatar = data['avatar_url']?.toString() ?? '';
      _avatarUrl = _origAvatar;
      _username.text = _origUsername;
      _phone.text = _origPhone;
      _loading = false;
    });
  }

  Future<void> _pickAvatar() async {
    try {
      final x = await ImagePicker().pickImage(
          source: ImageSource.gallery, imageQuality: 78, maxWidth: 800);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      setState(() => _uploadingAvatar = true);
      final res = await ApiService()
          .uploadMedia(bytes: bytes, filename: x.name, mime: 'image/jpeg');
      if (!mounted) return;
      setState(() => _uploadingAvatar = false);
      if (res != null && res['url'] != null) {
        setState(() => _avatarUrl = res['url'].toString());
      } else {
        showToast(context, 'Could not upload photo', type: ToastType.error);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _uploadingAvatar = false);
        showToast(context, 'Could not pick photo', type: ToastType.error);
      }
    }
  }

  @override
  void dispose() {
    for (final c in [_username, _phone, _currentPw, _newPw, _confirmPw]) {
      c.removeListener(_rebuild);
    }
    _username.dispose();
    _phone.dispose();
    _currentPw.dispose();
    _newPw.dispose();
    _confirmPw.dispose();
    super.dispose();
  }

  bool _isPwStrong(String p) =>
      p.length >= 8 &&
      RegExp(r'[A-Z]').hasMatch(p) &&
      RegExp(r'[a-z]').hasMatch(p) &&
      RegExp(r'[0-9]').hasMatch(p);

  // Phone validity is enforced by the IntlPhoneField (per country); the full
  // E.164 value is written into _phone as the user types.

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final wantsPwChange =
        _newPw.text.isNotEmpty || _currentPw.text.isNotEmpty;
    if (wantsPwChange) {
      if (_currentPw.text.isEmpty) {
        showToast(context, 'Enter your current password to change it',
            type: ToastType.error);
        return;
      }
      if (!_isPwStrong(_newPw.text)) {
        showToast(context,
            'New password needs 8+ chars with upper, lower & number',
            type: ToastType.error);
        return;
      }
      if (_newPw.text != _confirmPw.text) {
        showToast(context, 'New passwords do not match',
            type: ToastType.error);
        return;
      }
    }

    setState(() => _saving = true);
    final res = await ApiService().updateProfile(
      username: _username.text.trim(),
      phone: _phone.text.trim(),
      avatarUrl: _avatarUrl,
      currentPassword: wantsPwChange ? _currentPw.text : null,
      newPassword: wantsPwChange ? _newPw.text : null,
    );
    if (!mounted) return;
    setState(() => _saving = false);

    if (res['success'] == true) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('username', _username.text.trim());
      } catch (_) {}
      _currentPw.clear();
      _newPw.clear();
      _confirmPw.clear();
      _origUsername = _username.text.trim();
      _origPhone = _phone.text.trim();
      _origAvatar = _avatarUrl;
      if (!mounted) return;
      showToast(context, 'Profile updated', type: ToastType.success);
      Navigator.pop(context, true);
    } else {
      showToast(context, res['message'] ?? 'Could not update profile',
          type: ToastType.error);
    }
  }

  Future<void> _confirmDelete() async {
    final scheme = Theme.of(context).colorScheme;
    final confirmCtrl = TextEditingController();
    // A typed confirmation ("DELETE") gates the destructive action so a stray
    // tap can never wipe the account.
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final matches = confirmCtrl.text.trim().toUpperCase() == 'DELETE';
          return AlertDialog(
            icon: Icon(Icons.warning_amber_rounded,
                color: scheme.error, size: 34),
            title: const Text('Delete account?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'This permanently deletes your account and wipes all your '
                  'messages, media and profile from the server. This cannot be '
                  'undone.',
                ),
                const SizedBox(height: 18),
                Text('Type DELETE to confirm',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant)),
                const SizedBox(height: 8),
                TextField(
                  controller: confirmCtrl,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  onChanged: (_) => setLocal(() {}),
                  decoration: InputDecoration(
                    hintText: 'DELETE',
                    isDense: true,
                    border: const OutlineInputBorder(),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: scheme.error, width: 1.5),
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.delete_forever_rounded, size: 18),
                label: const Text('Delete forever'),
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  disabledBackgroundColor: scheme.error.withAlpha(60),
                ),
                onPressed: matches ? () => Navigator.pop(ctx, true) : null,
              ),
            ],
          );
        },
      ),
    );
    confirmCtrl.dispose();
    if (ok != true) return;

    setState(() => _saving = true);
    final res = await ApiService().deleteAccount();
    if (!mounted) return;
    if (res['success'] == true) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.clear();
      } catch (_) {}
      await BiometricService.instance.disable();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AuthPage()),
        (route) => false,
      );
    } else {
      setState(() => _saving = false);
      showToast(context, res['message'] ?? 'Could not delete account',
          type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppPopupShell(
      title: 'Profile',
      icon: Icons.person_rounded,
      desktopMaxWidth: 780,
      builder: (context, isWide) => _body(context, isWide),
    );
  }

  Widget _body(BuildContext context, bool isWide) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(40),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final pwMatch = _newPw.text.isNotEmpty && _newPw.text == _confirmPw.text;

    final username = _textField(
      _username,
      'Username',
      Icons.person_outline,
      validator: (v) =>
          (v == null || v.trim().isEmpty) ? 'Enter a username' : null,
    );
    final phone = _phoneField(scheme);
    final curPw = _pwField(_currentPw, 'Current password', _obscureCur,
        () => setState(() => _obscureCur = !_obscureCur), Icons.lock_outline);
    final newPw = _pwField(_newPw, 'New password', _obscureNew,
        () => setState(() => _obscureNew = !_obscureNew),
        Icons.lock_reset_outlined);
    final confPw = _pwField(_confirmPw, 'Confirm new password', _obscureConf,
        () => setState(() => _obscureConf = !_obscureConf),
        Icons.lock_reset_outlined);

    return Stack(
      children: [
        // Faint, centred logo watermark behind the profile form. Decorative
        // only — IgnorePointer so it never blocks taps, low opacity so it reads
        // as a watermark under the fields.
        Positioned.fill(
          child: IgnorePointer(
            child: Center(
              child: Opacity(
                opacity: 0.05,
                child: Image.asset(
                  'assets/images/logo.png',
                  width: MediaQuery.of(context).size.width * 0.45,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
        ),
        AbsorbPointer(
      absorbing: _saving,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _avatarPicker(scheme),
              const SizedBox(height: 20),
              _ReadonlyTile(
                icon: Icons.email_outlined,
                label: 'Email (cannot be changed)',
                value: _email,
              ),
              const SizedBox(height: 22),
              _heading('Your details', scheme),
              const SizedBox(height: 12),
              if (isWide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: username),
                    const SizedBox(width: 16),
                    Expanded(child: phone),
                  ],
                )
              else ...[
                username,
                const SizedBox(height: 14),
                phone,
              ],
              const SizedBox(height: 26),
              _heading('Change password', scheme),
              const SizedBox(height: 4),
              Text('Leave blank to keep your current password',
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              if (isWide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: curPw),
                    const SizedBox(width: 12),
                    Expanded(child: newPw),
                    const SizedBox(width: 12),
                    Expanded(child: confPw),
                  ],
                )
              else ...[
                curPw,
                const SizedBox(height: 14),
                newPw,
                const SizedBox(height: 14),
                confPw,
              ],
              if (_confirmPw.text.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      pwMatch
                          ? Icons.check_circle_rounded
                          : Icons.cancel_rounded,
                      size: 14,
                      color: pwMatch ? Colors.green : Colors.redAccent,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      pwMatch ? 'Passwords match' : 'Passwords do not match',
                      style: TextStyle(
                        fontSize: 11,
                        color: pwMatch ? Colors.green : Colors.redAccent,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 22),
              FilledButton(
                onPressed: (_saving || !_hasChanges) ? null : _save,
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.primary,
                  disabledBackgroundColor: scheme.primary.withAlpha(60),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: Colors.white),
                      )
                    : const Text('Save changes'),
              ),
              const SizedBox(height: 22),
              _heading('Security', scheme),
              const SizedBox(height: 12),
              _twoFactorSection(scheme),
              if (_bioAvailable) ...[
                const SizedBox(height: 12),
                _securitySection(scheme),
              ],
              const SizedBox(height: 26),
              _dangerZone(scheme),
            ],
          ),
        ),
      ),
        ),
      ],
    );
  }

  Widget _avatarPicker(ColorScheme scheme) {
    final full = _fullAvatar;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: _uploadingAvatar ? null : _pickAvatar,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                CircleAvatar(
                  radius: 42,
                  backgroundColor: scheme.primaryContainer,
                  backgroundImage: full != null
                      ? CachedNetworkImageProvider(full,
                          headers: mediaAuthHeaders(full))
                      : null,
                  child: full == null
                      ? Text(
                          _origUsername.isNotEmpty
                              ? _origUsername[0].toUpperCase()
                              : '?',
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                            color: scheme.onPrimaryContainer,
                          ),
                        )
                      : null,
                ),
                if (_uploadingAvatar)
                  Positioned.fill(
                    child: Container(
                      decoration: const BoxDecoration(
                        color: Colors.black45,
                        shape: BoxShape.circle,
                      ),
                      child: const Padding(
                        padding: EdgeInsets.all(28),
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      ),
                    ),
                  ),
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: scheme.surface, width: 2),
                    ),
                    child: const Icon(Icons.camera_alt_rounded,
                        size: 15, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text('Tap to change photo',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _heading(String t, ColorScheme scheme) => Text(
        t,
        style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurface),
      );

  // International phone field (country picker → E.164). Pre-filled from the
  // saved number; writes the full E.164 value into [_phone] on change.
  Widget _phoneField(ColorScheme scheme) {
    String country = 'TZ';
    String nsn = '';
    final orig = _origPhone.trim();
    if (orig.isNotEmpty) {
      try {
        final p = PhoneNumber.parse(orig);
        country = p.isoCode.name;
        nsn = p.nsn;
      } catch (_) {
        nsn = orig.replaceAll('+', '');
      }
    }
    return IntlPhoneField(
      initialCountryCode: country,
      initialValue: nsn,
      disableLengthCheck: false,
      decoration: InputDecoration(
        labelText: 'Phone number',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      onChanged: (phone) => _phone.text = phone.completeNumber,
      invalidNumberMessage: 'Enter a valid phone number',
    );
  }

  Widget _textField(
    TextEditingController c,
    String label,
    IconData icon, {
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: c,
      keyboardType: keyboardType,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _pwField(TextEditingController c, String label, bool obscure,
      VoidCallback toggle, IconData icon) {
    return TextFormField(
      controller: c,
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          icon: Icon(obscure ? Icons.visibility_off : Icons.visibility),
          onPressed: toggle,
        ),
      ),
    );
  }

  /// Authenticator-based 2FA + password recovery. Tapping opens the setup
  /// screen (QR enrollment / turn off). Always shown, since it's the recovery
  /// path for a forgotten password.
  Widget _twoFactorSection(ColorScheme scheme) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: _saving
          ? null
          : () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const TwoFactorSetupScreen(),
                ),
              );
              // Refresh the on/off badge after returning.
              _load2fa();
            },
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withAlpha(90),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: scheme.primary.withAlpha(60)),
        ),
        child: Row(
          children: [
            Icon(Icons.shield_outlined, color: scheme.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Two-factor & password recovery',
                      style: TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(
                    _twoFAOn
                        ? 'On — you can reset a forgotten password with your '
                            'authenticator code.'
                        : 'Set up Google Authenticator so you can recover your '
                            'account if you forget your password.',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _twoFAOn
                    ? Colors.green.withAlpha(40)
                    : scheme.primary.withAlpha(28),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _twoFAOn ? 'On' : 'Set up',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: _twoFAOn ? Colors.green.shade700 : scheme.primary,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded,
                color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _securitySection(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 4, 6, 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withAlpha(90),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.primary.withAlpha(60)),
      ),
      child: Row(
        children: [
          Icon(Icons.fingerprint_rounded, color: scheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Fingerprint / Face unlock',
                    style:
                        TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                const SizedBox(height: 2),
                Text(
                  'Lock Aluta and sign in with biometrics or your device PIN. '
                  'Your password is never stored on this device.',
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Switch(
            value: _bioOn,
            onChanged: _saving ? null : (v) => _toggleBio(v),
          ),
        ],
      ),
    );
  }

  Widget _dangerZone(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withAlpha(60),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.error.withAlpha(90)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Danger zone',
              style: TextStyle(
                  fontWeight: FontWeight.w700, color: scheme.error)),
          const SizedBox(height: 6),
          Text(
            'Deleting your account removes your profile, messages and media '
            'from the server permanently.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: _saving ? null : _confirmDelete,
              icon: const Icon(Icons.delete_forever_rounded, size: 20),
              label: const Text('Delete account'),
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error.withAlpha(28),
                foregroundColor: scheme.error,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: scheme.error.withAlpha(120)),
                ),
                textStyle: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadonlyTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _ReadonlyTile(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 2),
                Text(value.isEmpty ? '—' : value,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface)),
              ],
            ),
          ),
          Icon(Icons.lock_outline, size: 15, color: scheme.onSurfaceVariant),
        ],
      ),
    );
  }
}
