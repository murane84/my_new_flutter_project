part of '../relationship_space_page.dart';

// Split out of relationship_space_page.dart (pure code movement, no behaviour
// change): moment comments, memory detail sheet, moment video player. A library `part`, so it shares the page's imports and
// private members.

// ── memory / plan detail card (full read + reactions + comments) ───────────
class _MomentCommentsSheet extends StatefulWidget {
  const _MomentCommentsSheet({
    required this.spaceId,
    required this.moment,
    required this.accent,
    required this.apiBase,
    this.onChanged,
  });
  final int spaceId;
  final Map<String, dynamic> moment;
  final Color accent;
  final String apiBase;
  final VoidCallback? onChanged;

  @override
  State<_MomentCommentsSheet> createState() => _MomentCommentsSheetState();
}

class _MomentCommentsSheetState extends State<_MomentCommentsSheet> {
  late Map<String, dynamic> _m = Map<String, dynamic>.from(widget.moment);
  late List<Map<String, dynamic>> _comments = ((_m['comments'] as List?) ??
          const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();
  final TextEditingController _c = TextEditingController();
  bool _sending = false;
  int? _editingId;

  int get _mid => (_m['id'] as num).toInt();

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final list = await ApiService().getMomentComments(widget.spaceId, _mid);
    if (!mounted) return;
    setState(() {
      _comments = list;
      _m['comment_count'] = list.length;
    });
  }

  Future<void> _toggleReact(String emoji) async {
    final res = await ApiService().reactMoment(widget.spaceId, _mid, emoji);
    if (!mounted || res == null) return;
    setState(() => _m = {..._m, ...res});
    widget.onChanged?.call();
  }

