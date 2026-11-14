part of '../chat_page.dart';

// ── Live bond moments (bonded DMs only) ─────────────────────────────────────
//  • Here together: both of you in your chat → the header says so.
//  • Hold to feel: hold the heart button and they feel a lub-dub; both
//    holding at once → one heart beating on both screens.
//  • Date countdown: "when can I see you?" → Plan a date → the header counts
//    down; on the day it's kept in Our Space.
//  • Send with our song: a message carrying a 10 s clip of your song.
//  • Sleep-aware: after a good night, messages to them arrive without sound.
// Live signals are relayed by the server only between mutual friends who
// are actually in the app (bond_ping) — never stored, never pushed.

extension _ChatBondLive on _ChatPageState {
  // ── Here together ──────────────────────────────────────────────────────────

  void _bondPing(String kind) {
    if (!_bondedHere) return;
    try {
      _ws.sendEvent({'type': 'bond_ping', 'to': widget.friendId, 'kind': kind});
    } catch (_) {}
  }

  bool get _togetherNow =>
      _partnerHereAt != null &&
      DateTime.now().difference(_partnerHereAt!) < const Duration(seconds: 25);

  /// Every ~10 s while the chat is open (rides the presence timer).
  void _bondHereTick() {
    if (!_bondedHere) return;
    _bondPing('here');
    _hereSentAt = DateTime.now();
    _syncBondLive();
  }

  void _onBondPing(Map<String, dynamic> event) {
    final uid = int.tryParse('${event['user_id']}');
    if (uid != widget.friendId || !_bondedHere) return;
    switch ('${event['kind']}') {
      case 'here':
        final fresh = !_togetherNow;
        rebuildWith(() => _partnerHereAt = DateTime.now());
        // They just came in → tell them at once that I'm here too.
        final since = _hereSentAt == null
            ? const Duration(hours: 1)
            : DateTime.now().difference(_hereSentAt!);
        if (fresh && since > const Duration(seconds: 3)) _bondHereTick();
        if (fresh) Haptics.selectionClick();
      case 'leave':
        rebuildWith(() => _partnerHereAt = null);
      case 'touch':
        _partnerHoldEnd?.cancel();
        // A lost "let go" can't leave it beating forever.
        _partnerHoldEnd = Timer(const Duration(seconds: 12), () {
          if (mounted) _theyLetGo();
        });
        rebuildWith(() => _partnerHolding = true);
        _startBeat();
      case 'touch_end':
        _theyLetGo();
    }
    _syncBondLive();
  }

  void _theyLetGo() {
    _partnerHoldEnd?.cancel();
    rebuildWith(() => _partnerHolding = false);
    _maybeStopBeat();
  }

  /// Mirror what the header (in Home) shows: together + planned day.
  void _syncBondLive() {
    if (_isGroup) return;
    final id = widget.friendId;
    BondLive.instance.setTogether(id, _bondedHere && _togetherNow);
    final d = _plannedDate;
    BondLive.instance.setDate(id, d?.day);
    if (d != null) _keepMeetingDay(d);
  }

  // ── Hold to feel each other ────────────────────────────────────────────────

  void _holdStart() {
    if (!_bondedHere) return;
    Haptics.hold();
    rebuildWith(() => _iHolding = true);
    _bondPing('touch');
    _startBeat();
  }

  void _holdEnd() {
    if (!_iHolding) return;
    rebuildWith(() => _iHolding = false);
    _bondPing('touch_end');
    _maybeStopBeat();
  }

  void _startBeat() {
    if (_beatTimer != null) return;
    _lubDub();
    _beatTimer =
        Timer.periodic(const Duration(milliseconds: 1000), (_) => _lubDub());
  }

  Future<void> _lubDub() async {
    // Both holding → a stronger beat: you feel each other.
    if (_iHolding && _partnerHolding) {
      await Haptics.heavyImpact();
    } else {
      await Haptics.mediumImpact();
    }
    await Future<void>.delayed(const Duration(milliseconds: 170));
    await Haptics.lightImpact();
  }

  void _maybeStopBeat() {
    if (_iHolding || _partnerHolding) return;
    _beatTimer?.cancel();
    _beatTimer = null;
  }

