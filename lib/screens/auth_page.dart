import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'theme_provider.dart';
import 'login_screen.dart';
import 'register_screen.dart';

class AuthPage extends StatelessWidget {
  static const String routeName = '/auth';
  const AuthPage({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        automaticallyImplyLeading: false, // no back arrow on landing page
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(
              themeProvider.isDarkMode ? Icons.light_mode : Icons.dark_mode,
              color: Colors.white,
            ),
            onPressed: () => themeProvider.toggleTheme(!themeProvider.isDarkMode),
          ),
        ],
      ),
      body: Stack(
        children: [
          // Background image
          Positioned.fill(
            child: Image.asset(
              'assets/images/auth_background.jpg',
              fit: BoxFit.cover,
              errorBuilder: (ctx, anim, sanim) =>
                  Container(color: scheme.inverseSurface),
            ),
          ),
          // Dark overlay
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withAlpha(100),
                    Colors.black.withAlpha(200),
                  ],
                ),
              ),
            ),
          ),
          // Content
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: ConstrainedBox(
                    // Cap width on desktop; phone uses whatever is available
                    constraints: const BoxConstraints(maxWidth: 380),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Logo
                        Container(
                          width: 90,
                          height: 90,
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(30),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withAlpha(80),
                              width: 2,
                            ),
                          ),
                          child: const Icon(
                            Icons.music_note_rounded,
                            size: 50,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'Aluta',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 42,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 3,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Music & Chat — together',
                          style: TextStyle(
                            color: Colors.white.withAlpha(200),
                            fontSize: 15,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 56),
                        // Sign In button — pill, centred
                        SizedBox(
                          width: 200,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: scheme.primary,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                  vertical: 15),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24),
                              ),
                              elevation: 4,
                              textStyle: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            onPressed: () => Navigator.of(context).push(
                              _fadeRoute(const LoginPage()),
                            ),
                            child: const Text('Sign In'),
                          ),
                        ),
                        const SizedBox(height: 14),
                        // Create Account button — outline pill, centred
                        SizedBox(
                          width: 200,
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(
                                  color: Colors.white70, width: 1.5),
                              padding: const EdgeInsets.symmetric(
                                  vertical: 15),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            onPressed: () => Navigator.of(context).push(
                              _fadeRoute(const RegisterPage()),
                            ),
                            child: const Text('Create Account'),
                          ),
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

  PageRouteBuilder _fadeRoute(Widget page) => PageRouteBuilder(
    transitionDuration: const Duration(milliseconds: 400),
    pageBuilder: (ctx, anim, sanim) => page,
    transitionsBuilder: (ctx, anim, sanim, child) =>
        FadeTransition(opacity: anim, child: child),
  );
}
