import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../screens/theme_provider.dart';

/// Wraps pre-login / auth surfaces (welcome, sign in, register, splash, password
/// reset) so they ALWAYS wear the Aluta brand red — independent of the in-app
/// accent the user may have chosen. Personalization is an *inside-the-app*
/// reward; the front door stays brand-consistent for every visitor.
///
/// It only re-brands the accent-dependent pieces (the primary colour family +
/// the button / input themes that bake it in) and inherits everything else —
/// including the current Light/Dark mode — from the ambient theme.
class BrandTheme extends StatelessWidget {
  final Widget child;
  const BrandTheme({super.key, required this.child});

  // The exact brand primaries used by the default (accent-free) app theme.
  static const Color _lightPrimary = Color(0xFFD90429);
  static const Color _darkPrimary = Color(0xFFFF5A5F);

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final dark = base.brightness == Brightness.dark;

    final primary = dark ? _darkPrimary : _lightPrimary;
    final onPrimary = dark ? const Color(0xFF3A0007) : Colors.white;
    final primaryContainer =
        dark ? const Color(0xFF8E1420) : const Color(0xFFFFDAD7);
    final onPrimaryContainer =
        dark ? const Color(0xFFFFDAD7) : const Color(0xFF40000A);

    final brandScheme = base.colorScheme.copyWith(
      primary: primary,
      onPrimary: onPrimary,
      primaryContainer: primaryContainer,
      onPrimaryContainer: onPrimaryContainer,
    );

    return Theme(
      data: base.copyWith(
        colorScheme: brandScheme,
        // ElevatedButton bakes primary into its background — re-brand it.
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: primary,
            foregroundColor: onPrimary,
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
        // The focused input border also bakes primary in.
        inputDecorationTheme: base.inputDecorationTheme.copyWith(
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: primary, width: 2),
          ),
        ),
        // FilledButton / TextButton read colorScheme.primary at paint time, so
        // the brandScheme above already covers them.
      ),
      child: child,
    );
  }
}

/// The Now Playing "stage": a permanently-dark, immersive surface — independent
/// of the app's Light/Dark mode — because dark is what makes cover art, the
/// vinyl and the glow pop (the brand thesis). The user's chosen ACCENT colours
/// the controls (play button, progress bar, active icons) on that dark stage, so
/// the player still feels personalized and consistent with the rest of the app.
/// Aluta red is simply the default accent.
class PlayerTheme extends StatelessWidget {
  final Widget child;
  const PlayerTheme({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final accent = context.watch<ThemeProvider>().accent;
    final custom = accent.toARGB32() != ThemeProvider.defaultAccent.toARGB32();

    // Harmonised dark primary family from the accent; the default red keeps the
    // app's punchy dark-mode red so nothing shifts for un-personalized users.
    final seed =
        ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark);
    final primary = custom ? seed.primary : const Color(0xFFFF5A5F);
    final onPrimary = custom ? seed.onPrimary : const Color(0xFF3A0007);

    final scheme = seed.copyWith(
      primary: primary,
      onPrimary: onPrimary,
      primaryContainer:
          custom ? seed.primaryContainer : const Color(0xFF8E1420),
      onPrimaryContainer:
          custom ? seed.onPrimaryContainer : const Color(0xFFFFDAD7),
      // Fixed near-black brand surfaces — the stage stays dark for every accent
      // (these match the app's dark-mode surfaces for visual continuity).
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

    final base = Theme.of(context);
    return Theme(
      data: base.copyWith(
        colorScheme: scheme,
        scaffoldBackgroundColor: scheme.surface,
        // Re-brand the baked-in button/input themes to the accent + dark stage.
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: primary,
            foregroundColor: onPrimary,
            minimumSize: const Size.fromHeight(50),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        inputDecorationTheme: base.inputDecorationTheme.copyWith(
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: primary, width: 2),
          ),
        ),
      ),
      child: child,
    );
  }
}