  // ── Date countdown ─────────────────────────────────────────────────────────

  static final _meetRx = RegExp(
      r"when (can|could|will|do) (i|we) (see|meet) (you|u|each other)|"
      r"when (are|will|do) we (meet|see each other)|let'?s meet|"
      r"see you (soon|when)|tuonane|tukutane|tutaonana lini|lini tutaonana|"
      r"nikuone lini|date night",
      caseSensitive: false);

  /// The day we planned to meet (today or later), from the newest
  /// "Plan a date" message in this chat.
  ({DateTime day, Map<String, dynamic> msg})? get _plannedDate {
    if (_isGroup) return null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    for (final m in _messages) {
      final raw = m['meta'];
      if (raw == null || m['is_deleted'] == true) continue;
      try {
        final meta = raw is String ? jsonDecode(raw) : raw;
        final s = meta is Map ? meta['date'] : null;
        final d = s is String ? DateTime.tryParse(s) : null;
        if (d == null) continue;
        // The newest plan wins; a past one means nothing is planned.
        return d.isBefore(today) ? null : (day: d, msg: m);
      } catch (_) {}
    }
    return null;
  }

  /// "when can I see you?" just now (last 6 h) and nothing planned yet.
  Map<String, dynamic>? get _meetAsk {
    if (!_bondedDm || _plannedDate != null) return null;
    var n = 0;
    for (final m in _messages) {
      if (++n > 8) break;
      final d = _ts(m['timestamp']);
      if (d == null || DateTime.now().difference(d).inHours >= 6) break;
      if ((m['message_type'] ?? 'text') != 'text') continue;
      if (_songChipsDone.contains('md-${m['id']}')) return null;
      if (_meetRx.hasMatch('${m['content'] ?? ''}')) return m;
    }
    return null;
  }

