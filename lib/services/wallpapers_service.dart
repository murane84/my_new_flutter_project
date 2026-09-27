import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/app_config.dart';
import '../screens/token_helper.dart';

/// One preset wallpaper from the server gallery (GET /wallpapers).
/// [url] is the portrait image; [wideUrl] is an optional landscape variant used
/// to fill wide screens instead of tiling the portrait.
class WallpaperPreset {
  final String id;
  final String name;
  final String url; // e.g. "/wallpapers/w01"
  final String? wideUrl; // e.g. "/wallpapers/w01/wide"
  const WallpaperPreset({
    required this.id,
    required this.name,
    required this.url,
    this.wideUrl,
  });

  factory WallpaperPreset.fromJson(Map<String, dynamic> j) => WallpaperPreset(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        url: (j['url'] ?? '').toString(),
        wideUrl: (j['wide_url'] as String?),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        if (wideUrl != null) 'wide_url': wideUrl,
      };
}

const String _kCache = 'cached_wallpapers_v1';

/// Fetches and caches the preset wallpaper catalogue. Cache-first so the gallery
/// paints instantly and still works offline once seen; refreshes from the server
/// in the background.
class WallpapersService {
  WallpapersService._();
  static final WallpapersService instance = WallpapersService._();

  List<WallpaperPreset>? _mem;

  Future<List<WallpaperPreset>> load({bool forceRefresh = false}) async {
    if (_mem != null && !forceRefresh) return _mem!;
    final cached = await _readCache();
    if (cached.isNotEmpty && _mem == null) _mem = cached;
    try {
      final base = await AppConfig.baseUrl;
      final token = await getToken();
      final res = await http.get(
        Uri.parse('$base/wallpapers'),
        headers: token != null ? {'Authorization': 'Bearer $token'} : {},
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final body = jsonDecode(res.body);
        final List list = body is Map && body['wallpapers'] is List
            ? body['wallpapers'] as List
            : (body is List ? body : const []);
        final items = list
            .whereType<Map>()
            .map((m) => WallpaperPreset.fromJson(Map<String, dynamic>.from(m)))
            .where((w) => w.id.isNotEmpty && w.url.isNotEmpty)
            .toList();
        if (items.isNotEmpty) {
          _mem = items;
          await _writeCache(items);
        }
      }
    } catch (_) {}
    return _mem ?? cached;
  }

  Future<List<WallpaperPreset>> _readCache() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kCache);
      if (raw == null) return const [];
      final List list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((m) => WallpaperPreset.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _writeCache(List<WallpaperPreset> items) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
        _kCache,
        jsonEncode(items.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }
}
