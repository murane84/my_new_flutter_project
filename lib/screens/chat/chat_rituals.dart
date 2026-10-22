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

  DateTime _nextMorning() {
    final now = DateTime.now();
    var at = DateTime(now.year, now.month, now.day, 7);
    if (!at.isAfter(now.add(const Duration(minutes: 30)))) {
      at = at.add(const Duration(days: 1));
    }
    return at;
  }

  void _startGoodNight() {
    HapticFeedback.selectionClick();
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
    showToast(context, 'Sealed till 7 AM — they wake up to it 🌅');
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
    final now = DateTime.now();
    if (now.hour < 18) return false;
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
      if (mine && theirs) return false;
    }
    return true;
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
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Material(
              color: isDark
                  ? Colors.black.withValues(alpha: 0.35)
                  : Colors.white.withValues(alpha: 0.72),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: BorderSide(color: scheme.primary.withValues(alpha: 0.4)),
              ),
              child: InkWell(
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(icon, size: 16, color: scheme.primary),
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
    if (!MomentPrefs.instance.rituals.value) return const SizedBox.shrink();
    final chips = <Widget>[];
    if (_showGoodNight) {
      chips.add(_ritualChip(
        scheme: scheme,
        isDark: isDark,
        icon: Icons.nightlight_round,
        label: 'Send ${widget.friendName.split(' ').first} a good night 🌙',
        onTap: _startGoodNight,
        onClose: _dismissGoodNight,
      ));
    }
    if (_annivToday && !_isGroup) {
      chips.add(_ritualChip(
        scheme: scheme,
        isDark: isDark,
        icon: Icons.favorite_rounded,
        label: 'Happy anniversary 💞 — send a heart?',
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
    if (_streakAtRisk) {
      chips.add(_ritualChip(
        scheme: scheme,
        isDark: isDark,
        icon: Icons.local_fire_department_rounded,
        label: '🔥 $_streakDays days in tune — keep it going tonight',
        onTap: () {
          rebuildWith(() => _streakNudged = true);
          _composerFocus.requestFocus();
        },
        onClose: () => rebuildWith(() => _streakNudged = true),
      ));
    }
    final memory = _onThisDay;
    if (memory != null && !_heartMode) {
      final d = _ts(memory['timestamp'])!;
      final years = DateTime.now().year - d.year;
      chips.add(_ritualChip(
        scheme: scheme,
        isDark: isDark,
        icon: Icons.auto_awesome_rounded,
        label: years == 1
            ? 'On this day, 1 year ago ✨'
            : 'On this day, $years years ago ✨',
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
    return Column(mainAxisSize: MainAxisSize.min, children: chips);
  }
}