  Future<void> _send() async {
    final text = _c.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final res = _editingId != null
        ? await ApiService()
            .editMomentComment(widget.spaceId, _mid, _editingId!, text)
        : await ApiService().addMomentComment(widget.spaceId, _mid, text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (res != null) {
      _c.clear();
      _editingId = null;
      await _refresh();
      widget.onChanged?.call();
    }
  }

  void _commentActions(Map<String, dynamic> cm) {
    final cid = (cm['id'] as num?)?.toInt();
    if (cid == null) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (bctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: const Text('Edit'),
              onTap: () {
                Navigator.pop(bctx);
                setState(() {
                  _editingId = cid;
                  _c.text = (cm['body'] ?? '').toString();
                });
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded,
                  color: Colors.red),
              title: const Text('Delete',
                  style: TextStyle(color: Colors.red)),
              onTap: () async {
                Navigator.pop(bctx);
                final ok = await ApiService()
                    .deleteMomentComment(widget.spaceId, _mid, cid);
                if (ok && mounted) {
                  await _refresh();
                  widget.onChanged?.call();
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  String _ago(DateTime dt) {
    final d = DateTime.now().difference(dt.toLocal());
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    if (d.inDays < 7) return '${d.inDays}d';
    return DateFormat('MMM d').format(dt.toLocal());
  }

  Widget _commentRow(ColorScheme scheme, Map<String, dynamic> cm) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mine = cm['mine'] == true;
    final author = (cm['author'] as Map?)?.cast<String, dynamic>();
    final body = (cm['body'] ?? '').toString();
    final created = DateTime.tryParse((cm['created_at'] ?? '').toString());
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          diaryAuthorBadge(
            name: ContactNames.instance.displayName(of: author, registered: (author?['username'] ?? '?').toString()),
            imageUrl: resolveAvatarUrl(
                author?['avatar_url']?.toString(), widget.apiBase),
            radius: 13,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: GestureDetector(
              onLongPress: mine ? () => _commentActions(cm) : null,
              onSecondaryTap: mine ? () => _commentActions(cm) : null,
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 7),
                decoration: BoxDecoration(
                  color: mine
                      ? widget.accent.withValues(alpha: isDark ? 0.30 : 0.16)
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: (mine ? widget.accent : scheme.outlineVariant)
                          .withValues(alpha: mine ? 0.35 : 0.4)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mine ? 'You' : ContactNames.instance.displayName(of: author, registered: (author?['username'] ?? '').toString()),
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: widget.accent),
                    ),
                    const SizedBox(height: 2),
                    Text(body,
                        style: TextStyle(
                            fontSize: 13.5,
                            height: 1.3,
                            color: scheme.onSurface)),
                    const SizedBox(height: 3),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (created != null)
                          Text(_ago(created),
                              style: TextStyle(
                                  fontSize: 10,
                                  color: scheme.onSurfaceVariant)),
                        if (mine) ...[
                          const SizedBox(width: 5),
                          GestureDetector(
                            onTap: () => _commentActions(cm),
                            child: Icon(Icons.more_horiz_rounded,
                                size: 15,
                                color: scheme.onSurfaceVariant
                                    .withValues(alpha: 0.75)),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasText = _c.text.trim().isNotEmpty;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.82),
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
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
              child: diaryReactionRow(
                scheme: scheme,
                accent: widget.accent,
                entry: _m,
                onToggle: _toggleReact,
                onAdd: () async {
                  final em = await pickDiaryReaction(context, widget.accent);
                  if (em != null && mounted) _toggleReact(em);
                },
              ),
            ),
            Divider(height: 1, color: scheme.outlineVariant),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    _comments.isEmpty
                        ? 'Comments'
                        : 'Comments (${_comments.length})',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        color: scheme.onSurface)),
              ),
            ),
            Flexible(
              child: _comments.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(18, 22, 18, 26),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.forum_outlined,
                              size: 30,
                              color: widget.accent.withValues(alpha: 0.55)),
                          const SizedBox(height: 8),
                          Text('No comments yet',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: scheme.onSurface)),
                          const SizedBox(height: 2),
                          Text('Be the first to say something 💬',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
                      itemCount: _comments.length,
                      itemBuilder: (ctx, i) => _commentRow(scheme, _comments[i]),
                    ),
            ),
            Divider(height: 1, color: scheme.outlineVariant),
            if (_editingId != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    Icon(Icons.edit_rounded, size: 15, color: widget.accent),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('Editing your comment',
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: widget.accent)),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        _editingId = null;
                        _c.clear();
                      }),
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                  14, 10, 14, 12 + MediaQuery.of(context).viewInsets.bottom),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _c,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      textCapitalization: TextCapitalization.sentences,
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: _editingId != null
                            ? 'Edit your comment…'
                            : 'Add a comment…',
                        isDense: true,
                        filled: true,
                        fillColor: scheme.surfaceContainerHighest,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _sending
                      ? SizedBox(
                          width: 40,
                          height: 40,
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: widget.accent),
                          ),
                        )
                      : IconButton.filled(
                          onPressed: hasText ? _send : null,
                          style: IconButton.styleFrom(
                              backgroundColor: widget.accent,
                              foregroundColor: readableOn(widget.accent),
                              disabledBackgroundColor:
                                  widget.accent.withValues(alpha: 0.35)),
                          icon: const Icon(Icons.send_rounded, size: 18),
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MemoryDetailSheet extends StatefulWidget {
  final int spaceId;
  final Map<String, dynamic> entry;
  final Color accent;
  final String apiBase;
  final VoidCallback? onChanged;
  const _MemoryDetailSheet({
    required this.spaceId,
    required this.entry,
    required this.accent,
    required this.apiBase,
    this.onChanged,
  });

  @override
  State<_MemoryDetailSheet> createState() => _MemoryDetailSheetState();
}

class _MemoryDetailSheetState extends State<_MemoryDetailSheet> {
  late Map<String, dynamic> _e = Map<String, dynamic>.from(widget.entry);
  final TextEditingController _c = TextEditingController();
  final ScrollController _listC = ScrollController();
  bool _sending = false;
  // The memory body starts collapsed on this comment-focused page so the thread
  // gets the room; the reader expands it if they want the full text.
  bool _memoExpanded = false;
  // Rebuilds the send button's enabled state as the field fills/empties.
  bool _hasText = false;
  // The id of the comment being edited (its text is loaded into the composer),
  // or null when composing a new comment.
  int? _editingId;

  Color get _accent => widget.accent;

  /// Long-press actions on your own comment — a clean sheet instead of an
  /// inline "X". Edit loads it into the composer; Delete removes it.
  void _commentActions(Map<String, dynamic> cm) {
    final cid = (cm['id'] as num?)?.toInt();
    if (cid == null) return;
    final scheme = Theme.of(context).colorScheme;
    final preview = (cm['body'] ?? '').toString().trim();
    // One action row: a rounded, full-width tappable with an icon + label,
    // tinted for a destructive action.
    Widget action(IconData icon, String label, Color color, VoidCallback tap) =>
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Material(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: tap,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                child: Row(
                  children: [
                    Icon(icon, size: 20, color: color),
                    const SizedBox(width: 14),
                    Text(label,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: color)),
                  ],
                ),
              ),
            ),
          ),
        );
    showModalBottomSheet(
      context: context,
      backgroundColor: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        side: BorderSide(color: _accent.withValues(alpha: 0.28)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 10),
            // Grab handle.
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Which comment — a quiet one-line quote so it's clear what you're
            // about to edit or delete.
            if (preview.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Text('“$preview”',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontStyle: FontStyle.italic,
                        color: scheme.onSurfaceVariant)),
              ),
            action(Icons.edit_outlined, 'Edit', _accent, () {
              Navigator.pop(ctx);
              _startEditComment(cm);
            }),
            action(Icons.delete_outline_rounded, 'Delete', scheme.error, () {
              Navigator.pop(ctx);
              _deleteComment(cid);
            }),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  void _startEditComment(Map<String, dynamic> cm) {
    final cid = (cm['id'] as num?)?.toInt();
    if (cid == null) return;
    setState(() {
      _editingId = cid;
      _c.text = (cm['body'] ?? '').toString();
      _c.selection = TextSelection.collapsed(offset: _c.text.length);
    });
  }

  void _cancelEdit() {
    setState(() {
      _editingId = null;
      _c.clear();
    });
  }

  @override
  void initState() {
    super.initState();
    // Live updates: when a bond event lands over the socket (partner reacted or
    // commented), re-fetch THIS memory so its reactions + comment feed update in
    // place without a manual refresh.
    spaceEventBus.addListener(_onBus);
    _c.addListener(_onText);
    // Open on the NEWEST comment, like any chat thread.
    _scrollToBottom(animated: false);
  }

  void _onText() {
    final has = _c.text.trim().isNotEmpty;
    if (has != _hasText) setState(() => _hasText = has);
  }

  /// Drop the comment list to the bottom so the latest message is in view —
  /// on open and after sending. Post-frame so the new row is laid out first.
  void _scrollToBottom({bool animated = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_listC.hasClients) return;
      final max = _listC.position.maxScrollExtent;
      if (animated) {
        _listC.animateTo(max,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOut);
      } else {
        _listC.jumpTo(max);
      }
    });
  }

  @override
  void dispose() {
    spaceEventBus.removeListener(_onBus);
    _c.removeListener(_onText);
    _listC.dispose();
    _c.dispose();
    super.dispose();
  }

  Future<void> _onBus() async {
    final id = (_e['id'] as num?)?.toInt();
    if (id == null) return;
    final full = await ApiService().getSpace(widget.spaceId);
    if (!mounted || full == null) return;
    final match = ((full['diary'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where((e) => (e['id'] as num?)?.toInt() == id)
        .toList();
    if (match.isNotEmpty) {
      final before = _comments.length;
      setState(() => _e = match.first);
      // A comment arrived live (e.g. the partner replied) → bring it into view.
      if (_comments.length > before) _scrollToBottom();
    }
  }

  List<Map<String, dynamic>> get _comments =>
      ((_e['comments'] as List?) ?? const [])
          .whereType<Map>()
          .map((c) => Map<String, dynamic>.from(c))
          .toList();

  Future<void> _toggle(String emoji) async {
    final id = (_e['id'] as num).toInt();
    final updated =
        await ApiService().reactDiaryEntry(widget.spaceId, id, emoji);
    if (!mounted) return;
    if (updated != null) {
      setState(() => _e = updated);
      widget.onChanged?.call();
    } else {
      showToast(context, 'Could not react — try again', type: ToastType.error);
    }
  }

  Future<void> _addComment() async {
    final text = _c.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final id = (_e['id'] as num).toInt();
    final editing = _editingId;
    final c = editing != null
        ? await ApiService().editDiaryComment(widget.spaceId, id, editing, text)
        : await ApiService().addDiaryComment(widget.spaceId, id, text);
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (c != null) {
        final list = List<Map<String, dynamic>>.from(
            (_e['comments'] as List?) ?? const []);
        if (editing != null) {
          final idx =
              list.indexWhere((x) => (x['id'] as num?)?.toInt() == editing);
          if (idx >= 0) {
            list[idx] = Map<String, dynamic>.from(c);
          } else {
            list.add(Map<String, dynamic>.from(c));
          }
        } else {
          list.add(Map<String, dynamic>.from(c));
        }
        _e['comments'] = list;
        _e['comment_count'] = list.length;
        _c.clear();
        _editingId = null;
      }
    });
    if (c != null) {
      widget.onChanged?.call();
      // Follow a freshly sent comment down to it (an edit stays in place).
      if (editing == null) _scrollToBottom();
    } else if (mounted) {
      showToast(
          context,
          editing != null
              ? 'Could not edit comment'
              : 'Could not add comment',
          type: ToastType.error);
    }
  }

  Future<void> _deleteComment(int cid) async {
    final id = (_e['id'] as num).toInt();
    final ok = await ApiService().deleteDiaryComment(widget.spaceId, id, cid);
    if (!mounted) return;
    if (ok) {
      setState(() {
        final list = List<Map<String, dynamic>>.from(
            (_e['comments'] as List?) ?? const []);
        list.removeWhere((x) => (x['id'] as num?)?.toInt() == cid);
        _e['comments'] = list;
        _e['comment_count'] = list.length;
      });
      widget.onChanged?.call();
    }
  }

  /// The memory body text in the author's font; [maxLines] null = full text.
  Widget _memoBody(ColorScheme scheme, String body, int? maxLines) {
    return Text(
      body,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      style: TextStyle(
          fontFamily: diaryFontFamily((_e['font'] ?? '').toString()),
          fontSize: 14.5,
          height: 1.5,
          color: scheme.onSurface),
    );
  }

  /// Two comments count as the same run when they're from the same side of the
  /// bond (so a run of yours, or a run of theirs, groups under one avatar).
  bool _sameRun(Map<String, dynamic> a, Map<String, dynamic> b) {
    if ((a['mine'] == true) != (b['mine'] == true)) return false;
    final ai = ((a['author'] as Map?)?['id'] as num?)?.toInt();
    final bi = ((b['author'] as Map?)?['id'] as num?)?.toInt();
    return ai == bi;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = (_e['title'] ?? '').toString().trim();
    final body = (_e['body'] ?? '').toString().trim();
    final author = (_e['author'] as Map?)?.cast<String, dynamic>();
    final created = DateTime.tryParse((_e['created_at'] ?? '').toString());
    final isPlan = (_e['kind'] ?? '') == 'plan';
    final comments = _comments;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 36),
      backgroundColor: scheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 8, 10),
              child: Row(
                children: [
                  Icon(isPlan ? Icons.event_rounded : Icons.menu_book_rounded,
                      color: _accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                        title.isNotEmpty
                            ? title
                            : (isPlan ? 'Plan' : 'Memory'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: scheme.onSurface)),
                  ),
                  HeaderActionButton(
                    tooltip: 'Minimize',
                    icon: Icons.close_fullscreen_rounded,
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: scheme.outlineVariant),
            // PINNED memory — stays put while the comments scroll below it.
            // Its body is capped + scrolls on its own so a long memory can't
            // swallow the comment area.
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      diaryAuthorBadge(
                        name: ContactNames.instance.displayName(of: author, registered: (author?['username'] ?? '?').toString()),
                        imageUrl: resolveAvatarUrl(
                            author?['avatar_url']?.toString(), widget.apiBase),
                        radius: 15,
                      ),
                      const Spacer(),
                      if (created != null)
                        Text(_diaryAgo(created),
                            style: TextStyle(
                                fontSize: 11.5,
                                color: scheme.onSurfaceVariant)),
                    ],
                  ),
                  if (body.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    // Collapsed to a few lines by default so the CONVERSATION is
                    // the focus; expands (and scrolls, if very long) on request.
                    AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      alignment: Alignment.topCenter,
                      child: _memoExpanded
                          ? ConstrainedBox(
                              constraints:
                                  const BoxConstraints(maxHeight: 300),
                              child: SingleChildScrollView(
                                child: _memoBody(scheme, body, null),
                              ),
                            )
                          : _memoBody(scheme, body, 3),
                    ),
                    if (body.length > 140)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: GestureDetector(
                          onTap: () => setState(
                              () => _memoExpanded = !_memoExpanded),
                          child: Text(
                              _memoExpanded ? 'Show less' : 'Show more',
                              style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: _accent)),
                        ),
                      ),
                  ],
                  const SizedBox(height: 12),
                  diaryReactionRow(
                    scheme: scheme,
                    accent: _accent,
                    entry: _e,
                    onToggle: _toggle,
                    onAdd: () async {
                      final em = await pickDiaryReaction(context, _accent);
                      if (em != null && mounted) _toggle(em);
                    },
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: scheme.outlineVariant),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    comments.isEmpty
                        ? 'Comments'
                        : 'Comments (${comments.length})',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        color: scheme.onSurface)),
              ),
            ),
            // Comments scroll INDEPENDENTLY, so the memory above stays visible
            // however long the conversation grows.
            Flexible(
              child: comments.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(18, 18, 18, 22),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.forum_outlined,
                              size: 30,
                              color: _accent.withValues(alpha: 0.55)),
                          const SizedBox(height: 8),
                          Text('No comments yet',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: scheme.onSurface)),
                          const SizedBox(height: 2),
                          Text('Be the first to say something 💬',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    )
                  : ListView.builder(
                      controller: _listC,
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                      itemCount: comments.length,
                      itemBuilder: (ctx, i) {
                        // Show the avatar only on the LAST bubble of a run and
                        // tighten spacing within a run, so a burst of messages
                        // from one person reads as a group, like a chat.
                        final grouped = i < comments.length - 1 &&
                            _sameRun(comments[i], comments[i + 1]);
                        return _commentBubble(scheme, comments[i],
                            showAvatar: !grouped, grouped: grouped);
                      },
                    ),
            ),
            Divider(height: 1, color: scheme.outlineVariant),
            // While editing a comment, a slim banner makes it obvious and offers
            // a quick way out.
            if (_editingId != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    Icon(Icons.edit_rounded, size: 15, color: _accent),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('Editing your comment',
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: _accent)),
                    ),
                    TextButton(
                      onPressed: _cancelEdit,
                      style: TextButton.styleFrom(
                          foregroundColor: scheme.onSurfaceVariant,
                          visualDensity: VisualDensity.compact),
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                  14, 10, 14, 12 + MediaQuery.of(context).viewInsets.bottom),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _c,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _addComment(),
                      decoration: InputDecoration(
                        hintText: _editingId != null
                            ? 'Edit your comment…'
                            : 'Add a comment…',
                        isDense: true,
                        filled: true,
                        fillColor: scheme.surfaceContainerHighest,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _sending
                      ? SizedBox(
                          width: 40,
                          height: 40,
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: _accent),
                          ),
                        )
                      : IconButton.filled(
                          // Disabled (dimmed) until there's something to send.
                          onPressed: _hasText ? _addComment : null,
                          style: IconButton.styleFrom(
                              backgroundColor: _accent,
                              foregroundColor: readableOn(_accent),
                              disabledBackgroundColor:
                                  _accent.withValues(alpha: 0.35)),
                          icon: const Icon(Icons.send_rounded, size: 18),
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A comment as a circle-chat bubble: the sender's photo only (no name), mine
  /// on the right (accent-tinted), the partner's on the left (surface), each
  /// with the near-square tail corner — the same language as the Circle chats.
  Widget _commentBubble(ColorScheme scheme, Map<String, dynamic> cm,
      {bool showAvatar = true, bool grouped = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mine = cm['mine'] == true;
    final author = (cm['author'] as Map?)?.cast<String, dynamic>();
    final body = (cm['body'] ?? '').toString();
    final created = DateTime.tryParse((cm['created_at'] ?? '').toString());
    final cid = (cm['id'] as num?)?.toInt();
    // Avatar only on the last bubble of a run; a same-size spacer otherwise so
    // grouped bubbles stay in the same column.
    final Widget avatar = showAvatar
        ? diaryAuthorBadge(
            name: ContactNames.instance.displayName(of: author, registered: (author?['username'] ?? '?').toString()),
            imageUrl: resolveAvatarUrl(
                author?['avatar_url']?.toString(), widget.apiBase),
            radius: 12,
          )
        : const SizedBox(width: 24);
    final bubbleColor = mine
        ? _accent.withValues(alpha: isDark ? 0.30 : 0.16)
        : scheme.surfaceContainerHighest;
    final bubble = Flexible(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Modern chat-style: long-press (or right-click) your OWN comment to
        // edit or delete — no cramped inline "X".
        onLongPress: mine && cid != null ? () => _commentActions(cm) : null,
        onSecondaryTap: mine && cid != null ? () => _commentActions(cm) : null,
        child: Container(
          margin: EdgeInsets.only(bottom: grouped ? 3 : 8),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 7),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(mine ? 16 : 4),
            bottomRight: Radius.circular(mine ? 4 : 16),
          ),
          border: Border.all(
              color: (mine ? _accent : scheme.outlineVariant)
                  .withValues(alpha: mine ? 0.35 : 0.4)),
        ),
        child: Column(
          crossAxisAlignment:
              mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(body,
                style: TextStyle(
                    fontSize: 13.5, height: 1.3, color: scheme.onSurface)),
            const SizedBox(height: 3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (created != null)
                  Text(_diaryAgo(created),
                      style: TextStyle(
                          fontSize: 10, color: scheme.onSurfaceVariant)),
                if (mine && cid != null) ...[
                  const SizedBox(width: 5),
                  GestureDetector(
                    onTap: () => _commentActions(cm),
                    child: Icon(Icons.more_horiz_rounded,
                        size: 15,
                        color:
                            scheme.onSurfaceVariant.withValues(alpha: 0.75)),
                  ),
                ],
              ],
            ),
          ],
        ),
        ),
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment:
          mine ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: mine
          ? [bubble, const SizedBox(width: 6), avatar]
          : [avatar, const SizedBox(width: 6), bubble],
    );
  }
}

