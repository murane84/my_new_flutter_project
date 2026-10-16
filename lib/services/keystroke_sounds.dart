import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soundpool/soundpool.dart';

/// Optional subtle typing feedback: a soft "tick" when a character is typed and
/// a slightly duller "tock" when one is deleted. Off by default; toggled in
/// Appearance settings.
///
/// Built on Soundpool (native SoundPool on Android, the equivalent short-SFX
/// pools elsewhere). Why not a general audio player:
///
///  * A SoundPool never requests audio focus, so a tick layers on top of the
///    music instead of pausing it.
///  * play() is genuinely fire-and-forget — it kicks off a native stream and
///    returns immediately, and overlapping taps mix natively instead of
///    queueing. Fast / long typing therefore can't back up the audio layer and
///    jam the UI thread (which repeated audioplayers resume() calls did).
///
/// Each sound is loaded once; a keystroke is just a cheap play(id). Everything
/// is wrapped so a platform without a Soundpool backend (e.g. Windows desktop)
/// silently degrades to no ticks rather than throwing.
class KeystrokeSounds {
  KeystrokeSounds._();
  static final KeystrokeSounds instance = KeystrokeSounds._();

  static const String prefKey = 'keystroke_sounds';

  bool enabled = false;

  Soundpool? _pool;
  int? _typeId;
  int? _deleteId;
  bool _loaded = false;
  bool _loading = false;

  // A tiny rate floor: auto-repeating/held keys can fire far faster than anyone
  // types, and there's no point spawning a stream per event. ~18ms (≈55/s) is
  // well above human typing, so every real keystroke still ticks.
  int _lastPlayMs = 0;

  /// Load the saved preference (and warm the pool if on).
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
      final pool = Soundpool.fromOptions(
        options: const SoundpoolOptions(
          // Follows the media volume and, as a SoundPool, takes no audio focus,
          // so the music keeps playing underneath.
          streamType: StreamType.music,
          maxStreams: 8,
        ),
      );
      final typeData = await rootBundle.load('assets/sounds/type.wav');
      final deleteData = await rootBundle.load('assets/sounds/delete.wav');
      _typeId = await pool.load(typeData);
      _deleteId = await pool.load(deleteData);
      try {
        await pool.setVolume(soundId: _typeId, volume: 0.7);
        await pool.setVolume(soundId: _deleteId, volume: 0.7);
      } catch (_) {}
      _pool = pool;
      _loaded = true;
    } catch (_) {
      // No Soundpool backend here (or load failed) → ticks just stay silent.
      _loaded = false;
    } finally {
      _loading = false;
    }
  }

  void _trigger(int? soundId) {
    if (!enabled || !_loaded || soundId == null) return;
    final pool = _pool;
    if (pool == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastPlayMs < 18) return;
    _lastPlayMs = now;
    // Fire and forget; a failure to start one tick must never surface.
    pool.play(soundId).catchError((_) => 0);
  }

  void playType() => _trigger(_typeId);
  void playDelete() => _trigger(_deleteId);
}
