import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/app_config.dart';

/// Token storage.
///
/// flutter_secure_storage is unreliable in browsers (the web build stores the
/// token but reads can silently return null), which made every authenticated
/// request fail on the web PWA. So on web we use shared_preferences (backed by
/// localStorage — rock solid), and keep the encrypted secure storage on native.
final FlutterSecureStorage _storage = FlutterSecureStorage();

Future<void> saveToken(String token) async {
  _cachedAccessToken = token; // keep the sync cache (media headers) in step
  try {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConfig.tokenKey, token);
    } else {
      await _storage.write(key: AppConfig.tokenKey, value: token);
    }
  } catch (_) {/* best-effort */}
}

Future<String?> getToken() async {
  try {
    final t = kIsWeb
        ? (await SharedPreferences.getInstance()).getString(AppConfig.tokenKey)
        : await _storage.read(key: AppConfig.tokenKey);
    _cachedAccessToken = t; // refresh the sync cache used by media loaders
    return t;
  } catch (_) {
    return _cachedAccessToken;
  }
}

Future<void> removeToken() async {
  _cachedAccessToken = null;
  try {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(AppConfig.tokenKey);
    } else {
      await _storage.delete(key: AppConfig.tokenKey);
    }
  } catch (_) {/* best-effort */}
}

// ── Refresh token ───────────────────────────────────────────────────────────
// Long-lived (30 days). Used to silently mint a new access token so an expired
// access token never bounces the user to the login screen.
const String _refreshKey = 'refresh_token';

Future<void> saveRefreshToken(String token) async {
  try {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_refreshKey, token);
    } else {
      await _storage.write(key: _refreshKey, value: token);
    }
  } catch (_) {/* best-effort */}
}

Future<String?> getRefreshToken() async {
  try {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_refreshKey);
    }
    return await _storage.read(key: _refreshKey);
  } catch (_) {
    return null;
  }
}

Future<void> removeRefreshToken() async {
  try {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_refreshKey);
    } else {
      await _storage.delete(key: _refreshKey);
    }
  } catch (_) {/* best-effort */}
}

// ── Media auth ───────────────────────────────────────────────────────────────
// In-memory copies of the access token AND our API origin, kept for widgets
// that need them SYNCHRONOUSLY (image / file / audio widgets build without
// awaiting, so they read from here). Warmed by warmMediaAuth() at startup.
String? _cachedAccessToken;
String? _cachedApiBase;

/// Prime the synchronous caches (token + API base) before the first UI frame,
/// so media loaders can attach the right auth header immediately and never 401
/// on a cold start. In release the base resolves instantly to the prod origin.
Future<void> warmMediaAuth() async {
  await getToken(); // populates _cachedAccessToken
  try {
    _cachedApiBase = await AppConfig.baseUrl;
  } catch (_) {/* falls back to relative-only matching */}
}

/// Authorization header for fetching OUR OWN protected media. The token is
/// attached ONLY when the URL is on our own backend — a relative path, or an
/// absolute URL under our API origin — AND points at a media route
/// (`/attachments/` or `/media/`). This is deliberately host-scoped: an
/// external host must NEVER receive our JWT. That matters because
///   • GIF CDNs (e.g. GIPHY, whose URLs are https://media.giphy.com/media/…)
///     would otherwise match on the `/media/` substring and both leak the token
///     AND get rejected by the CDN (breaking GIF display); and
///   • `media_url` is client-writable, so a malicious sender could set an image
///     URL to https://evil.com/attachments/x to try to exfiltrate the token.
/// Host-scoping closes both.
Map<String, String> mediaAuthHeaders(String url) {
  final t = _cachedAccessToken;
  if (t == null || t.isEmpty) return const {};
  final base = _cachedApiBase;
  final onOurBackend = !url.startsWith('http') || // relative → our own origin
      (base != null && base.isNotEmpty && url.startsWith(base));
  if (!onOurBackend) return const {};
  if (url.contains('/attachments/') || url.contains('/media/')) {
    return {'Authorization': 'Bearer $t'};
  }
  return const {};
}
