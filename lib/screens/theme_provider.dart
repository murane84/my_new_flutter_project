import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide appearance: theme mode (System / Light / Dark) and a curated app
/// accent colour. Dark is the brand's signature look, but the choice is the
/// user's. The accent is a small preset set (never a raw colour wheel) so it
/// can't fragment the brand. Per-Space colour lives on each RelationshipSpace,
/// not here — this is the whole-app layer only.
class ThemeProvider with ChangeNotifier {
  /// The brand red — the default accent. Picking it keeps the hand-tuned
  /// palette exactly; any other preset re-derives the primary family from it.
  static const Color defaultAccent = Color(0xFFD90429);

  ThemeMode _themeMode = ThemeMode.system;
  Color _accent = defaultAccent;

  ThemeMode get themeMode => _themeMode;
  Color get accent => _accent;
  bool get isDarkMode => _themeMode == ThemeMode.dark;

  ThemeProvider() {
    _load();
  }

  /// Back-compat: the old quick dark⇆light toggle (still used on the auth pages
  /// and the overflow menu). Routes through [setThemeMode].
  void toggleTheme(bool isDarkMode) {
    setThemeMode(isDarkMode ? ThemeMode.dark : ThemeMode.light);
  }

  void setThemeMode(ThemeMode mode) {
    if (_themeMode == mode) return;
    _themeMode = mode;
    _persistMode(mode);
    notifyListeners();
  }

  void setAccent(Color c) {
    if (_accent.toARGB32() == c.toARGB32()) return;
    _accent = c;
    _persistAccent(c);
    notifyListeners();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    // Theme mode: prefer the new key; fall back to the legacy isDarkMode bool so
    // an existing user's current light/dark choice is preserved across update.
    final modeStr = prefs.getString('themeModeStr');
    if (modeStr != null) {
      _themeMode = _modeFromString(modeStr);
    } else if (prefs.containsKey('isDarkMode')) {
      _themeMode = (prefs.getBool('isDarkMode') ?? false)
          ? ThemeMode.dark
          : ThemeMode.light;
    }
    final accentVal = prefs.getInt('accentColor');
    if (accentVal != null) _accent = Color(accentVal);
    notifyListeners();
  }

  Future<void> _persistMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('themeModeStr', _modeToString(mode));
    // Keep the legacy bool loosely in sync for any old reader.
    await prefs.setBool('isDarkMode', mode == ThemeMode.dark);
  }

  Future<void> _persistAccent(Color c) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('accentColor', c.toARGB32());
  }

  static String _modeToString(ThemeMode m) => m == ThemeMode.dark
      ? 'dark'
      : m == ThemeMode.light
          ? 'light'
          : 'system';

  static ThemeMode _modeFromString(String s) => s == 'dark'
      ? ThemeMode.dark
      : s == 'light'
          ? ThemeMode.light
          : ThemeMode.system;
}
