import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'home_page.dart';
import 'device_link.dart';
import 'theme_provider.dart';
import 'auth_page.dart';
import 'register_screen.dart';
import 'forgot_password_screen.dart';
import 'token_helper.dart';
import '../services/biometric_service.dart';
import '../utils/snackbar_helper.dart';

class LoginPage extends StatefulWidget {
  static const String routeName = '/login';
  const LoginPage({super.key});

  @override
  LoginPageState createState() => LoginPageState();
}

class LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _bioLoginAvailable = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map<String, String>) {
        _emailController.text = args['email'] ?? '';
        _passwordController.text = args['password'] ?? '';
      }
    });
    _checkBioLogin();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _performLogin() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);

    final result = await ApiService().login(
      _emailController.text.trim(),
      _passwordController.text.trim(),
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (result['success'] == true) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('isLoggedIn', true);
      await prefs.setString('username', result['username'] ?? '');
      await saveToken(result['access_token'] ?? '');

      // Offer biometric quick-unlock now that we have a valid session + refresh
      // token to gate behind it. Never blocks sign-in.
      await _maybeOfferBiometric(_emailController.text.trim());

      if (!mounted) return;
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
      showErrorSnackBar(
        context,
        result['message'] ?? 'Login failed. Please try again.',
      );
    }
  }

  /// After a successful password sign-in, offer to turn on fingerprint / Face /
  /// Windows Hello quick-unlock — but only once, and only where the device
  /// supports it. Declining is remembered so we never nag on every login.
  Future<void> _maybeOfferBiometric(String email) async {
    try {
      if (await BiometricService.instance.isEnabled()) return;
      if (!await BiometricService.instance.isAvailable()) return;
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('bio_prompt_declined') == true) return;
      if (!mounted) return;
      final wantsIt = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          final scheme = Theme.of(ctx).colorScheme;
          final isDark = Theme.of(ctx).brightness == Brightness.dark;
          final badgeIcon = isDark ? const Color(0xFFFF8A93) : scheme.primary;
          return Dialog(
            insetPadding: const EdgeInsets.all(24),
            backgroundColor: scheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(color: scheme.primary.withAlpha(130)),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 24, 22, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Soft-red fingerprint badge
                    Container(
                      width: 58,
                      height: 58,
                      decoration: BoxDecoration(
                        color: scheme.primary.withAlpha(isDark ? 46 : 26),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: scheme.primary.withAlpha(isDark ? 90 : 70)),
                      ),
                      child: Icon(Icons.fingerprint_rounded,
                          size: 30, color: badgeIcon),
                    ),
                    const SizedBox(height: 15),
                    const Text('Quick unlock',
                        style: TextStyle(
                            fontSize: 19, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 7),
                    Text(
                      'Sign in with your fingerprint, face or device PIN — and '
                      'keep Aluta locked when you reopen it.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13,
                          height: 1.4,
                          color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.lock_outline_rounded,
                            size: 13, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 5),
                        Text('Your password is never stored',
                            style: TextStyle(
                                fontSize: 11.5,
                                color: scheme.onSurfaceVariant)),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            style: TextButton.styleFrom(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 12),
                              foregroundColor: scheme.onSurfaceVariant,
                            ),
                            child: const Text('Not now'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => Navigator.pop(ctx, true),
                            icon: const Icon(Icons.fingerprint_rounded,
                                size: 18),
                            style: FilledButton.styleFrom(
                              backgroundColor: scheme.primary,
                              foregroundColor: Colors.white,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            label: const Text('Enable'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
      if (wantsIt == true) {
        final ok = await BiometricService.instance
            .authenticate('Confirm to enable quick unlock');
        if (ok) {
          await BiometricService.instance.enable(email);
        }
      } else if (wantsIt == false) {
        await prefs.setBool('bio_prompt_declined', true);
      }
    } catch (_) {/* never block sign-in on this */}
  }

  /// If quick-unlock is enrolled and a refresh token is still stored, offer a
  /// one-tap fingerprint sign-in on this screen (for users returning on their
  /// own device). Password entry always stays available alongside it.
  Future<void> _checkBioLogin() async {
    try {
      final enabled = await BiometricService.instance.isEnabled();
      final refresh = await getRefreshToken();
      if (enabled && refresh != null && refresh.isNotEmpty) {
        final acct = await BiometricService.instance.enrolledAccount() ?? '';
        if (!mounted) return;
        setState(() => _bioLoginAvailable = true);
        if (_emailController.text.isEmpty && acct.isNotEmpty) {
          _emailController.text = acct;
        }
      }
    } catch (_) {/* biometric login simply will not be offered */}
  }

  Future<void> _biometricLogin() async {
    final ok = await BiometricService.instance.authenticate('Sign in to Aluta');
    if (!ok || !mounted) return;
    setState(() => _isLoading = true);
    final refreshed = await ApiService().refreshAccessToken();
    if (!mounted) return;
    if (refreshed) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('isLoggedIn', true);
      try {
        final data = await ApiService().getUserData();
        await prefs.setString('username', data['username']?.toString() ?? '');
      } catch (_) {}
      if (!mounted) return;
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
      // Refresh token expired / revoked — fall back to password sign-in.
      setState(() {
        _isLoading = false;
        _bioLoginAvailable = false;
      });
      showErrorSnackBar(
        context,
        'Session expired — please sign in with your password.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
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
    final onColor = isDark ? Colors.white : const Color(0xFF2A1414);
    final subColor =
        isDark ? Colors.white.withAlpha(180) : const Color(0xFF7A4A45);
    final cardBg =
        isDark ? Colors.white.withAlpha(20) : Colors.white.withAlpha(238);
    final cardBorder =
        isDark ? Colors.white.withAlpha(50) : Colors.black.withAlpha(20);
    final wmColor = isDark ? Colors.white : primary;
    final wmOpacity = isDark ? 0.06 : 0.05;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new, color: onColor),
          onPressed: () => Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => const AuthPage()),
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              themeProvider.isDarkMode ? Icons.light_mode : Icons.dark_mode,
              color: onColor,
            ),
            onPressed: () =>
                themeProvider.toggleTheme(!themeProvider.isDarkMode),
          ),
        ],
      ),
      body: Stack(
        children: [
          // Branded gradient backdrop
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
          // Faint, fully-contained logo watermark (never cropped)
          Positioned.fill(
            child: Center(
              child: FractionallySizedBox(
                widthFactor: 0.9,
                heightFactor: 0.9,
                child: Opacity(
                  opacity: wmOpacity,
                  child: Image.asset(
                    'assets/images/logo.png',
                    fit: BoxFit.contain,
                    color: wmColor,
                    colorBlendMode: BlendMode.srcIn,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
          // Centred, width-capped card
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 32),
                child: Center(
                  child: ConstrainedBox(
                    // max 420px on Windows/desktop — phone uses full width
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Heading
                        Text(
                          'Welcome back',
                          style: TextStyle(
                            color: subColor,
                            fontSize: 15,
                          ),
                        ),
                        Text(
                          'Sign In',
                          style: TextStyle(
                            color: onColor,
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 28),

                        // Glass card
                        Container(
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: cardBg,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: cardBorder),
                            boxShadow: isDark
                                ? null
                                : [
                                    BoxShadow(
                                      color: Colors.black.withAlpha(20),
                                      blurRadius: 26,
                                      offset: const Offset(0, 12),
                                    ),
                                  ],
                          ),
                          child: Form(
                            key: _formKey,
                            child: Column(
                              children: [
                                _buildField(
                                  controller: _emailController,
                                  label: 'Email',
                                  icon: Icons.email_outlined,
                                  keyboardType: TextInputType.emailAddress,
                                  textInputAction: TextInputAction.next,
                                  validator: (v) =>
                                      v == null || v.isEmpty
                                          ? 'Enter your email'
                                          : null,
                                ),
                                const SizedBox(height: 14),
                                _buildField(
                                  controller: _passwordController,
                                  label: 'Password',
                                  icon: Icons.lock_outline,
                                  obscure: _obscurePassword,
                                  // Enter on the password field = Sign In
                                  textInputAction: TextInputAction.done,
                                  onSubmitted: _isLoading ? null : _performLogin,
                                  suffix: IconButton(
                                    icon: Icon(
                                      _obscurePassword
                                          ? Icons.visibility_off
                                          : Icons.visibility,
                                      color: isDark
                                          ? Colors.white70
                                          : Colors.black54,
                                    ),
                                    onPressed: () => setState(
                                      () => _obscurePassword =
                                          !_obscurePassword,
                                    ),
                                  ),
                                  validator: (v) =>
                                      v == null || v.isEmpty
                                          ? 'Enter your password'
                                          : null,
                                ),

                                // Forgot password → recover via authenticator
                                // (Google Authenticator) code.
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton(
                                    onPressed: _isLoading
                                        ? null
                                        : () => Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder: (_) =>
                                                    const ForgotPasswordScreen(),
                                              ),
                                            ),
                                    style: TextButton.styleFrom(
                                      foregroundColor: scheme.primary,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 4),
                                      minimumSize: const Size(0, 36),
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    child: const Text(
                                      'Forgot password?',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 14),

                                // Sign In button — pill width, centred
                                Center(
                                  child: SizedBox(
                                    width: 180,
                                    height: 48,
                                    child: ElevatedButton(
                                      onPressed:
                                          _isLoading ? null : _performLogin,
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: scheme.primary,
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(24),
                                        ),
                                        elevation: 4,
                                      ),
                                      child: _isLoading
                                          ? const SizedBox(
                                              width: 20,
                                              height: 20,
                                              child:
                                                  CircularProgressIndicator(
                                                strokeWidth: 2.5,
                                                color: Colors.white,
                                              ),
                                            )
                                          : const Text(
                                              'Sign In',
                                              style: TextStyle(
                                                fontSize: 15,
                                                fontWeight: FontWeight.w600,
                                                letterSpacing: 0.5,
                                              ),
                                            ),
                                    ),
                                  ),
                                ),
                                // One-tap fingerprint sign-in (own device)
                                if (_bioLoginAvailable) ...[
                                  const SizedBox(height: 18),
                                  Center(
                                    child: GestureDetector(
                                      onTap:
                                          _isLoading ? null : _biometricLogin,
                                      behavior: HitTestBehavior.opaque,
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Container(
                                            width: 54,
                                            height: 54,
                                            decoration: BoxDecoration(
                                              color: scheme.primary.withAlpha(
                                                  isDark ? 46 : 26),
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: scheme.primary.withAlpha(
                                                    isDark ? 90 : 70),
                                              ),
                                            ),
                                            child: Icon(
                                              Icons.fingerprint_rounded,
                                              size: 28,
                                              color: isDark
                                                  ? const Color(0xFFFF8A93)
                                                  : scheme.primary,
                                            ),
                                          ),
                                          const SizedBox(height: 7),
                                          Text(
                                            'Sign in with fingerprint',
                                            style: TextStyle(
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w600,
                                              color: subColor,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                                // Desktop & WEB: sign in by scanning a QR with
                                // the phone (inherits the phone's saved contact
                                // names for name personalisation). Web has no
                                // fingerprint/Face (that needs WebAuthn), so this
                                // QR "log in with your phone" is its passwordless
                                // option — the same flow the desktop app uses.
                                // Hidden only on native mobile (you ARE the phone).
                                if (kIsWeb ||
                                    (defaultTargetPlatform !=
                                            TargetPlatform.android &&
                                        defaultTargetPlatform !=
                                            TargetPlatform.iOS)) ...[
                                  const SizedBox(height: 18),
                                  Center(
                                    child: OutlinedButton.icon(
                                      onPressed: _isLoading
                                          ? null
                                          : () => Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                    builder: (_) =>
                                                        const DesktopQrLoginScreen()),
                                              ),
                                      icon: const Icon(
                                          Icons.qr_code_scanner_rounded,
                                          size: 18),
                                      label:
                                          const Text('Log in with your phone'),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: scheme.primary,
                                        side: BorderSide(
                                            color:
                                                scheme.primary.withAlpha(120)),
                                        minimumSize: const Size(210, 46),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(24),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(height: 20),

                        // Footer link
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              "Don't have an account?",
                              style: TextStyle(color: subColor, fontSize: 13),
                            ),
                            TextButton(
                              onPressed: () => Navigator.push(
                                context,
                                PageRouteBuilder(
                                  pageBuilder: (ctx, anim, sanim) =>
                                      const RegisterPage(),
                                  transitionsBuilder:
                                      (ctx, anim, sanim, child) =>
                                          FadeTransition(
                                              opacity: anim, child: child),
                                  transitionDuration:
                                      const Duration(milliseconds: 300),
                                ),
                              ),
                              child: Text(
                                'Sign Up',
                                style: TextStyle(
                                  color: scheme.primary,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool obscure = false,
    Widget? suffix,
    TextInputType? keyboardType,
    TextInputAction? textInputAction,
    VoidCallback? onSubmitted,
    String? Function(String?)? validator,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final onColor = isDark ? Colors.white : const Color(0xFF2A1414);
    final hintColor = isDark ? Colors.white70 : Colors.black54;
    final fillCol =
        isDark ? Colors.white.withAlpha(25) : Colors.white.withAlpha(220);
    final borderCol =
        isDark ? Colors.white.withAlpha(60) : Colors.black.withAlpha(38);
    final focusCol =
        isDark ? Colors.white : Theme.of(context).colorScheme.primary;
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onFieldSubmitted: onSubmitted != null ? (_) => onSubmitted() : null,
      validator: validator,
      style: TextStyle(color: onColor),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: hintColor),
        prefixIcon: Icon(icon, color: hintColor, size: 20),
        suffixIcon: suffix,
        filled: true,
        fillColor: fillCol,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: borderCol),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: focusCol, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.redAccent),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.redAccent, width: 1.5),
        ),
        errorStyle: const TextStyle(color: Colors.orange),
      ),
    );
  }
}
