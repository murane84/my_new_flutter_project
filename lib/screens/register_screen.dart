import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:email_validator/email_validator.dart';
import 'api_service.dart';
import 'login_screen.dart';
import 'theme_provider.dart';
import 'auth_page.dart';
import '../utils/snackbar_helper.dart';

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
  bool _isLoading = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  bool _isPasswordStrong(String password) =>
      password.length >= 8 &&
      RegExp(r'[A-Z]').hasMatch(password) &&
      RegExp(r'[a-z]').hasMatch(password) &&
      RegExp(r'[0-9]').hasMatch(password);

  Future<void> _performRegister() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);

    final result = await ApiService().register(
      _emailController.text.trim(),
      _passwordController.text.trim(),
      _usernameController.text.trim(),
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
    final themeProvider = Provider.of<ThemeProvider>(context);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
          onPressed: () => Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => const AuthPage()),
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              themeProvider.isDarkMode ? Icons.light_mode : Icons.dark_mode,
              color: Colors.white,
            ),
            onPressed: () =>
                themeProvider.toggleTheme(!themeProvider.isDarkMode),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: Image.asset(
              'assets/images/auth_background.jpg',
              fit: BoxFit.cover,
              errorBuilder: (ctx, anim, sanim) =>
                  Container(color: scheme.inverseSurface),
            ),
          ),
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withAlpha(120),
                    Colors.black.withAlpha(210),
                  ],
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
                            color: Colors.white.withAlpha(180),
                            fontSize: 15,
                          ),
                        ),
                        const Text(
                          'Create Account',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 28),

                        Container(
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(20),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                                color: Colors.white.withAlpha(50)),
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
                                  validator: (v) {
                                    if (v == null || v.isEmpty) {
                                      return 'Enter your email';
                                    }
                                    if (!EmailValidator.validate(
                                        v.trim())) {
                                      return 'Enter a valid email address';
                                    }
                                    return null;
                                  },
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
                                      color: Colors.white70,
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
                                      color: Colors.white.withAlpha(120),
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
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
                              style: TextStyle(
                                  color: Colors.white.withAlpha(180),
                                  fontSize: 13),
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
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      validator: validator,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70),
        prefixIcon: Icon(icon, color: Colors.white70, size: 20),
        suffixIcon: suffix,
        filled: true,
        fillColor: Colors.white.withAlpha(25),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.white.withAlpha(60)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.white, width: 1.5),
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
