// "Install Aluta Admin on your home screen". Chrome / Edge / Android fire
// `beforeinstallprompt`; tool/build_admin.ps1 adds a tiny script to the admin
// index.html that catches it before Flutter has loaded (it can fire early), and
// this file installs the same catcher in case it fires later. iPhone/iPad
// Safari has no prompt — we show the Share → "Add to Home Screen" steps instead.
// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'admin_widgets.dart';

const String _js = r'''
(function () {
  if (globalThis.__alutaInstallWired) return;
  globalThis.__alutaInstallWired = true;
  globalThis.addEventListener('beforeinstallprompt', function (e) {
    e.preventDefault();
    globalThis.__alutaInstall = e;
    if (globalThis.__alutaOnInstallReady) globalThis.__alutaOnInstallReady();
  });
  globalThis.addEventListener('appinstalled', function () {
    globalThis.__alutaInstall = null;
    globalThis.__alutaInstalled = true;
    if (globalThis.__alutaOnInstallReady) globalThis.__alutaOnInstallReady();
  });
})();
globalThis.alutaAdminInstall = {
  ready: function () { return !!globalThis.__alutaInstall; },
  installed: function () {
    return !!(globalThis.__alutaInstalled ||
      (globalThis.matchMedia &&
        globalThis.matchMedia('(display-mode: standalone)').matches) ||
      (globalThis.navigator && globalThis.navigator.standalone === true));
  },
  ios: function () {
    var ua = (globalThis.navigator && globalThis.navigator.userAgent) || '';
    var iPadOs = /Macintosh/.test(ua) && globalThis.navigator.maxTouchPoints > 1;
    return /iPhone|iPad|iPod/.test(ua) || iPadOs;
  },
  prompt: async function () {
    var e = globalThis.__alutaInstall;
    if (!e) return 'unavailable';
    e.prompt();
    var choice = await e.userChoice;
    globalThis.__alutaInstall = null;
    return (choice && choice.outcome) || 'dismissed';
  }
};
''';

extension type _InstallApi._(JSObject _) implements JSObject {
  external JSBoolean ready();
  external JSBoolean installed();
  external JSBoolean ios();
  external JSPromise<JSString> prompt();
}

class AdminInstall {
  AdminInstall._();
  static final AdminInstall instance = AdminInstall._();

  /// What to offer right now: null = nothing, 'prompt' = one-tap install,
  /// 'ios' = show the Share → Add to Home Screen steps.
  final ValueNotifier<String?> offer = ValueNotifier<String?>(null);

  static const _kSnooze = 'aluta_admin_install_snooze_until';
  _InstallApi? _api;
  bool _snoozed = false;

  Future<void> init() async {
    try {
      if (!globalContext.has('alutaAdminInstall')) {
        globalContext.callMethod('eval'.toJS, _js.toJS);
      }
      _api = globalContext.getProperty<_InstallApi>('alutaAdminInstall'.toJS);
      globalContext.setProperty(
          '__alutaOnInstallReady'.toJS, (() => _refresh()).toJS);
      final p = await SharedPreferences.getInstance();
      final until = p.getInt(_kSnooze) ?? 0;
      _snoozed = DateTime.now().millisecondsSinceEpoch < until;
    } catch (_) {}
    _refresh();
  }

  void _refresh() {
    final api = _api;
    if (api == null || _snoozed) {
      offer.value = null;
      return;
    }
    try {
      if (api.installed().toDart) {
        offer.value = null;
      } else if (api.ready().toDart) {
        offer.value = 'prompt';
      } else if (api.ios().toDart) {
        offer.value = 'ios';
      } else {
        offer.value = null;
      }
    } catch (_) {
      offer.value = null;
    }
  }

  /// Shows the browser's install dialog. Returns true when installed.
  Future<bool> install() async {
    final api = _api;
    if (api == null) return false;
    try {
      final r = (await api.prompt().toDart).toDart;
      _refresh();
      return r == 'accepted';
    } catch (_) {
      return false;
    }
  }

  /// "Not now" — ask again in a week.
  Future<void> snooze() async {
    _snoozed = true;
    offer.value = null;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(
          _kSnooze,
          DateTime.now()
              .add(const Duration(days: 7))
              .millisecondsSinceEpoch);
    } catch (_) {}
  }
}

/// The "Install on your home screen" card. [onGradient] = drawn on the red
/// sign-in backdrop (white text); otherwise it follows the dashboard theme.
class AdminInstallCard extends StatelessWidget {
  const AdminInstallCard({super.key, this.onGradient = false});
  final bool onGradient;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: AdminInstall.instance.offer,
      builder: (context, offer, _) {
        if (offer == null) return const SizedBox.shrink();
        final p = context.adm;
        final ios = offer == 'ios';
        final text = onGradient ? Colors.white : p.text;
        final muted = onGradient ? Colors.white70 : p.muted;
        return Container(
          margin: const EdgeInsets.only(top: 14),
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          decoration: BoxDecoration(
            color: onGradient
                ? Colors.white.withAlpha(22)
                : kAdminRed.withValues(alpha: p.dark ? 0.14 : 0.07),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: onGradient
                    ? Colors.white.withAlpha(60)
                    : kAdminRed.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              AdminIconChip(
                icon: ios
                    ? Icons.ios_share_rounded
                    : Icons.install_mobile_rounded,
                color: kAdminRed,
                size: 38,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Install Aluta Admin',
                        style: TextStyle(
                            color: text,
                            fontWeight: FontWeight.w700,
                            fontSize: 14)),
                    const SizedBox(height: 2),
                    Text(
                      ios
                          ? 'In Safari tap Share (the square with an arrow), '
                              'then “Add to Home Screen”.'
                          : 'Open it from your home screen or taskbar like an '
                              'app — one tap, full screen.',
                      style: TextStyle(color: muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              if (!ios)
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: onGradient ? Colors.white : kAdminRed,
                    foregroundColor: onGradient ? kAdminRed : Colors.white,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () async {
                    final ok = await AdminInstall.instance.install();
                    if (ok && context.mounted) {
                      adminToast(context, 'Installed — find Aluta Admin on '
                          'your home screen');
                    }
                  },
                  child: const Text('Install'),
                ),
              IconButton(
                tooltip: ios ? 'Got it' : 'Not now',
                onPressed: AdminInstall.instance.snooze,
                icon: Icon(Icons.close_rounded, color: muted, size: 20),
              ),
            ],
          ),
        );
      },
    );
  }
}
