import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/adaptive_sheet.dart';
import '../utils/app_config.dart';
import '../utils/radii.dart';
import '../utils/toast_helper.dart';
import 'haptics.dart';

/// Updates for the Android app while Aluta lives outside the Play Store.
///
/// The server (routers/releases.py) says which build is newest; if mine is
/// older, a card offers it ("Later" hides that build for a day). A build
/// below `min_build` must update. Update downloads the APK with progress,
/// checks its SHA-256, and hands it to Android's installer.
///
/// Off on web / desktop / iOS, and in a Play Store build
/// (`--dart-define=PLAY_STORE=true`): Play forbids self-updating there.
class AppUpdater {
  AppUpdater._();
  static final AppUpdater instance = AppUpdater._();

  static const bool _playStore = bool.fromEnvironment('PLAY_STORE');
  static const _kSnooze = 'update_snooze_v1'; // "<build>|<epoch ms>"
  static const _kChecked = 'update_checked_v1'; // epoch ms of last auto check

  bool get supported =>
      !kIsWeb && !_playStore && defaultTargetPlatform == TargetPlatform.android;

  bool _busy = false;
  final ValueNotifier<double?> progress = ValueNotifier<double?>(null);

  /// The newest release if it's newer than this install, else null.
  Future<Map<String, dynamic>?> _newer() async {
    final base = await AppConfig.baseUrl;
    final resp = await http
        .get(Uri.parse('$base/app/latest?platform=android'))
        .timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) return null;
    final data = Map<String, dynamic>.from(jsonDecode(resp.body) as Map);
    final mine = int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0;
    final build = (data['build'] as num?)?.toInt() ?? 0;
    if (build <= mine) return null;
    data['__mine'] = mine;
    return data;
  }

  /// At start-up: at most every 6 hours, quietly. [manual]: from the menu —
  /// always checks and says when everything is up to date.
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
      if (!manual) {
        final last = p.getInt(_kChecked) ?? 0;
        if (now - last < const Duration(hours: 6).inMilliseconds) return;
      }
      await p.setInt(_kChecked, now);
      final rel = await _newer();
      if (!context.mounted) return;
      if (rel == null) {
        if (manual) {
          showToast(context, 'You have the latest Aluta 💞',
              type: ToastType.success);
        }
        return;
      }
      final mine = rel['__mine'] as int;
      final required = mine < ((rel['min_build'] as num?)?.toInt() ?? 0);
      // "Later" on this build → quiet for a day (a required one always asks).
      if (!manual && !required) {
        final s = (p.getString(_kSnooze) ?? '').split('|');
        if (s.length == 2 &&
            s[0] == '${rel['build']}' &&
            now - (int.tryParse(s[1]) ?? 0) <
                const Duration(days: 1).inMilliseconds) {
          return;
        }
      }
      await _offer(context, rel, required: required);
    } catch (_) {
      if (manual && context.mounted) {
        showToast(context, 'Couldn’t check for updates — try again',
            type: ToastType.error);
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _offer(BuildContext context, Map<String, dynamic> rel,
      {required bool required}) async {
    final later = await showAdaptiveSheet<bool>(
      context: context,
      isDismissible: !required,
      enableDrag: !required,
      showDragHandle: !required,
      isScrollControlled: true,
      builder: (c) => PopScope(
        canPop: !required,
        child: _UpdateCard(rel: rel, required: required, updater: this),
      ),
    );
    if (later == true) {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          _kSnooze, '${rel['build']}|${DateTime.now().millisecondsSinceEpoch}');
    }
  }

  /// Download (with progress), verify, open the installer. Returns an error
  /// line, or null when the installer opened.
  Future<String?> install(Map<String, dynamic> rel) async {
    final base = await AppConfig.baseUrl;
    final url = '$base${rel['url'] ?? '/download/aluta.apk'}';
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

/// "Aluta 1.0.3 is ready" — what's new, Update / Later, then progress.
class _UpdateCard extends StatefulWidget {
  const _UpdateCard(
      {required this.rel, required this.required, required this.updater});
  final Map<String, dynamic> rel;
  final bool required;
  final AppUpdater updater;

  @override
  State<_UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<_UpdateCard> {
  bool _working = false;
  String? _error;

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
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(_error!,
                    style: const TextStyle(color: Color(0xFFE53935))),
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
