import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A chosen chat wallpaper.
/// - mode 'default' → the built-in pattern wallpaper
/// - mode 'motif'   → the romantic hearts/notes/blossoms scatter (faint)
/// - mode 'photo'   → [url] (a fully-resolved image URL: a server preset, a
///   reused Our Space photo, or the user's own uploaded picture). [wideUrl] is
///   an optional landscape variant used to fill wide screens instead of tiling
///   the portrait.
class ChatBg {
  final String mode; // 'default' | 'motif' | 'photo'
  final String? url;
  final String? wideUrl;
  const ChatBg(this.mode, this.url, {this.wideUrl});

  bool get isPhoto => mode == 'photo' && (url ?? '').isNotEmpty;
  bool get isMotif => mode == 'motif';

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

/// Legacy single notifier, kept mirroring the all-chats default so any old
/// reference keeps working. New code calls [chatBackgroundFor].
final ValueNotifier<ChatBg> chatBackground =
    ValueNotifier<ChatBg>(ChatBg.defaults);

const String _kAll = 'chat_bg_all_v1'; // JSON ChatBg: the default for all chats
const String _kOverrides = 'chat_bg_overrides_v1'; // JSON {convKey: ChatBg}
const String _kLegacyMode = 'chat_bg_mode_v1'; // migrate old single choice
const String _kLegacyUrl = 'chat_bg_url_v1';

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

/// The all-chats default (what a chat with no override shows).
ChatBg get chatBackgroundAll => _all;

/// Whether a chat has its own wallpaper distinct from the all-chats default.
bool hasChatOverride(String convKey) => _overrides.containsKey(convKey);

Future<void> loadChatBackground() async {
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
    chatBackground.value = _all;
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
