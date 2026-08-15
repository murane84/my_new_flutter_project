import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
// Prefixed: package:provider also exports Consumer/ChangeNotifierProvider.
import 'package:flutter_riverpod/flutter_riverpod.dart' as rp;
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/share_inbox.dart';
import 'utils/brand_theme.dart';
import 'screens/theme_provider.dart';
import 'screens/home_page.dart';
import 'screens/login_screen.dart';
import 'screens/register_screen.dart';
import 'screens/auth_page.dart';
import 'screens/lock_screen.dart';
import 'services/biometric_service.dart';
import 'screens/friends_list_screen.dart';
import 'screens/chat_page.dart';
import 'screens/music_controls.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'services/audio_handler.dart';
import 'services/notif_service.dart';
import 'services/fcm_service.dart';
import 'services/metadata_overrides.dart';
import 'services/live_session_service.dart' show liveHostNotify;
import 'utils/toast_helper.dart';
import 'screens/token_helper.dart' show warmMediaAuth;
import 'state/playback_state.dart' show providerContainer;

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// ── Share-into-Aluta (receive images shared from other apps) ─────────────────
// Android/iOS only. The plugin has no web/Windows implementation, so guard every
// call — invoking it there would throw MissingPluginException.
bool get _shareIntakeSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Listen for images shared in while the app is already running.
void _listenForSharedMedia() {
  if (!_shareIntakeSupported) return;
  try {
    ReceiveSharingIntent.instance.getMediaStream().listen((files) {
      final imgs = files
          .where((f) => f.type == SharedMediaType.image)
          .map((f) => f.path)
          .toList();
      if (imgs.isEmpty) return;
      ShareInbox.instance.add(imgs);
      // Surface the friend list (with its "tap a contact to send" banner) in
      // case the share arrived while the user was in a chat or sub-screen.
      navigatorKey.currentState?.popUntil((r) => r.isFirst);
      ReceiveSharingIntent.instance.reset();
    }, onError: (_) {});
  } catch (_) {/* platform without the plugin */}
}

/// Consume any image the app was COLD-LAUNCHED with (shared while it was closed)
/// and stash it for the recipient picker to present once we're signed in.
Future<void> consumeInitialSharedMedia() async {
  if (!_shareIntakeSupported) return;
  try {
    final files = await ReceiveSharingIntent.instance.getInitialMedia();
    final imgs = files
        .where((f) => f.type == SharedMediaType.image)
        .map((f) => f.path)
        .toList();
    if (imgs.isNotEmpty) {
      ShareInbox.instance.add(imgs);
      ReceiveSharingIntent.instance.reset();
    }
  } catch (_) {/* platform without the plugin */}
}

/// FCM background/terminated handler. Runs in its OWN isolate, so it must
/// initialise Firebase itself, then it turns the data push into a local
/// notification. Must be a top-level function annotated for AOT entry.
@pragma('vm:entry-point')
Future<void> _fcmBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
    await handleFcmData(message.data);
  } catch (_) {/* best-effort */}
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Paint the app (its splash) AS SOON AS POSSIBLE. Only Sentry wraps runApp, so
  // it still installs capture of BOTH uncaught Flutter framework errors and
  // async (PlatformDispatcher / zone) errors. Everything heavy — the audio
  // foreground service, notification channels, Firebase/FCM, and the auth +
  // metadata warm-up — is deferred to _bootstrapServices(), which runs AFTER the
  // first frame.
  //
  // WHY: previously all of that was awaited BEFORE runApp, so `runApp` (and thus
  // the first Flutter frame) didn't happen until a chain of first-time native
  // binds + cold-network calls finished. On a cold first-post-install launch
  // that left the screen frozen on the native launch image long enough to read
  // as "app not responding" (ANR). The splash — a live, animating Flutter frame
  // — now shows immediately and gates entry to Home on the bootstrap instead.
  await SentryFlutter.init(
    (options) {
      // Placeholder DSN. Replace with your project's DSN, or supply it at build
      // time: --dart-define=SENTRY_DSN=https://<key>@<org>.ingest.sentry.io/<id>
      // An empty DSN keeps Sentry installed but inert (no events sent), so the
      // app runs cleanly until a real DSN is provided.
      options.dsn =
          const String.fromEnvironment('SENTRY_DSN', defaultValue: '');
      // Errors only — no performance tracing — to keep it lightweight.
      options.tracesSampleRate = 0.0;
    },
    appRunner: () => runApp(
      // Riverpod's scope wraps everything. We pass OUR container (the same one
      // non-widget code uses via `providerContainer`) so widget `ref` and that
      // container share a single state tree. The existing provider-package
      // ThemeProvider stays untouched inside it.
      rp.UncontrolledProviderScope(
        container: providerContainer,
        child: ChangeNotifierProvider(
          create: (_) => ThemeProvider(),
          child: const MyApp(),
        ),
      ),
    ),
  );
  // Head start on the heavy init while the splash paints; the splash awaits the
  // same (memoised) future before navigating on to Home.
  _bootstrapServices();
}