/// A tiny tap-to-play pill for a dedication's voice note (just_audio).
class _MomentVideoPlayer extends StatefulWidget {
  const _MomentVideoPlayer({required this.url});
  final String url;

  @override
  State<_MomentVideoPlayer> createState() => _MomentVideoPlayerState();
}

class _MomentVideoPlayerState extends State<_MomentVideoPlayer> {
  VideoPlayerController? _c;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      VideoPlayerController c;
      if (!kIsWeb) {
        // Cache-first, same as the moment tile: play from the device so the
        // fullscreen view doesn't depend on streaming (which fails on some
        // platforms with "can't play on this device"). Reuse the cached copy
        // the tile already downloaded, or fetch it once if missing.
        File? f = await MediaStore.instance.cached(widget.url);
        f ??= await MediaStore.instance
            .getFile(widget.url, mediaAuthHeaders(widget.url));
        c = f != null
            ? VideoPlayerController.file(f)
            : VideoPlayerController.networkUrl(
                Uri.parse(widget.url),
                httpHeaders: mediaAuthHeaders(widget.url),
              );
      } else {
        c = VideoPlayerController.networkUrl(
          Uri.parse(widget.url),
          httpHeaders: mediaAuthHeaders(widget.url),
        );
      }
      await c.initialize();
      if (!mounted) {
        c.dispose();
        return;
      }
      setState(() => _c = c);
      c.addListener(_onTick);
      c.setLooping(true);
      c.play();
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  String _fmtDur(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  // Fullscreen playback controls: play/pause, ticking time, draggable seek bar.
  Widget _fsControls(VideoPlayerController c) {
    final dur = c.value.duration;
    final pos = c.value.position;
    final totalMs =
        dur.inMilliseconds <= 0 ? 1.0 : dur.inMilliseconds.toDouble();
    final curMs = pos.inMilliseconds.toDouble().clamp(0.0, totalMs);
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      padding: EdgeInsets.fromLTRB(
          12, 34, 12, 20 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xE6000000), Color(0x00000000)],
        ),
      ),
      child: Row(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (c.value.isPlaying) {
                c.pause();
              } else {
                final pp = c.value.position;
                final dd = c.value.duration;
                if (dd > Duration.zero &&
                    pp >= dd - const Duration(milliseconds: 250)) {
                  c.seekTo(Duration.zero);
                }
                c.play();
              }
              setState(() {});
            },
            child: Icon(
                c.value.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                color: Colors.white,
                size: 30),
          ),
          const SizedBox(width: 8),
          Text(_fmtDur(pos),
              style: const TextStyle(color: Colors.white, fontSize: 12)),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: accent,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                overlayColor: accent.withValues(alpha: 0.2),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                min: 0,
                max: totalMs,
                value: curMs,
                onChanged: (v) {
                  c.seekTo(Duration(milliseconds: v.round()));
                  setState(() {});
                },
              ),
            ),
          ),
          Text(_fmtDur(dur),
              style: const TextStyle(color: Colors.white, fontSize: 12)),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _c?.removeListener(_onTick);
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return GestureDetector(
      onTap: () {
        if (c == null || !c.value.isInitialized) return;
        if (c.value.isPlaying) {
          c.pause();
        } else {
          c.play();
        }
        setState(() {});
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: Colors.black),
          if (_error)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  "This video can't play on this device.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            )
          else if (c == null || !c.value.isInitialized)
            const Center(
                child: CircularProgressIndicator(color: Colors.white))
          else
            Center(
              child: AspectRatio(
                aspectRatio:
                    c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
                child: VideoPlayer(c),
              ),
            ),
          if (c != null &&
              c.value.isInitialized &&
              !c.value.isPlaying &&
              !_error)
            const Center(
              child: Icon(Icons.play_arrow_rounded,
                  color: Colors.white70, size: 64),
            ),
          if (c != null && c.value.isInitialized && !_error)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _fsControls(c),
            ),
          Positioned(
            top: 40,
            right: 16,
            child: IconButton(
              icon: const Icon(Icons.close_rounded, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ],
      ),
    );
  }
}
