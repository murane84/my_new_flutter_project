part of '../chat_page.dart';

// ── Secret heart: love-letter composer + receipts ───────────────────────────
// When the composer's ❤ toggle is on, a small tray rides above the input:
// pick the heart's mood (colour + cover + letter title), seal it until a
// moment ("Tonight 8 PM", "Tomorrow morning", a date…), and tap a prompt to
// start the note. Server side: my_aluta_api/hearts.py.

extension _ChatHeartComposer on _ChatPageState {
  /// First open by me (the recipient) → the sender's "Opened 💗" receipt.
  void _reportHeartOpened(Map<String, dynamic> msg) {
    final id = int.tryParse(msg['id'].toString());
    if (id == null || _myId == null || _myHeartOpen(msg) != null) return;
    final now = DateTime.now().toUtc().toIso8601String();
    final opens = _heartOpens(msg)..[_myId!] = now;
    msg['heart_opens'] = jsonEncode(opens);
    msg['opened_at'] ??= now;
    unawaited(_saveMessagesCache()); // survives a restart
    // "Send opened receipts" off → the sender isn't told (it still counts as
    // opened HERE, so the knock and stars stop).
    if (!HeartLock.instance.sendReceipts) return;
    unawaited(ApiService().heartOpened(id));
  }

  /// Answer a heart with a heart: the composer switches to heart mode with a
  /// fitting mood (a "sorry" is best answered with love).
  void _startHeartBack(Map<String, dynamic> msg) {
    final m = (msg['heart_mood'] ?? 'love').toString();
    HapticFeedback.selectionClick();
    rebuildWith(() {
      _heartMode = true;
      _heartMood = (m == 'sorry') ? 'love' : (HeartMood.of(m).key);
      _heartUnlockAt = null;
      _replyTo = null;
    });
    showToast(context, 'Write your heart back 💌');
  }

  /// Unsend a heart nobody has opened yet (it never lands).
  Future<void> _takeBackHeart(Map<String, dynamic> msg) async {
    final id = int.tryParse(msg['id'].toString());
    if (id == null) return;
    await _deleteMessage(id, true);
    if (mounted) showToast(context, 'Heart taken back — they never saw it');
  }

