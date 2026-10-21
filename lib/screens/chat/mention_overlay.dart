part of '../chat_page.dart';

// ── @-mentions (group chats) ────────────────────────────────────────────────
// Type "@" in a group composer to tag members.
//
// • The picker is rendered INLINE, directly above the composer (see
//   _buildInput), not in a floating Overlay. It therefore rides on top of the
//   keyboard with the composer and can never be covered by it, whatever the
//   layout (phone home with player bar + footer, full-screen chat, desktop).
// • Rows show the name saved in YOUR phone book (search matches it and the
//   Aluta username), but the text inserted is the member's Aluta USERNAME —
//   the one identity every reader shares, so the receiver's bubble, the
//   server and the "you were mentioned" highlight all agree.
// • Who gets tagged is derived from the TEXT at send time
//   ([_resolveMentions]), so deleting a tag, editing, or restoring a draft
//   can never send a stale mention.

extension _ChatMentions on _ChatPageState {
  /// Load the group's members (for the picker). Best-effort.
  Future<void> _loadGroupMembers() async {
    if (!_isGroup) return;
    try {
      final data = await ApiService().getConversation(_cid);
      final mem = (data?['members'] as List?) ?? const [];
      if (!mounted) return;
      _groupMembers = mem
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      _publishMentionNames();
      rebuildWith(() {});
    } catch (_) {}
  }

  /// Tell the bubble renderer how I name each member, so "@juma" in a
  /// message shows as my phone-book name for Juma (else his profile name).
  void _publishMentionNames() {
    for (final m in _groupMembers) {
      final u = _memberUsername(m);
      if (u.isEmpty) continue;
      MentionSelf.names[u.toLowerCase()] = _memberName(m);
    }
  }

  /// Phone-book name if I saved this member, else their Aluta username.
  String _memberName(Map<String, dynamic> m) {
    final phone = (m['phone'] ?? '').toString();
    final saved =
        phone.isNotEmpty ? ContactNames.instance.nameFor(phone) : null;
    return (saved != null && saved.isNotEmpty)
        ? saved
        : (m['username'] ?? 'User').toString();
  }

  String _memberUsername(Map<String, dynamic> m) =>
      (m['username'] ?? '').toString().trim();

  /// The token inserted into the text for a member: "@user" with inner spaces
  /// joined by a non-breaking space so it stays one highlightable run.
  String _mentionToken(Map<String, dynamic> m) =>
      '@${_memberUsername(m).replaceAll(' ', '\u00A0')}';

  bool _isMe(Map<String, dynamic> m) =>
      _myId != null && m['user_id']?.toString() == _myId;

  /// Detect the "@token" the cursor is in and open / refresh / close the
  /// picker. Called from the composer listener (text AND cursor changes).
  void _updateMentionQuery() {
    final text = _ctrl.text;
    final sel = _ctrl.selection;
    if (!_isGroup || !sel.isValid || !sel.isCollapsed) {
      _closeMentionPicker();
      return;
    }
    final cursor = sel.baseOffset.clamp(0, text.length);
    int at = -1;
    for (int i = cursor - 1; i >= 0 && cursor - i <= 40; i--) {
      final ch = text[i];
      if (ch == '@') {
        if (i == 0 || RegExp(r'[\s(\[{"]').hasMatch(text[i - 1])) at = i;
        break;
      }
      // Plain whitespace ends the token; the NBSP inside an inserted tag does
      // too (we're past a finished tag, not typing a query).
      if (ch == '\n' || ch == ' ' || ch == '\u00A0' || ch == '\t') break;
    }
    if (at == -1) {
      _closeMentionPicker();
      return;
    }
    final opening = _mentionQuery == null;
    _mentionStart = at;
    _mentionQuery = text.substring(at + 1, cursor);
    if (opening && _groupMembers.isEmpty) unawaited(_loadGroupMembers());
  }

  List<Map<String, dynamic>> _mentionCandidates() {
    final q = (_mentionQuery ?? '').toLowerCase().trim();
    final prefix = <Map<String, dynamic>>[];
    final contains = <Map<String, dynamic>>[];
    for (final m in _groupMembers) {
      if (_isMe(m) || _memberUsername(m).isEmpty) continue;
      final name = _memberName(m).toLowerCase();
      final user = _memberUsername(m).toLowerCase();
      if (q.isEmpty || name.startsWith(q) || user.startsWith(q)) {
        prefix.add(m);
      } else if (name.contains(q) || user.contains(q)) {
        contains.add(m);
      }
    }
    int byName(Map<String, dynamic> a, Map<String, dynamic> b) =>
        _memberName(a).toLowerCase().compareTo(_memberName(b).toLowerCase());
    prefix.sort(byName);
    contains.sort(byName);
    return [...prefix, ...contains];
  }

  void _closeMentionPicker() {
    _mentionQuery = null;
    _mentionStart = -1;
    _mentionTicked.clear();
  }

  /// Replace the typed "@query" with the chosen tag(s) (or "@all ").
  void _commitMentions(List<Map<String, dynamic>> members, {bool all = false}) {
    final text = _ctrl.text;
    final end = _ctrl.selection.baseOffset.clamp(0, text.length);
    final start = _mentionStart.clamp(0, text.length);
    if (start > end || (!all && members.isEmpty)) {
      rebuildWith(_closeMentionPicker);
      return;
    }
    final insert =
        all ? '@all ' : '${members.map(_mentionToken).join(' ')} ';
    final before = text.substring(0, start);
    final after = text.substring(end);
    _applyingListEdit = true; // don't re-run the @ detector on our own edit
    _ctrl.value = TextEditingValue(
      text: before + insert + after,
      selection:
          TextSelection.collapsed(offset: before.length + insert.length),
    );
    _applyingListEdit = false;
    rebuildWith(_closeMentionPicker);
  }

