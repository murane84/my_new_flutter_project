import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'account_prefs.dart';

/// On/off switches for Aluta's "moments" — the warm, app-initiated touches —
/// gathered in one place (Moments & nudges). All default ON; all local.
class MomentPrefs {
  MomentPrefs._();
  static final MomentPrefs instance = MomentPrefs._();

  /// Welcome-back cards (music playing, away summary).
  final ValueNotifier<bool> welcomeCards = ValueNotifier<bool>(true);

  /// Good night · anniversary · on-this-day · streak chips in chats.
  final ValueNotifier<bool> rituals = ValueNotifier<bool>(true);

  /// Once-a-day "Today's glow" card.
  final ValueNotifier<bool> glowDaily = ValueNotifier<bool>(true);

  static const _keys = {
    'welcome': 'moments_welcome_on',
    'rituals': 'moments_rituals_on',
    'glow': 'glow_daily_on',
  };

  Future<void>? _loading;
  Future<void> load() {
    if (_loading == null) {
      AccountPrefs.onRestore(_doLoad); // toggles came back from the account
    }
    return _loading ??= _doLoad();
  }

  Future<void> _doLoad() async {
    try {
      final p = await SharedPreferences.getInstance();
      welcomeCards.value = p.getBool(_keys['welcome']!) ?? true;
      rituals.value = p.getBool(_keys['rituals']!) ?? true;
      glowDaily.value = p.getBool(_keys['glow']!) ?? true;
    } catch (_) {}
  }

  Future<void> _set(String k, ValueNotifier<bool> n, bool v) async {
    n.value = v;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_keys[k]!, v);
    } catch (_) {}
    AccountPrefs.touch();
  }

  Future<void> setWelcome(bool v) => _set('welcome', welcomeCards, v);
  Future<void> setRituals(bool v) => _set('rituals', rituals, v);
  Future<void> setGlowDaily(bool v) => _set('glow', glowDaily, v);
}
