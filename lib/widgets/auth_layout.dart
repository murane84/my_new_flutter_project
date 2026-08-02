import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../screens/theme_provider.dart';
import 'animated_background.dart';

class AuthLayout extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool centerContent;
  final bool useGlassCard; // Wrap child in glass card
  final double maxCardWidth; // Max width for card
  final double scrollThreshold; // Enable scroll if screen height < threshold

  const AuthLayout({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(24),
    this.centerContent = true,
    this.useGlassCard = false,
    this.maxCardWidth = 400,
    this.scrollThreshold = 500, // scroll if screen height < 500
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<ThemeProvider>(context).isDarkMode;

    // Build the glass card (or plain child)
    Widget contentCard = useGlassCard
        ? ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxCardWidth),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 25),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.black.withAlpha(180)
                    : Colors.white.withAlpha(220),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.red.withAlpha(isDark ? 120 : 160),
                ),
                boxShadow: [
                  BoxShadow(
                    color: isDark
                        ? Colors.black.withAlpha(120)
                        : Colors.white.withAlpha(120),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: child,
            ),
          )
        : child;

    return Stack(
      children: [
        const IgnorePointer(child: AnimatedBackground()),
        Container(
          color: isDark
              ? Colors.black.withAlpha(160)
              : Colors.white.withAlpha(120),
        ),
        SafeArea(
          child: SingleChildScrollView(
            padding: padding,
            physics: const BouncingScrollPhysics(),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 400),
                child: contentCard,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
