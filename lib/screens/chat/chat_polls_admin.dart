part of '../chat_page.dart';

/// Bumped by the host (group header: "Mama and Neema are listening now") to
/// open the open group's jam composer.
final ValueNotifier<int> chatJamRequest = ValueNotifier<int>(0);

// ── Group admins + polls ────────────────────────────────────────────────────
// Admins: a small accent "admin" tag beside their name on bubbles, and when
// the group is set to admins-only (server-enforced) the composer becomes a
// calm frosted note for everyone else. Polls: a group message carrying
// {q, options, multi, votes}; members tap to vote (optimistic, server
// confirms + broadcasts `poll_updated`), bars fill in the theme colour and
// the leader gets a soft heart-pulse ring — Aluta, not a spreadsheet.

extension _ChatPollsAdmin on _ChatPageState {
  /// Poll message id → sequence of my latest in-flight vote on it.
  static final Map<String, int> _pollVoteSeq = <String, int>{};

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
                Icon(Icons.shield_outlined, size: 17, color: accentInk(scheme)),
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

  /// A DM with someone I blocked: the composer gives way to a calm bar that
  /// says so and unblocks in one tap (with the same confirm as everywhere).
  Widget _buildBlockedBar(ColorScheme scheme, bool isDark) {
    final name = widget.friendName;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.fromLTRB(16, 4, 6, 4),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.black.withValues(alpha: 0.35)
                  : Colors.white.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                Icon(Icons.block_rounded, size: 17, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'You blocked $name',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface.withValues(alpha: 0.75)),
                  ),
                ),
                TextButton(
                  onPressed: () => BlockList.instance
                      .toggle(context, widget.friendId, name),
                  child: const Text('Unblock'),
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
      // My own vote on this poll is still in flight: this broadcast may be
      // OLDER than what I just tapped (the double snap 3 → 2 → 3 → 2).
      // Hold it; my vote's response — the server's newest state — wins.
      if (mid != null && _pollVoteSeq.containsKey(mid)) return true;
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
    // A jam is always ONE vote per person, so it can name a single winner.
    if (poll['multi'] == true && poll['kind'] != 'jam') {
      next = mine.contains(option)
          ? (mine.where((e) => e != option).toList())
          : [...mine, option];
    } else {
      next = (mine.length == 1 && mine.first == option) ? [] : [option];
    }
    Haptics.selectionClick();
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
    // Only the LATEST tap's response may paint (quick re-taps / un-votes
    // otherwise land out of order and the bar jumps back and forth).
    final key = '$mid';
    final seq = (_pollVoteSeq[key] ?? 0) + 1;
    _pollVoteSeq[key] = seq;
    final res = await ApiService().votePoll(_cid, mid, next);
    final latest = _pollVoteSeq[key] == seq;
    if (latest) _pollVoteSeq.remove(key);
    if (!mounted || !latest) return;
    if (res == null) {
      setPoll(before);
      _showErrorSnack('Vote not sent — check your connection.');
    } else {
      setPoll(res);
      _saveMessagesCache();
    }
  }

  /// Host asked (group header's "… listening now" strip) to start a jam.
  void _onJamRequest() {
    if (!mounted || !_isGroup) return;
    _openPollComposer(startJam: true);
  }

  Future<void> _openPollComposer({bool startJam = false}) async {
    final scheme = Theme.of(context).colorScheme;
    final q = TextEditingController(
        text: startJam ? 'What do we play next? 🎶' : '');
    // Song titles I can offer for a jam (my loaded playlist / web queue).
    final songTitles = _jamSongTitles();
    // What the circle is playing right now ("Lorraine · Nisamehe") + mine —
    // the obvious first picks for a jam.
    final live = _jamLiveSuggestions();
    // Started as a jam → the first two songs are already filled in, so the
    // button works straight away (edit or add more if you like).
    final seeds = startJam
        ? <String>{for (final s in live) s.title, ...songTitles}
            .take(2)
            .toList()
        : const <String>[];
    final opts = [
      for (final t in seeds) TextEditingController(text: t),
      for (var i = seeds.length; i < 2; i++) TextEditingController(),
    ];
    if (seeds.length == 2) opts.add(TextEditingController());
    var multi = false;
    var jam = startJam;
    // Jam decides: 'half' (more than half vote), 'all' (everyone votes), or
    // a countdown in minutes ('1' / '2' / '5'). The starter can also start
    // a countdown later from the poll itself.
    var closeMode = 'half';
    var showWhy = false; // tapped the button before it was ready
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
        // Say what's missing instead of a silent grey button.
        final String? why = q.text.trim().isEmpty
            ? (jam ? 'Write the question for the jam' : 'Write a question')
            : clean.length < 2
                ? (jam
                    ? (clean.isEmpty
                        ? 'Add two songs to vote on'
                        : 'Add one more song to start the jam')
                    : 'Add at least two options')
                : distinct != clean.length
                    ? (jam ? 'Songs need to be different' : 'Options need to be different')
                    : null;
        void addOption(String text) {
          // Into the first empty box (or a new one), never a duplicate.
          if (clean.map((e) => e.toLowerCase()).contains(text.toLowerCase())) {
            return;
          }
          final empty = opts.where((c) => c.text.trim().isEmpty);
          if (empty.isNotEmpty) {
            empty.first.text = text;
          } else if (opts.length < 12) {
            opts.add(TextEditingController(text: text));
          }
          if (opts.last.text.trim().isNotEmpty && opts.length < 12) {
            opts.add(TextEditingController());
          }
        }
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
                        color: accentInk(scheme)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(jam ? 'Group jam' : 'New poll',
                          style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: scheme.onSurface)),
                    ),
                    // A jam: fill the options from my songs.
                    if (songTitles.isNotEmpty || jam)
                      TextButton.icon(
                        onPressed: () async {
                          if (songTitles.isEmpty) {
                            showToast(context,
                                'Load some songs in your player to pick from — or type a song name',
                                type: ToastType.info);
                            return;
                          }
                          final picked = await _pickJamSongs(
                              ctx, songTitles,
                              initial: opts
                                  .map((c) => c.text.trim())
                                  .where((t) => t.isNotEmpty)
                                  .toList());
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
                  // Playing right now in the circle → one tap adds it.
                  if (jam && live.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final s in live)
                          ActionChip(
                            avatar: const Icon(Icons.headphones_rounded,
                                size: 16),
                            label: Text('${s.who} · ${s.title}',
                                overflow: TextOverflow.ellipsis),
                            onPressed: () => setS(() => addOption(s.title)),
                          ),
                      ],
                    ),
                  ],
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
                        decoration: deco(
                                jam ? 'Song ${i + 1}' : 'Option ${i + 1}',
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
                  // A jam is one vote each; instead it can race a clock.
                  if (!jam)
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: multi,
                      onChanged: (v) => setS(() => multi = v),
                      title: const Text('Allow several answers'),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 6),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text('Decide',
                              style: TextStyle(
                                  fontSize: 13,
                                  color: scheme.onSurfaceVariant)),
                          for (final m in const [
                            ('half', 'when half vote'),
                            ('all', 'when everyone votes'),
                            ('1', 'in 1 min'),
                            ('2', 'in 2 min'),
                            ('5', 'in 5 min'),
                          ])
                            ChoiceChip(
                              label: Text(m.$2),
                              selected: closeMode == m.$1,
                              onSelected: (_) => setS(() => closeMode = m.$1),
                            ),
                        ],
                      ),
                    ),
                  // What's still needed — always shown once tapped, and the
                  // "different" clash as soon as it happens.
                  if (why != null &&
                      (showWhy || distinct != clean.length))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(children: [
                        Icon(Icons.info_outline_rounded,
                            size: 15, color: scheme.error),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(why,
                              style: TextStyle(
                                  color: scheme.error, fontSize: 12.5)),
                        ),
                      ]),
                    ),
                  const SizedBox(height: 4),
                  FilledButton.icon(
                    // Never a dead end: not ready yet → it says why.
                    onPressed: () {
                      if (!ok) {
                        Haptics.lightImpact();
                        setS(() => showWhy = true);
                        return;
                      }
                      Navigator.pop(ctx, {
                        'q': q.text.trim(),
                        'options': clean,
                        'multi': jam ? false : multi,
                        if (jam) 'kind': 'jam',
                        if (jam && closeMode == 'all') 'until': 'all',
                        if (jam && int.tryParse(closeMode) != null)
                          'closes_at':
                              DateTime.now().millisecondsSinceEpoch ~/ 1000 +
                                  int.parse(closeMode) * 60,
                      });
                    },
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

  /// Songs the group is playing right now (members who share their listening
  /// with me), then mine — "who · title", de-duplicated by title.
  List<({String who, String title})> _jamLiveSuggestions() {
    final out = <({String who, String title})>[];
    final seen = <String>{};
    void add(String who, String title) {
      final t = title.trim();
      if (t.isEmpty || t == 'Aluta' || !seen.add(t.toLowerCase())) return;
      out.add((who: who, title: t));
    }

    for (final m in _groupMembers) {
      final id = int.tryParse((m['user_id'] ?? m['id'] ?? '').toString());
      if (id == null || id.toString() == _myId) continue;
      final np = NowPlayingPresence.instance.trackFor(id);
      if (np == null) continue;
      add(_memberName(m).split(' ').first, (np['title'] ?? '').toString());
    }
    add('You', _nowPlayingTitle());
    return out.take(6).toList();
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

  /// The jam song picker: a search pill, each song as a soft card with its
  /// own colour disc (title + artist split out), tap to pick — picks get a
  /// numbered badge in the order chosen — and a sticky "Add N songs" button
  /// that says what's missing instead of greying out. [initial] = songs
  /// already in the jam (pre-picked).
  Future<List<String>?> _pickJamSongs(BuildContext ctx, List<String> titles,
      {List<String> initial = const []}) async {
    final scheme = Theme.of(ctx).colorScheme;
    final isDark = Theme.of(ctx).brightness == Brightness.dark;
    final chosen = <String>[
      for (final t in initial)
        if (titles.contains(t)) t,
    ];
    var query = '';
    var nudge = false;

    // File-name titles → (title, artist). "Artist - Title" (spaced dash) is
    // the common tag style; "Title-Artist" (tight dash, e.g. "Chagua
    // Moja-Fid Q") is the other. A side carrying ft / feat / x / & / a comma
    // is the artist either way.
    ({String title, String artist}) split(String raw) {
      final spaced = RegExp(r'^(.+?)\s+[-–—]\s+(.+)$').firstMatch(raw);
      final tight = spaced ?? RegExp(r'^(.+?)\s*[-–—]\s*(.+)$').firstMatch(raw);
      if (tight == null) return (title: raw, artist: '');
      final a = tight.group(1)!.trim(), b = tight.group(2)!.trim();
      final feat = RegExp(r'(\bft\.?\b|\bfeat\.?\b|\s[x&]\s|,)', caseSensitive: false);
      final aIsArtist = feat.hasMatch(a) && !feat.hasMatch(b);
      final bIsArtist = feat.hasMatch(b) && !feat.hasMatch(a);
      if (aIsArtist) return (title: b, artist: a);
      if (bIsArtist) return (title: a, artist: b);
      return spaced != null ? (title: b, artist: a) : (title: a, artist: b);
    }

    Color discColor(String t) {
      final h = t.toLowerCase().codeUnits.fold<int>(7, (a, c) => (a * 31 + c) & 0x7fffffff);
      return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.55, isDark ? 0.42 : 0.55)
          .toColor();
    }

    return showModalBottomSheet<List<String>>(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (c) => StatefulBuilder(builder: (c, setC) {
        final q = query.trim().toLowerCase();
        final shown = q.isEmpty
            ? titles
            : titles.where((t) => t.toLowerCase().contains(q)).toList();
        final n = chosen.length;
        final ready = n >= 2;
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
          child: SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(c).height * 0.82),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(height: 8),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: scheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2)),
                ),
                // Header: the jam disc + title + live count.
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
                  child: Row(children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(colors: [
                          scheme.primary,
                          Color.lerp(scheme.primary, Colors.white, 0.3)!,
                        ]),
                        boxShadow: [
                          BoxShadow(
                              color: scheme.primary.withValues(alpha: 0.35),
                              blurRadius: 12,
                              offset: const Offset(0, 4)),
                        ],
                      ),
                      child: const Icon(Icons.queue_music_rounded,
                          color: Colors.white, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Pick the jam songs',
                              style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                  color: scheme.onSurface)),
                          const SizedBox(height: 2),
                          AnimatedSwitcher(
                            duration: Motion.quick,
                            child: Text(
                              n == 0
                                  ? 'Choose 2 to 12 — the group votes'
                                  : '$n picked · ${n < 2 ? 'one more to go' : 'tap more or add'}',
                              key: ValueKey(n),
                              style: TextStyle(
                                  fontSize: 12.5,
                                  color: n >= 2
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (n > 0)
                      TextButton(
                        onPressed: () => setC(chosen.clear),
                        child: const Text('Clear'),
                      ),
                  ]),
                ),
                // Search pill (only worth it on a longer list).
                if (titles.length > 6)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: TextField(
                      onChanged: (v) => setC(() => query = v),
                      decoration: InputDecoration(
                        // Pill, like every search box (theme borders are 12 px boxes).
                        border: pillSearchBorder(scheme),
                        enabledBorder: pillSearchBorder(scheme),
                        focusedBorder: pillSearchBorder(scheme, focused: true),
                        // One compact height for every search pill (38 px, like Circle's).
                        isDense: true,
                        constraints: const BoxConstraints(minHeight: 38, maxHeight: 38),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 38, maxHeight: 38),
                        suffixIconConstraints: const BoxConstraints(minWidth: 38, minHeight: 38, maxHeight: 38),
                        hintText: 'Search your songs',
                        prefixIcon: const Icon(Icons.search_rounded, size: 20),
                        filled: true,
                        fillColor: scheme.surfaceContainerHighest
                            .withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                Flexible(
                  child: shown.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(28),
                          child: Text('No song matches “$query”',
                              style:
                                  TextStyle(color: scheme.onSurfaceVariant)),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
                          itemCount: shown.length,
                          itemBuilder: (_, i) {
                            final t = shown[i];
                            final pos = chosen.indexOf(t);
                            final on = pos >= 0;
                            final parts = split(t);
                            final disc = discColor(t);
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(16),
                                  onTap: () => setC(() {
                                    nudge = false;
                                    if (on) {
                                      chosen.remove(t);
                                    } else if (chosen.length < 12) {
                                      chosen.add(t);
                                      Haptics.selectionClick();
                                    }
                                  }),
                                  child: AnimatedContainer(
                                    duration: Motion.quick,
                                    padding: const EdgeInsets.fromLTRB(
                                        10, 9, 12, 9),
                                    decoration: BoxDecoration(
                                      color: on
                                          ? scheme.primary.withValues(
                                              alpha: isDark ? 0.18 : 0.08)
                                          : scheme.surfaceContainerHighest
                                              .withValues(alpha: 0.35),
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(
                                        color: on
                                            ? scheme.primary
                                                .withValues(alpha: 0.65)
                                            : Colors.transparent,
                                        width: 1.4,
                                      ),
                                    ),
                                    child: Row(children: [
                                      // A little vinyl in the song's colour.
                                      Container(
                                        width: 38,
                                        height: 38,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          gradient: RadialGradient(colors: [
                                            Colors.white
                                                .withValues(alpha: 0.9),
                                            disc,
                                            Color.lerp(
                                                disc, Colors.black, 0.35)!,
                                          ], stops: const [0.12, 0.2, 1]),
                                        ),
                                        child: Icon(Icons.music_note_rounded,
                                            size: 16,
                                            color: Colors.white
                                                .withValues(alpha: 0.9)),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(parts.title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    fontSize: 14.5,
                                                    fontWeight: on
                                                        ? FontWeight.w700
                                                        : FontWeight.w600,
                                                    color: scheme.onSurface)),
                                            if (parts.artist.isNotEmpty)
                                              Text(parts.artist,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                      fontSize: 12,
                                                      color: scheme
                                                          .onSurfaceVariant)),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      // Pick order badge / empty ring.
                                      AnimatedScale(
                                        scale: on ? 1 : 0.9,
                                        duration:
                                            Motion.quick,
                                        curve: Curves.easeOutBack,
                                        child: Container(
                                          width: 26,
                                          height: 26,
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: on
                                                ? scheme.primary
                                                : Colors.transparent,
                                            border: Border.all(
                                                color: on
                                                    ? scheme.primary
                                                    : scheme.outlineVariant,
                                                width: 1.6),
                                          ),
                                          child: on
                                              ? Text('${pos + 1}',
                                                  style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 12,
                                                      fontWeight:
                                                          FontWeight.w800))
                                              : null,
                                        ),
                                      ),
                                    ]),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
                // Sticky action: always tappable, says what's missing.
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (nudge && !ready)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                            n == 0
                                ? 'Pick at least two songs'
                                : 'Pick one more song',
                            style: TextStyle(
                                color: scheme.error, fontSize: 12.5)),
                      ),
                    FilledButton.icon(
                      onPressed: () {
                        if (!ready) {
                          Haptics.lightImpact();
                          setC(() => nudge = true);
                          return;
                        }
                        Navigator.pop(c, List<String>.of(chosen));
                      },
                      icon: const Icon(Icons.playlist_add_check_rounded,
                          size: 20),
                      label: Text(ready
                          ? 'Add $n songs to the jam'
                          : n == 1
                              ? 'Pick one more'
                              : 'Pick 2 songs'),
                      style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                          backgroundColor: ready
                              ? scheme.primary
                              : scheme.primary.withValues(alpha: 0.45),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16))),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        );
      }),
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
    final isJamPoll = poll['kind'] == 'jam';
    final multi = poll['multi'] == true && !isJamPoll;
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
    final isJam = isJamPoll;
    // Jam: ONE winner — the first song (in order) holding the top count.
    final winner = top > 0 ? counts.indexOf(top) : -1;
    // Jam game state: countdown, majority race, ties.
    final closesAt = (poll['closes_at'] as num?)?.toInt();
    final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final jamClosed = isJam && closesAt != null && nowS >= closesAt;
    final members = _groupMembers.isNotEmpty
        ? _groupMembers.length
        : (widget.memberCount > 0 ? widget.memberCount : 0);
    final waitAll = poll['until'] == 'all';
    final need = members <= 0
        ? 1
        : (waitAll ? members : members ~/ 2 + 1);
    final decided = isJam && top > 0 && (voters >= need || jamClosed);
    final tied = isJam && top > 0 && counts.where((c) => c == top).length > 1;
    final sorted = [...counts]..sort((a, b) => b.compareTo(a));
    final score = sorted.length > 1 ? '${sorted[0]}–${sorted[1]}' : '$top–0';
    if (isJam) _jamCelebrate(msg['id'].toString(), decided);
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
                leading: isJam ? i == winner : (top > 0 && counts[i] == top),
                multi: multi,
                jam: isJam,
                textColor: textColor,
                accent: accent,
                onTap: (pending || jamClosed) ? null : () => _votePoll(msg, i),
              ),
            ),
          if (isJam)
            _jamRace(voters, need, closesAt, jamClosed, decided, textColor,
                accent,
                waitAll: waitAll,
                // The starter can kick off a clock any time before it's
                // decided (e.g. the rest of the group is offline).
                onStartClock: (isMe && !decided && closesAt == null)
                    ? () => _jamStartClock(msg)
                    : null)
          else
            Text(
              voters == 0
                  ? 'No votes yet · tap to vote'
                  : '$voters vote${voters == 1 ? '' : 's'}'
                      '${mine.isEmpty ? ' · tap to vote' : ''}',
              style: TextStyle(
                  fontSize: 11, color: textColor.withValues(alpha: 0.6)),
            ),
          if (isJam && winner >= 0 && !pending && decided)
            // Rebuilds when a jam room opens / closes in the group.
            ListenableBuilder(
              listenable: LiveRoomsRegistry.instance,
              builder: (_, _) => _jamAction(msg, options, winner,
                  counts[winner], textColor, accent,
                  tied: tied && poll['decider'] != true,
                  tiedSongs: [
                    for (var i = 0; i < options.length; i++)
                      if (counts[i] == top) options[i],
                  ],
                  score: score),
            ),
        ],
      ),
    );
  }

  // ── Group Jam → actually play the winner ──────────────────────────────────
  // The vote names the next song; the GROUP Listen Together room plays it.
  // Host of the room live here → "▶ Play the winner" (queued right after the
  // current song for everyone) + a fresh vote on the songs left. No room yet
  // and I have the song → "🎧 Start the jam room" with the winner. Otherwise
  // a hint that whoever hosts plays it. Songs come from the HOST's device.

  /// Jam message id → what already happened to it (queued / decider…).
  static final Map<String, String> _jamDone = <String, String>{};
  static final Map<String, String> _jamScore = <String, String>{};
  // Jams I've seen undecided this session (so a crossing celebrates once).
  static final Set<String> _jamSeenOpen = <String>{};
  static final Set<String> _jamCheered = <String>{};

  /// 🎉 when a jam crosses the line while I'm watching (not on reopen).
  void _jamCelebrate(String mid, bool decided) {
    if (!decided) {
      _jamSeenOpen.add(mid);
      return;
    }
    if (_jamSeenOpen.contains(mid) && _jamCheered.add(mid)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Haptics.mediumImpact();
        HeartBurst.react(context, '🎉');
      });
    }
  }

  /// The race to a decision: a bar filling toward "more than half", and the
  /// countdown when the jam has one.
  /// The jam's starter picks a countdown (from now) — server-checked.
  Future<void> _jamStartClock(Map<String, dynamic> msg) async {
    final mid = int.tryParse(msg['id'].toString());
    if (mid == null) return;
    final minutes = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Close the vote in…',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
          for (final m in const [1, 2, 5, 10])
            ListTile(
              leading: const Icon(Icons.timer_rounded),
              title: Text('$m minute${m == 1 ? '' : 's'}'),
              onTap: () => Navigator.pop(ctx, m),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (minutes == null || !mounted) return;
    final res = await ApiService().startPollCountdown(_cid, mid, minutes);
    if (!mounted) return;
    if (res == null) {
      _showErrorSnack('Couldn’t start the countdown — try again.');
      return;
    }
    final i = _messages.indexWhere((m) => m['id'].toString() == '$mid');
    if (i != -1) {
      rebuildWith(() {
        _messages[i] = Map<String, dynamic>.from(_messages[i])..['poll'] = res;
      });
      _saveMessagesCache();
    }
  }

  Widget _jamRace(int voters, int need, int? closesAt, bool closed,
      bool decided, Color textColor, Color accent,
      {bool waitAll = false, VoidCallback? onStartClock}) {
    Widget build() {
      final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final left = closesAt == null ? null : (closesAt - nowS);
      final frac = (voters / need).clamp(0.0, 1.0);
      String label;
      if (decided) {
        label = closed && voters < need
            ? '⏱ Time’s up · $voters vote${voters == 1 ? '' : 's'}'
            : '🏁 Decided · $voters vote${voters == 1 ? '' : 's'}';
      } else if (closed) {
        label = '⏱ Time’s up · no votes — nothing plays';
      } else {
        final l = left == null ? null : (left < 0 ? 0 : left);
        final mm = l == null
            ? ''
            : ' · ⏳ ${l ~/ 60}:${(l % 60).toString().padLeft(2, '0')}';
        label = waitAll && left == null
            ? '$voters of $need · waiting for everyone'
            : '$voters of $need votes to decide$mm';
      }
      return Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: decided ? 1.0 : frac),
                duration: Motion.slow,
                curve: Curves.easeOutCubic,
                builder: (_, v, _) => LinearProgressIndicator(
                  value: v,
                  minHeight: 5,
                  color: accent,
                  backgroundColor: textColor.withValues(alpha: 0.12),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(children: [
              Expanded(
                child: Text(label,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight:
                            decided ? FontWeight.w700 : FontWeight.w500,
                        color: decided
                            ? accent
                            : textColor.withValues(alpha: 0.65))),
              ),
              if (onStartClock != null)
                TextButton.icon(
                  onPressed: onStartClock,
                  icon: Icon(Icons.timer_rounded, size: 15, color: accent),
                  label: Text('Start countdown',
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: accent)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(0, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
            ]),
          ],
        ),
      );
    }

    if (closesAt == null || closed) return build();
    // Tick the countdown each second; rebuild the whole poll when it ends.
    return StreamBuilder<int>(
      stream: Stream<int>.periodic(const Duration(seconds: 1), (i) => i),
      builder: (_, _) {
        final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        if (nowS >= closesAt) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) rebuildWith(() {});
          });
        }
        return build();
      },
    );
  }

  /// True when a "🏆 “title” won…" line was posted AFTER this jam poll — the
  /// winner was played by someone, so nobody else should play it again.
  bool _jamWinnerPosted(Map<String, dynamic> poll, String title) {
    final pAt = DateTime.tryParse((poll['timestamp'] ?? '').toString());
    final head = '🏆 “$title”';
    for (final m in _messages) {
      final c = (m['content'] ?? '').toString();
      if (!c.startsWith(head)) continue;
      final at = DateTime.tryParse((m['timestamp'] ?? '').toString());
      if (pAt == null || at == null || !at.isBefore(pAt)) return true;
    }
    return false;
  }

  /// 🏆 the result line in the group when a winner starts playing (its
  /// sender is the jam's DJ for that round).
  void _postJamResult(String mid, String title) {
    final score = _jamScore[mid] ?? '';
    unawaited(_sendStructured(
        'text',
        '🏆 “$title” won${score.isEmpty ? '' : ' $score'}'
        ' — now playing for the group 🎶'));
  }

  /// The other songs of a decider's original jam (carried on afterwards).
  List<String> _jamRestOf(Map<String, dynamic> msg) =>
      ((_pollOf(msg)?['rest'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList();

  /// This week's jam DJ: the member whose phone played the most jam winners
  /// (🏆 lines) in the last 7 days — null when none.
  String? _jamDjId() {
    // Keyed by chat AND length: the cache is static, so another group with
    // the same message count must not get this group's DJ.
    final cacheKey = '${_isGroup ? _cid : -1}:${_messages.length}';
    if (_jamDjCacheKey == cacheKey) return _jamDjCache;
    _jamDjCacheKey = cacheKey;
    final now = DateTime.now();
    final since = now.subtract(const Duration(days: 7));
    final midnight = DateTime(now.year, now.month, now.day);
    final wins = <String, int>{};
    final today = <String, int>{};
    for (final m in _messages) {
      final c = (m['content'] ?? '').toString();
      if (!c.startsWith('🏆 “')) continue;
      final ts = DateTime.tryParse((m['timestamp'] ?? '').toString())
          ?.toLocal();
      if (ts != null && ts.isBefore(since)) continue;
      final id = m['sender_id']?.toString();
      if (id == null) continue;
      wins[id] = (wins[id] ?? 0) + 1;
      if (ts != null && !ts.isBefore(midnight)) {
        today[id] = (today[id] ?? 0) + 1;
      }
    }
    String? top(Map<String, int> t) {
      String? best;
      var n = 0;
      t.forEach((id, c) {
        if (c > n) {
          n = c;
          best = id;
        }
      });
      return best;
    }

    final best = top(wins);
    final bestToday = top(today);
    // Remember it for the group's row in the Circle list ("👑 Lorraine").
    if (_isGroup) {
      String? djName;
      for (final m in _groupMembers) {
        if (m['user_id']?.toString() == best) {
          djName = _memberName(m);
          break;
        }
      }
      if (best == _myId) djName = 'You';
      final cid = _cid;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        GroupMeta.instance.setDj(cid, djName);
        // By id too, for Group info's crowns (week + today).
        GroupMeta.instance.setDjIds(cid,
            week: int.tryParse(best ?? ''), day: int.tryParse(bestToday ?? ''));
      });
    }
    return _jamDjCache = best;
  }

  static String? _jamDjCacheKey;
  static String? _jamDjCache;

  Widget _djTag(ColorScheme scheme, {Color? on}) {
    final c = on == null ? scheme.primary : bubbleTintOn(scheme.primary, on);
    return Tooltip(
      message: 'Jam DJ of the week — most winners played',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.withValues(alpha: 0.45)),
        ),
        child: Text('👑 DJ',
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w800, color: c)),
      ),
    );
  }

  /// The local file for a jam song title (matched against my loaded songs).
  String? _jamPathFor(String title) {
    // Jam titles come from file names OR from what members are playing
    // ("African Vibe" while the file is "African Vibe - DHDMusic.mp3"), so
    // compare loosely: letters/digits only; exact first, then "file name
    // starts with / contains the title" (long-enough titles only).
    String norm(String s) =>
        s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    final want = norm(title);
    if (want.isEmpty) return null;
    String? starts, contains;
    try {
      for (final p in playlistNotifier.value) {
        var name = p.split(RegExp(r'[\\/]')).last;
        name = name.replaceAll(RegExp(r'\.[A-Za-z0-9]{2,4}$'), '');
        final n = norm(name);
        if (n == want) return p;
        if (want.length >= 4) {
          if (n.startsWith(want)) starts ??= p;
          if (n.contains(want)) contains ??= p;
        }
      }
    } catch (_) {}
    return starts ?? contains;
  }

  Widget _jamAction(Map<String, dynamic> msg, List<String> options, int winner,
      int votes, Color textColor, Color accent,
      {bool tied = false,
      List<String> tiedSongs = const [],
      String score = ''}) {
    final mid = msg['id'].toString();
    // Shown only once the group has DECIDED (more than half voted, or the
    // countdown ran out): then "Play the winner" appears on its own for
    // whoever has the song on their phone.
    final title = options[winner];
    final s = activeLiveSession;
    final hostingHere =
        s != null && s.isHost && s.controller.conversationId == _cid;
    final listeningHere = s != null && !s.isHost;
    final path = kIsWeb ? null : _jamPathFor(title);
    Widget note(String t) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(t,
              style: TextStyle(
                  fontSize: 11.5,
                  fontStyle: FontStyle.italic,
                  color: textColor.withValues(alpha: 0.7))),
        );
    // Someone (anyone in the group, me included) already played this jam's
    // winner — the 🏆 line is in the chat after the poll → a settled
    // "played" (not a stale "playing in the room" after the room ended).
    if (_jamWinnerPosted(msg, title)) {
      return note('Played for the group — chosen by $votes 🎶');
    }
    if (_jamDone.containsKey(mid)) return note(_jamDone[mid]!);
    // A jam left for a day is over; nothing to act on any more.
    final at = DateTime.tryParse((msg['timestamp'] ?? '').toString());
    if (at != null &&
        DateTime.now().difference(at.toLocal()) > const Duration(hours: 24)) {
      return note('This jam has ended');
    }
    // A dead heat → sudden death: a 30-second decider between the tied songs.
    if (tied) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: FilledButton.icon(
          onPressed: () {
            rebuildWith(() => _jamDone[mid] = 'Tie! A 30-second decider is on ⚡');
            _sendPoll({
              'q': '⚡ Decider: ${tiedSongs.join(' vs ')}',
              'options': tiedSongs,
              'multi': false,
              'kind': 'jam',
              'decider': true,
              // The rest of this jam's songs come back after the decider.
              'rest': [
                for (final o in options)
                  if (!tiedSongs.contains(o)) o,
                for (final r in _jamRestOf(msg))
                  if (!tiedSongs.contains(r)) r,
              ],
              'closes_at':
                  DateTime.now().millisecondsSinceEpoch ~/ 1000 + 30,
            });
          },
          icon: const Icon(Icons.bolt_rounded, size: 18),
          label: const Text('It’s a tie — 30-second decider'),
          style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: onAccent(accent),
              minimumSize: const Size.fromHeight(38),
              shape: const StadiumBorder()),
        ),
      );
    }
    _jamScore[mid] = score;
    if (hostingHere) {
      if (path == null) {
        return note(s.controller.allowContributions
            ? '“$title” isn’t on your phone — a member who has it can send it in.'
            : '“$title” isn’t in your loaded songs — load it to play.');
      }
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: FilledButton.icon(
          onPressed: () => _jamPlayWinner(msg, options, winner, path),
          icon: const Icon(Icons.play_arrow_rounded, size: 18),
          label: const Text('Play the winner'),
          style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: onAccent(accent),
              minimumSize: const Size.fromHeight(38),
              shape: const StadiumBorder()),
        ),
      );
    }
    if (listeningHere) {
      // I'm in THIS group's jam room and the winner is on MY phone → send
      // it to the host, straight in after the current song.
      final inThisRoom = s.controller.conversationId == _cid;
      if (inThisRoom && path != null && s.controller.remoteContribAllowed) {
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: OutlinedButton.icon(
            onPressed: () => _jamSendWinner(msg, title, path),
            icon: const Icon(Icons.upload_rounded, size: 18),
            label: const Text('Send the winner to the room'),
            style: OutlinedButton.styleFrom(
                foregroundColor: accent,
                side: BorderSide(color: accent.withValues(alpha: 0.6)),
                minimumSize: const Size.fromHeight(38),
                shape: const StadiumBorder()),
          ),
        );
      }
      return note('The host plays the winner next 🎧');
    }
    // A member's jam room is live here → join it (they play the winner).
    final live = LiveRoomsRegistry.instance.roomForConversation(_cid);
    final join = LiveRoomsRegistry.instance.joinRoom;
    if (s == null && live != null && join != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: OutlinedButton.icon(
          onPressed: () => join(live),
          icon: const Icon(Icons.headphones_rounded, size: 18),
          label: const Text('Join the jam room'),
          style: OutlinedButton.styleFrom(
              foregroundColor: accent,
              side: BorderSide(color: accent.withValues(alpha: 0.6)),
              minimumSize: const Size.fromHeight(38),
              shape: const StadiumBorder()),
        ),
      );
    }
    if (s == null && path != null) {
      // The song is on MY phone and the group has decided → play it: this
      // opens the group's jam room starting with the winner.
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: FilledButton.icon(
          onPressed: () => _jamStartRoom(msg, title, path),
          icon: const Icon(Icons.play_arrow_rounded, size: 18),
          label: const Text('Play the winner'),
          style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: onAccent(accent),
              minimumSize: const Size.fromHeight(38),
              shape: const StadiumBorder()),
        ),
      );
    }
    return note('The group chose “$title” — whoever has it on their phone '
        'can play it 🎧');
  }

  Future<void> _jamPlayWinner(Map<String, dynamic> msg, List<String> options,
      int winner, String path) async {
    final s = activeLiveSession;
    if (s == null) return;
    try {
      final bytes = Uint8List.fromList(await readFileBytes(path));
      if (bytes.isEmpty) throw StateError('empty');
      s.controller.watchJam(options[winner]); // count its reactions
      await s.controller.playNext(LiveTrack(bytes: bytes, title: options[winner]));
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not read that song.', type: ToastType.error);
      }
      return;
    }
    if (!mounted) return;
    final mid = msg['id'].toString();
    rebuildWith(() => _jamDone[mid] = 'Queued for the group 🎶');
    showToast(context, '“${options[winner]}” is up next for everyone 🎶',
        type: ToastType.success);
    _postJamResult(mid, options[winner]);
    _jamRollOn(options, winner, rest: _jamRestOf(msg));
  }

  /// Listener in the group's jam room: upload the winner from my phone to
  /// the host — it plays right after the current song.
  Future<void> _jamSendWinner(
      Map<String, dynamic> msg, String title, String path) async {
    final s = activeLiveSession;
    if (s == null) return;
    Uint8List bytes;
    try {
      bytes = Uint8List.fromList(await readFileBytes(path));
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not read that song.', type: ToastType.error);
      }
      return;
    }
    final ok = await s.controller.contributeTrack(bytes, title,
        by: _myName.isEmpty ? null : _myName, next: true);
    if (!mounted) return;
    if (ok) {
      final mid = msg['id'].toString();
      rebuildWith(() => _jamDone[mid] = 'Sent to the room — plays next 🎶');
      _postJamResult(mid, title);
      // The jam rolls on from whoever played the winner, room host or not.
      final opts = ((_pollOf(msg)?['options'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList();
      final w = opts.indexOf(title);
      if (w >= 0) _jamRollOn(opts, w, rest: _jamRestOf(msg));
      showToast(context, 'Sent — “$title” plays next for everyone 🎶',
          type: ToastType.success);
    } else {
      showToast(context, 'Couldn’t send it — the host may have songs off.',
          type: ToastType.error);
    }
  }

  Future<void> _jamStartRoom(
      Map<String, dynamic> msg, String title, String path) async {
    final token = await getToken();
    final myUserId = int.tryParse(_myId ?? '');
    if (token == null || myUserId == null || !mounted) return;
    Uint8List bytes;
    try {
      bytes = Uint8List.fromList(await readFileBytes(path));
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not read that song.', type: ToastType.error);
      }
      return;
    }
    if (bytes.isEmpty || !mounted) return;
    playbackBus.onPause?.call();
    final mid = msg['id'].toString();
    rebuildWith(() => _jamDone[mid] = 'Opening the jam room 🎶');
    // The room counts this winner's reactions for the group.
    LiveSessionController.pendingJamTitle = title;
    // Only once the room is REALLY live: the 🏆 line + the next vote.
    final poll0 = _pollOf(msg);
    final opts0 = ((poll0?['options'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
    final rest0 = _jamRestOf(msg);
    LiveSessionController.pendingJamOnLive = () {
      if (!mounted) return;
      rebuildWith(() => _jamDone[mid] = 'Playing in the jam room 🎶');
      _postJamResult(mid, title);
      final w = opts0.indexOf(title);
      if (w >= 0) _jamRollOn(opts0, w, rest: rest0);
    };
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => LiveSessionScreen.roomHost(
        token: token,
        myUserId: myUserId,
        audioBytes: bytes,
        title: title,
        conversationId: widget.conversationId,
        groupName: widget.groupTitle.isEmpty ? 'the group' : widget.groupTitle,
      ),
    ));
  }

  /// Rolling jam: the moment a winner is queued, a fresh vote goes up with
  /// the songs that are left (when there are still two or more).
  void _jamRollOn(List<String> options, int winner,
      {List<String> rest = const []}) {
    // After a decider, the songs of the ORIGINAL jam that weren't in the tie
    // ([rest]) come back too — the jam carries on, not just the loser.
    final left = <String>[];
    for (var i = 0; i < options.length; i++) {
      if (i != winner && !left.contains(options[i])) left.add(options[i]);
    }
    for (final r in rest) {
      if (r != options[winner] && !left.contains(r)) left.add(r);
    }
    if (left.length < 2) return;
    _sendPoll({
      'q': 'After “${options[winner]}”, what next? 🎶',
      'options': left,
      'multi': false,
      'kind': 'jam',
    });
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
                      duration: Motion.slow,
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
                        duration: Motion.quick,
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
