part of '../chat_page.dart';

// ── Music moments in a conversation ─────────────────────────────────────────
//  • Song reaction: react to any message with the song playing right now —
//    stored as a reaction "🎵 <title>" (works on today's server) and shown as
//    a little vinyl chip.
//  • Dedication (groups): from a song bubble, dedicate it to a member — a
//    tagged message "🎶 Dedicating … to @them" (they get the mention).
//  • Voice note over music: a voice note recorded while a song plays carries
//    a "🎵 with …" caption so the moment is remembered.

const String _songReactPrefix = '🎵 ';

extension _ChatMusicMoments on _ChatPageState {
  /// Title of the track playing on this device right now, or ''.
  String _nowPlayingTitle() {
    try {
      final np = providerContainer.read(nowPlayingProvider);
      final playing = np.playing || (playbackBus.isPlaying?.call() ?? false);
      if (!playing) return '';
      return np.track.trim();
    } catch (_) {
      return '';
    }
  }

  String _clip(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n - 1).trimRight()}…';

  void _reactWithSong(Map<String, dynamic> msg) {
    final t = _nowPlayingTitle();
    if (t.isEmpty) return;
    _addReaction(msg, '$_songReactPrefix${_clip(t, 40)}');
  }

  bool _isSongReaction(String r) => r.startsWith(_songReactPrefix);

  /// The vinyl chip for a song reaction.
  Widget _songReactionChip(String r, ColorScheme scheme) {
    final title = r.substring(_songReactPrefix.length);
    return Container(
      padding: const EdgeInsets.fromLTRB(3, 2, 8, 2),
      constraints: const BoxConstraints(maxWidth: 180),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(colors: [
          scheme.primary.withValues(alpha: 0.16),
          scheme.primary.withValues(alpha: 0.06),
        ]),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.35)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const RadialGradient(colors: [
              Color(0xFF444444),
              Color(0xFF111111),
            ]),
            border: Border.all(color: Colors.black26),
          ),
          alignment: Alignment.center,
          child: Container(
            width: 5,
            height: 5,
            decoration:
                BoxDecoration(shape: BoxShape.circle, color: scheme.primary),
          ),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface)),
        ),
      ]),
    );
  }

  /// Song bubble → "Dedicate to…" (groups): pick a member, send a tagged note.
  Future<void> _dedicateSongToMember(Map<String, dynamic> msg) async {
    if (!_isGroup) return;
    final title = ((msg['content'] as String?)?.trim().isNotEmpty == true
            ? (msg['content'] as String).trim()
            : (msg['media_name'] as String?) ?? 'this song')
        .replaceAll(RegExp(r'\.(mp3|m4a|aac|wav|flac|ogg)$', caseSensitive: false), '');
    final others = _groupMembers
        .where((m) => m['user_id']?.toString() != _myId)
        .toList();
    if (others.isEmpty) {
      await _loadGroupMembers();
      if (!mounted) return;
    }
    final members = _groupMembers
        .where((m) => m['user_id']?.toString() != _myId)
        .toList();
    if (members.isEmpty || !mounted) return;
    final scheme = Theme.of(context).colorScheme;
    final pick = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
            child: Row(children: [
              Icon(Icons.card_giftcard_rounded, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Dedicate “${_clip(title, 34)}” to…',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w800)),
              ),
            ]),
          ),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final m in members)
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: scheme.primaryContainer,
                    child: Text(_memberName(m).isNotEmpty
                        ? _memberName(m)[0].toUpperCase()
                        : '?'),
                  ),
                  title: Text(_memberName(m)),
                  onTap: () => Navigator.pop(ctx, m),
                ),
            ]),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (pick == null || !mounted) return;
    final uid = int.tryParse(pick['user_id'].toString());
    final handle = _memberUsername(pick).replaceAll(' ', ' ');
    if (uid == null || handle.isEmpty) return;
    final text = '🎶 Dedicating “${_clip(title, 60)}” to @$handle 💞';
    final tempId = _newTempId();
    _insertOptimistic(_optimisticMsg(tempId, 'text', text));
    _markActivity();
    Future<void> attempt() async {
      try {
        final sent = await ApiService().sendMessage(widget.friendId, text,
            messageType: 'text',
            conversationId: widget.conversationId,
            mentions: [uid]);
        _replaceOptimistic(tempId, sent);
        if (sent == null && mounted) {
          _showErrorSnack('Dedication failed — tap the ! to retry.');
        }
      } catch (_) {
        _replaceOptimistic(tempId, null);
      }
    }

    _outbox[tempId] = attempt;
    unawaited(attempt());
  }

  /// Caption for a voice note recorded over music ('' when none).
  String _voiceMusicCaption() {
    final t = _recordSong;
    if (t == null || t.isEmpty) return '';
    return '🎵 with “${_clip(t, 48)}”';
  }
}