/// Heavy, one-time app bootstrap — the native + network initialisation that used
/// to block the first frame. Runs AFTER runApp so a cold first launch shows the
/// (responsive) splash instead of a frozen native image. Memoised so the splash
/// can await the very same run; every step is guarded so one failure never
/// blocks the rest, and none of it is required to render the splash itself.
Future<void>? _bootstrapFuture;
Future<void> _bootstrapServices() {
  return _bootstrapFuture ??= () async {
    // Media session (car / Bluetooth / lock-screen controls + the foreground
    // service that keeps the app alive & online while music plays).
    try {
      await initAudioService();
    } catch (_) {/* never block launch on the media session */}
    try {
      await initNotifications();
    } catch (_) {}
    // Push notifications (Android/iOS only). Firebase reads its config from
    // android/app/google-services.json; if that or the Firebase project isn't
    // set up, this whole block fails softly and the app still runs (WebSocket-
    // only delivery). The background handler is registered here (a few ms after
    // the first frame) rather than before runApp.
    if (fcmSupported) {
      try {
        await Firebase.initializeApp();
        FirebaseMessaging.onBackgroundMessage(_fcmBackgroundHandler);
        await FcmService.instance.init();
      } catch (_) {/* Firebase not configured yet — non-fatal */}
    }
    // Restore backed-up song-detail edits so custom titles/artists show at once.
    try {
      await metadataStore.load();
    } catch (_) {}
    // Warm the in-memory auth caches (access token + API origin) so the first
    // protected avatar/image frame in Home can attach the auth header (otherwise
    // a cold-start frame could 401), scoped to our host (never leaked to CDNs).
    try {
      await warmMediaAuth();
    } catch (_) {}
    // Start listening for images shared into Aluta while it's running (Android/
    // iOS only; a no-op elsewhere).
    _listenForSharedMedia();
  }();
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
          side: BorderSide(color: scheme.primary.withAlpha(130)),
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
      // Thin red accent margin on modal bottom sheets, matching the dialogs
      // and the custom popups.
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          side: BorderSide(color: scheme.primary.withAlpha(130)),
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
        //
        // App accent (personalization): the default brand red keeps every value
        // below exactly. Any other preset re-derives ONLY the primary family
        // from the chosen accent — surfaces / neutrals stay brand-tuned, so the
        // dark, intimate identity is preserved while the accent shifts.
        final accent = themeProvider.accent;
        final bool customAccent =
            accent.toARGB32() != ThemeProvider.defaultAccent.toARGB32();
        final ColorScheme? lightP = customAccent
            ? ColorScheme.fromSeed(
                seedColor: accent, brightness: Brightness.light)
            : null;
        final ColorScheme? darkP = customAccent
            ? ColorScheme.fromSeed(
                seedColor: accent, brightness: Brightness.dark)
            : null;
        final lightScheme = ColorScheme.fromSeed(
          seedColor: const Color(0xFFD90429),
          brightness: Brightness.light,
        ).copyWith(
          primary: lightP?.primary ?? const Color(0xFFD90429),
          onPrimary: lightP?.onPrimary ?? Colors.white,
          primaryContainer: lightP?.primaryContainer ?? const Color(0xFFFFDAD7),
          onPrimaryContainer:
              lightP?.onPrimaryContainer ?? const Color(0xFF40000A),
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
          primary: darkP?.primary ?? const Color(0xFFFF5A5F),
          onPrimary: darkP?.onPrimary ?? const Color(0xFF3A0007),
          primaryContainer: darkP?.primaryContainer ?? const Color(0xFF8E1420),
          onPrimaryContainer:
              darkP?.onPrimaryContainer ?? const Color(0xFFFFDAD7),
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
              case LockScreen.routeName:
                return _fade(const LockScreen());
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
                  friendAvatar: (args['friendAvatar'] as String?) ?? '',
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
    // Route host-facing live-session notifications (e.g. "X left the session")
    // through the app's global overlay, so they show even when the Listen
    // Together popup is minimised. Set once; survives this screen's disposal.
    liveHostNotify = (message) {
      final ctx = navigatorKey.currentContext;
      if (ctx != null) showToast(ctx, message, type: ToastType.info);
    };
    _checkLoginStatus();
  }

  Future<void> _checkLoginStatus() async {
    // If the app was cold-launched from another app's Share sheet, grab the
    // shared image(s) now; HomePage presents the recipient picker once signed in.
    await consumeInitialSharedMedia();
    // Run the heavy service bootstrap WHILE this splash (a live, animating frame)
    // is on screen — not before runApp, where it froze the native launch image
    // on a cold first start. Wait for BOTH a short brand-minimum (no flash on
    // warm launches) and the bootstrap, but cap the bootstrap so a slow or
    // unreachable service can't pin the splash — it keeps finishing in the
    // background, and the pieces Home needs (auth + metadata) are quick + local.
    await Future.wait([
      _bootstrapServices()
          .timeout(const Duration(seconds: 8), onTimeout: () {}),
      Future.delayed(const Duration(milliseconds: 600)),
    ]);
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    final isLoggedIn = prefs.getBool('isLoggedIn') ?? false;
    // Signed in + quick-unlock enrolled → gate entry behind the biometric lock
    // screen. Otherwise fall straight through to Home (or Auth if signed out).
    final bioLocked = isLoggedIn && await BiometricService.instance.isEnabled();
    if (!mounted) return;
    Navigator.pushReplacementNamed(
      context,
      bioLocked
          ? LockScreen.routeName
          : (isLoggedIn ? HomePage.routeName : AuthPage.routeName),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Splash is a pre-login brand surface → always brand red (accent-free),
    // in both light and dark modes.
    return BrandTheme(
      child: Builder(builder: (context) {
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
              errorBuilder: (_, _, _) => Icon(
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
      }),
    );
  }
}
