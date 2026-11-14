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
  String get _membersCacheKey => 'group_members_v1_$_cid';

  /// Members + roles as last seen on this device — so the "admin" tags, the
  /// admins-only composer and the @-picker are right on the FIRST frame,
  /// instead of popping in after the network round-trip.
  Future<void> _loadCachedGroupMembers() async {
    if (!_isGroup || _groupMembers.isNotEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_membersCacheKey);
      if (raw == null || !mounted) return;
      final d = jsonDecode(raw);
      if (d is! Map) return;
      _adminsOnly = d['admins_only'] == true;
      _amAdmin = d['my_role']?.toString() == 'admin';
      _groupMembers = ((d['members'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      _publishMentionNames();
      rebuildWith(() {});
    } catch (_) {}
  }

  /// Load the group's members (for the picker). Best-effort.
  Future<void> _loadGroupMembers() async {
    if (!_isGroup) return;
    try {
      final data = await ApiService().getConversation(_cid);
      final mem = (data?['members'] as List?) ?? const [];
      if (!mounted) return;
      if (data != null) {
        _adminsOnly = data['admins_only'] == true;
        _amAdmin = data['my_role']?.toString() == 'admin';
      }
      _groupMembers = mem
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      ContactNames.instance.rememberAll(_groupMembers);
      _publishMentionNames();
      rebuildWith(() {});
      if (data != null) {
        try {
          final p = await SharedPreferences.getInstance();
          await p.setString(
              _membersCacheKey,
              jsonEncode({
                'admins_only': _adminsOnly,
                'my_role': data['my_role'],
                'members': _groupMembers,
              }));
        } catch (_) {}
      }
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
    // Who's most likely meant: whoever spoke most recently here (and, among
    // equals, more often), then the rest by name — so "@" + one tap is
    // usually the right person.
    final lastAt = <String, int>{};
    final count = <String, int>{};
    var i = 0;
    for (final msg in _messages) {
      if (i++ >= 300) break;
      final sid = msg['sender_id']?.toString();
      if (sid == null || sid == _myId) continue;
      lastAt.putIfAbsent(sid, () => i);
      count[sid] = (count[sid] ?? 0) + 1;
    }
    int rank(Map<String, dynamic> a, Map<String, dynamic> b) {
      final ia = a['user_id']?.toString() ?? '', ib = b['user_id']?.toString() ?? '';
      final la = lastAt[ia] ?? 1 << 30, lb = lastAt[ib] ?? 1 << 30;
      // Spoke within the last ~40 messages → by recency; otherwise by
      // how often, then the name.
      final ra = la <= 40 ? la : 1000, rb = lb <= 40 ? lb : 1000;
      if (ra != rb) return ra.compareTo(rb);
      final ca = count[ia] ?? 0, cb = count[ib] ?? 0;
      if (ca != cb) return cb.compareTo(ca);
      return _memberName(a).toLowerCase().compareTo(_memberName(b).toLowerCase());
    }
    prefix.sort(rank);
    contains.sort(rank);
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

  /// Tapped "@Juma" in a bubble → a small card: who it is (the name I saved,
  /// their @username, admin), and Message / Call. Only what the group already
  /// shares. "@all" shows how many it reached.
  void _peekMention(String key) {
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    final ink = accentInk(scheme);
    Haptics.selectionClick();
    if (key == 'all') {
      final n = _groupMembers.where((m) => !_isMe(m)).length;
      showToast(context,
          n > 0 ? '@all tags everyone here — $n people' : '@all tags everyone here',
          type: ToastType.info);
      return;
    }
    Map<String, dynamic>? m;
    for (final g in _groupMembers) {
      if (_memberUsername(g).toLowerCase() == key) {
        m = g;
        break;
      }
    }
    if (m == null) {
      showToast(context, 'They’re no longer in this group',
          type: ToastType.info);
      return;
    }
    final member = m;
    if (_isMe(member)) {
      showToast(context, 'That’s you 💞', type: ToastType.info);
      return;
    }
    final id = (member['user_id'] as num?)?.toInt();
    final name = _memberName(member);
    final user = _memberUsername(member);
    final phone = (member['phone'] ?? '').toString();
    final rel = (member['avatar_url'] ?? '').toString();
    final url = rel.isNotEmpty ? fullMediaUrl(rel) : null;
    final admin = member['role']?.toString() == 'admin';
    // Calling: only someone saved in my phone book (I know them).
    final known = phone.isNotEmpty && ContactNames.instance.hasRealName(phone);
    showAdaptiveSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.5), width: 2),
              ),
              child: CircleAvatar(
                radius: 34,
                backgroundColor: scheme.primaryContainer,
                backgroundImage: url != null
                    ? authNetworkImageProvider(url, mediaAuthHeaders(url))
                    : null,
                child: url == null
                    ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                        style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            color: scheme.onPrimaryContainer))
                    : null,
              ),
            ),
            const SizedBox(height: 10),
            Text(name,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface)),
            const SizedBox(height: 2),
            Row(mainAxisSize: MainAxisSize.min, children: [
              if (user != name)
                Text('@$user', style: TextStyle(fontSize: 13, color: ink)),
              if (admin) ...[
                if (user != name) const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('admin',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: ink)),
                ),
              ],
            ]),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                      shape: const StadiumBorder(),
                      padding: const EdgeInsets.symmetric(vertical: 12)),
                  onPressed: id == null
                      ? null
                      : () {
                          Navigator.of(ctx).pop();
                          _openDmWith(id, user, phone, rel);
                        },
                  icon: const Icon(Icons.chat_bubble_rounded, size: 18),
                  label: const Text('Message'),
                ),
              ),
              if (known) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                        shape: const StadiumBorder(),
                        padding: const EdgeInsets.symmetric(vertical: 12)),
                    onPressed: id == null
                        ? null
                        : () async {
                            Navigator.of(ctx).pop();
                            final ok = await CallService.instance.startCall(
                              peerId: id,
                              peerName: name,
                              peerAvatar: rel,
                              myName:
                                  _myName.isNotEmpty ? _myName : 'Aluta user',
                              myAvatar: _myAvatar,
                              fallbackPhone: phone,
                            );
                            if (!ok && mounted) {
                              showToast(context, 'You’re already in a call',
                                  type: ToastType.info);
                            }
                          },
                    icon: const Icon(Icons.call_rounded, size: 18),
                    label: const Text('Call'),
                  ),
                ),
              ],
            ]),
          ]),
        ),
      ),
    );
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

    final picking = ticked.isNotEmpty;
    final ink = accentInk(scheme);

    Widget row(Map<String, dynamic> m) {
      final id = (m['user_id'] as num?)?.toInt();
      final name = _memberName(m);
      final user = _memberUsername(m);
      final on = id != null && ticked.contains(id);
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Material(
          color: on
              ? scheme.primary.withValues(alpha: isDark ? 0.18 : 0.09)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.lg),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.lg),
            // Tap = tag this person now. Hold = pick several; while picking,
            // a tap toggles and "Tag N" tags them all.
            onTap: id == null
                ? null
                : () => picking ? toggle(id) : _commitMentions([m]),
            onLongPress: id == null ? null : () => toggle(id),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 10, 6),
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: on ? scheme.primary : Colors.transparent,
                          width: 2),
                    ),
                    child: avatarFor(m, name),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: scheme.onSurface)),
                        if (user.isNotEmpty && user != name)
                          Text('@$user',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11.5, color: ink)),
                      ],
                    ),
                  ),
                  // Ticks only appear once you're picking several.
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 160),
                    transitionBuilder: (c, a) =>
                        ScaleTransition(scale: a, child: c),
                    child: !picking
                        ? const SizedBox.shrink()
                        : Icon(
                            on
                                ? Icons.check_circle_rounded
                                : Icons.radio_button_unchecked_rounded,
                            key: ValueKey(on),
                            size: 20,
                            color: on
                                ? scheme.primary
                                : scheme.outlineVariant),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // Everyone: a soft accent pill row at the top.
    final everyone = Padding(
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 4),
      child: Material(
        color: scheme.primary.withValues(alpha: isDark ? 0.16 : 0.08),
        borderRadius: BorderRadius.circular(Radii.lg),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.lg),
          onTap: () => _commitMentions(const [], all: true),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
            child: Row(children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.lerp(scheme.primary, Colors.white, 0.25)!,
                      scheme.primary,
                    ],
                  ),
                ),
                child: Icon(Icons.groups_rounded,
                    size: 18, color: scheme.onPrimary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Everyone',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: scheme.onSurface)),
                    Text('@all · notify the whole group',
                        style: TextStyle(fontSize: 11.5, color: ink)),
                  ],
                ),
              ),
            ]),
          ),
        ),
      ),
    );

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      constraints: BoxConstraints(maxHeight: maxH, maxWidth: 520),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
            scheme.primary.withValues(alpha: isDark ? 0.06 : 0.03),
            scheme.surface),
        borderRadius: BorderRadius.circular(Radii.xl),
        border: Border.all(
            color: scheme.primary.withValues(alpha: isDark ? 0.28 : 0.16)),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: isDark ? 0.18 : 0.10),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
            child: Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.primary.withValues(alpha: 0.14),
                  ),
                  child: Icon(Icons.alternate_email_rounded,
                      size: 13, color: ink),
                ),
                const SizedBox(width: 8),
                Text(picking ? '${ticked.length} picked' : 'Tag someone',
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurface)),
                if (!picking) ...[
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text('· hold to pick several',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11.5, color: scheme.onSurfaceVariant)),
                  ),
                ],
                const Spacer(),
                if (picking)
                  FilledButton.tonal(
                    style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        shape: const StadiumBorder()),
                    onPressed: () => _commitMentions(_groupMembers
                        .where((m) =>
                            ticked.contains((m['user_id'] as num?)?.toInt()))
                        .toList()),
                    child: Text('Tag ${ticked.length}'),
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
                    padding: const EdgeInsets.only(bottom: 6),
                    shrinkWrap: true,
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.manual,
                    children: [
                      if (showAll && !picking) everyone,
                      if (candidates.isEmpty && !showAll)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Center(
                            child: Text('No one here matches "@$_mentionQuery"',
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
