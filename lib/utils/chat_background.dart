import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/api_service.dart';

/// A chosen chat wallpaper.
/// - mode 'default' → the built-in pattern wallpaper
/// - mode 'motif'   → the romantic hearts/notes/blossoms scatter (faint)
/// - mode 'watermark' → the Aluta mark, theme-tinted, as a whisper lattice
/// - mode 'photo'   → [url] (a fully-resolved image URL: a server preset, a
///   reused Our Space photo, or the user's own uploaded picture). [wideUrl] is
///   an optional landscape variant used to fill wide screens instead of tiling
///   the portrait.
class ChatBg {
  final String mode; // 'default' | 'motif' | 'watermark' | 'photo'
  final String? url;
  final String? wideUrl;
  const ChatBg(this.mode, this.url, {this.wideUrl});

  bool get isPhoto => mode == 'photo' && (url ?? '').isNotEmpty;
  bool get isMotif => mode == 'motif';
  bool get isWatermark => mode == 'watermark';

  Map<String, dynamic> toJson() => {
        'mode': mode,
        if ((url ?? '').isNotEmpty) 'url': url,
        if ((wideUrl ?? '').isNotEmpty) 'wide': wideUrl,
      };

  factory ChatBg.fromJson(Map<String, dynamic> j) => ChatBg(
        (j['mode'] ?? 'default').toString(),
        j['url'] as String?,
        wideUrl: j['wide'] as String?,
      );

  static const ChatBg defaults = ChatBg('default', null);
}

/// Bumped whenever ANY chat background changes, so open chats re-resolve their
/// own wallpaper. Chats listen to this rather than to a single global value,
/// because each conversation may now carry its own wallpaper.
final ValueNotifier<int> chatBgRevision = ValueNotifier<int>(0);

/// How strongly a photo wallpaper shows through the readability veil, 0..1.
/// 0.5 is the balanced default ("foggish"), 1.0 shows the picture nearly clear,
/// and 0.0 fades it far back. Backgrounds listen to this so a change repaints
/// live. Persisted so the choice survives restarts.
final ValueNotifier<double> wallpaperClarity = ValueNotifier<double>(0.5);
const String _kClarity = 'wallpaper_clarity_v1';

/// The veil opacity to paint over a wallpaper, derived from [wallpaperClarity]
/// and a per-surface [base] (its opacity at the default 0.5 clarity). Higher
/// clarity thins the veil (clearer picture); lower clarity thickens it (fainter
/// picture). Clamped so text never becomes unreadable or the veil fully opaque.
double wallpaperVeilAlpha(double base) {
  final c = wallpaperClarity.value.clamp(0.0, 1.0);
  final factor = 1.0 + (0.5 - c) * 1.7;
  return (base * factor).clamp(0.04, 0.92);
}

/// Persist + broadcast a new wallpaper clarity (0..1).
Future<void> setWallpaperClarity(double v) async {
  v = v.clamp(0.0, 1.0);
  wallpaperClarity.value = v;
  try {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kClarity, v);
  } catch (_) {}
  _markChanged();
}

/// How concentrated the DEFAULT theme-colour backdrop (the "motif": the ambient
/// wash + hearts/notes pattern + corner glows shown when there's no photo
/// wallpaper) appears, 0..1. The default (0.6) is already noticeably richer than
/// the old pale look; the user can push it further or dial it back. No upper
/// cap on the user's freedom beyond keeping it a tasteful wash. Persisted.
final ValueNotifier<double> motifStrength = ValueNotifier<double>(0.6);
const String _kMotif = 'motif_strength_v1';

/// Scale a motif base alpha by the chosen concentration. At 0.6 (default) a base
/// is ~2x the old value; 1.0 is ~3x (vivid); 0.0 fades it right back.
double motifAccentAlpha(double base) {
  final s = motifStrength.value.clamp(0.0, 1.0);
  final factor = 0.5 + s * 2.5; // 0 -> .5x, .6 -> 2x, 1 -> 3x
  return (base * factor).clamp(0.0, 0.9);
}

