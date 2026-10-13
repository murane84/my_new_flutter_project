import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Optional subtle typing feedback: a soft "tick" when a character is typed and
/// a slightly duller "tock" when one is deleted. Off by default; toggled in
/// Appearance settings. A tiny round-robin player pool keeps fast typing from
/// cutting itself off.
class KeystrokeSounds {
  KeystrokeSounds._();
  static final KeystrokeSounds instance = KeystrokeSounds._();

  static const String prefKey = 'keystroke_sounds';

  bool enabled = false;
  bool _poolReady = false;
  final List<AudioPlayer> _pool = [];
  int _rr = 0;

  /// Load the saved preference (and warm the player pool if on).
  Future<void> init() async {
    try {
      final p = await SharedPreferences.getInstance();
      enabled = p.getBool(prefKey) ?? false;
    } catch (_) {}
    if (enabled) await _ensurePool();
  }

  Future<void> setEnabled(bool value) async {
    enabled = value;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(prefKey, value);
    } catch (_) {}
    if (value) await _ensurePool();
  }

  Future<void> _ensurePool() async {
    if (_poolReady) return;
    try {
      for (var i = 0; i < 3; i++) {
        final pl = AudioPlayer();
        await pl.setReleaseMode(ReleaseMode.stop);
        try {
          await pl.setPlayerMode(PlayerMode.lowLatency);
        } catch (_) {/* some platforms ignore this */}
        _pool.add(pl);
      }
      _poolReady = true;
    } catch (_) {}
  }

  void _play(String asset) {
    if (!enabled || !_poolReady || _pool.isEmpty) return;
    final pl = _pool[_rr % _pool.length];
    _rr++;
    // Fire and forget; the WAVs are already quiet so volume handling quirks
    // across platforms don't matter.
    pl.play(AssetSource(asset), volume: 0.6).catchError((_) {});
  }

  void playType() => _play('sounds/type.wav');
  void playDelete() => _play('sounds/delete.wav');
}
