import 'package:flutter/foundation.dart';

import '../screens/api_service.dart';

/// "Tell me when they're online" — the friends I'm waiting on. The server
/// holds the real one-shot watch (it fires a push even when Aluta is closed);
/// this mirrors it so sheets can show "Stop waiting" and drop it once fired.
class OnlineWatchList extends ChangeNotifier {
  OnlineWatchList._();
  static final OnlineWatchList instance = OnlineWatchList._();

  final Set<int> _ids = {};
  bool isWatching(int id) => _ids.contains(id);

  // Friends I was about to Listen Together with when they were offline —
  // their "online now" card then offers Listen together in one tap.
  final Set<int> _listenIntent = {};
  bool wantsListen(int id) => _listenIntent.contains(id);
  void clearListen(int id) => _listenIntent.remove(id);

  /// Watch [id] for the next online moment, remembering it's for a listen.
  /// Returns 'watching' / 'online' / null (failed).
  Future<String?> watchForListen(int id) async {
    // Stored on the server with the watch (purpose=listen), so the heads-up
    // on ANY of my devices offers Listen together — even after a reinstall.
    final res = await ApiService().setOnlineWatch(id, true, purpose: 'listen');
    if (res == 'watching') {
      _ids.add(id);
      _listenIntent.add(id);
    } else {
      _listenIntent.remove(id);
    }
    notifyListeners();
    return res;
  }

  Future<void> load() async {
    // From the account: every device knows what I'm waiting for, and why.
    final st = await ApiService().onlineWatchState();
    _ids
      ..clear()
      ..addAll(st.watching);
    _listenIntent
      ..clear()
      ..addAll(st.listen);
    notifyListeners();
  }

  /// Start / stop. Returns 'watching', 'online', 'stopped' or null (failed).
  Future<String?> toggle(int id) async {
    final on = !_ids.contains(id);
    final res = await ApiService().setOnlineWatch(id, on);
    if (res == 'watching') _ids.add(id);
    if (res == 'stopped' || res == 'online') _ids.remove(id);
    notifyListeners();
    return res;
  }

  /// The watch fired (they came online) — it's over.
  void fired(int id) {
    if (_ids.remove(id)) notifyListeners();
  }
}