  /// Who opened this heart: user id → ISO time (from `heart_opens`).
  Map<String, String> _heartOpens(Map<String, dynamic> msg) {
    final raw = msg['heart_opens'];
    if (raw is! String || raw.isEmpty) return <String, String>{};
    try {
      final m = jsonDecode(raw);
      if (m is Map) {
        return m.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {}
    return <String, String>{};
  }

  /// When *I* opened it (null = not yet). DMs from before per-member opens
  /// existed fall back to the single opened_at.
  DateTime? _myHeartOpen(Map<String, dynamic> msg) {
    final mine = _myId == null ? null : _heartOpens(msg)[_myId!];
    if (mine != null && mine.isNotEmpty) return parseServerTime(mine);
    if (!_isGroup) {
      final o = (msg['opened_at'] ?? '').toString();
      if (o.isNotEmpty) return parseServerTime(o);
    }
    return null;
  }

  /// A timed heart's moment passed but the note isn't here yet → fetch it.
  Future<void> _unsealHeart(Map<String, dynamic> msg) async {
    final id = int.tryParse(msg['id'].toString());
    if (id == null) return;
    final fresh = await ApiService().heartUnseal(id);
    if (fresh == null || !mounted) return;
    final content = (fresh['content'] ?? '').toString();
    if (content.isEmpty) return;
    rebuildWith(() {
      final idx =
          _messages.indexWhere((m) => m['id'].toString() == id.toString());
      if (idx != -1) _messages[idx]['content'] = content;
    });
  }

  /// The tray shown above the composer while a secret heart is being written.
  Widget _buildHeartTray(ColorScheme scheme, bool isDark) {
    final mood = HeartMood.of(_heartMood);
    final tint = mood.color;
    final empty = _ctrl.text.trim().isEmpty;

    Widget chip({
      required Widget label,
      required bool on,
      required VoidCallback onTap,
      IconData? icon,
      Color? color,
    }) {
      final c = color ?? tint;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Material(
          color: on ? c.withValues(alpha: 0.18) : scheme.surface,
          shape: StadiumBorder(
              side: BorderSide(
                  color: on ? c : scheme.outlineVariant.withValues(alpha: 0.6))),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 14, color: on ? c : scheme.onSurfaceVariant),
                    const SizedBox(width: 5),
                  ],
                  DefaultTextStyle.merge(
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                        color: on ? c : scheme.onSurface),
                    child: label,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            tint.withValues(alpha: isDark ? 0.22 : 0.12),
            tint.withValues(alpha: isDark ? 0.08 : 0.04),
          ],
        ),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.favorite_rounded, size: 15, color: tint),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _heartUnlockAt == null
                      ? 'Secret heart · they hold it to open'
                      : 'Sealed · ${heartOpensLabel(_heartUnlockAt!).toLowerCase()}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: tint),
                ),
              ),
              IconButton(
                tooltip: 'Back to a normal message',
                visualDensity: VisualDensity.compact,
                onPressed: () => rebuildWith(() {
                  _heartMode = false;
                  _heartMood = 'love';
                  _heartUnlockAt = null;
                }),
                icon: Icon(Icons.close_rounded,
                    size: 17, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Moods.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final m in HeartMood.all)
                  chip(
                    label: Text(m.label),
                    icon: m.icon,
                    color: m.color,
                    on: m.key == _heartMood,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      rebuildWith(() => _heartMood = m.key);
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // When it opens + note starters.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                // Timed hearts are a one-to-one ritual (DMs only).
                if (!_isGroup)
                  chip(
                    label: Text(_heartUnlockAt == null
                        ? 'Open anytime'
                        : heartOpensLabel(_heartUnlockAt!, prefix: '')),
                    icon: _heartUnlockAt == null
                        ? Icons.schedule_rounded
                        : Icons.hourglass_top_rounded,
                    on: _heartUnlockAt != null,
                    onTap: _pickHeartUnlock,
                  ),
                if (empty)
                  for (final p in mood.prompts)
                    chip(
                      label: Text('${p.trim()}…'),
                      icon: Icons.edit_note_rounded,
                      on: false,
                      color: scheme.onSurfaceVariant,
                      onTap: () {
                        _ctrl.value = TextEditingValue(
                          text: p,
                          selection: TextSelection.collapsed(offset: p.length),
                        );
                        rebuildWith(() {});
                      },
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// "When should it open?" — quick presets + a date & time picker.
  Future<void> _pickHeartUnlock() async {
    final now = DateTime.now();
    DateTime at(int dayOffset, int hour, [int minute = 0]) =>
        DateTime(now.year, now.month, now.day + dayOffset, hour, minute);
    final tonight = now.hour < 20 ? at(0, 20) : at(1, 20);
    final morning = at(now.hour < 7 ? 0 : 1, 7);
    final presets = <(String, IconData, DateTime)>[
      ('In 1 hour', Icons.timelapse_rounded, now.add(const Duration(hours: 1))),
      (now.hour < 20 ? 'Tonight, 8:00 PM' : 'Tomorrow night, 8:00 PM',
          Icons.nights_stay_rounded, tonight),
      ('${now.hour < 7 ? 'This' : 'Tomorrow'} morning, 7:00 AM',
          Icons.wb_twilight_rounded, morning),
    ];
    // Our anniversary (day + month this device remembers for this friend).
    final annivKey = 'heart_anniv_${widget.friendId}';
    String? annivMd;
    try {
      final p = await SharedPreferences.getInstance();
      annivMd = p.getString(annivKey);
    } catch (_) {}
    DateTime? nextOf(String? md) {
      if (md == null) return null;
      final parts = md.split('-');
      if (parts.length != 2) return null;
      final mo = int.tryParse(parts[0]), d = int.tryParse(parts[1]);
      if (mo == null || d == null) return null;
      var c = DateTime(now.year, mo, d, 8);
      if (!c.isAfter(now.add(const Duration(minutes: 1)))) {
        c = DateTime(now.year + 1, mo, d, 8);
      }
      return c;
    }

    final anniv = nextOf(annivMd);
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    final choice = await showModalBottomSheet<Object>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Container(
          margin: const EdgeInsets.all(10),
          constraints: const BoxConstraints(maxWidth: 520),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(24),
            border:
                Border.all(color: scheme.primary.withValues(alpha: 0.18)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 14),
              Icon(Icons.hourglass_top_rounded, color: scheme.primary),
              const SizedBox(height: 6),
              Text('When should it open?',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface)),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
                child: Text(
                  'It stays sealed — even to you — until then, and you both '
                  'get a little ping when it opens.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12.5, color: scheme.onSurfaceVariant),
                ),
              ),
              for (final p in presets)
                ListTile(
                  leading: Icon(p.$2, color: scheme.primary),
                  title: Text(p.$1),
                  onTap: () => Navigator.pop(ctx, p.$3),
                ),
              ListTile(
                leading: Icon(Icons.celebration_rounded, color: scheme.primary),
                title: Text(anniv == null
                    ? 'On our anniversary…'
                    : 'On our anniversary · ${DateFormat('d MMM').format(anniv)}'),
                subtitle: Text(anniv == null
                    ? 'Set the date once — opens that morning every year you pick it'
                    : 'Opens at 8:00 AM · long-press to change the date'),
                onTap: () => Navigator.pop(ctx, anniv ?? 'anniv'),
                onLongPress: () => Navigator.pop(ctx, 'anniv'),
              ),
              ListTile(
                leading: Icon(Icons.event_rounded, color: scheme.primary),
                title: const Text('Pick a date & time…'),
                subtitle: const Text('An anniversary, a birthday, a reunion'),
                onTap: () => Navigator.pop(ctx, 'pick'),
              ),
              if (_heartUnlockAt != null)
                ListTile(
                  leading: Icon(Icons.lock_open_rounded,
                      color: scheme.onSurfaceVariant),
                  title: const Text('Open anytime (no seal)'),
                  onTap: () => Navigator.pop(ctx, 'clear'),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'clear') {
      rebuildWith(() => _heartUnlockAt = null);
      return;
    }
    DateTime? when = choice is DateTime ? choice : null;
    if (choice == 'anniv') {
      final d = await showDatePicker(
        context: context,
        initialDate: anniv ?? now,
        firstDate: DateTime(now.year - 60),
        lastDate: DateTime(now.year + 1, 12, 31),
        helpText: 'Our anniversary',
      );
      if (d == null || !mounted) return;
      final md = '${d.month}-${d.day}';
      try {
        final p = await SharedPreferences.getInstance();
        await p.setString(annivKey, md);
      } catch (_) {}
      when = nextOf(md);
    }
    if (!mounted) return;
    if (choice == 'pick') {
      final d = await showDatePicker(
        context: context,
        initialDate: now.add(const Duration(days: 1)),
        firstDate: now,
        lastDate: now.add(const Duration(days: 365)),
        helpText: 'Open on',
      );
      if (d == null || !mounted) return;
      final t = await showTimePicker(
        context: context,
        initialTime: const TimeOfDay(hour: 20, minute: 0),
        helpText: 'At',
      );
      if (t == null || !mounted) return;
      when = DateTime(d.year, d.month, d.day, t.hour, t.minute);
    }
    if (when == null || !mounted) return;
    if (when.isBefore(DateTime.now().add(const Duration(minutes: 1)))) {
      showToast(context, 'Pick a moment a little later', type: ToastType.info);
      return;
    }
    rebuildWith(() => _heartUnlockAt = when);
  }
}