  Future<void> _planDate(Map<String, dynamic>? ask) async {
    if (ask != null) rebuildWith(() => _songChipsDone.add('md-${ask['id']}'));
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(days: 1)),
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'When will you meet?',
      confirmText: 'Plan it 💞',
    );
    if (picked == null || !mounted) return;
    final day =
        '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    final text = '📅 Let’s meet on ${DateFormat('EEE d MMM').format(picked)} 💞';
    rebuildWith(() {
      _sendDateOnce = day;
      _ctrl.value = TextEditingValue(
          text: text, selection: TextSelection.collapsed(offset: text.length));
    });
    await _sendMessage();
    _syncBondLive();
  }

  /// On the day, the one who planned it keeps it in Our Space (once).
  Future<void> _keepMeetingDay(
      ({DateTime day, Map<String, dynamic> msg}) plan) async {
    final now = DateTime.now();
    if (plan.day.year != now.year ||
        plan.day.month != now.month ||
        plan.day.day != now.day) {
      return;
    }
    if (plan.msg['sender_id']?.toString() != _myId) return;
    final sid = _defaultKeepSpaceId;
    final key = 'met_kept_${plan.msg['id']}';
    if (sid == null || _songChipsDone.contains(key)) return;
    _songChipsDone.add(key);
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getBool(key) == true) return;
      await p.setBool(key, true);
      await ApiService().addMoment(sid,
          kind: 'note',
          caption: '💞 The day we met — ${DateFormat('d MMM y').format(now)}');
      spaceEventBus.value++;
    } catch (_) {}
  }

  // ── Send with our song ─────────────────────────────────────────────────────

  Future<void> _sendWithSong() async {
    final bed = await _ourSongBed(clip: 10);
    if (!mounted) return;
    if (bed == null) {
      showToast(context, 'Add a song to Our Playlist to send it along',
          type: ToastType.info);
      return;
    }
    rebuildWith(() => _sendBedOnce = bed);
    await _sendMessage();
  }

  // ── Duo status ─────────────────────────────────────────────────────────────

  /// My person sent half of a duo status: add my photo → one side-by-side
  /// status goes live, from both of us.
  Future<void> _addDuoHalf(Map<String, dynamic> msg) async {
    final rel = (msg['media_url'] as String?) ?? '';
    final partnerId = int.tryParse('${msg['sender_id']}');
    if (rel.isEmpty || partnerId == null) return;
    final src = await showAdaptiveSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (!kIsWeb)
            ListTile(
              leading: const Icon(Icons.photo_camera_rounded),
              title: const Text('Take my half'),
              onTap: () => Navigator.pop(c, ImageSource.camera),
            ),
          ListTile(
            leading: const Icon(Icons.photo_library_rounded),
            title: const Text('Choose a photo'),
            onTap: () => Navigator.pop(c, ImageSource.gallery),
          ),
        ]),
      ),
    );
    if (src == null || !mounted) return;
    final picked = await ImagePicker()
        .pickImage(source: src, maxWidth: 1600, imageQuality: 88);
    if (picked == null || !mounted) return;
    rebuildWith(() => _duoBusy = true);
    try {
      final url = fullMediaUrl(rel);
      final theirs = await http.get(Uri.parse(url), headers: mediaAuthHeaders(url));
      if (theirs.statusCode != 200) throw Exception('their half');
      final mine = await picked.readAsBytes();
      // Theirs on the left, mine on the right (decoded off the UI thread).
      final jpg = await compute(_composeDuo, (theirs.bodyBytes, mine));
      if (jpg == null) throw Exception('compose');
      final assetId = await ApiService().uploadStoryMedia(
          bytes: jpg, filename: 'duo.jpg', mime: 'image/jpeg');
      if (assetId == null) throw Exception('upload');
      final them = _livePeerLabel.trim().split(RegExp(r'\s+')).first;
      final me = _myName.trim().split(RegExp(r'\s+')).first;
      final created = await ApiService().createStory(
        kind: 'photo',
        mediaAssetId: assetId,
        mediaMime: 'image/jpeg',
        caption: me.isEmpty ? '$them 💞' : '$them 💞 $me',
        coAuthorId: partnerId,
      );
      if (created == null) throw Exception('post');
      _songChipsDone.add('duo-${msg['id']}');
      unawaited(ApiService().sendMessage(
          partnerId, '💞 Our duo status is live',
          messageType: 'text'));
      if (mounted) {
        showToast(context, 'Your duo status is live 💞',
            type: ToastType.success);
      }
    } catch (_) {
      if (mounted) {
        showToast(context, 'Couldn’t make the duo — try again',
            type: ToastType.error);
      }
    } finally {
      rebuildWith(() => _duoBusy = false);
    }
  }

  // ── Sleep-aware sending ────────────────────────────────────────────────────

  static final _gnRx = RegExp(
      r"good\s*night|\bgn\b|usiku\s*mwema|lala\s*salama|sleep (well|tight|sweet)",
      caseSensitive: false);

  bool _isGoodNight(Map<String, dynamic> m) {
    if ((m['message_type'] ?? '') == 'heart') {
      // The good-night ritual seals a heart until the morning.
      final ua = DateTime.tryParse('${m['unlock_at'] ?? ''}')?.toLocal();
      if (ua != null && ua.hour >= 5 && ua.hour <= 9) return true;
    }
    return _gnRx.hasMatch('${m['content'] ?? ''}');
  }

  /// After a good night (either of us, last 10 h) they haven't written
  /// since, and they're not in the app now → they're asleep.
  bool get _partnerAsleep {
    if (!_bondedDm || _isFriendOnline) return false;
    final h = DateTime.now().hour;
    if (h >= 9 && h < 20) return false;
    for (final m in _messages) {
      final d = _ts(m['timestamp']);
      if (d == null || DateTime.now().difference(d).inHours >= 10) break;
      if (_isGoodNight(m)) return true;
      // They wrote something that isn't a good night → awake.
      if (m['sender_id']?.toString() != _myId) return false;
    }
    return false;
  }

  /// Meta for a send: a song bed, a planned date, and "quiet" when they sleep.
  String? _metaFor({Map<String, dynamic>? bed, String? date}) {
    final m = <String, dynamic>{
      if (bed != null) 'bed': Map<String, dynamic>.from(bed)..remove('kind'),
      'date': ?date,
      if (_partnerAsleep) 'quiet': 1,
    };
    return m.isEmpty ? null : jsonEncode(m);
  }

  Map<String, dynamic>? _metaOf(Map<String, dynamic> msg) {
    final raw = msg['meta'];
    if (raw == null) return null;
    try {
      final m = raw is String ? jsonDecode(raw) : raw;
      return m is Map ? Map<String, dynamic>.from(m) : null;
    } catch (_) {
      return null;
    }
  }

  /// Under a bubble: "🌙 Sent while you slept" (theirs) / "🌙 Sent quietly"
  /// (mine), and a song pill for a message sent with our song.
  Widget? _bondNotes(Map<String, dynamic> msg, bool isMe) {
    final meta = _metaOf(msg);
    if (meta == null) return null;
    final quiet = meta['quiet'] == 1 || meta['quiet'] == true;
    final bed = meta['bed'] is Map &&
            (msg['message_type'] ?? 'text') == 'text'
        ? Map<String, dynamic>.from(meta['bed'] as Map)
        : null;
    // A duo status invite from my person: add my half.
    final duo = !isMe &&
        (meta['duo'] == 1 || meta['duo'] == true) &&
        (msg['message_type'] ?? '') == 'image';
    final duoDone = _songChipsDone.contains('duo-${msg['id']}');
    if (!quiet && bed == null && !duo) return null;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
          left: isMe ? 0 : 46, right: isMe ? 10 : 0, top: 2, bottom: 2),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Wrap(spacing: 6, runSpacing: 4, children: [
          if (bed != null)
            _SongNotePill(
              msgId: '${msg['id']}',
              bed: bed,
              autoPlay: !isMe &&
                  msg['is_read'] != true &&
                  (_ts(msg['timestamp']) ?? DateTime(2000))
                      .isAfter(DateTime.now().subtract(const Duration(hours: 6))),
            ),
          if (duo)
            ActionChip(
              avatar: Text(duoDone ? '💞' : '📸'),
              label: Text(duoDone ? 'Duo is live' : 'Add your half'),
              shape: const StadiumBorder(),
              onPressed: duoDone || _duoBusy ? null : () => _addDuoHalf(msg),
            ),
          if (quiet)
            Text(isMe ? '🌙 Sent quietly' : '🌙 Sent while you slept',
                style: TextStyle(
                    fontSize: 11, color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

/// "♪ with “Skeletun”" under a message sent with our song: tap to play its
/// clip; a fresh one from them plays once, softly, as it arrives.
class _SongNotePill extends StatefulWidget {
  const _SongNotePill(
      {required this.msgId, required this.bed, required this.autoPlay});
  final String msgId;
  final Map<String, dynamic> bed;
  final bool autoPlay;

  @override
  State<_SongNotePill> createState() => _SongNotePillState();
}

class _SongNotePillState extends State<_SongNotePill> {
  static final Set<String> _played = {};
  bool _on = false;

  String get _owner => 'note-${widget.msgId}';

  @override
  void initState() {
    super.initState();
    if (widget.autoPlay && _played.add(widget.msgId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _play());
    }
  }

  Future<void> _play() async {
    final ok = await _SongBed.play(_owner, widget.bed, volume: 0.3);
    if (!mounted || !ok) return;
    setState(() => _on = true);
    final secs = (widget.bed['clip'] as num?)?.toInt() ?? 10;
    Future.delayed(Duration(seconds: secs), () {
      if (mounted) setState(() => _on = false);
    });
  }

  @override
  void dispose() {
    unawaited(_SongBed.stop(owner: _owner, fadeMs: 300));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primary.withValues(alpha: 0.10),
      shape: StadiumBorder(
          side: BorderSide(color: scheme.primary.withValues(alpha: 0.30))),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: () {
          if (_on) {
            unawaited(_SongBed.stop(owner: _owner, fadeMs: 400));
            setState(() => _on = false);
          } else {
            _play();
          }
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 3, 10, 3),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(_on ? Icons.pause_rounded : Icons.music_note_rounded,
                size: 14, color: accentInk(scheme)),
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                  'with “${sharedTrackNames(widget.bed, playlistNotifier.value).$1}”',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: accentInk(scheme))),
            ),
          ]),
        ),
      ),
    );
  }
}

