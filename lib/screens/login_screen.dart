import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'home_page.dart';
import 'theme_provider.dart';
import 'auth_page.dart';
import 'register_screen.dart';
import 'token_helper.dart';
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
            Color.lerp(primary, Colors.white, 0.78)!,
            Color.lerp(primary, Colors.white, 0.90)!,
            Colors.white,
          ];
    final onColor = isDark ? Colors.white : const Color(0xFF2A1414);
    final subColor =
        isDark ? Colors.white.withAlpha(180) : const Color(0xFF7A4A45);
    final cardBg =
        isDark ? Colors.white.withAlpha(20) : Colors.white.withAlpha(175);
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
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
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
                                const SizedBox(height: 28),

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
                                          SlideTransition(
                                            position: Tween<Offset>(
                                              begin: const Offset(1, 0),
                                              end: Offset.zero,
                                            ).animate(CurvedAnimation(
                                              parent: anim,
                                              curve: Curves.easeOutCubic,
                                            )),
                                            child: child,
                                          ),
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
