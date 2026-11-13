import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:cryptography/cryptography.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/adaptive_sheet.dart';
import '../utils/app_config.dart';
import '../utils/radii.dart';
import '../utils/toast_helper.dart';
import 'haptics.dart';

/// Updates for the Android and Windows apps while Aluta lives outside the
/// stores.
///
/// The server (routers/releases.py) says which build is newest; if mine is
/// older, a card offers it ("Later" hides that build for a day). A build
/// below `min_build` must update.
///  • Android: downloads the APK that fits this phone (arm64, else the
///    universal one) with progress, checks its SHA-256, opens the installer.
///  • Windows: opens the new zip's download in the browser (a running app
///    can't replace its own files).
///
/// How it reaches people (so nobody sits on an old build):
///  • a toast "✨ Aluta 1.0.3 is ready" — Update starts it, a tap shows
///    what's new, Later hides that build for a day;
///  • after three Laters (or a build a week old) the card itself comes up;
///  • the SERVER starts it: a publish reaches every open app at once
///    (socket `app_versions`), closed Android phones by push, and anyone
///    offline the moment they reconnect; then the app re-reminds every
///    6 hours until the new build is installed (see "Server-first").
///  • web: the same signal, as a "Reload" toast.
///
/// In-app install: Android and Windows (web reloads). Off on iOS / macOS /
/// Linux, and in a store build (`--dart-define=PLAY_STORE=true`): Play
/// forbids self-updating there.
class AppUpdater {
  AppUpdater._();
  static final AppUpdater instance = AppUpdater._();

  static const bool _playStore = bool.fromEnvironment('PLAY_STORE');
  static const _kLaters = 'update_laters_v1'; // "<build>|<times Later>"
  static const kPushed = 'update_pushed_v1'; // build last announced by push

  /// The newer release found by the last check (null: up to date / unknown)
  /// — the menu shows "Update to 1.0.3" from it.
  final ValueNotifier<Map<String, dynamic>?> available =
      ValueNotifier<Map<String, dynamic>?>(null);

  AppLifecycleListener? _life;

  // ── Server-first ─────────────────────────────────────────────────────────
  // The SERVER starts every update prompt: when a build is published it
  // tells every open app at once (socket `app_versions`) and closed Android
  // phones by push; anyone offline hears it the moment their socket
  // reconnects (the server sends `app_versions` on every connect). Each
  // build is prompted ONCE when announced. Until it's installed, the app
  // reminds again every 6 hours (the cycle below), then goes quiet until
  // the server announces the next one. No blind polling.
  static const _kPending = 'update_pending_v1'; // "<slot>|<build>[|<min>]"
  static const _kPrompted = 'update_prompted_v1'; // "<build>|<epoch ms>"
  static const Duration _remindEvery = Duration(hours: 6);

  // Web: an open tab keeps running the code it loaded; deploy_web.bat
  // builds the number in (ALUTA_BUILD) to compare with what's deployed.
  static const int _webBuilt = int.fromEnvironment('ALUTA_BUILD');

  Timer? _cycle;
  int? _announcing; // the build being prompted from a server event right now
  BuildContext Function()? _homeCtx; // Home's context (outlives any sheet)
  bool get _cycleOn => supported || (kIsWeb && _webBuilt > 0);

  Future<int> _mine() async => kIsWeb
      ? _webBuilt
      : int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0;

  /// From Home once: the 6-hour reminder cycle (it only acts while a newer
  /// build the server announced is still not installed).
  void startCycle(BuildContext Function() context) {
    if (!_cycleOn || _cycle != null || _life != null) return;
    _homeCtx = context;
    void tick() {
      final c = context();
      if (c.mounted) _remind(c);
    }
    Future.delayed(const Duration(seconds: 10), tick); // after a restart
    _resumeWifiWait(context); // a "Wait for Wi-Fi" from before
    _cleanOld(); // update files for builds already installed
    _cycle = Timer.periodic(const Duration(minutes: 15), (_) => tick());
    _life = AppLifecycleListener(onResume: tick);
  }

