import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:shared_preferences/shared_preferences.dart';

import 'account_prefs.dart';

/// Every vibration in Aluta goes through here, so the user's choice in
/// Appearance → Vibration is respected everywhere — never some taps buzzing
/// and others not. Same method names as [HapticFeedback].
///
/// • [enabled] — all vibration on/off (default on).
/// • Long-press is the exception: [hold] always answers, whatever the
///   setting — the "handshake" that a hold landed (Android's own long-press
///   buzz ignores app settings too, so this keeps every hold alike).
/// • [tabs] — the tick when switching a tab or section (Harmony · Circle ·
///   Glow, Circle's All · Status · Listening · Circle, Glow's categories,
///   Our Space sections). Default on; only matters while [enabled].
class Haptics {
  Haptics._() {
    _load();
    AccountPrefs.onRestore(_load);
  }
  static final Haptics instance = Haptics._();

  static const _kOn = 'haptics_on_v1';
  static const _kTabs = 'haptics_tabs_v1';

  final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);
  final ValueNotifier<bool> tabs = ValueNotifier<bool>(true);

  /// Phones / tablets only — desktop and web have nothing to vibrate.
  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      enabled.value = p.getBool(_kOn) ?? true;
      tabs.value = p.getBool(_kTabs) ?? true;
    } catch (_) {}
  }

  Future<void> setEnabled(bool v) async {
    enabled.value = v;
    await _save(_kOn, v);
    if (v) HapticFeedback.selectionClick(); // feel what you just enabled
  }

  Future<void> setTabs(bool v) async {
    tabs.value = v;
    await _save(_kTabs, v);
    if (v && enabled.value) HapticFeedback.selectionClick();
  }

  Future<void> _save(String k, bool v) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(k, v);
      AccountPrefs.touch();
    } catch (_) {}
  }

  /// Read the saved choice now (call once at start-up).
  static Future<void> init() => instance._load();

  static bool get _on => instance.enabled.value;

  /// Switching a tab / section — one light tick, on every tab bar alike.
  static Future<void> tab() async {
    if (_on && instance.tabs.value) await HapticFeedback.selectionClick();
  }

  /// A long-press landed (menu / sheet / peek opened, hold completed).
  /// Always on — the one vibration the Vibration switch leaves alone.
  static Future<void> hold() async {
    if (supported) await HapticFeedback.mediumImpact();
  }

  /// The same, for a long-press on an InkWell / ListTile: Android already
  /// buzzed for it natively, so only iOS needs ours (never two buzzes).
  static Future<void> holdInk() async {
    if (supported && defaultTargetPlatform == TargetPlatform.iOS) {
      await HapticFeedback.mediumImpact();
    }
  }

  /// The small ticks while a hold builds up (the secret heart racing).
  static Future<void> holdTick() async {
    if (supported) await HapticFeedback.selectionClick();
  }

  static Future<void> selectionClick() async {
    if (_on) await HapticFeedback.selectionClick();
  }

  static Future<void> lightImpact() async {
    if (_on) await HapticFeedback.lightImpact();
  }

  static Future<void> mediumImpact() async {
    if (_on) await HapticFeedback.mediumImpact();
  }

  static Future<void> heavyImpact() async {
    if (_on) await HapticFeedback.heavyImpact();
  }

  static Future<void> vibrate() async {
    if (_on) await HapticFeedback.vibrate();
  }
}
