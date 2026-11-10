import 'package:flutter/foundation.dart';

/// "Is a status of mine on its way?" — one signal for the whole app, fed by
/// ApiService.createStory itself (every way of posting goes through it:
/// the composer, Share as status, a song share…).
///
/// The "Your story" tile shows a posting ring while [busy] and a short
/// "Posted ✓" right after; Home refetches statuses when [posted] bumps, so
/// the new ring appears without a manual refresh.
class StoryPosting extends ChangeNotifier {
  StoryPosting._();
  static final StoryPosting instance = StoryPosting._();

  int _inFlight = 0;
  bool get busy => _inFlight > 0;

  /// Bumps once per successful post.
  int get posted => _posted;
  int _posted = 0;

  DateTime? _lastPostedAt;

  /// Posted within the last few seconds → "Posted ✓".
  bool get justPosted {
    final t = _lastPostedAt;
    return t != null &&
        DateTime.now().difference(t) < const Duration(seconds: 4);
  }

  void begin() {
    _inFlight++;
    notifyListeners();
  }

  void end({required bool ok}) {
    if (_inFlight > 0) _inFlight--;
    if (ok) {
      _posted++;
      _lastPostedAt = DateTime.now();
      // Let "Posted ✓" fall back to "Your story" on its own.
      Future.delayed(const Duration(seconds: 4, milliseconds: 100),
          notifyListeners);
    }
    notifyListeners();
  }
}
