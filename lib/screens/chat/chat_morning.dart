part of '../chat_page.dart';

// "Deliver at their morning" 🌅 — hold-to-send on a DM: the message waits on
// the server and goes out when they first open Aluta after 5 AM their time
// (server morning.py). A small strip above the composer shows what's waiting,
// with Cancel (the text comes back to the composer).

extension _ChatMorning on _ChatPageState {
  bool get _canHoldForMorning =>
      !_isGroup && widget.friendId > 0 && !_heartMode && _editing == null;

  Future<void> _loadHeld() async {
    if (_isGroup || widget.friendId <= 0) return;
    final list = await ApiService().heldFor(widget.friendId);
    rebuildWith(() => _held = list);
  }

  /// Long-press on Send: the send options sheet.
  void _showSendOptions() {
    if (!_canHoldForMorning || _ctrl.text.trim().isEmpty) return;
    HapticFeedback.mediumImpact();
    final scheme = Theme.of(context).colorScheme;
    final first = _peerFirst;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 6),
            ListTile(
              leading: const Text('🌅', style: TextStyle(fontSize: 22)),
              title: Text('Deliver at $first\'s morning'),
              subtitle: Text(
                  'Arrives when $first opens Aluta after 5 AM their time — '
                  'no buzz in the night'),
              onTap: () {
                Navigator.pop(ctx);
                _holdForMorning();
              },
            ),
            ListTile(
              leading: Icon(Icons.send_rounded, color: scheme.primary),
              title: const Text('Send now'),
              onTap: () {
                Navigator.pop(ctx);
                _sendMessage();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _holdForMorning() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    var content = text;
    final reply = _replyTo;
    if (reply != null) {
      final lines = _replyQuoteText(reply).split('\n').take(2).join('\n');
      content = '> $lines\n\n$text';
      _rememberQuoteAuthor(lines, reply);
    }
    _ctrl.clear();
    rebuildWith(() => _replyTo = null);
    _saveDraft();
    final res = await ApiService().holdForMorning(widget.friendId, content);
    if (!mounted) return;
    if (res == null) {
      // Give the words back rather than losing them.
      if (_ctrl.text.isEmpty) _ctrl.text = text;
      showToast(context, "Couldn't save it for the morning — try again",
          type: ToastType.error);
      return;
    }
    if (res['sent_now'] == true) {
      // Already morning where they are → it went out right away.
      showToast(context, "☀️ It's already morning for $_peerFirst — sent now",
          type: ToastType.success);
      _loadMessages();
      return;
    }
    rebuildWith(() => _held = [..._held, res]);
    showToast(context, "🌅 It'll be waiting when $_peerFirst wakes up",
        type: ToastType.success);
  }

  Future<void> _cancelHeld(Map<String, dynamic> h) async {
    final id = (h['id'] as num?)?.toInt();
    if (id == null) return;
    final back = await ApiService().cancelHeld(id);
    if (!mounted) return;
    if (back == null) {
      showToast(context, 'It has already gone out', type: ToastType.info);
      _loadHeld();
      return;
    }
    rebuildWith(() => _held = _held.where((x) => x['id'] != h['id']).toList());
    // Back into the composer so it can be edited or sent now.
    if (_ctrl.text.trim().isEmpty && back.isNotEmpty) {
      _ctrl.text = _stripQuote(back);
    }
    showToast(context, 'Cancelled — back in your message box');
  }

  Widget _buildHeldStrip(ColorScheme scheme) {
    final n = _held.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 2),
      child: Row(
        children: [
          const Text('🌅', style: TextStyle(fontSize: 15)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              n == 1
                  ? 'Waiting for $_peerFirst\'s morning: '
                      '“${_clip(_stripQuote((_held.first['content'] ?? '').toString()), 40)}”'
                  : '$n messages waiting for $_peerFirst\'s morning',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            onPressed: () => n == 1 ? _cancelHeld(_held.first) : _showHeldList(),
            child: Text(n == 1 ? 'Cancel' : 'View'),
          ),
        ],
      ),
    );
  }

  void _showHeldList() {
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Text('🌅 For $_peerFirst\'s morning',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            for (final h in _held)
              ListTile(
                title: Text(
                  _stripQuote((h['content'] ?? '').toString()),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _cancelHeld(h);
                  },
                  child: const Text('Cancel'),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
