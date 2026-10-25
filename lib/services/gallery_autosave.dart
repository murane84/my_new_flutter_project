import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/token_helper.dart' show mediaAuthHeaders;
import '../utils/app_config.dart';
import '../utils/time_utils.dart' show parseServerTime;
import 'account_prefs.dart';
import 'media_store.dart';

/// "Save received photos & videos to my Gallery" (off by default).
///
/// Chat media leaves Aluta's server after 24 h. With this on, every photo
/// (and, optionally, video) someone sends me is copied into the phone's own
/// Gallery — an "Aluta" album — as it arrives, so nothing is lost.
///  • only media RECEIVED after the switch was turned on (never my history);
///  • never secret hearts (their media is the sender's to share);
///  • videos optionally only on Wi-Fi;
///  • each message saved once (remembered on this device).
/// The switches follow the account (AccountPrefs); the "from when" mark is
/// per device, so a new phone starts saving from the moment it's set up.
class GalleryAutoSave extends ChangeNotifier {
  GalleryAutoSave._();
  static final GalleryAutoSave instance = GalleryAutoSave._();

  static const kOn = 'gallery_autosave_on';
  static const kVideos = 'gallery_autosave_videos';
  static const kWifi = 'gallery_autosave_wifi';
  static const _kSince = 'gallery_autosave_since';
  static const _kSaved = 'gallery_saved_ids';

  bool on = false, videos = true, videosWifiOnly = true;
  int _since = 0;
  final Set<String> _saved = {};
  final Set<String> _busy = {};
  bool _loaded = false;

  bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    AccountPrefs.onRestore(_reload);
    await _reload();
  }

  Future<void> _reload() async {
    try {
      final p = await SharedPreferences.getInstance();
      on = p.getBool(kOn) ?? false;
      videos = p.getBool(kVideos) ?? true;
      videosWifiOnly = p.getBool(kWifi) ?? true;
      _since = p.getInt(_kSince) ?? 0;
      if (on && _since == 0) {
        // Switched on elsewhere (restored from the account): this device
        // starts from now, never sweeping old chats into the Gallery.
        _since = DateTime.now().millisecondsSinceEpoch;
        await p.setInt(_kSince, _since);
      }
      _saved
        ..clear()
        ..addAll(p.getStringList(_kSaved) ?? const []);
    } catch (_) {}
    notifyListeners();
  }

  /// Turn it on/off. ON asks for Gallery access first; returns false if the
  /// permission was refused (the switch stays off).
  Future<bool> setOn(bool v) async {
    if (v && supported) {
      final perm = await PhotoManager.requestPermissionExtend();
      if (!perm.hasAccess) return false;
    }
    on = v;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(kOn, v);
      if (v) {
        _since = DateTime.now().millisecondsSinceEpoch;
        await p.setInt(_kSince, _since);
      }
    } catch (_) {}
    AccountPrefs.touch();
    notifyListeners();
    return true;
  }

  Future<void> setVideos(bool v) async {
    videos = v;
    await _setBool(kVideos, v);
  }

  Future<void> setWifiOnly(bool v) async {
    videosWifiOnly = v;
    await _setBool(kWifi, v);
  }

  Future<void> _setBool(String k, bool v) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(k, v);
    } catch (_) {}
    AccountPrefs.touch();
    notifyListeners();
  }

  /// Look at a message that just arrived / loaded; save it if it qualifies.
  /// Cheap to call for every message (most return immediately).
  void consider(Map<String, dynamic> msg, String? myId) {
    if (!on || !supported || myId == null) return;
    final type = (msg['message_type'] ?? '').toString();
    final isVideo = type == 'video';
    if (type != 'image' && !isVideo) return;
    if (isVideo && !videos) return;
    if (msg['is_deleted'] == true || msg['__pending'] == true) return;
    final sender = (msg['sender_id'] ??
            (msg['sender'] is Map ? (msg['sender'] as Map)['id'] : null))
        ?.toString();
    if (sender == null || sender == myId) return; // only what I RECEIVE
    final id = msg['id']?.toString() ?? '';
    if (id.isEmpty || id.startsWith('tmp-')) return;
    if (_saved.contains(id) || !_busy.add(id)) return;
    final rel = (msg['media_url'] ?? '').toString();
    if (rel.isEmpty || rel.contains('giphy') || rel.contains('tenor')) {
      _busy.remove(id);
      return;
    }
    final raw = (msg['timestamp'] ?? '').toString();
    final ts = raw.isEmpty ? null : parseServerTime(raw);
    if (ts == null || ts.millisecondsSinceEpoch < _since - 60000) {
      _busy.remove(id); // from before I switched this on
      return;
    }
    unawaited(_save(id, rel, isVideo,
        (msg['media_name'] ?? '').toString(), msg['media_mime']?.toString()));
  }

  Future<void> _save(
      String id, String rel, bool isVideo, String name, String? mime) async {
    try {
      if (isVideo && videosWifiOnly) {
        final c = await Connectivity().checkConnectivity();
        if (!c.contains(ConnectivityResult.wifi) &&
            !c.contains(ConnectivityResult.ethernet)) {
          return; // try again next time it's seen on Wi-Fi
        }
      }
      // Never pop a permission prompt out of nowhere: the switch asked
      // already; a device restored from the account without access waits
      // until the user grants it from the setting.
      final perm = await PhotoManager.getPermissionState(
          requestOption: const PermissionRequestOption());
      if (!perm.hasAccess) return;
      final url = rel.startsWith('http') ? rel : '${await AppConfig.baseUrl}$rel';
      final f = await MediaStore.instance.getFile(url, mediaAuthHeaders(url));
      if (f == null) return;
      final fname = name.isNotEmpty
          ? name
          : 'aluta_${DateTime.now().millisecondsSinceEpoch}${isVideo ? '.mp4' : '.jpg'}';
      if (isVideo) {
        await PhotoManager.editor
            .saveVideo(f, title: fname, relativePath: 'Movies/Aluta');
      } else {
        await PhotoManager.editor.saveImage(await f.readAsBytes(),
            filename: fname, relativePath: 'Pictures/Aluta');
      }
      _saved.add(id);
      final p = await SharedPreferences.getInstance();
      // Keep the memory bounded (the newest 800 ids).
      final list = _saved.toList();
      await p.setStringList(
          _kSaved, list.length > 800 ? list.sublist(list.length - 800) : list);
    } catch (_) {
    } finally {
      _busy.remove(id);
    }
  }
}
