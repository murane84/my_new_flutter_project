part of '../chat_page.dart';

// "A voice hello" 🎙️ — hold the mic in a DM to record a 5-second hello. It
// travels as a normal voice note captioned [_kVoiceHello]; the friend hears
// it play softly, once, the next time they open the chat.

const String _kVoiceHello = '👋 Voice hello';
const int _kVoiceHelloMaxMs = 5000;

extension _ChatVoiceHello on _ChatPageState {
  Future<void> _startVoiceHello() async {
    if (_isGroup || _heartMode || _isRecording) return;
    HapticFeedback.mediumImpact();
    rebuildWith(() => _helloMode = true);
    showToast(context, '🎙️ Say a quick hello — it stops at 5 seconds');
    await _startRecording();
    if (!_isRecording) rebuildWith(() => _helloMode = false);
  }

  /// On open: the newest unheard voice hello from them (last 7 days) plays
  /// softly — once ever, remembered per message on this device.
  Future<void> _pickVoiceHello() async {
    if (_isGroup || _myId == null) return;
    Map<String, dynamic>? hello;
    for (final m in _messages) {
      // _messages is newest-first.
      if ((m['message_type'] ?? '') != 'audio') continue;
      if (m['sender_id']?.toString() == _myId) continue;
      if ((m['content'] ?? '').toString().trim() != _kVoiceHello) continue;
      hello = m;
      break;
    }
    if (hello == null) return;
    final id = hello['id']?.toString() ?? '';
    if (id.isEmpty || id.startsWith('tmp-')) return;
    final ts = (hello['timestamp'] ?? '').toString();
    if (ts.isNotEmpty &&
        DateTime.now().difference(parseServerTime(ts)).inDays > 7) {
      return;
    }
    try {
      final p = await SharedPreferences.getInstance();
      final played = p.getStringList('voice_hello_played') ?? const [];
      if (played.contains(id)) return;
      // Remember first, so it never plays twice even if this open is cut short.
      await p.setStringList(
          'voice_hello_played', [...played.take(199), id]);
    } catch (_) {
      return;
    }
    rebuildWith(() => _helloAutoId = id);
  }
}
