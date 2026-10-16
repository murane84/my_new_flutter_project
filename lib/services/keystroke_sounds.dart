import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Optional subtle typing feedback: a soft "tick" when a character is typed and
/// a slightly duller "tock" when one is deleted. Off by default; toggled in
/// Appearance settings.
///
/// Two things made the first version misbehave and are fixed here:
///
///  1. Enabling it stopped the music. The default [AudioContext] asks Android
///     for audio focus, which pauses whatever is playing. We now give every
///     keystroke player a non-focus / "mix with others" context so it layers on
///     top of the song instead of interrupting it.
///
///  2. Fast typing went numb. The old code reloaded the WAV from assets on
///     every single keystroke, which can't keep up with a fast typist, so only
///     the first tap was audible. Now each sound is loaded ONCE into a small
///     ring of low-latency players (SoundPool on Android); a keystroke just
///     re-triggers the next player in the ring, so rapid taps overlap cleanly.
class KeystrokeSounds {
  KeystrokeSounds._();
  static final KeystrokeSounds instance = KeystrokeSounds._();

  static const String prefKey = 'keystroke_sounds';

  // A few preloaded voices per sound so fast typing overlaps instead of
  // cutting itself off.
  static const int _voicesPerSound = 4;

  bool enabled = false;
  bool _poolReady = false;

  final List<AudioPlayer> _typePool = [];
  final List<AudioPlayer> _deletePool = [];
  int _typeRr = 0;
  int _deleteRr = 0;
  int _lastPlayMs = 0;

  /// A context that plays the tick WITHOUT grabbing audio focus, so music and
  /// other audio keep playing underneath it.
  static final AudioContext _noFocusContext = AudioContext(
    android: const AudioContextAndroid(
      isSpeakerphoneOn: false,
      stayAwake: false,
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.assistanceSonification,
      audioFocus: AndroidAudioFocus.none,
    ),
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.ambient,
      options: const {AVAudioSessionOptions.mixWithOthers},
    ),
  );

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

  Future<AudioPlayer> _makeVoice(String asset) async {
    final pl = AudioPlayer();
    // Never take audio focus away from the music player.
    try {
      await pl.setAudioContext(_noFocusContext);
    } catch (_) {/* some platforms ignore this */}
    try {
      await pl.setReleaseMode(ReleaseMode.stop);
    } catch (_) {}
    try {
      await pl.setPlayerMode(PlayerMode.lowLatency);
    } catch (_) {/* some platforms ignore this */}
    try {
      await pl.setVolume(0.6);
    } catch (_) {}
    // Load the asset ONCE. From here on a keystroke only re-triggers playback,
    // which is cheap enough to keep up with fast typing.
    try {
      await pl.setSource(AssetSource(asset));
    } catch (_) {}
    return pl;
  }

  Future<void> _ensurePool() async {
    if (_poolReady) return;
    try {
      for (var i = 0; i < _voicesPerSound; i++) {
        _typePool.add(await _makeVoice('sounds/type.wav'));
        _deletePool.add(await _makeVoice('sounds/delete.wav'));
      }
      _poolReady = true;
    } catch (_) {}
  }

  void _trigger(List<AudioPlayer> pool, int Function() nextIndex) {
    if (!enabled || !_poolReady || pool.isEmpty) return;
    // Bound how often we touch the native audio layer. Held/auto-repeat keys
    // can fire far faster than anyone types, and hammering the platform
    // channel was jamming the UI thread. A ~30ms floor (≈33/s) is well above
    // human typing speed, so every real keystroke still ticks.
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastPlayMs < 30) return;
    _lastPlayMs = now;
    final pl = pool[nextIndex() % pool.length];
    // Just re-trigger the already-loaded source. In low-latency (SoundPool)
    // mode resume() replays from the start on its own; after a normal play the
    // ReleaseMode.stop resets the position, so resume() replays there too. We
    // deliberately do NOT seek: seek isn't supported in low-latency mode and
    // the extra per-keystroke platform call was the source of the overload.
    pl.resume().catchError((_) {});
  }

  void playType() => _trigger(_typePool, () => _typeRr++);
  void playDelete() => _trigger(_deletePool, () => _deleteRr++);
}