  /// `app_versions` from the server (on connect, and on every publish).
  Future<void> onServerVersions(
      BuildContext context, Map<String, dynamic> versions) async {
    if (!_cycleOn) return;
    final slot = kIsWeb ? 'web' : await _slot();
    var v = versions[slot];
    if (v == null && slot == 'android-universal') v = versions['android'];
    if (v is! Map) return;
    final build = (v['build'] as num?)?.toInt() ?? 0;
    final mine = await _mine();
    final p = await SharedPreferences.getInstance();
    if (build <= mine) {
      // Up to date (or just updated): the cycle stops.
      await p.remove(_kPending);
      available.value = null;
      return;
    }
    final minB = (v['min_build'] as num?)?.toInt() ?? 0;
    await p.setString(_kPending, '$slot|$build|$minB');
    // In the background: remember it; the prompt comes on coming back.
    if (!_inFront) return;
    // Once per announced build; the 6-hour cycle does the reminding.
    // A REQUIRED update (mine < min_build) never waits: every time.
    final s = (p.getString(_kPrompted) ?? '').split('|');
    final promptedThis =
        s.length == 2 && s[0] == '$build' && mine >= minB;
    if (promptedThis) {
      if (context.mounted) _remind(context);
      return;
    }
    // The same publish arrives as two events (app_versions + the legacy
    // app_update) within a second: only the first one prompts.
    if (_announcing == build) return;
    _announcing = build;
    try {
      // A little jitter so every open app doesn't hit the server at once.
      await Future.delayed(
          Duration(milliseconds: 300 + DateTime.now().microsecond % 3000));
      if (context.mounted) {
        await _prompt(context, '${v['version'] ?? ''}', build);
      }
    } finally {
      // Kept for a minute so a late duplicate is still ignored.
      Future.delayed(const Duration(minutes: 1), () {
        if (_announcing == build) _announcing = null;
      });
    }
  }

  /// The 6-hour reminder: a newer build is waiting and it's been 6 h since
  /// the last prompt → prompt again. Installed → the cycle stops.
  Future<void> _remind(BuildContext context) async {
    if (!_inFront) return;
    final ready = _readyUnseen;
    if (ready != null) {
      _readyUnseen = null;
      _toastReady(context, ready.rel, ready.file);
      return;
    }
    final p = await SharedPreferences.getInstance();
    final pend = (p.getString(_kPending) ?? '').split('|');
    if (pend.length < 2) return;
    final build = int.tryParse(pend[1]) ?? 0;
    final minB = pend.length > 2 ? int.tryParse(pend[2]) ?? 0 : 0;
    final mine = await _mine();
    if (build <= mine) {
      await p.remove(_kPending);
      available.value = null;
      return;
    }
    final s = (p.getString(_kPrompted) ?? '').split('|');
    // Required (mine < min_build): no 6-hour wait — the card comes back.
    final last = s.length == 2 && s[0] == '$build' && mine >= minB
        ? int.tryParse(s[1]) ?? 0
        : 0;
    if (DateTime.now().millisecondsSinceEpoch - last <
        _remindEvery.inMilliseconds) {
      return;
    }
    if (context.mounted) await _prompt(context, '', build);
  }

