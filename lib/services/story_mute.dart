import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_prefs.dart';

/// Friends whose statuses I've muted: still there at the end of the tray
/// (greyed), but never lit as "new" — on the tray or their chat tile. No
/// unfriending; undo any time. Synced with the account.
class StoryMute extends ChangeNotifier {
  StoryMute._();
  static final StoryMute instance = StoryMute._();

  static const key = 'muted_story_authors_v1';
  final Set<int> _ids = {};
  bool _loaded = false;

  bool isMuted(int id) => _ids.contains(id);

  Future<void> load() async {
    if (!_loaded) AccountPrefs.onRestore(_doLoad);
    _loaded = true;
    await _doLoad();
  }

  Future<void> _doLoad() async {
    try {
      final p = await SharedPreferences.getInstance();
      _ids
        ..clear()
        ..addAll((p.getStringList(key) ?? const [])
            .map(int.tryParse)
            .whereType<int>());
      notifyListeners();
    } catch (_) {}
  }

  Future<void> toggle(int id) async {
    _ids.contains(id) ? _ids.remove(id) : _ids.add(id);
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(key, _ids.map((e) => '$e').toList());
    } catch (_) {}
    AccountPrefs.touch();
  }
}
