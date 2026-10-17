import 'dart:io' show Platform;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:shared_preferences/shared_preferences.dart';

/// In-app sound effects, with two INDEPENDENT switches:
///
///  * Keystroke sounds — a soft tick/tock while typing (off by default; many
///    people find key clicks distracting).
///  * Message tones — a light "whoosh" when your message is sent and a soft
///    ding when one arrives in the chat you're viewing (on by default).
///
/// On Android everything runs through a tiny native SoundPool bridge
/// (`aluta/keystroke`): SoundPool is built for short, frequent UI sounds —
/// play() is fire-and-forget, overlaps mix natively, and it never takes audio
/// focus — so fast typing can't jam the UI and the music keeps playing. Off
/// Android (desktop / web) it falls back to a small low-latency audioplayers
/// pool. (Class name kept for import stability; it's really the app's sound hub.)
class KeystrokeSounds {
  KeystrokeSounds._();
  static final KeystrokeSounds instance = KeystrokeSounds._();

  // Preference keys (kept separate so the two switches are independent).
  static const String prefKey = 'keystroke_sounds'; // typing ticks
  static const String prefMessages = 'message_tones'; // sent / received

  static const MethodChannel _ch = MethodChannel('aluta/keystroke');

  bool get _useNative => !kIsWeb && Platform.isAndroid;

  bool keystrokesEnabled = false;
  bool messagesEnabled = true;

  bool _loaded = false;
  bool _loading = false;
  int _lastTypeMs = 0;

  // Non-Android fallback players, keyed by sound name.
  final Map<String, List<AudioPlayer>> _pools = {};
  final Map<String, int> _rr = {};

  /// Load both saved preferences (and warm the engine if either is on).
  Future<void> init() async {
    try {
      final p = await SharedPreferences.getInstance();
      keystrokesEnabled = p.getBool(prefKey) ?? false;
      messagesEnabled = p.getBool(prefMessages) ?? true;
    } catch (_) {}
    if (keystrokesEnabled || messagesEnabled) await _ensureLoaded();
  }

  Future<void> setKeystrokesEnabled(bool value) async {
    keystrokesEnabled = value;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(prefKey, value);
    } catch (_) {}
    if (value) await _ensureLoaded();
  }

  Future<void> setMessagesEnabled(bool value) async {
    messagesEnabled = value;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(prefMessages, value);
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
        await _buildFallbackPools();
        _loaded = _pools.isNotEmpty;
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

  Future<void> _buildFallbackPools() async {
    // Typing needs overlap (2 voices); message tones are infrequent (1 each).
    _pools['type'] = [await _voice('sounds/type.wav'), await _voice('sounds/type.wav')];
    _pools['delete'] =
        [await _voice('sounds/delete.wav'), await _voice('sounds/delete.wav')];
    _pools['sent'] = [await _voice('sounds/sent.wav')];
    _pools['received'] = [await _voice('sounds/received.wav')];
  }

  void _fire(String which) {
    if (!_loaded) return;
    if (_useNative) {
      _ch.invokeMethod('play', {'which': which}).catchError((_) {});
    } else {
      final pool = _pools[which];
      if (pool == null || pool.isEmpty) return;
      final i = (_rr[which] ?? 0);
      _rr[which] = i + 1;
      pool[i % pool.length].resume().catchError((_) {});
    }
  }

  // ── Typing ticks (throttled: held/auto-repeat keys can't flood) ──────────
  void _tick(String which) {
    if (!keystrokesEnabled) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastTypeMs < 18) return; // ~55/s, well above human typing
    _lastTypeMs = now;
    _fire(which);
  }

  void playType() => _tick('type');
  void playDelete() => _tick('delete');

  // ── Message tones (no throttle; they're infrequent) ──────────────────────
  void playSent() {
    if (messagesEnabled) _fire('sent');
  }

  void playReceived() {
    if (messagesEnabled) _fire('received');
  }
}
