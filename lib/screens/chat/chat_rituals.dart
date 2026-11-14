part of '../chat_page.dart';

// ── Rituals & memories (bonded DMs) ─────────────────────────────────────────
//  • Good night: after 9 PM, a soft chip above the composer turns the next
//    message into a sealed heart that opens at 7 AM their morning.
//  • On this day: when the thread holds a message from this date in an
//    earlier year, a small "1 year ago today" chip jumps to it.
// Local only; shown once per day per chat (dismissable).

extension _ChatRituals on _ChatPageState {
  bool get _bondedDm => !_isGroup && _defaultKeepSpaceId != null;

  String get _todayKey {
    final d = DateTime.now();
    return '${d.year}-${d.month}-${d.day}';
  }

  /// "Night of": until 2 AM it's still last night (good-night chip).
  String get _nightKey {
    final d = DateTime.now().subtract(const Duration(hours: 2));
    return '${d.year}-${d.month}-${d.day}';
  }

  /// Server times are UTC (often without a zone marker) → local.
  DateTime? _ts(Object? raw) {
    final s = (raw ?? '').toString();
    return s.isEmpty ? null : parseServerTime(s);
  }

  Future<void> _loadRitualFlags() async {
    try {
      final p = await SharedPreferences.getInstance();
      final k = _todayKey;
      _gnDoneToday = p.getString('gn_done_${widget.friendId}') == _nightKey;
      _memoryDoneToday = p.getString('otd_done_$_activeConvKey') == k;
      // Our anniversary (month-day saved from the heart composer's picker).
      final md = p.getString('heart_anniv_${widget.friendId}');
      final now = DateTime.now();
      _annivToday = md == '${now.month}-${now.day}' &&
          p.getString('anniv_done_${widget.friendId}') != k;
      if (mounted) rebuildWith(() {});
      _ritualsFlagsLoaded = true;
      _bondRituals();
    } catch (_) {}
  }

