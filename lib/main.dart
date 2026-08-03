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

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, child) {
        final lightScheme = ColorScheme.fromSeed(
          seedColor: Colors.red,
          brightness: Brightness.light,
        );
        final darkScheme = ColorScheme.fromSeed(
          seedColor: Colors.red,
          brightness: Brightness.dark,
        );

        return MaterialApp(
          navigatorKey: navigatorKey,
          debugShowCheckedModeBanner: false,
          title: 'Aluta',
          theme: _buildTheme(lightScheme),
          darkTheme: _buildTheme(darkScheme),
          themeMode: themeProvider.themeMode,
          initialRoute: SplashScreen.routeName,
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