/// While you hold the heart (or they do): a heart beating in the middle of
/// the chat; both holding → one bigger heart, "Together 💞".
class _HoldHearts extends StatefulWidget {
  const _HoldHearts(
      {required this.mine, required this.theirs, required this.name});
  final bool mine;
  final bool theirs;
  final String name;

  @override
  State<_HoldHearts> createState() => _HoldHeartsState();
}

class _HoldHeartsState extends State<_HoldHearts>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1000))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  static double _beat(double t) {
    double bump(double c, double w, double h) {
      final d = (t - c).abs();
      return d >= w ? 0 : h * (1 - d / w);
    }

    return 1 + bump(0.1, 0.1, 0.22) + bump(0.3, 0.1, 0.14);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final both = widget.mine && widget.theirs;
    final label = both
        ? 'Together 💞'
        : widget.mine
            ? 'Holding ${widget.name}…'
            : '${widget.name} is holding you';
    final size = both ? 120.0 : 84.0;
    return IgnorePointer(
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          AnimatedBuilder(
            animation: _c,
            builder: (_, child) => Transform.scale(
                scale: _beat(_c.value), child: child),
            child: AnimatedContainer(
              duration: Motion.emphasized,
              curve: Motion.enter,
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: both ? 0.55 : 0.35),
                    blurRadius: both ? Depth.xl * 1.5 : Depth.xl,
                    spreadRadius: both ? 6 : 0,
                  ),
                ],
              ),
              child: Icon(Icons.favorite_rounded,
                  size: size, color: scheme.primary),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(Radii.lg),
            ),
            child: Text(label,
                style: TextStyle(
                    fontWeight: FontWeight.w800, color: accentInk(scheme))),
          ),
        ]),
      ),
    );
  }
}

