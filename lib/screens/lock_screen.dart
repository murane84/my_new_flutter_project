import 'package:flutter/material.dart';
import '../services/biometric_service.dart';
import 'home_page.dart';
import 'auth_page.dart';

/// Shown on launch when the user is signed in AND has quick-unlock enabled.
/// Auto-invokes the fingerprint / Face / Windows Hello prompt; on success it
/// drops the user straight into the app. If biometrics fail or are cancelled,
/// the user can retry or fall back to a full email + password sign-in.
class LockScreen extends StatefulWidget {
  static const String routeName = '/lock';
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  bool _authenticating = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    // Fire the OS prompt as soon as the first frame is up.
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  Future<void> _unlock() async {
    if (_authenticating) return;
    setState(() {
      _authenticating = true;
      _failed = false;
    });
    final ok = await BiometricService.instance.authenticate('Unlock Aluta');
    if (!mounted) return;
    if (ok) {
      Navigator.pushReplacementNamed(context, HomePage.routeName);
    } else {
      setState(() {
        _authenticating = false;
        _failed = true;
      });
    }
  }

  void _usePassword() {
    Navigator.pushReplacementNamed(context, AuthPage.routeName);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = scheme.primary;

    final gradColors = isDark
        ? [
            Color.lerp(primary, Colors.black, 0.25)!,
            Color.lerp(primary, Colors.black, 0.62)!,
            const Color(0xFF0B0505),
          ]
        : [
            Color.lerp(primary, Colors.white, 0.88)!,
            Color.lerp(primary, Colors.white, 0.96)!,
            Colors.white,
          ];
    final titleColor = isDark ? Colors.white : const Color(0xFF3A1210);
    final subColor =
        isDark ? Colors.white.withAlpha(200) : const Color(0xFF7A4A45);

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: gradColors,
                  stops: const [0.0, 0.55, 1.0],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Brand logo
                      Container(
                        width: 88,
                        height: 88,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withAlpha(isDark ? 70 : 40),
                              blurRadius: 20,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Image.asset(
                          'assets/images/logo.png',
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) =>
                              Icon(Icons.forum_rounded, size: 40, color: primary),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Aluta is locked',
                        style: TextStyle(
                          color: titleColor,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _failed
                            ? 'Unlock failed. Tap to try again, or sign in with your password.'
                            : 'Unlock with your fingerprint, face or device PIN',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: subColor, fontSize: 14),
                      ),
                      const SizedBox(height: 40),
                      // Big tap-to-unlock circle
                      _UnlockButton(
                        authenticating: _authenticating,
                        onTap: _authenticating ? null : _unlock,
                        primary: primary,
                        isDark: isDark,
                      ),
                      const SizedBox(height: 40),
                      TextButton.icon(
                        onPressed: _usePassword,
                        icon: Icon(Icons.password_rounded,
                            size: 18, color: subColor),
                        label: Text(
                          'Sign in with password instead',
                          style: TextStyle(
                            color: subColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UnlockButton extends StatelessWidget {
  final bool authenticating;
  final VoidCallback? onTap;
  final Color primary;
  final bool isDark;
  const _UnlockButton({
    required this.authenticating,
    required this.onTap,
    required this.primary,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final ring = isDark ? primary.withAlpha(120) : primary.withAlpha(90);
    final fill = isDark ? primary.withAlpha(48) : primary.withAlpha(28);
    final icon = isDark ? const Color(0xFFFF8A93) : primary;
    return Semantics(
      button: true,
      label: 'Unlock with biometrics',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 104,
          height: 104,
          decoration: BoxDecoration(
            color: fill,
            shape: BoxShape.circle,
            border: Border.all(color: ring, width: 1.6),
            boxShadow: [
              BoxShadow(
                color: primary.withAlpha(40),
                blurRadius: 24,
                spreadRadius: -4,
              ),
            ],
          ),
          child: authenticating
              ? Padding(
                  padding: const EdgeInsets.all(34),
                  child: CircularProgressIndicator(strokeWidth: 2.5, color: icon),
                )
              : Icon(Icons.fingerprint_rounded, size: 54, color: icon),
        ),
      ),
    );
  }
}