  /// Who this text tags: the member ids whose "@username" appears as a token,
  /// and whether "@all" was used. Derived from the final text, so it is always
  /// consistent with what the recipients will read.
  ({List<int> ids, bool all}) _resolveMentions(String text) {
    if (!_isGroup || !text.contains('@')) return (ids: const [], all: false);
    final tokens = <String>{};
    for (final m in RegExp(r'(?<![^\s(\[{"\u0027])@([^\s@.,!?;:)\]}"\u0027]+(?:\u00A0[^\s@.,!?;:)\]}"\u0027]+)*)')
        .allMatches(text)) {
      tokens.add(m.group(1)!.replaceAll('\u00A0', ' ').toLowerCase());
    }
    final all = tokens.contains('all');
    final ids = <int>[];
    for (final m in _groupMembers) {
      if (_isMe(m)) continue;
      final u = _memberUsername(m).toLowerCase();
      final id = (m['user_id'] as num?)?.toInt();
      if (id != null && u.isNotEmpty && tokens.contains(u)) ids.add(id);
    }
    return (ids: ids, all: all);
  }

  /// The inline "Tag members" card shown above the composer while typing "@".
  Widget _buildMentionPicker(ColorScheme scheme, bool isDark) {
    final candidates = _mentionCandidates();
    final ticked = _mentionTicked;
    final q = (_mentionQuery ?? '').toLowerCase();
    final showAll = 'all'.startsWith(q.trim());

    // Size to the space ABOVE the keyboard, so on a phone with the keyboard
    // up the chat list keeps a sliver and nothing overlaps. View insets are
    // read from the View (the Scaffold strips them from this subtree).
    final view = View.of(context);
    final kb = view.viewInsets.bottom / view.devicePixelRatio;
    final visible = MediaQuery.sizeOf(context).height - kb;
    final maxH = (visible * (kb > 0 ? 0.34 : 0.40)).clamp(120.0, 320.0);

    Widget avatarFor(Map<String, dynamic> m, String name) {
      final rel = (m['avatar_url'] ?? '').toString();
      final url = rel.isNotEmpty ? fullMediaUrl(rel) : null;
      return CircleAvatar(
        radius: 17,
        backgroundColor: scheme.primaryContainer,
        backgroundImage: url != null
            ? authNetworkImageProvider(url, mediaAuthHeaders(url))
            : null,
        child: url == null
            ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: TextStyle(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700))
            : null,
      );
    }

    void toggle(int id) => rebuildWith(() {
          if (!ticked.remove(id)) ticked.add(id);
        });

    Widget row(Map<String, dynamic> m) {
      final id = (m['user_id'] as num?)?.toInt();
      final name = _memberName(m);
      final user = _memberUsername(m);
      final on = id != null && ticked.contains(id);
      return InkWell(
        // Tap = tag this person now. Once you've started ticking, a tap
        // toggles instead, and the button below tags them all.
        onTap: id == null
            ? null
            : () => ticked.isEmpty ? _commitMentions([m]) : toggle(id),
        onLongPress: id == null ? null : () => toggle(id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          child: Row(
            children: [
              avatarFor(m, name),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    if (user.isNotEmpty && user != name)
                      Text('@$user',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11.5,
                              color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: on ? 'Untick' : 'Select several',
                onPressed: id == null ? null : () => toggle(id),
                icon: Icon(
                  on
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: on ? scheme.primary : scheme.outlineVariant,
                  size: 22,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      constraints: BoxConstraints(maxHeight: maxH, maxWidth: 560),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
            color: scheme.primary.withValues(alpha: isDark ? 0.30 : 0.16)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.40 : 0.10),
            blurRadius: 18,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 6, 6),
            child: Row(
              children: [
                Icon(Icons.alternate_email_rounded,
                    size: 16, color: scheme.primary),
                const SizedBox(width: 7),
                Text(
                    ticked.isEmpty
                        ? 'Tag members'
                        : '${ticked.length} selected',
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurface)),
                const Spacer(),
                if (ticked.isNotEmpty)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                    onPressed: () => _commitMentions(_groupMembers
                        .where((m) => ticked
                            .contains((m['user_id'] as num?)?.toInt()))
                        .toList()),
                    icon: const Icon(Icons.check_rounded, size: 17),
                    label: Text('Tag ${ticked.length}'),
                  ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Close',
                  onPressed: () => rebuildWith(_closeMentionPicker),
                  icon: Icon(Icons.close_rounded,
                      size: 18, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: _groupMembers.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(18),
                    child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.4)),
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    shrinkWrap: true,
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.manual,
                    children: [
                      if (showAll)
                        InkWell(
                          onTap: () => _commitMentions(const [], all: true),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 17,
                                  backgroundColor:
                                      scheme.primary.withValues(alpha: 0.16),
                                  child: Icon(Icons.groups_rounded,
                                      size: 18, color: scheme.primary),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text('@all',
                                          style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                              color: scheme.primary)),
                                      Text('Notify everyone in this group',
                                          style: TextStyle(
                                              fontSize: 11.5,
                                              color:
                                                  scheme.onSurfaceVariant)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (candidates.isEmpty && !showAll)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Center(
                            child: Text('No members match "@$_mentionQuery"',
                                style: TextStyle(
                                    color: scheme.onSurfaceVariant)),
                          ),
                        ),
                      for (final m in candidates) row(m),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