/// A bonded partner typing: a little record turning slowly (no pulsing).
class _SpinningRecord extends StatefulWidget {
  const _SpinningRecord({super.key});

  @override
  State<_SpinningRecord> createState() => _SpinningRecordState();
}

class _SpinningRecordState extends State<_SpinningRecord>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(seconds: 3))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: 26,
      height: 16,
      child: Center(
        child: RotationTransition(
          turns: _c,
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const SweepGradient(colors: [
                Color(0xFF111111),
                Color(0xFF3A3A3A),
                Color(0xFF111111),
                Color(0xFF2A2A2A),
                Color(0xFF111111),
              ]),
              border: Border.all(color: Colors.black26, width: 0.5),
            ),
            child: Center(
              child: Container(
                width: 6,
                height: 6,
                decoration:
                    BoxDecoration(shape: BoxShape.circle, color: accent),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Two photos side by side (theirs | mine) as one JPEG for a duo status —
/// each half cover-cropped to 540×960, a thin rose seam between them.
List<int>? _composeDuo((List<int>, List<int>) halves) {
  try {
    final a = img.decodeImage(Uint8List.fromList(halves.$1));
    final b = img.decodeImage(Uint8List.fromList(halves.$2));
    if (a == null || b == null) return null;
    const w = 540, h = 960;
    img.Image cover(img.Image src) {
      final scale = (w / src.width) > (h / src.height)
          ? w / src.width
          : h / src.height;
      final r = img.copyResize(src,
          width: (src.width * scale).ceil(),
          height: (src.height * scale).ceil(),
          interpolation: img.Interpolation.average);
      return img.copyCrop(r,
          x: (r.width - w) ~/ 2, y: (r.height - h) ~/ 2, width: w, height: h);
    }

    final out = img.Image(width: w * 2, height: h);
    img.compositeImage(out, cover(a), dstX: 0, dstY: 0);
    img.compositeImage(out, cover(b), dstX: w, dstY: 0);
    img.fillRect(out,
        x1: w - 2, y1: 0, x2: w + 2, y2: h,
        color: img.ColorRgb8(0xFF, 0x5C, 0x8A));
    return img.encodeJpg(out, quality: 84);
  } catch (_) {
    return null;
  }
}
