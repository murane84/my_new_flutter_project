import 'dart:async';

import 'package:flutter/foundation.dart';

import 'now_playing_presence.dart';

/// A calm reading of who's listening, for the places that change LAYOUT
/// with it (the Our Space hero, the Harmony badge, Circle's "Listening
/// now" zone and count). The raw presence flips on every pause, song
/// change or buffering gap; this one:
///  • shows a start only once playback has held for [startDelay];
///  • after a stop / pause keeps the song as "paused" for [stopGrace]
///    (a quick resume or the next song just carries on);
///  • changes song in place while it's showing.
/// Rings, dots and tune-in still read the raw presence — only what would
/// make things jump uses this.
class SteadyListening extends ChangeNotifier {
  SteadyListening._() {
    NowPlayingPresence.instance.addListener(_sync);
    _sync();
  }
  static final SteadyListening instance = SteadyListening._();

  static const startDelay = Duration(seconds: 2);
  static const stopGrace = Duration(seconds: 20);

  final Map<int, Map<String, dynamic>> _shown = {};
  final Set<int> _paused = {};
  final Map<int, Timer> _startTimers = {};
  final Map<int, Timer> _stopTimers = {};

  /// The song to show for [id] (playing, or paused within the grace).
  Map<String, dynamic>? trackFor(int id) => _shown[id];

  /// Shown, but stopped / paused right now (inside the grace).
  bool isPaused(int id) => _paused.contains(id);

  /// Shown and actually playing.
  bool isPlaying(int id) => _shown.containsKey(id) && !_paused.contains(id);

  void _sync() {
    final p = NowPlayingPresence.instance;
    var changed = false;
    final ids = {...p.ids, ..._shown.keys, ..._startTimers.keys};
    for (final id in ids) {
      final playing = p.trackFor(id);
      if (playing != null) {
        _stopTimers.remove(id)?.cancel();
        if (_shown.containsKey(id)) {
          // Already showing: a resume or the next song — update in place.
          if (_paused.remove(id) || !mapEquals(_shown[id], playing)) {
            changed = true;
          }
          _shown[id] = playing;
        } else {
          _startTimers[id] ??= Timer(startDelay, () {
            _startTimers.remove(id);
            final t = NowPlayingPresence.instance.trackFor(id);
            if (t == null) return; // it didn't hold
            _shown[id] = t;
            _paused.remove(id);
            notifyListeners();
          });
        }
      } else {
        _startTimers.remove(id)?.cancel();
        if (_shown.containsKey(id) && !_paused.contains(id)) {
          // Stopped / paused: keep it, softly, for the grace.
          _paused.add(id);
          final frozen = p.pausedTrackFor(id);
          if (frozen != null) _shown[id] = frozen;
          changed = true;
          _stopTimers[id]?.cancel();
          _stopTimers[id] = Timer(stopGrace, () {
            _stopTimers.remove(id);
            if (NowPlayingPresence.instance.trackFor(id) != null) return;
            _shown.remove(id);
            _paused.remove(id);
            notifyListeners();
          });
        }
      }
    }
    if (changed) notifyListeners();
  }

  /// Drop someone at once (blocked) — no grace.
  void forget(int id) {
    _startTimers.remove(id)?.cancel();
    _stopTimers.remove(id)?.cancel();
    _paused.remove(id);
    if (_shown.remove(id) != null) notifyListeners();
  }
}
