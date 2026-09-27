import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The user's chosen chat wallpaper.
/// - mode 'default' → the built-in pattern wallpaper
/// - mode 'motif'   → the romantic hearts/notes/blossoms scatter (faint)
/// - mode 'photo'   → [url] (a fully-resolved image URL, reused from the user's
///   Our Space background so the same picture does double duty)
class ChatBg {
  final String mode; // 'default' | 'motif' | 'photo'
  final String? url;
  const ChatBg(this.mode, this.url);

  bool get isPhoto => mode == 'photo' && (url ?? '').isNotEmpty;
  bool get isMotif => mode == 'motif';
}

/// Open chats listen to this so a change applies live.
final ValueNotifier<ChatBg> chatBackground =
    ValueNotifier<ChatBg>(const ChatBg('default', null));

const String _kMode = 'chat_bg_mode_v1';
const String _kUrl = 'chat_bg_url_v1';

Future<void> loadChatBackground() async {
  try {
    final p = await SharedPreferences.getInstance();
    final mode = p.getString(_kMode) ?? 'default';
    final url = p.getString(_kUrl);
    chatBackground.value = ChatBg(mode, url);
  } catch (_) {}
}

Future<void> setChatBackground(String mode, {String? url}) async {
  final m = (mode == 'photo' && (url ?? '').isEmpty) ? 'default' : mode;
  chatBackground.value = ChatBg(m, url);
  try {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kMode, m);
    if ((url ?? '').isEmpty) {
      await p.remove(_kUrl);
    } else {
      await p.setString(_kUrl, url!);
    }
  } catch (_) {}
}
