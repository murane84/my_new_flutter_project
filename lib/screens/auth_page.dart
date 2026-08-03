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
    final primary = scheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Dark: deep red → black. Light: soft red tint → white (bright).
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

    final titleColor = isDark ? Colors.white : const Color(0xFF3A1210);
    final subColor =
        isDark ? Colors.white.withAlpha(205) : const Color(0xFF7A4A45);
    final iconColor = isDark ? Colors.white : primary;
    final wmColor = isDark ? Colors.white : primary;
    final wmOpacity = isDark ? 0.06 : 0.05;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(
              themeProvider.isDarkMode ? Icons.light_mode : Icons.dark_mode,
              color: iconColor,
            ),
            onPressed: () =>
                themeProvider.toggleTheme(!themeProvider.isDarkMode),
          ),
        ],
      ),
      body: Stack(
        children: [
          // ── Backdrop gradient ────────────────────────────────────────
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
          // ── Faint contained logo watermark ───────────────────────────
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
          // ── Content ──────────────────────────────────────────────────
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 104,
                        height: 104,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withAlpha(isDark ? 70 : 40),
                              blurRadius: 24,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Image.asset(
                          'assets/images/logo.png',
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => Icon(
                            Icons.forum_rounded,
                            size: 48,
                            color: primary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Aluta',
                        style: TextStyle(
                          color: titleColor,
                          fontSize: 42,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 3,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Music & Chat — together',
                        style: TextStyle(
                          color: subColor,
                          fontSize: 15,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 56),
                      // Sign In — filled pill
                      SizedBox(
                        width: 220,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isDark ? Colors.white : primary,
                            foregroundColor: isDark ? primary : Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(28),
                            ),
                            elevation: 6,
                            shadowColor: Colors.black.withAlpha(120),
                            textStyle: const TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          onPressed: () => Navigator.of(context)
                              .push(_fadeRoute(const LoginPage())),
                          child: const Text('Sign In'),
                        ),
                      ),
                      const SizedBox(height: 14),
                      // Create Account — outline pill
                      SizedBox(
                        width: 220,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: isDark ? Colors.white : primary,
                            side: BorderSide(
                              color: isDark
                                  ? Colors.white.withAlpha(160)
                                  : primary.withAlpha(150),
                              width: 1.5,
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(28),
                            ),
                            textStyle: const TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          onPressed: () => Navigator.of(context)
                              .push(_fadeRoute(const RegisterPage())),
                          child: const Text('Create Account'),
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

  PageRouteBuilder _fadeRoute(Widget page) => PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (ctx, anim, sanim) => page,
        transitionsBuilder: (ctx, anim, sanim, child) =>
            FadeTransition(opacity: anim, child: child),
      );
}
