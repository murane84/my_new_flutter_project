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
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: multi,
                    onChanged: (v) => setS(() => multi = v),
                    title: const Text('Allow several answers'),
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
                        HapticFeedback.lightImpact();
                        setS(() => showWhy = true);
                        return;
                      }
                      Navigator.pop(ctx, {
                        'q': q.text.trim(),
                        'options': clean,
                        'multi': multi,
                        if (jam) 'kind': 'jam',
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
                            duration: const Duration(milliseconds: 180),
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
                        isDense: true,
                        hintText: 'Search your songs',
                        prefixIcon: const Icon(Icons.search_rounded, size: 20),
                        filled: true,
                        fillColor: scheme.surfaceContainerHighest
                            .withValues(alpha: 0.6),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none),
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
                                      HapticFeedback.selectionClick();
                                    }
                                  }),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 170),
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
                                            const Duration(milliseconds: 160),
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
                          HapticFeedback.lightImpact();
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
