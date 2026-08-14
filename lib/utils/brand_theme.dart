import 'package:flutter/material.dart';

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
