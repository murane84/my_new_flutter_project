import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'widgets/splash_particles.dart';
import 'widgets/busy_overlay.dart';
import 'services/app_busy.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
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
import 'screens/preload_screen.dart';
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
import 'services/call_lock.dart';
import 'services/contact_names.dart';
import 'services/fcm_service.dart';
import 'services/metadata_overrides.dart';
import 'services/live_session_service.dart' show liveHostNotify;
import 'utils/toast_helper.dart';
import 'utils/session_events.dart';
import 'utils/popup_shell.dart' show GlobalTapOrigin;
import 'screens/token_helper.dart' show warmMediaAuth;
import 'state/playback_state.dart' show providerContainer;
import 'services/web_update_checker.dart';
import 'utils/readable.dart';
import 'utils/chat_background.dart' show loadChatBackground;

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
bool _spaceFullHooked = false;
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

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
      final media = files
          .where((f) =>
              f.type == SharedMediaType.image ||
              f.type == SharedMediaType.video ||
              f.type == SharedMediaType.file)
          .map((f) => f.path)
          .toList();
      if (media.isEmpty) return;
      ShareInbox.instance.add(media);
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
    final media = files
        .where((f) =>
            f.type == SharedMediaType.image ||
            f.type == SharedMediaType.video ||
            f.type == SharedMediaType.file)
        .map((f) => f.path)
        .toList();
    if (media.isNotEmpty) {
      ShareInbox.instance.add(media);
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
  final binding = WidgetsFlutterBinding.ensureInitialized();
  // Hold the native launch logo until the splash has its logo decoded
  // (SplashScreen lifts it), with a safety net so it can never get stuck.
  FlutterNativeSplash.preserve(widgetsBinding: binding);
  Future.delayed(const Duration(seconds: 4), _liftNativeSplash);
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
  // Riverpod's scope wraps everything. We pass OUR container (the same one
  // non-widget code uses via `providerContainer`) so widget `ref` and that
  // container share a single state tree. The provider-package ThemeProvider
  // stays untouched inside it.
  Widget appRoot() => rp.UncontrolledProviderScope(
        container: providerContainer,
        child: ChangeNotifierProvider(
          create: (_) => ThemeProvider(),
          child: const MyApp(),
        ),
      );

  // Sentry DSN. Supply at build time:
  //   --dart-define=SENTRY_DSN=https://<key>@<org>.ingest.sentry.io/<id>
  const sentryDsn = String.fromEnvironment('SENTRY_DSN', defaultValue: '');
  if (sentryDsn.isEmpty) {
    // No DSN → Sentry would be inert anyway (it sends nothing). Skip its native
    // init entirely so the FIRST FRAME paints without waiting on a pre-frame
    // MethodChannel. This matters most on a cold first-launch right after an
    // APK update, when Android is busy re-optimising (dexopt) and every native
    // call is slow — shaving the last pre-frame work reduces the "not
    // responding" window. When a real DSN is provided we wrap runApp as before
    // so startup errors are still captured.
    runApp(appRoot());
  } else {
    await SentryFlutter.init(
      (options) {
        options.dsn = sentryDsn;
        // Errors only — no performance tracing — to keep it lightweight.
        options.tracesSampleRate = 0.0;
      },
      appRunner: () => runApp(appRoot()),
    );
  }
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
    // Saved chat wallpapers, before any chat paints (otherwise a chat shows
    // the built-in default for a beat, then swaps to the chosen one).
    try {
      await loadChatBackground();
    } catch (_) {}
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
    // Phone-book names in memory before the chat list paints (no registered
    // name first, then a snap to "My wife"). Snapshot first, account backup on
    // a fresh install.
    try {
      await ContactNames.instance
          .prime()
          .timeout(const Duration(seconds: 4), onTimeout: () {});
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
    // Web only: watch for a newer deployed build and offer a "Reload" banner so
    // the open tab doesn't keep running stale assets. No-op off the web.
    WebUpdateChecker.instance.start(scaffoldMessengerKey);
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
        // Very pale picks (butter, petal, neon yellow…) would vanish as text
        // on the light surface — deepen them a touch for light mode only.
        final lightAccent = accent.computeLuminance() > 0.55
            ? Color.lerp(accent, Colors.black, 0.28)!
            : accent;
        final lightScheme = ColorScheme.fromSeed(
          seedColor: const Color(0xFFD90429),
          brightness: Brightness.light,
        ).copyWith(
          // Use the EXACT chosen accent (like Our Space) so a vivid pick stays
          // vivid, instead of Material's tone-mapped (muted) seed primary.
          primary: customAccent ? lightAccent : const Color(0xFFD90429),
          // Three-tier ink: white on darkish, graphite on normal, black on
          // shining accents (see readableOn).
          onPrimary: customAccent ? readableOn(lightAccent) : Colors.white,
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
          // Exact accent here too — a neon stays neon on the dark surface.
          primary: customAccent ? accent : const Color(0xFFFF5A5F),
          onPrimary: customAccent
              ? readableOn(accent)
              : const Color(0xFF3A0007),
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
          scaffoldMessengerKey: scaffoldMessengerKey,
          debugShowCheckedModeBanner: false,
          // Let lists be dragged with a mouse / trackpad on web + desktop
          // (Flutter disables mouse drag-scrolling by default there, which made
          // the Circle friend list feel unscrollable on the web build).
          scrollBehavior: const _AppScrollBehavior(),
          title: 'Aluta',
          theme: _buildTheme(lightScheme),
          darkTheme: _buildTheme(darkScheme),
          themeMode: themeProvider.themeMode,
          // Record every tap's position app-wide so any popup opened right after
          // genies out of / back into that exact button/tile (see showAppPopup).
          // The phone's font-size setting still applies, but within a band
          // (85–115 %) the layouts are designed for: a huge system font used
          // to push the song title and feel strip out of the music page (and
          // squeeze other screens) on some phones.
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(
                textScaler: mq.textScaler
                    .clamp(minScaleFactor: 0.85, maxScaleFactor: 1.15),
              ),
              child: GlobalTapOrigin(
                child: BusyOverlay(child: child ?? const SizedBox.shrink()),
              ),
            );
          },
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
              case PreloadScreen.routeName:
                return _fade(const PreloadScreen());
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

/// Native launch mark on Android: the 864px splash canvas shows as 288dp with
/// the mark 126dp wide. logo.png's mark fills 65.8% of its frame, so 191.5dp
/// of logo.png lines up exactly with what the user saw the instant they
/// tapped the icon. The splash starts there, so the handoff has no jump.
const double _kNativeLogo = 191.5;

bool _nativeSplashUp = true;
void _liftNativeSplash() {
  if (!_nativeSplashUp) return;
  _nativeSplashUp = false;
  FlutterNativeSplash.remove();
}
const double _kLogo = 120;
// Column below the logo: gap 18 + title 46 + gap 8 + tagline 24 + gap 34 +
// loader 30 → the logo's resting centre sits 80px above the screen centre.
const double _kLogoRise = 80;

class SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  // One timeline from the tap: heartbeat → burst → logo glides up with a 3D
  // turn → wordmark flips in letter by letter → tagline → living field →
  // equalizer. Then a soft fade-out so the next screen never overlaps it.
  late final AnimationController _entrance = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2300));
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2200));
  late final AnimationController _eq = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100));
  late final AnimationController _exit = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 360));
  late final Animation<double> _beat = CurvedAnimation(
      parent: _entrance, curve: const Interval(0.03, 0.24));
  late final Animation<double> _burst = CurvedAnimation(
      parent: _entrance, curve: const Interval(0.08, 0.66));
  late final Animation<double> _glide = CurvedAnimation(
      parent: _entrance,
      curve: const Interval(0.22, 0.52, curve: Curves.easeInOutCubic));
  late final Animation<double> _titleAnim = CurvedAnimation(
      parent: _entrance, curve: const Interval(0.42, 0.74));
  late final Animation<double> _taglineAnim = CurvedAnimation(
      parent: _entrance,
      curve: const Interval(0.58, 0.86, curve: Curves.easeOut));
  late final Animation<double> _fieldAnim = CurvedAnimation(
      parent: _entrance,
      curve: const Interval(0.3, 0.85, curve: Curves.easeOut));
  late final Animation<double> _spinAnim = CurvedAnimation(
      parent: _entrance,
      curve: const Interval(0.82, 1.0, curve: Curves.easeOut));
  bool _started = false;

  // Fade + rise-up entrance for a widget, driven by [a].
  Widget _rise(Animation<double> a, double dy, Widget child) {
    return AnimatedBuilder(
      animation: a,
      builder: (_, c) {
        final v = a.value.clamp(0.0, 1.0);
        return Opacity(
          opacity: v,
          child:
              Transform.translate(offset: Offset(0, (1 - v) * dy), child: c),
        );
      },
      child: child,
    );
  }

  // lub-dub: two quick swells, the second smaller, like a real heartbeat.
  double _beatScale(double t) {
    if (t <= 0 || t >= 1) return 1;
    final a = math.sin((t / 0.45).clamp(0.0, 1.0) * math.pi) * 0.075;
    final b = t > 0.5 ? math.sin(((t - 0.5) / 0.4).clamp(0.0, 1.0) * math.pi) * 0.045 : 0.0;
    return 1 + a + b;
  }

  // The logo, from the native launch spot to its place above the wordmark.
  Widget _logoLayer(ColorScheme scheme) {
    return AnimatedBuilder(
      animation: Listenable.merge([_entrance, _pulse, _exit]),
      builder: (_, child) {
        final g = _glide.value;
        final size = _kNativeLogo + (_kLogo - _kNativeLogo) * g;
        final ignite = (_entrance.value / 0.18).clamp(0.0, 1.0);
        final glow = ignite * (0.22 + _pulse.value * 0.38);
        // A half-turn of depth while it travels, settling flat.
        final tilt = math.sin(g * math.pi) * 0.42;
        final m = Matrix4.identity()
          ..setEntry(3, 2, 0.0012)
          ..rotateY(tilt)
          ..rotateX(-tilt * 0.25);
        return Center(
          child: Transform.translate(
            offset: Offset(0, -_kLogoRise * g),
            child: Transform(
              alignment: Alignment.center,
              transform: m,
              child: Transform.scale(
                scale: _beatScale(_beat.value),
                child: Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: scheme.primary.withValues(alpha: glow * 0.9),
                        blurRadius: 46 + 20 * (1 - g),
                        spreadRadius: -size * 0.12,
                      ),
                    ],
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
      child: Image.asset(
        'assets/images/logo.png',
        gaplessPlayback: true,
        errorBuilder: (_, _, _) =>
            Icon(Icons.forum_rounded, size: 72, color: scheme.primary),
      ),
    );
  }

  // "Aluta": each letter flips up out of the page, glossy, one after another.
  Widget _wordmark(ColorScheme scheme) {
    const word = 'Aluta';
    final base = scheme.primary;
    return SizedBox(
      height: 46,
      child: AnimatedBuilder(
        animation: _titleAnim,
        builder: (_, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < word.length; i++)
              Builder(builder: (_) {
                final t = ((_titleAnim.value * 1.6) - i * 0.15).clamp(0.0, 1.0);
                final e = Curves.easeOutBack.transform(t);
                return Opacity(
                  opacity: t,
                  child: Transform(
                    alignment: Alignment.bottomCenter,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 0.003)
                      ..rotateX((1 - e) * 1.35),
                    child: ShaderMask(
                      blendMode: BlendMode.srcIn,
                      shaderCallback: (r) => LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color.lerp(base, Colors.white, 0.55)!,
                          base,
                          Color.lerp(base, Colors.black, 0.35)!,
                        ],
                        stops: const [0.0, 0.5, 1.0],
                      ).createShader(r),
                      child: Text(
                        word[i],
                        style: TextStyle(
                          fontSize: 36,
                          height: 1.2,
                          fontWeight: FontWeight.bold,
                          color: base,
                          letterSpacing: 2,
                          shadows: [
                            Shadow(
                              color: base.withValues(alpha: 0.55),
                              blurRadius: 18,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  // A small live equalizer instead of a generic spinner: music is on its way.
  Widget _equalizer(ColorScheme scheme) {
    return FadeTransition(
      opacity: _spinAnim,
      child: SizedBox(
        width: 46,
        height: 30,
        child: AnimatedBuilder(
          animation: _eq,
          builder: (_, _) => Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < 5; i++)
                Container(
                  width: 5.5,
                  height: 6 +
                      22 *
                          (0.5 +
                              0.5 *
                                  math.sin(_eq.value * 2 * math.pi * (i.isEven ? 1 : 2) +
                                      i * 1.3)),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color.lerp(scheme.primary, Colors.white, 0.5)!,
                        scheme.primary,
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: scheme.primary.withValues(alpha: 0.5),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    splashOnScreen.value++; // hide the busy loader while the splash is up
    // Route host-facing live-session notifications (e.g. "X left the session")
    // through the app's global overlay, so they show even when the Listen
    // Together popup is minimised. Set once; survives this screen's disposal.
    // Our Space storage full (server said 413 on a keepsake): one clear toast.
    // Hooked once per app run (the splash can be shown again after sign-out).
    if (!_spaceFullHooked) {
      _spaceFullHooked = true;
      SessionEvents.instance.spaceFull.addListener(() {
        final ctx = navigatorKey.currentContext;
        if (ctx != null) {
          showToast(ctx,
              'Our Space is full — remove a few moments to keep new ones',
              type: ToastType.error, duration: const Duration(seconds: 4));
        }
      });
    }
    liveHostNotify = (message) {
      final ctx = navigatorKey.currentContext;
      if (ctx != null) showToast(ctx, message, type: ToastType.info);
    };
    _checkLoginStatus();
    _pulse.repeat(reverse: true);
    _eq.repeat();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // Keep the native launch logo up until our logo is decoded, then lift it
    // and start the timeline on the very same picture — no black blink.
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    precacheImage(const AssetImage('assets/images/logo.png'), context)
        .timeout(const Duration(milliseconds: 600), onTimeout: () {})
        .catchError((_) {})
        .whenComplete(() {
      _liftNativeSplash();
      if (!mounted) return;
      if (still) {
        _entrance.value = 1;
      } else {
        _entrance.forward();
        // Feel the heartbeat on phones.
        Future.delayed(const Duration(milliseconds: 90), () {
          if (mounted) HapticFeedback.lightImpact();
        });
      }
    });
  }

  Future<void> _checkLoginStatus() async {
    // If the app was cold-launched from another app's Share sheet, grab the
    // shared image(s) now; HomePage presents the recipient picker once signed in.
    await consumeInitialSharedMedia();
    // Opened by Accept / a tap on a ringing call: every second counts — the
    // caller is waiting. Stop the banner from coming back, skip the brand
    // moment and the preload, and go straight to Home (which answers).
    final callLaunch = await consumeCallLaunchAction();
    final forCall = callLaunch != null &&
        callLaunch.actionId != kCallDecline &&
        callLaunch.payload['group'] != true;
    if (forCall) unawaited(cancelCallNotification());
    // Run the heavy service bootstrap WHILE this splash (a live, animating frame)
    // is on screen — not before runApp, where it froze the native launch image
    // on a cold first start. Wait for BOTH a short brand-minimum (no flash on
    // warm launches) and the bootstrap, but cap the bootstrap so a slow or
    // unreachable service can't pin the splash — it keeps finishing in the
    // background, and the pieces Home needs (auth + metadata) are quick + local.
    await Future.wait([
      _bootstrapServices().timeout(Duration(seconds: forCall ? 4 : 8),
          onTimeout: () {}),
      // Hold long enough for the whole entrance (heartbeat → burst → glide →
      // wordmark → tagline → field) to play before moving on.
      if (!forCall) Future.delayed(const Duration(milliseconds: 2400)),
    ]);
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    final isLoggedIn = prefs.getBool('isLoggedIn') ?? false;
    // Signed in + quick-unlock enrolled → gate entry behind the biometric lock
    // screen. Otherwise fall straight through to Home (or Auth if signed out).
    var bioLocked = isLoggedIn && await BiometricService.instance.isEnabled();
    // Opened by an incoming call (Accept or a tap on the ringing banner):
    // answer first, like a phone's lock screen — the lock returns when the
    // call ends (see call_lock.dart). Decline stays behind the lock.
    if (bioLocked && forCall) {
      bioLocked = false;
      lockBypassedForCall = true;
    }
    if (!mounted) return;
    // Bow out first, so the next screen arrives on black instead of sliding
    // over the wordmark.
    if (!forCall) {
      try {
        await _exit.forward().orCancel;
      } catch (_) {}
    }
    if (!mounted) return;
    Navigator.pushReplacementNamed(
      context,
      bioLocked
          ? LockScreen.routeName
          : (isLoggedIn
              // A call: straight to Home (it paints from cache and answers);
              // the preload's network refresh would only keep them waiting.
              ? (forCall ? HomePage.routeName : PreloadScreen.routeName)
              : AuthPage.routeName),
    );
  }

  @override
  void dispose() {
    splashOnScreen.value = (splashOnScreen.value - 1).clamp(0, 99);
    _entrance.dispose();
    _pulse.dispose();
    _eq.dispose();
    _exit.dispose();
    super.dispose();
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
          body: AnimatedBuilder(
            animation: _exit,
            builder: (_, child) {
              final e = Curves.easeIn.transform(_exit.value);
              return Opacity(
                opacity: 1 - e,
                child: Transform.scale(scale: 1 + 0.05 * e, child: child),
              );
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Soft red bloom from below, so the black has depth.
                FadeTransition(
                  opacity: _fieldAnim,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(0, 0.15),
                        radius: 0.95,
                        colors: [
                          scheme.primary.withValues(alpha: 0.16),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
                SplashParticles(color: scheme.primary, reveal: _fieldAnim),
                SplashBurst(progress: _burst, color: scheme.primary),
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: _kLogo), // the logo layer sits here
                      const SizedBox(height: 18),
                      _wordmark(scheme),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 24,
                        child: _rise(
                          _taglineAnim,
                          12,
                          Text(
                            'Closer, in harmony',
                            style: TextStyle(
                              fontSize: 14.5,
                              color: Colors.white.withValues(alpha: 0.82),
                              letterSpacing: 1.4,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 34),
                      _equalizer(scheme),
                    ],
                  ),
                ),
                _logoLayer(scheme),
              ],
            ),
          ),
        );
      }),
    );
  }
}

/// App-wide scroll behavior: enable drag-scrolling with every pointer kind so
/// mouse and trackpad users on web and desktop can drag lists (not just use the
/// wheel). Mouse-wheel scrolling keeps working as the Material default.
class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.unknown,
      };
}
