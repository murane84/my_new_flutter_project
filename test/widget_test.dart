// Minimal smoke test: boots straight to the auth/login screen — the screen the
// app lands on when logged out — and checks it renders.
//
// We pump `AuthPage` directly rather than the real `main()` / SplashScreen,
// which does platform-plugin init (audio service, notifications, secure
// storage) that can't run in a headless test.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// Only ProviderScope is needed from Riverpod; `show` avoids the Consumer/
// Provider/ChangeNotifierProvider name clash with package:provider.
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aluta/screens/auth_page.dart';
import 'package:aluta/screens/theme_provider.dart';

void main() {
  setUp(() {
    // ThemeProvider reads SharedPreferences on construction — mock the platform
    // channel so the test doesn't touch a real device.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('app boots to the login (auth) screen', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: ChangeNotifierProvider<ThemeProvider>(
          create: (_) => ThemeProvider(),
          child: const MaterialApp(home: AuthPage()),
        ),
      ),
    );
    // A single frame is enough. Avoid pumpAndSettle: splash/looping animations
    // never settle and would hang the test.
    await tester.pump();

    expect(find.byType(AuthPage), findsOneWidget);
    // The auth landing offers Sign In / Create Account.
    expect(find.text('Sign In'), findsWidgets);
  });
}
