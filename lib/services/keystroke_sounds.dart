import 'dart:io' show Platform;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:shared_preferences/shared_preferences.dart';

/// Optional subtle typing feedback: a soft "tick" when a character is typed and
/// a slightly duller "tock" when one is deleted. Off by default; toggled in
/// Appearance settings.
///
/// On Android the ticks run through a tiny native SoundPool bridge
/// (`aluta/keystroke`): SoundPool is built for short, frequent UI sounds —
/// play() is fire-and-forget and overlapping streams mix natively, so fast or
/// long typing can't back up the audio layer and jam the UI thread (which a
/// general audio player's per-keystroke calls did). It also never takes audio
/// focus, so the music keeps playing underneath.
///
/// Off Android (desktop / web) there's no SoundPool, so it falls back to a
/// small low-latency audioplayers pool — those platforms have the headroom.
class KeystrokeSounds {
  KeystrokeSounds._();
  static final KeystrokeSounds instance = KeystrokeSounds._();

  static const String prefKey = 'keystroke_sounds';
  static const MethodChannel _ch = MethodChannel('aluta/keystroke');

  bool get _useNative => !kIsWeb && Platform.isAndroid;

  bool enabled = false;
  bool _loaded = false;
  bool _loading = false;
  int _lastPlayMs = 0;

  // Non-Android fallback pool (desktop / web).
  final List<AudioPlayer> _typePool = [];
  final List<AudioPlayer> _deletePool = [];
  int _typeRr = 0;
  int _deleteRr = 0;

  /// Load the saved preference (and warm the engine if on).
  Future<void> init() async {
    try {
      final p = await SharedPreferences.getInstance();
      enabled = p.getBool(prefKey) ?? false;
    } catch (_) {}
    if (enabled) await _ensureLoaded();
  }

  Future<void> setEnabled(bool value) async {
    enabled = value;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(prefKey, value);
    } catch (_) {}
    if (value) await _ensureLoaded();
  }

  Future<void> _ensureLoaded() async {
    if (_loaded || _loading) return;
    _loading = true;
    try {
      if (_useNative) {
        final ok = await _ch.invokeMethod<bool>('load');
        _loaded = ok ?? false;
      } else {
        await _buildFallbackPool();
        _loaded = _typePool.isNotEmpty;
      }
    } catch (_) {
      _loaded = false;
    } finally {
      _loading = false;
    }
  }

  Future<AudioPlayer> _voice(String asset) async {
    final pl = AudioPlayer();
    try {
      await pl.setReleaseMode(ReleaseMode.stop);
    } catch (_) {}
    try {
      await pl.setPlayerMode(PlayerMode.lowLatency);
    } catch (_) {}
    try {
      await pl.setVolume(0.6);
    } catch (_) {}
    try {
      await pl.setSource(AssetSource(asset));
    } catch (_) {}
    return pl;
  }

  Future<void> _buildFallbackPool() async {
    for (var i = 0; i < 2; i++) {
      _typePool.add(await _voice('sounds/type.wav'));
      _deletePool.add(await _voice('sounds/delete.wav'));
    }
  }

  void _play(String which, List<AudioPlayer> pool, int Function() rr) {
    if (!enabled || !_loaded) return;
    // A tiny rate floor: auto-repeating/held keys can fire far faster than
    // anyone types. ~18ms (≈55/s) is well above human typing, so every real
    // keystroke still ticks.
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastPlayMs < 18) return;
    _lastPlayMs = now;
    if (_useNative) {
      // Fire and forget; a failed tick must never surface.
      _ch.invokeMethod('play', {'which': which}).catchError((_) {});
    } else {
      if (pool.isEmpty) return;
      pool[rr() % pool.length].resume().catchError((_) {});
    }
  }

  void playType() => _play('type', _typePool, () => _typeRr++);
  void playDelete() => _play('delete', _deletePool, () => _deleteRr++);
}