/// Persist + broadcast a new motif concentration (0..1).
Future<void> setMotifStrength(double v) async {
  v = v.clamp(0.0, 1.0);
  motifStrength.value = v;
  try {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kMotif, v);
  } catch (_) {}
  _markChanged();
}

/// Legacy single notifier, kept mirroring the all-chats default so any old
/// reference keeps working. New code calls [chatBackgroundFor].
final ValueNotifier<ChatBg> chatBackground =
    ValueNotifier<ChatBg>(ChatBg.defaults);

const String _kAll = 'chat_bg_all_v1'; // JSON ChatBg: the default for all chats
const String _kOverrides = 'chat_bg_overrides_v1'; // JSON {convKey: ChatBg}
const String _kLegacyMode = 'chat_bg_mode_v1'; // migrate old single choice
const String _kLegacyUrl = 'chat_bg_url_v1';
const String _kApplyAll = 'chat_bg_apply_all_v1';
// Set once the user actually picks an all-chats wallpaper. Until then each
// chat gets a smart default by kind (see [chatBackgroundSmart]).
const String _kAllChosen = 'chat_bg_all_chosen_v1';
bool _allChosen = false;
// DMs known to be with a bonded partner (they start on the Motif). Remembered
// so the right wallpaper paints on the FIRST frame, not after the Spaces load.
const String _kBondedKeys = 'chat_bg_bonded_keys_v1';
Set<String> _bondedKeys = {};

/// Tell the wallpaper whether this DM is with a bonded partner (from the
/// chat, once its Spaces are known). Persisted; repaints only on a change.
Future<void> noteChatBonded(String convKey, bool bonded) async {
  if (convKey.isEmpty || convKey.startsWith('g')) return;
  final changed =
      bonded ? _bondedKeys.add(convKey) : _bondedKeys.remove(convKey);
  if (!changed) return;
  chatBgRevision.value++;
  try {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kBondedKeys, _bondedKeys.toList());
  } catch (_) {}
}

// Remembered "Apply to all chats" choice so picking a wallpaper (e.g. from the
// gallery) keeps applying to every DM once the user has chosen that, instead
// of silently reverting to this-chat-only each time the sheet re-opens.
bool _applyAllPref = true;
bool get wallpaperApplyAllDefault => _applyAllPref;
Future<void> setWallpaperApplyAllDefault(bool v) async {
  _applyAllPref = v;
  try {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kApplyAll, v);
  } catch (_) {}
  _markChanged();
}

ChatBg _all = ChatBg.defaults;
Map<String, ChatBg> _overrides = {};

/// Stable per-conversation key. DM -> `d<friendId>`, group -> `g<conversationId>`.
String chatConvKey({int? friendId, int? conversationId}) {
  if (conversationId != null) return 'g$conversationId';
  if (friendId != null) return 'd$friendId';
  return '';
}

/// The wallpaper a given chat should show: its own override, else the all-chats
/// default.
ChatBg chatBackgroundFor(String convKey) => _overrides[convKey] ?? _all;

/// Like [chatBackgroundFor], but before the user has ever chosen a wallpaper
/// each kind of chat starts with its own character: a bonded (couple) chat
/// gets the romantic Motif, a group the Aluta Watermark, any other DM the
/// Default. Any pick the user makes (per chat or for all) always wins.
ChatBg chatBackgroundSmart(String convKey,
    {required bool isGroup, bool bonded = false}) {
  final o = _overrides[convKey];
  if (o != null) return o;
  if (_allChosen) return _all;
  // "Bonded" is about THIS DM's person — never a group, and never just
  // "I have a Space with someone".
  if (!isGroup && (bonded || _bondedKeys.contains(convKey))) {
    return const ChatBg('motif', null);
  }
  if (isGroup) return const ChatBg('watermark', null);
  return _all;
}

