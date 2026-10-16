import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';
import 'home_page.dart';
import 'auth_page.dart';
import 'token_helper.dart';
import '../utils/toast_helper.dart';
import '../utils/brand_theme.dart';

/// Shown right after sign-in when an operator reset the account's password
/// (must_change_password). The user must set their own password before using
/// the app. Reuses /users/me/update, which clears the forced flag on success.
class ForcePasswordChangeScreen extends StatefulWidget {
  const ForcePasswordChangeScreen({super.key, required this.currentPassword});

  /// The (default/temporary) password the user just signed in with — used as
  /// the "current password" the update endpoint verifies.
  final String currentPassword;

  @override
  State<ForcePasswordChangeScreen> createState() =>
      _ForcePasswordChangeScreenState();
}

class _ForcePasswordChangeScreenState extends State<ForcePasswordChangeScreen> {
  final _newPw = TextEditingController();
  final _confirmPw = TextEditingController();
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    _newPw.dispose();
    _confirmPw.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_newPw.text.length < 6) {
      showToast(context, 'New password must be at least 6 characters.',
          type: ToastType.error);
      return;
    }
    if (_newPw.text != _confirmPw.text) {
      showToast(context, 'Passwords don\'t match.', type: ToastType.error);
      return;
    }
    if (_newPw.text == widget.currentPassword) {
      showToast(context, 'Choose a password different from the temporary one.',
          type: ToastType.error);
      return;
    }
    setState(() => _busy = true);
    final res = await ApiService().updateProfile(
      currentPassword: widget.currentPassword,
      newPassword: _newPw.text,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (res['success'] == true) {
      showToast(context, 'Password updated.', type: ToastType.success);
      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          pageBuilder: (ctx, anim, sanim) => const HomePage(),
          transitionsBuilder: (ctx, anim, sanim, child) =>
              FadeTransition(opacity: anim, child: child),
          transitionDuration: const Duration(milliseconds: 300),
        ),
      );
    } else {
      showToast(context,
          (res['message'] ?? 'Could not update password.').toString(),
          type: ToastType.error);
    }
  }

  Future<void> _signOut() async {
    try {
      await removeToken();
      await removeRefreshToken();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('isLoggedIn', false);
    } catch (_) {}
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const AuthPage()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return BrandTheme(
      child: Builder(builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        // Can't be dismissed — the user must set a password (or sign out).
        return PopScope(
          canPop: false,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Set a new password'),
              automaticallyImplyLeading: false,
              actions: [
                TextButton(
                  onPressed: _busy ? null : _signOut,
                  child: const Text('Sign out'),
                ),
              ],
            ),
            body: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.lock_reset_rounded,
                        size: 54, color: scheme.primary),
                    const SizedBox(height: 14),
                    const Text(
                      'Choose your own password',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Your account was recovered with a temporary password. '
                      'Set a new one you\'ll remember to finish securing it.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13.5,
                          height: 1.45,
                          color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 22),
                    TextField(
                      controller: _newPw,
                      obscureText: _obscure,
                      decoration: InputDecoration(
                        labelText: 'New password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(_obscure
                              ? Icons.visibility_off
                              : Icons.visibility),
                          onPressed: () =>
                              setState(() => _obscure = !_obscure),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _confirmPw,
                      obscureText: _obscure,
                      onSubmitted: (_) => _busy ? null : _submit(),
                      decoration: const InputDecoration(
                        labelText: 'Confirm new password',
                        prefixIcon: Icon(Icons.lock_outline),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      height: 50,
                      child: FilledButton(
                        onPressed: _busy ? null : _submit,
                        style: FilledButton.styleFrom(
                          backgroundColor: scheme.primary,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        child: _busy
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.5, color: Colors.white))
                            : const Text('Save password',
                                style: TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}
