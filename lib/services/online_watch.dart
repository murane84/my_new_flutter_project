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

  Future<void> load() async {
    final ids = await ApiService().onlineWatches();
    _ids
      ..clear()
      ..addAll(ids);
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
