import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:logger/logger.dart';
import 'home_page.dart';
import 'auth_page.dart';

final logger = Logger();

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    logger.i('SplashScreen initialized');
    _checkLoginStatus();
  }

  Future<void> _checkLoginStatus() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    bool isLoggedIn = prefs.getBool('isLoggedIn') ?? false;
    logger.i('User logged in: $isLoggedIn');

    await Future.delayed(const Duration(seconds: 2));

    // Check if the widget is still mounted before using the context
    if (!mounted) return;

    if (isLoggedIn) {
      logger.i('Navigating to HomePage');
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => HomePage()), // Removed const
      );
    } else {
      logger.i('Navigating to AuthPage');
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => AuthPage()), // Removed const
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Text(
          "Aluta",
          style: TextStyle(color: Color(0xFFFA0202), fontSize: 22),
        ),
      ),
    );
  }
}
