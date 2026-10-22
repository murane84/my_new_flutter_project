part of '../chat_page.dart';

// ── Group admins + polls ────────────────────────────────────────────────────
// Admins: a small accent "admin" tag beside their name on bubbles, and when
// the group is set to admins-only (server-enforced) the composer becomes a
// calm frosted note for everyone else. Polls: a group message carrying
// {q, options, multi, votes}; members tap to vote (optimistic, server
// confirms + broadcasts `poll_updated`), bars fill in the theme colour and
// the leader gets a soft heart-pulse ring — Aluta, not a spreadsheet.

extension _ChatPollsAdmin on _ChatPageState {
  bool _isMemberAdmin(Object? userId) {
    final id = userId?.toString();
    if (id == null) return false;
    for (final m in _groupMembers) {
      if (m['user_id']?.toString() == id) return m['role'] == 'admin';
    }
    return false;
  }

  /// Members can't post right now (group set to admins-only, I'm no admin).
  bool get _postingLocked => _isGroup && _adminsOnly && !_amAdmin;

  // [on]: the bubble it sits on — the badge colour stays readable there.
  Widget _adminTag(ColorScheme scheme, {Color? on}) {
    final c = on == null ? scheme.primary : bubbleTintOn(scheme.primary, on);
    return Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: c.withValues(alpha: 0.45)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.shield_rounded, size: 9, color: c),
          const SizedBox(width: 2),
          Text('admin',
              style: TextStyle(
                  fontSize: 9.5,
                  height: 1.0,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                  color: c)),
        ]),
      );
  }

  Widget _buildAdminsOnlyBar(ColorScheme scheme, bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.black.withValues(alpha: 0.35)
                  : Colors.white.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.shield_outlined, size: 17, color: scheme.primary),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Only admins can send messages here',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface.withValues(alpha: 0.75)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Socket events for this file. Returns true when handled.
  bool _handleGroupMetaWs(String? type, Map<String, dynamic> event) {
    if (!_isGroup) return false;
    if (event['conversation_id']?.toString() != _cid.toString()) return false;
    if (type == 'poll_updated') {
      final mid = event['message_id']?.toString();
      final idx = _messages.indexWhere((m) => m['id'].toString() == mid);
      if (idx != -1) {
        rebuildWith(() {
          _messages[idx] = Map<String, dynamic>.from(_messages[idx])
            ..['poll'] = event['poll'];
        });
        _saveMessagesCache();
      }
      return true;
    }
    if (type == 'conversation_updated') {
      if (event['admins_only'] is bool) {
        rebuildWith(() => _adminsOnly = event['admins_only'] as bool);
      }
      _loadGroupMembers(); // roles may have changed
      return true;
    }
    return false;
  }

  // ── Polls ────────────────────────────────────────────────────────────────
  Map<String, dynamic>? _pollOf(Map<String, dynamic> msg) {
    final raw = msg['poll'];
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is! String || raw.isEmpty) return null;
    try {
      final d = jsonDecode(raw);
      return d is Map ? Map<String, dynamic>.from(d) : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _votePoll(Map<String, dynamic> msg, int option) async {
    final poll = _pollOf(msg);
    final mid = int.tryParse(msg['id'].toString());
    if (poll == null || mid == null || _myId == null) return;
    final votes = Map<String, dynamic>.from((poll['votes'] as Map?) ?? {});
    final mine = ((votes[_myId] as List?) ?? const [])
        .map((e) => (e as num).toInt())
        .toList();
    List<int> next;
    if (poll['multi'] == true) {
      next = mine.contains(option)
          ? (mine.where((e) => e != option).toList())
          : [...mine, option];
    } else {
      next = (mine.length == 1 && mine.first == option) ? [] : [option];
    }
    HapticFeedback.selectionClick();
    final before = msg['poll'];
    void setPoll(Object? p) {
      final i = _messages.indexWhere((m) => m['id'].toString() == '$mid');
      if (i == -1) return;
      rebuildWith(() {
        _messages[i] = Map<String, dynamic>.from(_messages[i])..['poll'] = p;
      });
    }

    if (next.isEmpty) {
      votes.remove(_myId);
    } else {
      votes[_myId!] = next..sort();
    }
    setPoll(jsonEncode({...poll, 'votes': votes}));
    final res = await ApiService().votePoll(_cid, mid, next);
    if (!mounted) return;
    if (res == null) {
      setPoll(before);
      _showErrorSnack('Vote not sent — check your connection.');
    } else {
      setPoll(res);
      _saveMessagesCache();
    }
  }

  Future<void> _openPollComposer() async {
    final scheme = Theme.of(context).colorScheme;
    final q = TextEditingController();
    final opts = [TextEditingController(), TextEditingController()];
    var multi = false;
    var jam = false;
    // Song titles I can offer for a jam (my loaded playlist / web queue).
    final songTitles = _jamSongTitles();
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        final clean = opts
            .map((c) => c.text.trim())
            .where((t) => t.isNotEmpty)
            .toList();
        final distinct = clean.map((e) => e.toLowerCase()).toSet().length;
        final ok = q.text.trim().isNotEmpty &&
            clean.length >= 2 &&
            distinct == clean.length;
        InputDecoration deco(String hint, {Widget? suffix}) => InputDecoration(
              hintText: hint,
              isDense: true,
              filled: true,
              fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
              suffixIcon: suffix,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(
                      color: scheme.primary.withValues(alpha: 0.5))),
            );
        return Padding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                          color: scheme.outlineVariant,
                          borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    Icon(jam ? Icons.queue_music_rounded : Icons.poll_rounded,
                        color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(jam ? 'Group jam' : 'New poll',
                          style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: scheme.onSurface)),
                    ),
                    // A jam: fill the options from my songs.
                    if (songTitles.isNotEmpty)
                      TextButton.icon(
                        onPressed: () async {
                          final picked =
                              await _pickJamSongs(ctx, songTitles);
                          if (picked == null || picked.length < 2) return;
                          setS(() {
                            jam = true;
                            if (q.text.trim().isEmpty) {
                              q.text = 'What do we play next? 🎶';
                            }
                            final old = List.of(opts);
                            opts
                              ..clear()
                              ..addAll(picked
                                  .map((t) => TextEditingController(text: t)));
                            if (opts.length < 12) {
                              opts.add(TextEditingController());
                            }
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              for (final c in old) {
                                c.dispose();
                              }
                            });
                          });
                        },
                        icon: const Icon(Icons.library_music_rounded, size: 18),
                        label: const Text('Songs'),
                      ),
                  ]),
                  const SizedBox(height: 14),
                  TextField(
                    controller: q,
                    autofocus: true,
                    maxLength: 300,
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (_) => setS(() {}),
                    decoration: deco('Ask something…').copyWith(counterText: ''),
                  ),
                  const SizedBox(height: 10),
                  for (var i = 0; i < opts.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TextField(
                        key: ObjectKey(opts[i]),
                        controller: opts[i],
                        maxLength: 100,
                        textCapitalization: TextCapitalization.sentences,
                        onChanged: (_) => setS(() {
                          // Typing in the last box opens a fresh one.
                          if (i == opts.length - 1 &&
                              opts[i].text.trim().isNotEmpty &&
                              opts.length < 12) {
                            opts.add(TextEditingController());
                          }
                        }),
                        decoration: deco('Option ${i + 1}',
                                suffix: opts.length > 2 &&
                                        i < opts.length - 1
                                    ? IconButton(
                                        icon: const Icon(Icons.close_rounded,
                                            size: 18),
                                        onPressed: () {
                                          final gone = opts[i];
                                          setS(() => opts.removeAt(i));
                                          WidgetsBinding.instance
                                              .addPostFrameCallback(
                                                  (_) => gone.dispose());
                                        },
                                      )
                                    : null)
                            .copyWith(counterText: ''),
                      ),
                    ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: multi,
                    onChanged: (v) => setS(() => multi = v),
                    title: const Text('Allow several answers'),
                  ),
                  if (clean.length >= 2 && distinct != clean.length)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text('Options need to be different',
                          style:
                              TextStyle(color: scheme.error, fontSize: 12)),
                    ),
                  const SizedBox(height: 4),
                  FilledButton.icon(
                    onPressed: ok
                        ? () => Navigator.pop(ctx, {
                              'q': q.text.trim(),
                              'options': clean,
                              'multi': multi,
                              if (jam) 'kind': 'jam',
                            })
                        : null,
                    icon: const Icon(Icons.send_rounded, size: 18),
                    label: Text(jam ? 'Start the jam' : 'Send poll'),
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(46),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14))),
                  ),
                ],
              ),
            ),
          ),
        );
      }),
    );
    // The sheet is still animating out (its fields still build) — dispose
    // the controllers once it's fully gone.
    Future.delayed(const Duration(milliseconds: 600), () {
      q.dispose();
      for (final c in opts) {
        c.dispose();
      }
    });
    if (result == null || !mounted) return;
    _sendPoll(result);
  }

  /// Titles from my loaded playlist (or the web queue), de-duplicated.
  List<String> _jamSongTitles() {
    final out = <String>[];
    final seen = <String>{};
    void add(String t) {
      final s = t.trim();
      if (s.isNotEmpty && seen.add(s.toLowerCase())) out.add(s);
    }

    try {
      for (final p in playlistNotifier.value) {
        var name = p.split(RegExp(r'[\\/]')).last;
        name = name.replaceAll(RegExp(r'\.[A-Za-z0-9]{2,4}$'), '');
        add(name);
      }
      if (out.isEmpty) {
        for (final e in playbackBus.webQueue?.call() ?? const []) {
          add(e.title);
        }
      }
    } catch (_) {}
    return out;
  }

  Future<List<String>?> _pickJamSongs(
      BuildContext ctx, List<String> titles) async {
    final chosen = <String>{};
    return showModalBottomSheet<List<String>>(
      context: ctx,
      isScrollControlled: true,
      builder: (c) => StatefulBuilder(
        builder: (c, setC) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(c).height * 0.7),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 8, 4),
                child: Row(children: [
                  Expanded(
                    child: Text('Pick 2–12 songs (${chosen.length})',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w800)),
                  ),
                  TextButton(
                    onPressed: chosen.length >= 2
                        ? () => Navigator.pop(
                            c, titles.where(chosen.contains).toList())
                        : null,
                    child: const Text('Use'),
                  ),
                ]),
              ),
              Flexible(
                child: ListView(shrinkWrap: true, children: [
                  for (final t in titles)
                    CheckboxListTile(
                      dense: true,
                      value: chosen.contains(t),
                      title: Text(t, maxLines: 1, overflow: TextOverflow.ellipsis),
                      secondary: const Icon(Icons.music_note_rounded),
                      onChanged: (v) => setC(() {
                        if (v == true && chosen.length < 12) {
                          chosen.add(t);
                        } else {
                          chosen.remove(t);
                        }
                      }),
                    ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  void _sendPoll(Map<String, dynamic> spec) {
    final question = spec['q'] as String;
    final tempId = _newTempId();
    final optimistic = _optimisticMsg(tempId, 'poll', question);
    optimistic['poll'] = jsonEncode({...spec, 'votes': {}});
    _insertOptimistic(optimistic);
    _markActivity();
    Future<void> attempt() async {
      try {
        final sent = await ApiService().sendMessage(
            widget.friendId, question,
            messageType: 'poll',
            conversationId: widget.conversationId,
            poll: jsonEncode(spec));
        _replaceOptimistic(tempId, sent);
        if (sent == null && mounted) {
          _showErrorSnack('Poll failed — tap the ! to retry.');
        }
      } catch (_) {
        _replaceOptimistic(tempId, null);
        if (mounted) _showErrorSnack('Poll failed — tap the ! to retry.');
      }
    }

    _outbox[tempId] = attempt;
    unawaited(attempt());
  }

  Widget _pollContent(Map<String, dynamic> msg, bool isMe, Color textColor,
      ColorScheme scheme) {
    final poll = _pollOf(msg);
    if (poll == null) {
      return Text('📊 ${msg['content'] ?? 'Poll'}',
          style: TextStyle(color: textColor));
    }
    final options = ((poll['options'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
    final votes = (poll['votes'] as Map?) ?? const {};
    final multi = poll['multi'] == true;
    final counts = List<int>.filled(options.length, 0);
    for (final v in votes.values) {
      for (final i in (v as List? ?? const [])) {
        final k = (i as num).toInt();
        if (k >= 0 && k < counts.length) counts[k]++;
      }
    }
    final voters = votes.length;
    final mine = ((votes[_myId] as List?) ?? const [])
        .map((e) => (e as num).toInt())
        .toSet();
    final top = counts.isEmpty ? 0 : counts.reduce(math.max);
    final pending = msg['__pending'] == true;
    final accent = isMe ? textColor : scheme.primary;
    final isJam = poll['kind'] == 'jam';
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 300),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Icon(isJam ? Icons.queue_music_rounded : Icons.poll_rounded,
                size: 15, color: accent),
            const SizedBox(width: 5),
            Text(
                isJam
                    ? 'GROUP JAM · vote the next song'
                    : (multi ? 'POLL · pick any' : 'POLL'),
                style: TextStyle(
                    fontSize: 10.5,
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w800,
                    color: accent.withValues(alpha: 0.85))),
          ]),
          const SizedBox(height: 6),
          Text(poll['q']?.toString() ?? '',
              style: TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                  color: textColor)),
          const SizedBox(height: 8),
          for (var i = 0; i < options.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _pollOption(
                label: options[i],
                count: counts[i],
                frac: voters == 0 ? 0 : counts[i] / voters,
                picked: mine.contains(i),
                leading: top > 0 && counts[i] == top,
                multi: multi,
                jam: isJam,
                textColor: textColor,
                accent: accent,
                onTap: pending ? null : () => _votePoll(msg, i),
              ),
            ),
          Text(
            voters == 0
                ? 'No votes yet · tap to vote'
                : '$voters vote${voters == 1 ? '' : 's'}'
                    '${mine.isEmpty ? ' · tap to vote' : ''}',
            style:
                TextStyle(fontSize: 11, color: textColor.withValues(alpha: 0.6)),
          ),
        ],
      ),
    );
  }

  Widget _pollOption({
    required String label,
    required int count,
    required double frac,
    required bool picked,
    required bool leading,
    required bool multi,
    bool jam = false,
    required Color textColor,
    required Color accent,
    VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: picked
                    ? accent.withValues(alpha: 0.7)
                    : textColor.withValues(alpha: 0.16)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: Stack(
              children: [
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(end: frac.clamp(0.0, 1.0)),
                      duration: const Duration(milliseconds: 420),
                      curve: Curves.easeOutCubic,
                      builder: (_, f, _) => FractionallySizedBox(
                        widthFactor: f <= 0 ? 0.0001 : f,
                        heightFactor: 1,
                        child: Container(
                          color: accent.withValues(
                              alpha: picked ? 0.22 : 0.11),
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 9),
                  child: Row(
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        transitionBuilder: (c, a) =>
                            ScaleTransition(scale: a, child: c),
                        child: Icon(
                          key: ValueKey(picked),
                          picked
                              ? (multi
                                  ? Icons.check_box_rounded
                                  : Icons.check_circle_rounded)
                              : (multi
                                  ? Icons.check_box_outline_blank_rounded
                                  : Icons.radio_button_unchecked_rounded),
                          size: 18,
                          color: picked
                              ? accent
                              : textColor.withValues(alpha: 0.45),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(label,
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight:
                                    picked ? FontWeight.w700 : FontWeight.w500,
                                color: textColor)),
                      ),
                      if (leading)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: jam
                              ? Text('Next up 🎶',
                                  style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w800,
                                      color: accent))
                              : Icon(Icons.favorite_rounded,
                                  size: 12, color: accent),
                        ),
                      if (count > 0)
                        Text('$count',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: textColor.withValues(alpha: 0.75))),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
