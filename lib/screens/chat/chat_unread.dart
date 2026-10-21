part of '../chat_page.dart';

// ── "N new messages" ─────────────────────────────────────────────────────────
// This device remembers, per chat, the newest message id I'd actually reached
// (scrolled to the bottom with). Next time the chat opens, the first message
// from someone else after that point gets an Aluta-styled divider above it and
// the chat opens right there, so a busy group is easy to catch up on.
// Purely local — works on any server version.

extension _ChatUnread on _ChatPageState {
  String get _lastSeenKey => 'last_seen_msg_v1_$_activeConvKey';

  Future<void> _loadLastSeen() async {
    try {
      final p = await SharedPreferences.getInstance();
      _lastSeenAtOpen = p.getInt(_lastSeenKey);
    } catch (_) {}
  }

  int? _numId(Map<String, dynamic> m) => int.tryParse(m['id'].toString());

  /// Newest real (server) message id in the thread.
  int? _newestId() {
    for (final m in _messages) {
      final id = _numId(m);
      if (id != null) return id; // list is newest-first
    }
    return null;
  }

  /// Remember that I've seen everything currently in the thread.
  void _markSeenUpToNewest() {
    final id = _newestId();
    if (id == null || id <= _seenSavedId) return; // nothing new to record
    _seenSavedId = id;
    () async {
      try {
        final p = await SharedPreferences.getInstance();
        final prev = p.getInt(_lastSeenKey) ?? 0;
        if (id > prev) await p.setInt(_lastSeenKey, id);
      } catch (_) {}
    }();
  }

  /// Snapshot the divider position for this visit and open the chat there.
  void _placeUnreadDivider() {
    final seen = _lastSeenAtOpen;
    // Mentions after this point queue on the "@" stepper.
    _mentionBase ??= seen ?? _newestId();
    if (seen == null || _messages.isEmpty) {
      // First visit on this device: nothing to compare with — start fresh.
      if (_isAtBottom) _markSeenUpToNewest();
      return;
    }
    String? anchor;
    var count = 0;
    for (final m in _messages) {
      // newest → oldest; stop once we're back at what I'd seen
      final id = _numId(m);
      if (id == null) continue;
      if (id <= seen) break;
      if (m['sender_id']?.toString() == _myId) continue;
      if (m['is_deleted'] == true) continue;
      anchor = m['id'].toString(); // keeps moving to the OLDEST unread
      count++;
    }
    if (anchor == null) return;
    rebuildWith(() {
      _unreadAnchorId = anchor;
      _unreadCount = count;
    });
    // A handful fit on screen anyway; only scroll when the first unread would
    // otherwise be off-screen. Opened from a notification → that jump wins.
    if (count >= 4 && widget.initialJumpMessageId == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jumpToMessage(anchor!, flash: false);
      });
    }
  }

  /// The divider: a soft accent hairline both sides of an Aluta pill —
  /// the mark, "N new messages", in the theme colour.
  Widget _buildUnreadDivider(ColorScheme scheme, bool isDark) {
    final a = scheme.primary;
    Widget line(bool left) => Expanded(
          child: Container(
            height: 1.4,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: left
                    ? [a.withValues(alpha: 0), a.withValues(alpha: 0.55)]
                    : [a.withValues(alpha: 0.55), a.withValues(alpha: 0)],
              ),
            ),
          ),
        );
    final n = _unreadCount;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      child: Row(
        children: [
          line(true),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 10),
            padding: const EdgeInsets.fromLTRB(6, 4, 12, 4),
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                  a.withValues(alpha: isDark ? 0.22 : 0.12),
                  scheme.surface),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: a.withValues(alpha: 0.45)),
              boxShadow: [
                BoxShadow(
                  color: a.withValues(alpha: isDark ? 0.30 : 0.18),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipOval(
                  child: Image.asset('assets/images/logo.png',
                      width: 18,
                      height: 18,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Icon(Icons.mark_chat_unread_rounded,
                          size: 15, color: a)),
                ),
                const SizedBox(width: 7),
                Text(
                  n == 1 ? '1 new message' : '$n new messages',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                    color: isDark ? Color.lerp(a, Colors.white, 0.35) : a,
                  ),
                ),
              ],
            ),
          ),
          line(false),
        ],
      ),
    );
  }
}
