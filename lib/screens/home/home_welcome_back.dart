part of '../home_page.dart';

// 🌍 People first (brand strategy): a returning member is greeted by what
// their people left them — "Karibu tena — Asha sent you a song 🎵" — not by
// the clock. Once per app open, and again after 3 hours or more away. When
// nobody is waiting, nothing extra: the loading screen's greeting stands.

extension _HomeWelcomeBack on HomePageState {
  void _welcomeBack(List<dynamic> friends) {
    final me = _myUserId;
    final waiting = <Map<String, dynamic>>[];
    for (final f in friends) {
      if (f is! Map<String, dynamic>) continue;
      final unread = (f['unread_count'] as num?)?.toInt() ?? 0;
      if (unread <= 0) continue;
      final from = int.tryParse('${f['last_sender_id'] ?? ''}');
      if (me != null && from == me) continue;
      waiting.add(f);
    }
    if (waiting.isEmpty || !mounted) return;
    // Most recent first.
    waiting.sort((a, b) => '${b['last_timestamp'] ?? ''}'
        .compareTo('${a['last_timestamp'] ?? ''}'));
    String first(Map<String, dynamic> f) {
      final n = ContactNames.instance
          .displayName(
              userId: f['id'], registered: '${f['username'] ?? 'Someone'}')
          .trim();
      return n.isEmpty ? 'Someone' : n.split(RegExp(r'\s+')).first;
    }

    String what(Map<String, dynamic> f) {
      final p = '${f['last_message'] ?? ''}'.trim();
      if (p.startsWith('🎵')) return 'sent you a song 🎵';
      if (p.contains('Secret heart') || p.startsWith('❤️') ||
          p.startsWith('💌')) {
        return 'left you a heart 💞';
      }
      if (p.startsWith('📷') || p.startsWith('🎬')) {
        return 'shared a moment with you 📷';
      }
      if (p.startsWith('🎤')) return 'left you a voice note 🎤';
      return 'wrote to you 💬';
    }

    final a = waiting.first;
    final line = waiting.length == 1
        ? '${first(a)} ${what(a)}'
        : waiting.length == 2
            ? '${first(a)} and ${first(waiting[1])} wrote to you 💬'
            : '${first(a)} and ${waiting.length - 1} others are waiting '
                'for you 💬';
    showToast(context, 'Karibu tena — $line',
        type: ToastType.info, duration: const Duration(seconds: 4));
  }
}
