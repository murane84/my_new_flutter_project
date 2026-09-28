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
    final base = Theme.of(context);
    final baseScheme = base.colorScheme;
    final isDark = base.brightness == Brightness.dark;

    // Follow the app's Light/Dark theme (surfaces + text come straight from the
    // base scheme, like the chat area) and only re-brand the accent family with
    // the EXACT chosen colour so a vivid pick stays vivid.
    final primary = custom ? accent : baseScheme.primary;
    final onPrimary = custom
        ? (ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
            ? Colors.white
            : Colors.black)
        : baseScheme.onPrimary;

    final scheme = baseScheme.copyWith(
      primary: primary,
      onPrimary: onPrimary,
      // An opaque accent-tinted container that adapts to the active surface.
      primaryContainer: custom
          ? Color.alphaBlend(
              accent.withValues(alpha: isDark ? 0.30 : 0.16), baseScheme.surface)
          : baseScheme.primaryContainer,
      onPrimaryContainer: custom ? baseScheme.onSurface : baseScheme.onPrimaryContainer,
    );

    return Theme(
      data: base.copyWith(
        colorScheme: scheme,
        // Re-brand only the baked-in button/input accent; surfaces, text and
        // icons now inherit the active app theme.
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
