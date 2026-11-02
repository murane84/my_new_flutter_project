import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences held once loaded, so pages can read their saved copy
/// SYNCHRONOUSLY in initState and open complete on the very first frame —
/// instead of painting empty and filling in a moment later.
/// [warmPrefsNow] is called at start-up; null until then (pages fall back to
/// their normal async load).
SharedPreferences? prefsNow;

Future<SharedPreferences?> warmPrefsNow() async {
  try {
    return prefsNow ??= await SharedPreferences.getInstance();
  } catch (_) {
    return null;
  }
}
