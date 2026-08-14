import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:email_validator/email_validator.dart';
import 'package:intl_phone_field/intl_phone_field.dart';
import 'api_service.dart';
import 'login_screen.dart';
import 'theme_provider.dart';
import 'auth_page.dart';
import '../utils/snackbar_helper.dart';
import '../utils/brand_theme.dart';

class RegisterPage extends StatefulWidget {
  static const String routeName = '/register';
  const RegisterPage({super.key});

  @override
  RegisterPageState createState() => RegisterPageState();
}

class RegisterPageState extends State<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;

  // Common disposable / throw-away email domains blocked at sign-up.
  static const Set<String> _disposableDomains = {
    'mailinator.com', 'guerrillamail.com', '10minutemail.com', 'tempmail.com',
    'temp-mail.org', 'yopmail.com', 'trashmail.com', 'sharklasers.com',
    'getnada.com', 'dispostable.com', 'maildrop.cc', 'fakeinbox.com',
    'throwawaymail.com', 'mailnesia.com', 'tempail.com', 'moakt.com',
  };

  @override
  void initState() {
    super.initState();
    // Live feedback for the confirm-password match indicator.
    _passwordController.addListener(_onPwChanged);
    _confirmController.addListener(_onPwChanged);
  }

  void _onPwChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _passwordController.removeListener(_onPwChanged);
    _confirmController.removeListener(_onPwChanged);
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  // Phone validity is enforced per-country by the IntlPhoneField below; the
  // full E.164 value is captured into _phoneController as the user types.

  // Eligibility scan: valid format, real-looking domain, not disposable.
  String? _emailError(String value) {
    final email = value.trim().toLowerCase();
    if (email.isEmpty) return 'Enter your email';
    if (!EmailValidator.validate(email)) {
      return 'Enter a valid email address';
    }
    final domain = email.split('@').last;
    if (!domain.contains('.') || domain.split('.').last.length < 2) {
      return 'That email domain looks invalid';
    }
    if (_disposableDomains.contains(domain)) {
      return 'Please use a permanent email address';
    }
    return null;
  }

  bool _isPasswordStrong(String password) =>
      password.length >= 8 &&
      RegExp(r'[A-Z]').hasMatch(password) &&
      RegExp(r'[a-z]').hasMatch(password) &&
      RegExp(r'[0-9]').hasMatch(password);

  Future<void> _performRegister() async {
    if (!_formKey.currentState!.validate()) return;
    // Phone is mandatory (like email) — the IntlPhoneField writes the full E.164
    // value here as the user types; an empty value means they skipped it.
    if (_phoneController.text.trim().isEmpty) {
      showErrorSnackBar(context, 'Enter your phone number');
      return;
    }
    setState(() => _isLoading = true);

    final result = await ApiService().register(
      _emailController.text.trim(),
      _passwordController.text.trim(),
      _usernameController.text.trim(),
      phone: _phoneController.text.trim(),
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (result['success'] == true) {
      showSuccessSnackBar(context, 'Account created! Please sign in.');
      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 400),
          pageBuilder: (ctx, anim, sanim) => const LoginPage(),
          settings: RouteSettings(
            arguments: {
              'email': _emailController.text.trim(),
              'password': _passwordController.text.trim(),
            },
          ),
          transitionsBuilder: (ctx, anim, sanim, child) =>
              FadeTransition(opacity: anim, child: child),
        ),
      );
    } else {
      showErrorSnackBar(
        context,
        result['message'] ?? 'Registration failed. Please try again.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Pre-login → always brand red, regardless of the in-app accent.
    return BrandTheme(
      child: Builder(builder: (context) {
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
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 32),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Join Aluta',
                          style: TextStyle(
                            color: subColor,
                            fontSize: 15,
                          ),
                        ),
                        Text(
                          'Create Account',
                          style: TextStyle(
                            color: onColor,
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 28),

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
                                  controller: _usernameController,
                                  label: 'Username',
                                  icon: Icons.person_outline,
                                  validator: (v) =>
                                      v == null || v.trim().isEmpty
                                          ? 'Enter a username'
                                          : null,
                                ),
                                const SizedBox(height: 14),
                                _buildField(
                                  controller: _emailController,
                                  label: 'Email',
                                  icon: Icons.email_outlined,
                                  keyboardType: TextInputType.emailAddress,
                                  validator: (v) => _emailError(v ?? ''),
                                ),
                                const SizedBox(height: 14),
                                IntlPhoneField(
                                  // International number with a country picker →
                                  // we store the full E.164 value (+<cc><number>)
                                  // so contact matching works across countries.
                                  initialCountryCode: 'TZ',
                                  disableLengthCheck: false,
                                  decoration: InputDecoration(
                                    labelText: 'Phone number',
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  onChanged: (phone) =>
                                      _phoneController.text = phone.completeNumber,
                                  invalidNumberMessage:
                                      'Enter a valid phone number',
                                ),
                                const SizedBox(height: 6),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    'Used so friends can call you directly',
                                    style: TextStyle(
                                      color: isDark
                                          ? Colors.white.withAlpha(120)
                                          : Colors.black.withAlpha(120),
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 14),
                                _buildField(
                                  controller: _passwordController,
                                  label: 'Password',
                                  icon: Icons.lock_outline,
                                  obscure: _obscurePassword,
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
                                  validator: (v) {
                                    if (v == null || v.isEmpty) {
                                      return 'Enter a password';
                                    }
                                    if (!_isPasswordStrong(v)) {
                                      return 'Min 8 chars with upper, lower & number';
                                    }
                                    return null;
                                  },
                                ),
                                const SizedBox(height: 6),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    '8+ chars · uppercase · lowercase · number',
                                    style: TextStyle(
                                      color: isDark
                                          ? Colors.white.withAlpha(120)
                                          : Colors.black.withAlpha(120),
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 14),
                                // Confirm password
                                _buildField(
                                  controller: _confirmController,
                                  label: 'Confirm Password',
                                  icon: Icons.lock_reset_outlined,
                                  obscure: _obscureConfirm,
                                  suffix: IconButton(
                                    icon: Icon(
                                      _obscureConfirm
                                          ? Icons.visibility_off
                                          : Icons.visibility,
                                      color: isDark
                                          ? Colors.white70
                                          : Colors.black54,
                                    ),
                                    onPressed: () => setState(
                                      () => _obscureConfirm = !_obscureConfirm,
                                    ),
                                  ),
                                  validator: (v) {
                                    if (v == null || v.isEmpty) {
                                      return 'Confirm your password';
                                    }
                                    if (v != _passwordController.text) {
                                      return 'Passwords do not match';
                                    }
                                    return null;
                                  },
                                ),
                                // Live match feedback as the user types.
                                if (_confirmController.text.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          _confirmController.text ==
                                                  _passwordController.text
                                              ? Icons.check_circle_rounded
                                              : Icons.cancel_rounded,
                                          size: 14,
                                          color: _confirmController.text ==
                                                  _passwordController.text
                                              ? Colors.green
                                              : Colors.redAccent,
                                        ),
                                        const SizedBox(width: 5),
                                        Text(
                                          _confirmController.text ==
                                                  _passwordController.text
                                              ? 'Passwords match'
                                              : 'Passwords do not match',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: _confirmController.text ==
                                                    _passwordController.text
                                                ? Colors.green
                                                : Colors.redAccent,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 24),

                                // Create Account button — pill width, centred
                                Center(
                                  child: SizedBox(
                                    width: 200,
                                    height: 48,
                                    child: ElevatedButton(
                                      onPressed: _isLoading
                                          ? null
                                          : _performRegister,
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
                                              'Create Account',
                                              style: TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                                letterSpacing: 0.3,
                                              ),
                                            ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(height: 20),

                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'Already have an account?',
                              style: TextStyle(color: subColor, fontSize: 13),
                            ),
                            TextButton(
                              onPressed: () => Navigator.push(
                                context,
                                PageRouteBuilder(
                                  pageBuilder: (ctx, anim, sanim) =>
                                      const LoginPage(),
                                  transitionsBuilder:
                                      (ctx, anim, sanim, child) =>
                                          FadeTransition(
                                              opacity: anim, child: child),
                                  transitionDuration:
                                      const Duration(milliseconds: 300),
                                ),
                              ),
                              child: Text(
                                'Sign In',
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
      }),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool obscure = false,
    Widget? suffix,
    TextInputType? keyboardType,
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
          borderSide:
              const BorderSide(color: Colors.redAccent, width: 1.5),
        ),
        errorStyle: const TextStyle(color: Colors.orange),
      ),
    );
  }
}