/// The all-chats default (what a chat with no override shows).
ChatBg get chatBackgroundAll => _all;

/// Whether a chat has its own wallpaper distinct from the all-chats default.
bool hasChatOverride(String convKey) => _overrides.containsKey(convKey);

Future<void>? _loading;

/// Load the saved wallpapers once (memoised): the app bootstrap awaits it so
/// the first chat frame already has the right one; later calls reuse it.
Future<void> loadChatBackground() => _loading ??= _loadChatBackground();

Future<void> _loadChatBackground() async {
  try {
    final p = await SharedPreferences.getInstance();
    // One-time migration: an existing single global choice becomes the
    // all-chats default so nobody loses their previously picked wallpaper.
    if (!p.containsKey(_kAll) && p.containsKey(_kLegacyMode)) {
      final m = p.getString(_kLegacyMode) ?? 'default';
      final u = p.getString(_kLegacyUrl);
      _all = ChatBg(m, u);
      await p.setString(_kAll, jsonEncode(_all.toJson()));
    } else {
      final raw = p.getString(_kAll);
      _all = raw != null
          ? ChatBg.fromJson(Map<String, dynamic>.from(jsonDecode(raw)))
          : ChatBg.defaults;
    }
    _overrides = {};
    final ov = p.getString(_kOverrides);
    if (ov != null) {
      final Map<String, dynamic> m = Map<String, dynamic>.from(jsonDecode(ov));
      m.forEach((k, v) {
        _overrides[k] = ChatBg.fromJson(Map<String, dynamic>.from(v));
      });
    }
    _applyAllPref = p.getBool(_kApplyAll) ?? true;
    _bondedKeys = (p.getStringList(_kBondedKeys) ?? const []).toSet();
    // Existing users who already picked something non-default keep it.
    _allChosen = p.getBool(_kAllChosen) ?? (_all.mode != 'default');
    chatBackground.value = _all;
    wallpaperClarity.value =
        (p.getDouble(_kClarity) ?? 0.5).clamp(0.0, 1.0).toDouble();
    motifStrength.value =
        (p.getDouble(_kMotif) ?? 0.6).clamp(0.0, 1.0).toDouble();
    chatBgRevision.value++;
  } catch (_) {}
}

Future<void> _persist() async {
  try {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kAll, jsonEncode(_all.toJson()));
    await p.setString(
      _kOverrides,
      jsonEncode(_overrides.map((k, v) => MapEntry(k, v.toJson()))),
    );
  } catch (_) {}
  _markChanged();
}

// ── Account backup ─────────────────────────────────────────────────────────
// The wallpaper choices also live on the account (server `user_settings`,
// key 'chat_wallpaper'), so a reinstall or a new phone gets them back.
// Startup never waits on this: the local copy paints first, and
// [syncChatBackgroundWithAccount] runs in the background after sign-in.
// Newest change wins (by [_kRev], the local change time).
const String _kRev = 'chat_bg_rev_v1';
const String _kSettingKey = 'chat_wallpaper';
Timer? _pushTimer;
bool _applyingRemote = false;

void _markChanged() {
  if (_applyingRemote) return;
  final rev = DateTime.now().millisecondsSinceEpoch;
  SharedPreferences.getInstance()
      .then((p) => p.setInt(_kRev, rev))
      .catchError((_) => false);
  _pushTimer?.cancel();
  _pushTimer = Timer(const Duration(seconds: 3), () => _push(rev));
}

Map<String, dynamic> _snapshot() => {
      'all': _all.toJson(),
      'overrides': _overrides.map((k, v) => MapEntry(k, v.toJson())),
      'all_chosen': _allChosen,
      'apply_all': _applyAllPref,
      'clarity': wallpaperClarity.value,
      'motif': motifStrength.value,
    };

