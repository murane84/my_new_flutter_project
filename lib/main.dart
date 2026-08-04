import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/theme_provider.dart';
import 'screens/home_page.dart';
import 'screens/login_screen.dart';
import 'screens/register_screen.dart';
import 'screens/auth_page.dart';
import 'screens/friends_list_screen.dart';
import 'screens/chat_page.dart';
import 'screens/music_controls.dart';
import 'services/audio_handler.dart';
import 'services/notif_service.dart';
import 'services/metadata_overrides.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Media session (car / Bluetooth / lock-screen controls + a foreground
  // service that keeps the app alive & online while music plays). Guarded so a
  // failure never blocks launch.
  await initAudioService();
  await initNotifications();
  await metadataStore.load();
  runApp(
    ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  ThemeData _buildTheme(ColorScheme scheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withAlpha(80),
        contentPadding: const EdgeInsets.symmetric(
          vertical: 14,
          horizontal: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.error, width: 2),
        ),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        hintStyle: TextStyle(
          color: scheme.onSurfaceVariant.withAlpha(150),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant.withAlpha(80)),
        ),
        color: scheme.surface,
      ),
      bottomAppBarTheme: BottomAppBarThemeData(
        color: scheme.inverseSurface,
        elevation: 0,
      ),
      // One card language for every AlertDialog in the app: rounded, on-surface,
      // soft-bordered, with brand-weighted title/body text.
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 14,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: scheme.outlineVariant.withAlpha(70)),
        ),
        insetPadding:
            const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: TextStyle(
          color: scheme.onSurface.withAlpha(225),
          fontSize: 14,
          height: 1.45,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, child) {
        // Deliberate red-and-black brand palette (logo is red + black). We start
        // from a seed for harmonised secondary/tertiary tones, then override the
        // primary + surfaces so light mode reads crisp and vivid instead of the
        // washed-out pink/maroon that Material's default tonal mapping produces.
        final lightScheme = ColorScheme.fromSeed(
          seedColor: const Color(0xFFD90429),
          brightness: Brightness.light,
        ).copyWith(
          primary: const Color(0xFFD90429), // vivid crimson (brand red)
          onPrimary: Colors.white,
          primaryContainer: const Color(0xFFFFDAD7),
          onPrimaryContainer: const Color(0xFF40000A),
          secondary: const Color(0xFF201A1B), // near-black accent
          onSecondary: Colors.white,
          secondaryContainer: const Color(0xFFFFE1DE),
          onSecondaryContainer: const Color(0xFF2A1416),
          // Clean, near-neutral warm surfaces — kills the lavender/pink cast.
          surface: const Color(0xFFFFFBFB),
          onSurface: const Color(0xFF1A1416),
          surfaceContainerLowest: Colors.white,
          surfaceContainerLow: const Color(0xFFFBF3F3),
          surfaceContainer: const Color(0xFFF6EDED),
          surfaceContainerHigh: const Color(0xFFF0E7E7),
          surfaceContainerHighest: const Color(0xFFEAE1E1),
          onSurfaceVariant: const Color(0xFF4E4547),
          outline: const Color(0xFF847173),
          outlineVariant: const Color(0xFFD8C9CA),
          inverseSurface: const Color(0xFF201A1B), // near-black footer
          onInverseSurface: const Color(0xFFFBEEEE),
        );
        final darkScheme = ColorScheme.fromSeed(
          seedColor: const Color(0xFFD90429),
          brightness: Brightness.dark,
        ).copyWith(
          primary: const Color(0xFFFF5A5F), // punchy red that pops on black
          onPrimary: const Color(0xFF3A0007),
          primaryContainer: const Color(0xFF8E1420),
          onPrimaryContainer: const Color(0xFFFFDAD7),
          secondary: const Color(0xFFE7BDBD),
          // True near-black surfaces so the red accents spark.
          surface: const Color(0xFF141011),
          onSurface: const Color(0xFFF1E4E4),
          surfaceContainerLowest: const Color(0xFF0E0B0C),
          surfaceContainerLow: const Color(0xFF1B1617),
          surfaceContainer: const Color(0xFF201A1B),
          surfaceContainerHigh: const Color(0xFF2B2324),
          surfaceContainerHighest: const Color(0xFF362C2E),
          onSurfaceVariant: const Color(0xFFD6C4C5),
          outline: const Color(0xFF9E8E8F),
          outlineVariant: const Color(0xFF4E4344),
        );

        return MaterialApp(
          navigatorKey: navigatorKey,
          debugShowCheckedModeBanner: false,
          title: 'Aluta',
          theme: _buildTheme(lightScheme),
          darkTheme: _buildTheme(darkScheme),
          themeMode: themeProvider.themeMode,
          // Use `home:` (not initialRoute) so the root stack is a single route.
          // With initialRoute: '/splash', Flutter also generates a route for '/'
          // (the unknown-route "Page not found") and puts it underneath — which
          // is what a back-swipe from Home was revealing.
          home: const SplashScreen(),
          onGenerateRoute: (settings) {
            switch (settings.name) {
              case SplashScreen.routeName:
                return _fade(const SplashScreen());
              case LoginPage.routeName:
                return _fade(const LoginPage());
              case RegisterPage.routeName:
                return _slide(const RegisterPage());
              case AuthPage.routeName:
                return _fade(const AuthPage());
              case HomePage.routeName:
                return _fade(const HomePage());
              case FriendsListScreen.routeName:
                return _slide(const FriendsListScreen());
              case ChatPage.routeName:
                final args = settings.arguments as Map<String, dynamic>;
                return _slide(ChatPage(
                  textColor: Theme.of(navigatorKey.currentContext!).colorScheme.onSurface,
                  friendId: args['friendId'],
                  friendName: args['friendName'],
                ));
              case MusicControls.routeName:
                return _slide(MusicControls(
                  textColor: Theme.of(navigatorKey.currentContext!).colorScheme.onSurface,
                ));
              default:
                return _fade(const Scaffold(
                  body: Center(child: Text('Page not found')),
                ));
            }
          },
        );
      },
    );
  }

  PageRoute _fade(Widget page) => PageRouteBuilder(
    pageBuilder: (ctx, anim, sanim) => page,
    transitionsBuilder: (ctx, anim, sanim, child) =>
        FadeTransition(opacity: anim, child: child),
    transitionDuration: const Duration(milliseconds: 250),
  );

  PageRoute _slide(Widget page) => PageRouteBuilder(
    pageBuilder: (ctx, anim, sanim) => page,
    transitionsBuilder: (ctx, anim, sanim, child) => SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child,
    ),
    transitionDuration: const Duration(milliseconds: 300),
  );
}

class SplashScreen extends StatefulWidget {
  static const routeName = '/splash';
  const SplashScreen({super.key});

  @override
  SplashScreenState createState() => SplashScreenState();
}

class SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _checkLoginStatus();
  }

  Future<void> _checkLoginStatus() async {
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    final isLoggedIn = prefs.getBool('isLoggedIn') ?? false;
    if (!mounted) return;
    Navigator.pushReplacementNamed(
      context,
      isLoggedIn ? HomePage.routeName : AuthPage.routeName,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/images/logo.png',
              width: 120,
              height: 120,
              errorBuilder: (_, __, ___) => Icon(
                Icons.forum_rounded,
                size: 72,
                color: scheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Aluta',
              style: TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.bold,
                color: scheme.primary,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: scheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
