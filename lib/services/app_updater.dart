import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  static const _kPending = 'update_pending_v1'; // "<slot>|<build>"
  static const _kPrompted = 'update_prompted_v1'; // "<build>|<epoch ms>"
  static const Duration _remindEvery = Duration(hours: 6);

  // Web: an open tab keeps running the code it loaded; deploy_web.bat
  // builds the number in (ALUTA_BUILD) to compare with what's deployed.
  static const int _webBuilt = int.fromEnvironment('ALUTA_BUILD');

  Timer? _cycle;
  bool get _cycleOn => supported || (kIsWeb && _webBuilt > 0);

  Future<int> _mine() async => kIsWeb
      ? _webBuilt
      : int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0;

  /// From Home once: the 6-hour reminder cycle (it only acts while a newer
  /// build the server announced is still not installed).
  void startCycle(BuildContext Function() context) {
    if (!_cycleOn || _cycle != null || _life != null) return;
    void tick() {
      final c = context();
      if (c.mounted) _remind(c);
    }
    Future.delayed(const Duration(seconds: 10), tick); // after a restart
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
    await p.setString(_kPending, '$slot|$build');
    // In the background: remember it; the prompt comes on coming back.
    if (!_inFront) return;
    // Once per announced build; the 6-hour cycle does the reminding.
    final s = (p.getString(_kPrompted) ?? '').split('|');
    final promptedThis = s.length == 2 && s[0] == '$build';
    if (promptedThis) {
      if (context.mounted) _remind(context);
      return;
    }
    // A little jitter so every open app doesn't hit the server at once.
    await Future.delayed(
        Duration(milliseconds: 300 + DateTime.now().microsecond % 3000));
    if (context.mounted) await _prompt(context, '${v['version'] ?? ''}', build);
  }

  /// The 6-hour reminder: a newer build is waiting and it's been 6 h since
  /// the last prompt → prompt again. Installed → the cycle stops.
  Future<void> _remind(BuildContext context) async {
    if (!_inFront) return;
    final p = await SharedPreferences.getInstance();
    final pend = (p.getString(_kPending) ?? '').split('|');
    if (pend.length != 2) return;
    final build = int.tryParse(pend[1]) ?? 0;
    if (build <= await _mine()) {
      await p.remove(_kPending);
      available.value = null;
      return;
    }
    final s = (p.getString(_kPrompted) ?? '').split('|');
    final last = s.length == 2 && s[0] == '$build'
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

  /// Older servers send `app_update` {platform, build}: same as a publish.
  Future<void> announced(
      BuildContext context, int build, String platform) async {
    if (!supported || build <= 0) return;
    // A Windows build means nothing to a phone, and the other way round.
    if ((platform == 'windows') != !_android) return;
    await onServerVersions(context, {
      platform: {'build': build}
    });
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
        await p.setString(_kPending, '${await _slot()}|${rel['build']}');
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

  /// Download (with progress), verify, open the installer. Returns an error
  /// line, or null when the installer (Windows: the browser download) opened.
  Future<String?> install(Map<String, dynamic> rel) async {
    final base = await AppConfig.baseUrl;
    final url = '$base${rel['url'] ?? '/download/aluta.apk'}';
    if (!_android) {
      final ok = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
      return ok
          ? null
          : 'Couldn’t open the download — get it from aluta.ozilane.com/download';
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/aluta-${rel['build']}.apk');
    progress.value = 0;
    final client = http.Client();
    try {
      final resp = await client.send(http.Request('GET', Uri.parse(url)));
      if (resp.statusCode != 200) return 'The download isn’t available';
      final total = resp.contentLength ?? (rel['size'] as num?)?.toInt() ?? 0;
      final sink = file.openWrite();
      final hasher = Sha256().newHashSink();
      var got = 0;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        hasher.add(chunk);
        got += chunk.length;
        if (total > 0) progress.value = got / total;
      }
      await sink.close();
      hasher.close();
      final want = (rel['sha256'] ?? '').toString();
      if (want.isNotEmpty) {
        final h = (await hasher.hash()).bytes;
        final hex = h.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        if (hex != want) {
          await file.delete().catchError((_) => file);
          return 'The download was damaged — try again';
        }
      }
      progress.value = 1;
      final r = await OpenFilex.open(file.path,
          type: 'application/vnd.android.package-archive');
      if (r.type != ResultType.done) {
        return 'Allow Aluta to install apps, then tap Update again';
      }
      return null;
    } catch (_) {
      return 'The download stopped — check your connection';
    } finally {
      client.close();
      if (progress.value != 1) progress.value = null;
    }
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

  @override
  void initState() {
    super.initState();
    if (widget.start) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _update();
      });
    }
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
    final rel = widget.rel;
    final notes = (rel['notes'] ?? '')
        .toString()
        .split('\n')
        .map((l) => l.replaceFirst(RegExp(r'^[-•*]\s*'), '').trim())
        .where((l) => l.isNotEmpty)
        .take(6)
        .toList();
    final size = (rel['size'] as num?)?.toInt() ?? 0;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: Icon(Icons.system_update_rounded,
                    color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        widget.required
                            ? 'Please update Aluta'
                            : 'Aluta ${rel['version']} is ready',
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w800)),
                    Text(
                        widget.required
                            ? 'This version can’t keep up with the new server — '
                                'update to keep chatting.'
                            : size > 0
                                ? '${(size / 1048576).toStringAsFixed(0)} MB · your chats stay as they are'
                                : 'Your chats stay as they are',
                        style: TextStyle(
                            fontSize: 13, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ]),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text('What’s new',
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface)),
              const SizedBox(height: 4),
              for (final n in notes)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text('•  $n',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
            ],
            const SizedBox(height: 16),
            ValueListenableBuilder<double?>(
              valueListenable: widget.updater.progress,
              builder: (_, v, _) => !_working
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(Radii.sm),
                        child: LinearProgressIndicator(
                            value: (v == null || v <= 0) ? null : v,
                            minHeight: 6),
                      ),
                    ),
            ),
            if (_error != null) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(_error!,
                    style: const TextStyle(color: Color(0xFFE53935))),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: widget.updater.openDownloadPage,
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('Get it from the download page'),
                ),
              ),
            ],
            if (defaultTargetPlatform == TargetPlatform.windows)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                    'The new version downloads in your browser — close Aluta, '
                    'unzip it over your Aluta folder and open it again.',
                    style: TextStyle(
                        fontSize: 12.5, color: scheme.onSurfaceVariant)),
              ),
            Row(children: [
              if (!widget.required)
                TextButton(
                  onPressed:
                      _working ? null : () => Navigator.of(context).pop(true),
                  child: const Text('Later'),
                ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _working ? null : _update,
                icon: const Icon(Icons.download_rounded),
                label: Text(_working ? 'Downloading…' : 'Update'),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