  Future<void> _prompt(BuildContext context, String version, int build) async {
    if (kIsWeb) {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          _kPrompted, '$build|${DateTime.now().millisecondsSinceEpoch}');
      if (context.mounted) _webToast(context, version);
    } else {
      // check() records the prompt once it's actually shown — a failed
      // fetch (offline, server busy) is simply retried on the next tick.
      await check(context);
    }
  }

  /// Only prompt where it can be seen: a toast shown while Aluta is in the
  /// background would count as "prompted" and nobody would see it.
  bool get _inFront {
    final s = WidgetsBinding.instance.lifecycleState;
    return s == null || s == AppLifecycleState.resumed;
  }

  /// A push came in while Aluta was closed: remember the build so the
  /// cycle knows about it the next time the app runs.
  static Future<void> rememberPushed(int build) async {
    if (build <= 0) return;
    final p = await SharedPreferences.getInstance();
    final slot = defaultTargetPlatform == TargetPlatform.windows
        ? 'windows'
        : 'android';
    await p.setString(_kPending, '$slot|$build');
    await p.setString(
        _kPrompted, '$build|${DateTime.now().millisecondsSinceEpoch}');
  }

  void _webToast(BuildContext context, String version) {
    showToast(
      context,
      version.isEmpty ? '✨ A new Aluta is ready' : '✨ Aluta $version is ready',
      type: ToastType.info,
      duration: const Duration(seconds: 14),
      detail: 'Reload to get the new version — your chats stay',
      onTap: reloadWeb,
      actions: [ToastAction('Reload', reloadWeb)],
    );
  }

  /// Menu → Check for updates on the web: ask the live site now.
  Future<void> checkWeb(BuildContext context, {bool manual = false}) async {
    if (!kIsWeb) return;
    try {
      // Cache-busting query: past the browser cache and Flutter's worker.
      final r = await http
          .get(Uri.parse('${Uri.base.origin}/version.json'
              '?t=${DateTime.now().millisecondsSinceEpoch}'))
          .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      final j = Map<String, dynamic>.from(jsonDecode(r.body) as Map);
      final live = int.tryParse('${j['build_number']}') ?? 0;
      final ver = '${j['version'] ?? ''}';
      if (!context.mounted) return;
      if (_webBuilt > 0 && live > _webBuilt) {
        _webToast(context, ver);
      } else if (manual) {
        showToast(context, 'You have the latest Aluta ($ver) 💞',
            type: ToastType.success);
      }
    } catch (_) {
      if (manual && context.mounted) {
        showToast(context, 'Couldn’t check for updates — try again',
            type: ToastType.error);
      }
    }
  }

  /// Load the page again (the new build comes with it).
  void reloadWeb() {
    launchUrl(Uri.base, webOnlyWindowName: '_self');
  }

  bool get _android => defaultTargetPlatform == TargetPlatform.android;

  bool get supported =>
      !kIsWeb &&
      !_playStore &&
      (_android || defaultTargetPlatform == TargetPlatform.windows);

  /// Which published file fits this device: arm64 phones get the small
  /// split APK, older / 32-bit phones the universal one.
  String? _slotMemo;
  Future<String> _slot() async {
    if (_slotMemo != null) return _slotMemo!;
    if (!_android) return _slotMemo = 'windows';
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return _slotMemo = info.supported64BitAbis.contains('arm64-v8a')
          ? 'android'
          : 'android-universal';
    } catch (_) {
      return _slotMemo = 'android-universal'; // installs everywhere
    }
  }

  bool _busy = false;
  final ValueNotifier<double?> progress = ValueNotifier<double?>(null);

  /// The newest release if it's newer than this install, else null.
  Future<Map<String, dynamic>?> _newer() async {
    final base = await AppConfig.baseUrl;
    final slot = await _slot();
    var resp = await http
        .get(Uri.parse('$base/app/latest?platform=$slot'))
        .timeout(const Duration(seconds: 12));
    // No universal build published → the arm64 one is the only choice.
    if (resp.statusCode == 404 && slot == 'android-universal') {
      resp = await http
          .get(Uri.parse('$base/app/latest?platform=android'))
          .timeout(const Duration(seconds: 12));
    }
    // Never call a failed answer "up to date" — that's how an unpublished
    // or lost release hid itself. 404 = nothing published for this slot.
    if (resp.statusCode == 404) throw const _NoRelease();
    if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
    final data = Map<String, dynamic>.from(jsonDecode(resp.body) as Map);
    final mine = int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0;
    final build = (data['build'] as num?)?.toInt() ?? 0;
    if (build <= mine) return null;
    data['__mine'] = mine;
    return data;
  }

  /// Fetch the newest release's details and prompt (toast, or the card when
  /// required / put off 3 times / a week old). Called by the server-first
  /// flow and its 6-hour reminders; [manual] (the menu) also says when
  /// everything is up to date.
  Future<void> check(BuildContext context, {bool manual = false}) async {
    if (!supported || _busy) {
      if (manual && !supported && context.mounted) {
        showToast(context, 'Updates for this app come from where you got it',
            type: ToastType.info);
      }
      return;
    }
    _busy = true;
    try {
      final p = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      final rel = await _newer();
      available.value = rel;
      // Whatever found it (server, reminder, the menu), the 6-hour cycle
      // follows this build until it's installed.
      if (rel == null) {
        await p.remove(_kPending);
      } else {
        await p.setString(_kPending,
            '${await _slot()}|${rel['build']}|${rel['min_build'] ?? 0}');
        // Shown now → the next reminder is 6 hours from here.
        await p.setString(_kPrompted, '${rel['build']}|$now');
      }
      if (!context.mounted) return;
      if (rel == null) {
        if (manual) {
          final v = (await PackageInfo.fromPlatform()).version;
          if (!context.mounted) return;
          showToast(context, 'You have the latest Aluta ($v) 💞',
              type: ToastType.success);
        }
        return;
      }
      final mine = rel['__mine'] as int;
      final required = mine < ((rel['min_build'] as num?)?.toInt() ?? 0);
      if (manual || required || _escalate(p, rel)) {
        await _offer(context, rel, required: required);
      } else {
        _nudge(context, rel);
      }
    } catch (e) {
      if (manual && context.mounted) {
        if (e is _NoRelease) {
          showToast(context, 'No download is published for this device yet',
              type: ToastType.info);
        } else {
          showToast(context, 'Couldn’t check for updates — try again',
              type: ToastType.error);
        }
      }
    } finally {
      _busy = false;
    }
  }

  /// Put off three times, or out for a week → the card, not a toast.
  bool _escalate(SharedPreferences p, Map<String, dynamic> rel) {
    final s = (p.getString(_kLaters) ?? '').split('|');
    final laters = s.length == 2 && s[0] == '${rel['build']}'
        ? int.tryParse(s[1]) ?? 0
        : 0;
    if (laters >= 3) return true;
    final at = DateTime.tryParse((rel['updated_at'] ?? '').toString());
    return at != null && DateTime.now().difference(at).inDays >= 7;
  }

  /// The gentle way: a toast that doesn't stop what they're doing.
  void _nudge(BuildContext context, Map<String, dynamic> rel) {
    Haptics.lightImpact();
    final note = (rel['notes'] ?? '')
        .toString()
        .split('\n')
        .map((l) => l.replaceFirst(RegExp(r'^[-•*]\s*'), '').trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    void open({bool start = false}) {
      if (context.mounted) {
        _offer(context, rel, required: false, start: start);
      }
    }

    showToast(
      context,
      '✨ Aluta ${rel['version']} is ready',
      type: ToastType.info,
      duration: const Duration(seconds: 12),
      detail: note.isEmpty ? 'Tap to see what’s new' : note,
      onTap: open,
      actions: [
        ToastAction('Later', () => _later(rel)),
        ToastAction('Update', () => open(start: true)),
      ],
    );
  }

  Future<void> _later(Map<String, dynamic> rel) async {
    final p = await SharedPreferences.getInstance();
    final b = '${rel['build']}';
    final s = (p.getString(_kLaters) ?? '').split('|');
    final n = (s.length == 2 && s[0] == b ? int.tryParse(s[1]) ?? 0 : 0) + 1;
    await p.setString(_kLaters, '$b|$n');
    // Later → the next reminder comes 6 hours from now.
    await p.setString(
        _kPrompted, '$b|${DateTime.now().millisecondsSinceEpoch}');
  }

  /// The download page in the browser — the way out if the in-app
  /// download or installer won't play along.
  Future<void> openDownloadPage() async {
    final base = await AppConfig.baseUrl;
    await launchUrl(Uri.parse('$base/download'),
        mode: LaunchMode.externalApplication);
  }

  Future<void> _offer(BuildContext context, Map<String, dynamic> rel,
      {required bool required, bool start = false}) async {
    if (_sheetUp) return;
    _sheetUp = true;
    try {
      await _showCard(context, rel, required: required, start: start);
    } finally {
      _sheetUp = false;
    }
  }

  bool _sheetUp = false;

  Future<void> _showCard(BuildContext context, Map<String, dynamic> rel,
      {required bool required, required bool start}) async {
    final later = await showAdaptiveSheet<bool>(
      context: context,
      isDismissible: !required,
      enableDrag: !required,
      showDragHandle: !required,
      isScrollControlled: true,
      builder: (c) => PopScope(
        canPop: !required,
        child: _UpdateCard(
            rel: rel, required: required, start: start, updater: this),
      ),
    );
    if (later == true) await _later(rel);
  }

  /// On mobile data right now (no Wi-Fi / cable)? Android only.
  Future<bool> onMobileData() async {
    if (!_android) return false;
    try {
      final r = await Connectivity().checkConnectivity();
      return r.contains(ConnectivityResult.mobile) &&
          !r.contains(ConnectivityResult.wifi) &&
          !r.contains(ConnectivityResult.ethernet);
    } catch (_) {
      return false;
    }
  }

  // ── Wait for Wi-Fi ───────────────────────────────────────────────────────
  // "Wait for Wi-Fi" on the card: the release is remembered; the moment the
  // phone is on Wi-Fi (now, or the next time Aluta runs) it downloads
  // quietly, then says "ready to install". Nothing spent on mobile data.
  static const _kWifiWait = 'update_wifi_wait_v1'; // the release JSON
  StreamSubscription<List<ConnectivityResult>>? _wifiSub;
  BuildContext Function()? _wifiCtx;
  bool _wifiBusy = false;

  /// Is a Wi-Fi download queued (the card shows it)?
  final ValueNotifier<bool> waitingForWifi = ValueNotifier<bool>(false);

  Future<void> waitForWifi(Map<String, dynamic> rel) async {
    final p = await SharedPreferences.getInstance();
    final keep = Map<String, dynamic>.from(rel)..remove('__mine');
    await p.setString(_kWifiWait, jsonEncode(keep));
    // Later-equivalent: the reminders wait 6 h (it's handled).
    await p.setString(
        _kPrompted, '${rel['build']}|${DateTime.now().millisecondsSinceEpoch}');
    _watchWifi(_homeCtx);
  }

  /// From the cycle: pick a queued Wi-Fi download back up after a restart.
  Future<void> _resumeWifiWait(BuildContext Function() context) async {
    if (!_android) return;
    final p = await SharedPreferences.getInstance();
    if ((p.getString(_kWifiWait) ?? '').isNotEmpty) _watchWifi(context);
  }

  void _watchWifi(BuildContext Function()? context) {
    _wifiCtx = context ?? _wifiCtx;
    waitingForWifi.value = true;
    _wifiSub ??= Connectivity().onConnectivityChanged.listen((r) {
      if (r.contains(ConnectivityResult.wifi) ||
          r.contains(ConnectivityResult.ethernet)) {
        _wifiDownload();
      }
    });
    _wifiDownload(); // maybe on Wi-Fi already
  }

  Future<bool> _onWifi() async {
    try {
      final r = await Connectivity().checkConnectivity();
      return r.contains(ConnectivityResult.wifi) ||
          r.contains(ConnectivityResult.ethernet);
    } catch (_) {
      return false;
    }
  }

  // Downloaded on Wi-Fi while Aluta was in the background: told on return.
  ({Map<String, dynamic> rel, File file})? _readyUnseen;

  void _toastReady(BuildContext c, Map<String, dynamic> rel, File file) {
    Haptics.lightImpact();
    showToast(
      c,
      '✨ Aluta ${rel['version']} is downloaded',
      type: ToastType.success,
      duration: const Duration(seconds: 14),
      detail: 'Got it on Wi-Fi — tap to install',
      onTap: () => _openInstaller(file),
      actions: [ToastAction('Install', () => _openInstaller(file))],
    );
  }

  /// Old update files (builds I already have) leave the phone's storage.
  Future<void> _cleanOld() async {
    if (!_android) return;
    try {
      final mine =
          int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0;
      final dir = await getTemporaryDirectory();
      await for (final f in dir.list()) {
        final m = RegExp(r'aluta-(\d+)\.apk(\.ok)?$').firstMatch(f.path);
        if (m != null && (int.tryParse(m.group(1)!) ?? 0) <= mine) {
          await f.delete().catchError((_) => f);
        }
      }
    } catch (_) {}
  }

  Future<void> _wifiDownload() async {
    if (_wifiBusy || !await _onWifi()) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kWifiWait) ?? '';
    if (raw.isEmpty) return;
    final rel = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final mine =
        int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0;
    if (((rel['build'] as num?)?.toInt() ?? 0) <= mine) {
      await _stopWifiWait();
      return;
    }
    _wifiBusy = true;
    try {
      final (file, err) = await _download(rel, quiet: true);
      if (file == null || err != null) return; // tries again on next Wi-Fi
      await _stopWifiWait();
      final c = _wifiCtx?.call();
      if (c == null || !c.mounted || !_inFront) {
        _readyUnseen = (rel: rel, file: file); // told when they're back
        return;
      }
      _toastReady(c, rel, file);
    } finally {
      _wifiBusy = false;
    }
  }

  Future<void> _stopWifiWait() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kWifiWait);
    await _wifiSub?.cancel();
    _wifiSub = null;
    waitingForWifi.value = false;
  }

  /// Download (with progress) + SHA-256 check. A copy already downloaded
  /// and verified (e.g. on Wi-Fi) is reused. → (file, null) or (null, why).
  Future<(File?, String?)> _download(Map<String, dynamic> rel,
      {bool quiet = false}) async {
    final base = await AppConfig.baseUrl;
    final url = '$base${rel['url'] ?? '/download/aluta.apk'}';
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/aluta-${rel['build']}.apk');
    final ok = File('${file.path}.ok'); // written only after a good check
    if (await file.exists() && await ok.exists()) return (file, null);
    if (!quiet) progress.value = 0;
    final client = http.Client();
    try {
      final resp = await client.send(http.Request('GET', Uri.parse(url)));
      if (resp.statusCode != 200) return (null, 'The download isn’t available');
      final total = resp.contentLength ?? (rel['size'] as num?)?.toInt() ?? 0;
      final sink = file.openWrite();
      final hasher = Sha256().newHashSink();
      var got = 0;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        hasher.add(chunk);
        got += chunk.length;
        if (!quiet && total > 0) progress.value = got / total;
      }
      await sink.close();
      hasher.close();
      final want = (rel['sha256'] ?? '').toString();
      if (want.isNotEmpty) {
        final h = (await hasher.hash()).bytes;
        final hex = h.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        if (hex != want) {
          await file.delete().catchError((_) => file);
          return (null, 'The download was damaged — try again');
        }
      }
      await ok.writeAsString('ok');
      if (!quiet) progress.value = 1;
      return (file, null);
    } catch (_) {
      return (null, 'The download stopped — check your connection');
    } finally {
      client.close();
      if (!quiet && progress.value != 1) progress.value = null;
    }
  }

  Future<String?> _openInstaller(File file) async {
    final r = await OpenFilex.open(file.path,
        type: 'application/vnd.android.package-archive');
    return r.type == ResultType.done
        ? null
        : 'Allow Aluta to install apps, then tap Update again';
  }

  /// Android: download (or reuse the Wi-Fi copy), verify, open the
  /// installer. Windows: the zip in the browser. → an error line, or null.
  Future<String?> install(Map<String, dynamic> rel) async {
    if (!_android) {
      final base = await AppConfig.baseUrl;
      final url = '$base${rel['url'] ?? '/download/aluta-windows.zip'}';
      final ok = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
      return ok
          ? null
          : 'Couldn’t open the download — get it from aluta.ozilane.com/download';
    }
    final (file, err) = await _download(rel);
    if (file == null) return err;
    await _stopWifiWait(); // done either way
    return _openInstaller(file);
  }

}