Future<void> _push(int rev) async {
  try {
    await ApiService().putSetting(_kSettingKey, rev, _snapshot());
  } catch (_) {}
}

/// Reconcile with the account copy (call once after sign-in, unawaited):
/// a newer server copy is applied (reinstall / other device); a newer local
/// one is uploaded.
Future<void> syncChatBackgroundWithAccount() async {
  try {
    await loadChatBackground();
    final p = await SharedPreferences.getInstance();
    final localRev = p.getInt(_kRev) ?? 0;
    final remote = await ApiService().getSetting(_kSettingKey);
    if (remote == null) return; // offline — try next launch
    final data = remote.data;
    if (remote.rev > localRev && data is Map) {
      _applyingRemote = true;
      try {
        final d = Map<String, dynamic>.from(data);
        if (d['all'] is Map) {
          _all = ChatBg.fromJson(Map<String, dynamic>.from(d['all'] as Map));
        }
        _overrides = {};
        final ov = d['overrides'];
        if (ov is Map) {
          ov.forEach((k, v) {
            if (v is Map) {
              _overrides[k.toString()] =
                  ChatBg.fromJson(Map<String, dynamic>.from(v));
            }
          });
        }
        _allChosen = d['all_chosen'] == true;
        _applyAllPref = d['apply_all'] != false;
        final c = (d['clarity'] as num?)?.toDouble();
        final m = (d['motif'] as num?)?.toDouble();
        if (c != null) wallpaperClarity.value = c.clamp(0.0, 1.0).toDouble();
        if (m != null) motifStrength.value = m.clamp(0.0, 1.0).toDouble();
        await _persist();
        await p.setBool(_kAllChosen, _allChosen);
        await p.setBool(_kApplyAll, _applyAllPref);
        await p.setDouble(_kClarity, wallpaperClarity.value);
        await p.setDouble(_kMotif, motifStrength.value);
        await p.setInt(_kRev, remote.rev);
        chatBackground.value = _all;
        chatBgRevision.value++;
      } finally {
        _applyingRemote = false;
      }
    } else if (localRev > remote.rev) {
      await _push(localRev);
    } else if (localRev == 0 &&
        remote.rev == 0 &&
        (_allChosen || _overrides.isNotEmpty)) {
      // Chosen before account backup existed → back it up once now.
      final rev = DateTime.now().millisecondsSinceEpoch;
      await p.setInt(_kRev, rev);
      await _push(rev);
    }
  } catch (_) {}
}

ChatBg _norm(String mode, String? url, String? wideUrl) {
  final m = (mode == 'photo' && (url ?? '').isEmpty) ? 'default' : mode;
  return ChatBg(m, url, wideUrl: wideUrl);
}

/// Set the wallpaper for ONE chat (creates/updates that chat's override).
Future<void> setChatBackgroundFor(String convKey, String mode,
    {String? url, String? wideUrl}) async {
  if (convKey.isEmpty) return;
  _overrides[convKey] = _norm(mode, url, wideUrl);
  await _persist();
  chatBgRevision.value++;
}

/// Set the default for ALL chats and drop every per-chat override
/// ("one wallpaper for all").
Future<void> setChatBackgroundAll(String mode,
    {String? url, String? wideUrl}) async {
  _all = _norm(mode, url, wideUrl);
  _overrides.clear();
  _allChosen = true;
  try {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kAllChosen, true);
  } catch (_) {}
  await _persist();
  chatBackground.value = _all;
  chatBgRevision.value++;
}

/// Drop a chat's override so it follows the all-chats default again.
Future<void> clearChatOverride(String convKey) async {
  if (_overrides.remove(convKey) != null) {
    await _persist();
    chatBgRevision.value++;
  }
}

/// Back-compat shim for the previous global setter (now sets the all-chats
/// default).
Future<void> setChatBackground(String mode, {String? url}) =>
    setChatBackgroundAll(mode, url: url);