  /// Bond-only extras — run once both the flags and my Spaces are known
  /// (called from _loadRitualFlags AND _loadMySpaces, whichever lands last).
  Future<void> _bondRituals() async {
    if (!mounted || !_ritualsFlagsLoaded || !_bondedDm || _bondRitualsRan) {
      return;
    }
    _bondRitualsRan = true;
    final convAtStart = _activeConvKey;
    // Reach further back once a day so "on this day" can find last year.
    if (!_memoryDoneToday) {
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted && _activeConvKey == convAtStart) _searchDeepLoad();
      });
    }
    // Bonded: say "I'm here" now (Here together) and show any planned day.
    _bondHereTick();
    // The "In tune" streak with this partner (keep-it-alive chip).
    final sid = _defaultKeepSpaceId;
    if (sid == null) return;
    final st = await ApiService().getStreak(sid);
    if (!mounted || st == null || _activeConvKey != convAtStart) return;
    rebuildWith(() {
      _streakDays = (st['current_days'] as num?)?.toInt() ?? 0;
      _streakAlive = st['alive'] == true;
    });
  }

  /// A music nudge asked to pre-fill this chat (text, maybe as a heart).
  void _consumeCompose() {
    final r = chatComposeRequest.value;
    if (r == null || !mounted || _isGroup) return;
    if ((r['friendId'] as int?) != widget.friendId) return;
    chatComposeRequest.value = null;
    final text = (r['text'] ?? '').toString();
    rebuildWith(() {
      if (r['heart'] == true) {
        _heartMode = true;
        _heartMood = (r['mood'] ?? 'love').toString();
        _heartUnlockAt = null;
      }
      if (text.isNotEmpty) {
        // Never wipe what they'd already written — add to it.
        final cur = _ctrl.text.trim();
        // Already there (a repeated tap) → don't paste it twice.
        final t = cur.isEmpty
            ? text
            : (cur.contains(text) ? cur : '$cur $text');
        _ctrl.value = TextEditingValue(
            text: t, selection: TextSelection.collapsed(offset: t.length));
      }
    });
    _composerFocus.requestFocus();
  }

  /// A different chat opened in this same page → forget the last one's.
  void _resetRituals() {
    _gnDoneToday = _memoryDoneToday = _annivToday = false;
    _streakAlive = _streakNudged = false;
    _streakDays = 0;
    _recordSong = null;
    _ritualsFlagsLoaded = false;
    _bondRitualsRan = false;
  }

  Future<void> _markRitual(String key) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(key, key.startsWith('gn_') ? _nightKey : _todayKey);
    } catch (_) {}
  }

  bool get _showGoodNight {
    if (!_bondedDm || _gnDoneToday || _heartMode || _isRecording) return false;
    if (_editing != null || _ctrl.text.trim().isNotEmpty) return false;
    final h = DateTime.now().hour;
    return h >= 21 || h < 2;
  }

  /// Their next wake-up: their usual time when Aluta knows it, else 7 AM.
  DateTime _nextMorning([DateTime? wake]) {
    final now = DateTime.now();
    final w = wake ?? _ChatHeartComposer._wakeCache[widget.friendId]?.$1;
    var at = DateTime(now.year, now.month, now.day, w?.hour ?? 7,
        w == null ? 0 : w.minute);
    if (!at.isAfter(now.add(const Duration(minutes: 30)))) {
      at = at.add(const Duration(days: 1));
    }
    return at;
  }

  void _startGoodNight() {
    Haptics.selectionClick();
    const note = 'Good night, sleep sweet 🌙';
    rebuildWith(() {
      _gnDoneToday = true;
      _heartMode = true;
      _heartMood = 'love';
      _heartUnlockAt = _nextMorning();
      _replyTo = null;
      _ctrl.value = const TextEditingValue(
          text: note, selection: TextSelection.collapsed(offset: note.length));
    });
    _markRitual('gn_done_${widget.friendId}');
    final sealedAt = _heartUnlockAt;
    showToast(
        context,
        'Sealed till ${DateFormat('h:mm a').format(sealedAt ?? _nextMorning())}'
        ' — they wake up to it 🌅');
    // Their usual wake-up (when known) beats a fixed 7 AM — unless I've
    // already changed the time myself.
    _partnerWake().then((w) {
      if (w == null || !mounted || _heartUnlockAt != sealedAt) return;
      rebuildWith(() => _heartUnlockAt = _nextMorning(w));
    });
    // A lullaby from Our Playlist rides inside it (20 s, plays as it
    // opens); the chip above the composer lets me change or drop it.
    _ourSongBed(clip: 20).then((bed) {
      if (bed == null || !mounted || !_heartMode) return;
      rebuildWith(() => _pendingBed = {'kind': 'lullaby', ...bed});
    });
  }

  void _dismissGoodNight() {
    rebuildWith(() => _gnDoneToday = true);
    _markRitual('gn_done_${widget.friendId}');
  }

  /// Evening, a live streak, and today's "both wrote" not done yet.
  bool get _streakAtRisk {
    if (!_bondedDm || _streakNudged || !_streakAlive || _streakDays < 2) {
      return false;
    }
    if (DateTime.now().hour < 18) return false;
    // Listening together today keeps the streak too (the server counts it).
    if (_listenedToday) return false;
    final w = _wroteToday;
    return !(w.mine && w.theirs);
  }

  /// We listened together today (a "Listened together" log in this chat).
  bool get _listenedToday {
    final now = DateTime.now();
    for (final m in _messages) {
      final d = _ts(m['timestamp']);
      if (d == null) continue;
      if (d.year != now.year || d.month != now.month || d.day != now.day) {
        break; // newest-first: past today
      }
      if ((m['message_type'] ?? '') == 'live' &&
          (m['content'] ?? '').toString().trim() == 'listened') {
        return true;
      }
    }
    return false;
  }

  /// Who has written in this chat today (messages are newest-first).
  ({bool mine, bool theirs}) get _wroteToday {
    final now = DateTime.now();
    var mine = false, theirs = false;
    for (final m in _messages) {
      final d = _ts(m['timestamp']);
      if (d == null) continue;
      if (d.year != now.year || d.month != now.month || d.day != now.day) {
        break; // newest-first: past today
      }
      if (m['sender_id']?.toString() == _myId) {
        mine = true;
      } else {
        theirs = true;
      }
      if (mine && theirs) break;
    }
    return (mine: mine, theirs: theirs);
  }

  /// The streak chip's line, saying who still needs to show up today.
  String get _streakNudgeLine {
    final w = _wroteToday;
    final first = _livePeerLabel.trim().split(RegExp(r'\s+')).first;
    final days = '$_streakDays days in tune';
    if (w.mine && !w.theirs) {
      return '$days — nudge $first, or play one song together';
    }
    if (w.theirs && !w.mine) return '$days — reply tonight to keep it going';
    return '$days — keep the fire: play one song together tonight';
  }

  /// Oldest-first: the most meaningful (furthest back) same-day message.
  Map<String, dynamic>? get _onThisDay {
    if (_isGroup || _memoryDoneToday) return null;
    final now = DateTime.now();
    Map<String, dynamic>? best;
    for (final m in _messages) {
      if (m['is_deleted'] == true || (m['message_type'] ?? '') == 'heart') {
        continue;
      }
      final d = _ts(m['timestamp']);
      if (d == null || d.year >= now.year) continue;
      if (d.month == now.month && d.day == now.day) best = m; // keeps oldest
    }
    return best;
  }

  Widget _ritualChip({
    required ColorScheme scheme,
    required bool isDark,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required VoidCallback onClose,
    bool inRow = false,
  }) {
    return Padding(
      padding: inRow
          ? const EdgeInsets.only(right: 8)
          : const EdgeInsets.fromLTRB(14, 0, 14, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Radii.xl),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Material(
              color: isDark
                  ? Colors.black.withValues(alpha: 0.35)
                  : Colors.white.withValues(alpha: 0.72),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Radii.xl),
                side: BorderSide(color: scheme.primary.withValues(alpha: 0.4)),
              ),
              child: InkWell(
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(icon, size: 16, color: accentInk(scheme)),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(label,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface)),
                    ),
                    InkResponse(
                      onTap: onClose,
                      radius: 14,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Icon(Icons.close_rounded,
                            size: 14,
                            color: scheme.onSurface.withValues(alpha: 0.5)),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The chips row above the composer (good night / on this day).
  Widget _buildRitualChips(ColorScheme scheme, bool isDark) {
    final rituals = MomentPrefs.instance.rituals.value;
    // Song memories: the pending song bed (always), missed-call voice note
    // and long-call song (with the rituals).
    final songChips = _songMemoryChips(rituals: rituals);
    if (!rituals && songChips.isEmpty) return const SizedBox.shrink();
    final chips = <Widget>[];
    // More than one → they share a sideways row.
    final memo = rituals ? _onThisDay : null;
    final many = [
          ...songChips.map((_) => true),
          rituals && _showGoodNight,
          rituals && _annivToday && !_isGroup,
          rituals && _streakAtRisk,
          memo != null && !_heartMode,
        ].where((b) => b).length >
        1;
    for (final s in songChips) {
      chips.add(_ritualChip(
        inRow: many,
        scheme: scheme,
        isDark: isDark,
        icon: s.icon,
        label: s.label,
        onTap: s.onTap,
        onClose: s.onClose,
      ));
    }
    if (rituals && _showGoodNight) {
      chips.add(_ritualChip(
        inRow: many,
        scheme: scheme,
        isDark: isDark,
        icon: Icons.nightlight_round,
        label: 'Send ${widget.friendName.split(' ').first} a good night',
        onTap: _startGoodNight,
        onClose: _dismissGoodNight,
      ));
    }
    if (rituals && _annivToday && !_isGroup) {
      chips.add(_ritualChip(
        inRow: many,
        scheme: scheme,
        isDark: isDark,
        icon: Icons.favorite_rounded,
        label: 'Happy anniversary — send a heart?',
        onTap: () {
          rebuildWith(() {
            _annivToday = false;
            _heartMode = true;
            _heartMood = 'love';
            _heartUnlockAt = null;
          });
          _markRitual('anniv_done_${widget.friendId}');
        },
        onClose: () {
          rebuildWith(() => _annivToday = false);
          _markRitual('anniv_done_${widget.friendId}');
        },
      ));
    }
    if (rituals && _streakAtRisk) {
      chips.add(_ritualChip(
        inRow: many,
        scheme: scheme,
        isDark: isDark,
        icon: Icons.local_fire_department_rounded,
        // One flame: the chip's icon (no 🔥 emoji in the text as well).
        label: _streakNudgeLine,
        onTap: () {
          rebuildWith(() => _streakNudged = true);
          final w = _wroteToday;
          if (w.theirs && !w.mine) {
            _composerFocus.requestFocus(); // "reply tonight"
          } else {
            // "…play one song together" → your song, in sync.
            unawaited(_startListenTogether(presetTitle: _yourSongTitle));
          }
        },
        onClose: () => rebuildWith(() => _streakNudged = true),
      ));
    }
    final memory = memo;
    if (memory != null && !_heartMode) {
      final d = _ts(memory['timestamp'])!;
      final years = DateTime.now().year - d.year;
      chips.add(_ritualChip(
        inRow: many,
        scheme: scheme,
        isDark: isDark,
        icon: Icons.auto_awesome_rounded,
        label: years == 1
            ? 'On this day, 1 year ago'
            : 'On this day, $years years ago',
        onTap: () {
          rebuildWith(() => _memoryDoneToday = true);
          _markRitual('otd_done_$_activeConvKey');
          _jumpToMessage(memory['id'].toString());
        },
        onClose: () {
          rebuildWith(() => _memoryDoneToday = true);
          _markRitual('otd_done_$_activeConvKey');
        },
      ));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    if (chips.length == 1) return chips.first;
    // Several at once (good night + streak + on this day): one sideways row
    // like every chip row in Aluta, not a stack that pushes the chat up.
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SizedBox(
        height: 34,
        child: EdgeScrollRow(
          builder: (context, ctrl) => ListView(
            controller: ctrl,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            children: chips,
          ),
        ),
      ),
    );
  }
}