class _NoRelease implements Exception {
  const _NoRelease();
}

/// "Aluta 1.0.3 is ready" — what's new, Update / Later, then progress.
class _UpdateCard extends StatefulWidget {
  const _UpdateCard(
      {required this.rel,
      required this.required,
      required this.updater,
      this.start = false});
  final Map<String, dynamic> rel;
  final bool required;
  final bool start; // Update tapped on the toast → begin right away
  final AppUpdater updater;

  @override
  State<_UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<_UpdateCard> {
  bool _working = false;
  String? _error;
  bool _cell = false; // on mobile data (Android)
  String? _mineVersion; // "from 1.0.6"
  final _notesScroll = ScrollController();

  @override
  void dispose() {
    _notesScroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((i) {
      if (mounted) setState(() => _mineVersion = i.version);
    });
    widget.updater.onMobileData().then((cell) {
      if (!mounted) return;
      setState(() => _cell = cell);
      // Update tapped on the toast: start — unless that would spend mobile
      // data; then the card asks first (Download now / Wait for Wi-Fi).
      if (widget.start && !cell) _update();
    });
  }

  Future<void> _waitWifi() async {
    Haptics.selectionClick();
    await widget.updater.waitForWifi(widget.rel);
    if (!mounted) return;
    showToast(context,
        'We’ll download it on Wi-Fi and tell you when it’s ready 💞',
        type: ToastType.success);
    Navigator.of(context).pop(false);
  }

  Future<void> _update() async {
    Haptics.selectionClick();
    setState(() {
      _working = true;
      _error = null;
    });
    final err = await widget.updater.install(widget.rel);
    if (!mounted) return;
    setState(() {
      _working = false;
      _error = err;
    });
    // Installer open → the sheet can go (a required one stays until the
    // new build replaces this one).
    if (err == null && !widget.required) Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final rel = widget.rel;
    final notes = (rel['notes'] ?? '')
        .toString()
        .split('\n')
        .map((l) => l.replaceFirst(RegExp(r'^[-•*]\s*'), '').trim())
        .where((l) => l.isNotEmpty)
        .take(60) // any length — the list scrolls on its own
        .toList();
    final size = (rel['size'] as num?)?.toInt() ?? 0;
    final mb = size > 0 ? (size / 1048576).toStringAsFixed(0) : null;
    final windows = defaultTargetPlatform == TargetPlatform.windows;
    final deep = Color.alphaBlend(Colors.black.withValues(alpha: 0.35),
        scheme.primary);

    // A soft note box (mobile data / Windows / error), same look for all.
    Widget note(IconData icon, Widget text, {Widget? action, Color? tint}) =>
        Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
          decoration: BoxDecoration(
            color: (tint ?? scheme.primary).withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(Radii.lg),
            border: Border.all(
                color: (tint ?? scheme.primary).withValues(alpha: 0.18)),
          ),
          child: Row(children: [
            Icon(icon, size: 18, color: tint ?? scheme.primary),
            const SizedBox(width: 10),
            Expanded(child: text),
            ?action,
          ]),
        );

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── The hero: brand, the new version, what it costs ──────────
            Container(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.xl),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [scheme.primary, deep],
                ),
                boxShadow: [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.35),
                    blurRadius: 22,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Row(children: [
                Container(
                  width: 56,
                  height: 56,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(Radii.lg),
                  ),
                  child: Image.asset('assets/images/logo.png',
                      errorBuilder: (_, _, _) => Icon(
                          Icons.system_update_rounded,
                          color: scheme.primary)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(Radii.lg),
                        ),
                        child: Text(
                            widget.required ? 'UPDATE NEEDED' : '✨ NEW VERSION',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8)),
                      ),
                      const SizedBox(height: 6),
                      Text('Aluta ${rel['version']}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              height: 1.1)),
                      const SizedBox(height: 3),
                      Text(
                          [
                            if (_mineVersion != null) 'from $_mineVersion',
                            ?(mb == null ? null : '$mb MB'),
                            'your chats stay',
                          ].join(' · '),
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontSize: 12.5)),
                    ],
                  ),
                ),
              ]),
            ),
            if (widget.required)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                    'This version can’t keep up with the new server — '
                    'update to keep chatting.',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ),

            // ── What's new: clean rows, text wraps under itself ──────────
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 16),
              Row(children: [
                Text('What’s new',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurface)),
                const Spacer(),
                if (notes.length > 3)
                  Text('${notes.length} changes',
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
              ]),
              const SizedBox(height: 6),
              // Long notes scroll inside their own box (with a soft fade at
              // the bottom) — the card never grows past ~a third of the screen.
              ConstrainedBox(
                constraints: BoxConstraints(
                    maxHeight: (MediaQuery.sizeOf(context).height * 0.3)
                        .clamp(120.0, 300.0)),
                child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (r) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.white, Colors.white, Colors.transparent],
                    stops: [0, 0.86, 1],
                  ).createShader(r),
                  child: Scrollbar(
                    controller: _notesScroll,
                    child: SingleChildScrollView(
                      controller: _notesScroll,
                      padding: const EdgeInsets.only(right: 10, bottom: 18),
                      child: Column(children: [
                        for (final n in notes)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 7,
                                  height: 7,
                                  margin:
                                      const EdgeInsets.only(top: 7, right: 12),
                                  decoration: BoxDecoration(
                                    color: scheme.primary,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                Expanded(
                                  child: Text(n,
                                      style: TextStyle(
                                          fontSize: 14.5,
                                          height: 1.35,
                                          color: dark
                                              ? Colors.white
                                                  .withValues(alpha: 0.88)
                                              : scheme.onSurface)),
                                ),
                              ],
                            ),
                          ),
                      ]),
                    ),
                  ),
                ),
              ),
            ],

            // ── Notes: mobile data · Windows · something went wrong ──────
            if (_cell && !_working)
              ValueListenableBuilder<bool>(
                valueListenable: widget.updater.waitingForWifi,
                builder: (_, waiting, _) => note(
                  waiting
                      ? Icons.wifi_rounded
                      : Icons.signal_cellular_alt_rounded,
                  Text(
                      waiting
                          ? 'Waiting for Wi-Fi to download it — or get it now'
                          : 'You’re on mobile data${mb == null ? '' : ' — this uses $mb MB'}',
                      style: TextStyle(fontSize: 12.5, color: scheme.onSurface)),
                  // (a required update can't wait)
                  action: waiting || widget.required
                      ? null
                      : TextButton(
                          onPressed: _waitWifi,
                          child: const Text('Wait for Wi-Fi')),
                ),
              ),
            if (windows)
              note(
                Icons.folder_zip_rounded,
                Text(
                    'It downloads in your browser — close Aluta, unzip it over '
                    'your Aluta folder and open it again.',
                    style: TextStyle(fontSize: 12.5, color: scheme.onSurface)),
                action: IconButton(
                  tooltip: 'Download page (with install steps)',
                  onPressed: widget.updater.openDownloadPage,
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                ),
              ),
            if (_error != null)
              note(
                Icons.error_outline_rounded,
                Text(_error!,
                    style: TextStyle(fontSize: 12.5, color: scheme.onSurface)),
                tint: const Color(0xFFE53935),
                action: TextButton(
                  onPressed: widget.updater.openDownloadPage,
                  child: const Text('Download page'),
                ),
              ),

            // ── The action: a button that fills as it downloads ──────────
            const SizedBox(height: 18),
            if (_working)
              ValueListenableBuilder<double?>(
                valueListenable: widget.updater.progress,
                builder: (_, v, _) {
                  final f = (v ?? 0).clamp(0.0, 1.0);
                  final got = size > 0 ? (size * f / 1048576).round() : null;
                  final label = f >= 1
                      ? 'Opening the installer…'
                      : v == null || v <= 0
                          ? 'Starting the download…'
                          : got != null && mb != null
                              ? 'Downloading ${(f * 100).round()}% · $got of $mb MB'
                              : 'Downloading ${(f * 100).round()}%';
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.xxl),
                    child: SizedBox(
                      height: 54,
                      child: Stack(fit: StackFit.expand, children: [
                        ColoredBox(color: deep.withValues(alpha: 0.55)),
                        FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: (v == null || v <= 0) ? 0.04 : f,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(colors: [
                                scheme.primary,
                                Color.alphaBlend(
                                    Colors.white.withValues(alpha: 0.18),
                                    scheme.primary),
                              ]),
                            ),
                          ),
                        ),
                        Center(
                          child: Text(label,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 14.5)),
                        ),
                      ]),
                    ),
                  );
                },
              )
            else
              Row(children: [
                if (!widget.required)
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('Later'),
                  ),
                if (!widget.required) const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 54,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        shape: const StadiumBorder(),
                        textStyle: const TextStyle(
                            fontSize: 15.5, fontWeight: FontWeight.w800),
                      ),
                      onPressed: _update,
                      icon: Icon(windows
                          ? Icons.download_rounded
                          : Icons.system_update_rounded),
                      label: Text(_cell
                          ? 'Download now'
                          : windows
                              ? 'Download'
                              : 'Update now'),
                    ),
                  ),
                ),
              ]),
          ],
        ),
      ),
    );
  }
}
