part of '../relationship_space_page.dart';

// ── Love letters — every secret heart between the two of you ────────────────
// A quiet shelf of the hearts you've sent each other, newest first, to reread
// any time. Each one reopens as its letter (behind the device unlock when
// "Lock secret hearts" is on). Timed hearts that haven't opened yet show when
// they will. Server: GET /messages/hearts/{peer} (my_aluta_api/hearts.py).

// Kept hearts healed (made self-contained) this app run — once each.
final Set<int> _heartHealTried = <int>{};
// Which kept hearts can't be opened, per set of moments (scanned once).
final Map<String, Future<List<int>>> _brokenScans = {};

extension _SpaceLoveLetters on _RelationshipSpacePageState {
  Widget _loveLettersSection(ColorScheme scheme, {VoidCallback? onMenu}) {
    final pid = _partnerId;
    _lettersFuture ??= pid == null
        ? Future.value(const <Map<String, dynamic>>[])
        : ApiService().loveLetters(pid);
    final partner = _others.isNotEmpty
        ? ContactNames.instance.displayName(of: _others.first, registered: (_others.first['username'] ?? 'them').toString())
        : 'them';
    return _sectionPanel(
      scheme,
      Icons.mark_email_unread_rounded,
      'Love letters',
      onMenu: onMenu,
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _lettersFuture,
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2.4)),
            );
          }
          final letters = snap.data ?? const [];
          if (letters.isEmpty) return _lettersEmpty(scheme);
          // "On this day": hearts traded on today's date in earlier years.
          final now = DateTime.now();
          final onThisDay = letters.where((l) {
            final t = parseLocal(l['timestamp']);
            return t != null &&
                t.year < now.year &&
                t.month == now.month &&
                t.day == now.day;
          }).toList();
          return Column(children: [
            if (onThisDay.isNotEmpty) _onThisDay(scheme, onThisDay, partner),
            for (final l in letters) _letterCard(scheme, l, partner),
          ]);
        },
      ),
    );
  }

  Widget _onThisDay(ColorScheme scheme, List<Map<String, dynamic>> letters,
      String partner) {
    final t = parseLocal(letters.first['timestamp'])!;
    final years = DateTime.now().year - t.year;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _accent.withValues(alpha: 0.30),
            _accent.withValues(alpha: 0.10),
          ],
        ),
        border: Border.all(color: _accent.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, size: 18, color: _accent),
              const SizedBox(width: 8),
              Text(
                'On this day · ${years == 1 ? '1 year ago' : '$years years ago'}',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: scheme.onSurface),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final l in letters) _letterCard(scheme, l, partner),
        ],
      ),
    );
  }

  Widget _lettersEmpty(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
      child: Column(
        children: [
          Icon(Icons.favorite_border_rounded,
              size: 46, color: _accent.withValues(alpha: 0.7)),
          const SizedBox(height: 12),
          Text('No love letters yet',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurface)),
          const SizedBox(height: 6),
          Text(
            'Tap the ♡ in your chat composer to send a secret heart. '
            'Every one you trade lands here, to reread whenever you like.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _letterCard(
      ColorScheme scheme, Map<String, dynamic> l, String partner) {
    final mood = HeartMood.of(l['heart_mood']?.toString());
    final tint = mood.color;
    final mine = (l['sender_id'] as num?)?.toInt() == widget.myUserId;
    final sent = parseLocal(l['timestamp']);
    final unlock = parseLocal(l['unlock_at']);
    final sealed = unlock != null && DateTime.now().isBefore(unlock);
    final text = (l['content'] ?? '').toString();
    final opened = l['opened_at'] != null;
    final when = sent == null ? '' : DateFormat('d MMM y · h:mm a').format(sent);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: (sealed || text.isEmpty)
              ? () => showToast(
                  context,
                  sealed
                      ? 'Sealed · ${heartOpensLabel(unlock).toLowerCase()}'
                      : 'This one is opening — check back in a moment',
                  type: ToastType.info)
              : () => _rereadLetter(text, tint, mood, l),
          child: Ink(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  tint.withValues(alpha: 0.16),
                  tint.withValues(alpha: 0.05),
                ],
              ),
              border: Border.all(color: tint.withValues(alpha: 0.30)),
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: tint.withValues(alpha: 0.18),
                  ),
                  child: Icon(
                      sealed ? Icons.hourglass_top_rounded : mood.icon,
                      color: tint,
                      size: 21),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        mine ? 'To $partner · ${mood.title}' : 'From $partner · ${mood.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                            color: scheme.onSurface),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        sealed
                            ? heartOpensLabel(unlock)
                            : (mine
                                ? '$when · ${opened ? 'opened 💗' : 'not opened yet'}'
                                : when),
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Icon(
                    sealed ? Icons.lock_clock_rounded : Icons.lock_rounded,
                    size: 18,
                    color: tint.withValues(alpha: 0.8)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _rereadLetter(String text, Color tint, HeartMood mood,
      [Map<String, dynamic>? letter]) async {
    final ok = await HeartLock.instance.ensureUnlocked('Open love letter');
    if (!ok || !mounted) return;
    final size = MediaQuery.of(context).size;
    final sent = letter == null ? null : parseLocal(letter['timestamp']);
    final mine = letter != null &&
        (letter['sender_id'] as num?)?.toInt() == widget.myUserId;
    final partner = _others.isNotEmpty
        ? ContactNames.instance.displayName(
            of: _others.first,
            registered: (_others.first['username'] ?? '').toString())
        : '';
    showHeartGenie(
      context,
      originRect: Rect.fromCenter(
          center: Offset(size.width / 2, size.height / 2),
          width: 10,
          height: 10),
      text: text,
      accent: tint,
      mood: mood,
      from: letter == null ? null : (mine ? 'you' : partner),
      sentAt: sent,
      // The photo / clip / song / voice sealed inside — replayable here too.
      media: letter == null ? null : _heartMedia(letter),
    );
  }

  /// What a heart carried, drawn inside its letter (null = just words).
  Widget Function(double width)? _heartMedia(Map<String, dynamic> l) {
    final rel = (l['media_url'] ?? '').toString();
    if (rel.isEmpty) return null;
    final url = _full(rel)!;
    final mime = (l['media_mime'] ?? '').toString().toLowerCase();
    final name = (l['media_name'] ?? '').toString();
    if (mime.startsWith('image/')) {
      // Whole photo, fitted to the letter (the words stay in view); double-
      // tap or the corner button opens it full size.
      return (w) => ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: CompactPhoto(
              image: authNetworkImageProvider(url, mediaAuthHeaders(url)),
              width: w,
              maxHeight: (MediaQuery.sizeOf(context).height * 0.34)
                  .clamp(140.0, 340.0),
            ),
          );
    }
    if (mime.startsWith('video/')) {
      return (w) => GlimpseVideo(
            url: url,
            headers: mediaAuthHeaders(url),
            accent: Colors.white,
            maxWidth: w,
            aspectRatioFallback: 16 / 9,
            posterUrl: '$url/thumb',
          );
    }
    if (mime.startsWith('audio/')) {
      final voice = name.startsWith('heart_voice');
      final dot = name.lastIndexOf('.');
      final title = voice
          ? 'Voice note'
          : (dot > 0 ? name.substring(0, dot) : (name.isEmpty ? 'A song' : name));
      return (w) => SizedBox(
            width: w,
            child: _HeartAudioPlayer(
                url: url, title: title, voice: voice, fileName: name, mime: mime),
          );
    }
    return null;
  }

  /// Find a kept heart: the server's love-letter shelf first, then this
  /// device's own chat cache (it may still hold a heart the chat cleared).
  Map<String, dynamic>? _findHeartIn(
      List<Map<String, dynamic>> letters, int? mid, String? stamp) {
    for (final l in letters) {
      if (mid != null && (l['id'] as num?)?.toInt() == mid) return l;
      if (mid == null && stamp != null) {
        final t = parseLocal(l['timestamp']);
        if (t != null && DateFormat('d MMM, h:mm a').format(t) == stamp) {
          return l;
        }
      }
    }
    return null;
  }

  Future<Map<String, dynamic>?> _localHeart(int? mid, String? stamp) async {
    final pid = _partnerId;
    final me = widget.myUserId;
    if (pid == null || me == null) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('chat_cache_${me}_$pid');
      if (raw == null) return null;
      final list = jsonDecode(raw);
      if (list is! List) return null;
      final hearts = [
        for (final x in list)
          if (x is Map && x['message_type'] == 'heart' && x['is_deleted'] != true)
            Map<String, dynamic>.from(x),
      ];
      return _findHeartIn(hearts, mid, stamp);
    } catch (_) {
      return null;
    }
  }

  /// A kept heart's private snapshot as a letter map (null = none yet).
  Map<String, dynamic>? _snapLetter(Map<String, dynamic> ref) {
    final s = ref['snap'];
    if (s is! Map) return null;
    return {
      'id': ref['mid'],
      'content': (s['note'] ?? '').toString(),
      'heart_mood': ref['mood'],
      'sender_id': ref['from'],
      'timestamp': ref['ts'],
      'media_url': s['media_url'],
      'media_mime': s['media_mime'],
      'media_name': s['media_name'],
    };
  }

  Map<String, dynamic> _refOf(Map<String, dynamic> m) {
    try {
      final d = jsonDecode((m['ref'] ?? '').toString());
      if (d is Map) return Map<String, dynamic>.from(d);
    } catch (_) {}
    return <String, dynamic>{};
  }

  /// Self-heal: write the letter's words + a durable copy of what it carried
  /// into the moment, so it opens forever (on any device, chat or no chat).
  /// Runs once per moment per app run; either partner's device can do it.
  Future<void> _healKeptHeart(
      Map<String, dynamic> m, Map<String, dynamic> letter) async {
    final id = (m['id'] as num?)?.toInt();
    if (id == null || !_heartHealTried.add(id)) return;
    final unlock = parseLocal(letter['unlock_at']);
    if (unlock != null && DateTime.now().isBefore(unlock)) return; // sealed
    final ref = _refOf(m);
    if (ref['snap'] is Map) return;
    final rel = (letter['media_url'] ?? '').toString();
    final mime = (letter['media_mime'] ?? '').toString();
    final name = (letter['media_name'] ?? '').toString();
    String? media;
    if (rel.isNotEmpty) {
      media = rel;
      try {
        final url = _full(rel)!;
        List<int>? bytes;
        if (!kIsWeb) {
          final f = await MediaStore.instance.getFile(url, mediaAuthHeaders(url));
          if (f != null) bytes = await f.readAsBytes();
        }
        if (bytes != null && bytes.isNotEmpty) {
          final up = await ApiService().uploadMedia(
              bytes: bytes,
              filename: name.isEmpty ? 'keepsake' : name,
              mime: mime.isEmpty ? 'application/octet-stream' : mime,
              ephemeral: false);
          final u = (up?['url'] as String?) ?? '';
          if (u.isNotEmpty) media = u;
        }
      } catch (_) {}
    }
    ref['mid'] ??= letter['id'];
    ref['ts'] ??= letter['timestamp'];
    ref['mood'] ??= letter['heart_mood'] ?? 'love';
    ref['from'] ??= letter['sender_id'];
    ref['snap'] = {
      'note': (letter['content'] ?? '').toString(),
      'media_url': ?media,
      if (media != null) 'media_mime': mime,
      if (media != null) 'media_name': name,
    };
    final ok = await ApiService().healMomentRef(_id, id, jsonEncode(ref));
    if (ok) m['ref'] = jsonEncode(ref);
  }

  /// Reopen a kept heart from Our Space. [mid] = its message id (new keeps);
  /// [stamp] = the "d MMM, h:mm a" label older keeps carried in their text.
  /// [moment] = the pinned moment (for its snapshot / healing).
  Future<void> _openKeptHeart(
      {int? mid, String? stamp, Map<String, dynamic>? moment}) async {
    final pid = _partnerId;
    if (pid == null) return;
    final letters = await (_lettersFuture ??= ApiService().loveLetters(pid));
    if (!mounted) return;
    var hit = _findHeartIn(letters, mid, stamp) ?? await _localHeart(mid, stamp);
    if (!mounted) return;
    final ref = moment == null ? const <String, dynamic>{} : _refOf(moment);
    if (hit != null && moment != null && ref['snap'] is! Map) {
      _healKeptHeart(moment, hit); // make it self-contained for next time
    }
    hit ??= _snapLetter(ref);
    if (hit == null) {
      await _heartGoneSheet(moment);
      return;
    }
    final unlock = parseLocal(hit['unlock_at']);
    if (unlock != null && DateTime.now().isBefore(unlock)) {
      showToast(context, 'Sealed · ${heartOpensLabel(unlock).toLowerCase()}',
          type: ToastType.info);
      return;
    }
    final text = (hit['content'] ?? '').toString();
    final mood = HeartMood.of(hit['heart_mood']?.toString());
    await _rereadLetter(text, mood.color, mood, hit);
  }

  /// A kept heart in Pinned moments: mood-tinted, who · when · what's inside,
  /// and one tap reopens the letter itself.
  Widget _keptHeartCard(ColorScheme scheme, Map<String, dynamic> m) {
    Map<String, dynamic> ref = const {};
    try {
      final d = jsonDecode((m['ref'] ?? '').toString());
      if (d is Map) ref = Map<String, dynamic>.from(d);
    } catch (_) {}
    final mood = HeartMood.of(ref['mood']?.toString());
    final tint = mood.color;
    final fromMe = (ref['from'] as num?)?.toInt() == widget.myUserId;
    final partner = _others.isNotEmpty
        ? ContactNames.instance.displayName(
            of: _others.first,
            registered: (_others.first['username'] ?? '').toString())
        : 'them';
    final sent = parseLocal(ref['ts']);
    final media = (ref['media'] ?? '').toString();
    final inside = switch (media) {
      'song' => '🎵 ${(ref['title'] ?? 'a song').toString()}',
      'photo' => '📷 a photo',
      'video' => '🎬 a clip',
      'voice' => '🎤 a voice note',
      _ => '✉️ a note',
    };
    return _keptHeartPanel(
      scheme,
      tint: tint,
      icon: mood.icon,
      title: fromMe
          ? 'To $partner · ${mood.title}'
          : 'From $partner · ${mood.title}',
      sub: [
        if (sent != null) 'sent ${DateFormat('d MMM · h:mm a').format(sent)}',
        inside,
      ].join('  ·  '),
      onOpen: () =>
          _openKeptHeart(mid: (ref['mid'] as num?)?.toInt(), moment: m),
      // Known gone (no snapshot, not on the shelf) → the card says so.
      brokenCheck: ref['snap'] is Map
          ? null
          : () => _isHeartGone(m, (ref['mid'] as num?)?.toInt(), null),
    );
  }

  /// true when a kept heart can't be opened anywhere we can see. Also heals
  /// it on the spot when the letter IS available (shelf or local cache).
  Future<bool> _isHeartGone(
      Map<String, dynamic> m, int? mid, String? stamp) async {
    final pid = _partnerId;
    if (pid == null) return false;
    final letters = await (_lettersFuture ??= ApiService().loveLetters(pid));
    final hit = _findHeartIn(letters, mid, stamp) ?? await _localHeart(mid, stamp);
    if (hit != null) {
      if (m.isNotEmpty) _healKeptHeart(m, hit);
      return false;
    }
    return _snapLetter(_refOf(m)) == null;
  }

  /// A quiet line over Pinned moments when some kept hearts can't be opened
  /// anywhere (and heals the rest as it checks). "Tidy up" unpins those, after
  /// asking. Nothing is removed without a tap.
  Widget _brokenHeartsBanner(
      ColorScheme scheme, List<Map<String, dynamic>> moments) {
    final legacy = RegExp(r'^❤️ Secret heart · (.+)$');
    final hearts = [
      for (final m in moments)
        if (m['kind'] == 'heart' ||
            (m['kind'] == 'note' &&
                legacy.hasMatch((m['caption'] ?? '').toString().trim())))
          m,
    ];
    if (hearts.isEmpty) return const SizedBox.shrink();
    final key = [for (final m in hearts) '${m['id']}:${(m['ref'] ?? '').toString().length}']
        .join(',');
    final scan = _brokenScans[key] ??= () async {
      final out = <int>[];
      for (final m in hearts) {
        final ref = _refOf(m);
        final stamp = m['kind'] == 'note'
            ? legacy.firstMatch((m['caption'] ?? '').toString().trim())?.group(1)
            : null;
        final gone = await _isHeartGone(
            m, (ref['mid'] as num?)?.toInt(), stamp);
        final id = (m['id'] as num?)?.toInt();
        if (gone && id != null) out.add(id);
      }
      return out;
    }();
    return FutureBuilder<List<int>>(
      future: scan,
      builder: (_, snap) {
        final broken = snap.data ?? const <int>[];
        if (broken.isEmpty) return const SizedBox.shrink();
        final n = broken.length;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.6)),
            ),
            child: Row(children: [
              Icon(Icons.heart_broken_rounded,
                  size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    n == 1
                        ? "1 kept heart can't be opened here"
                        : "$n kept hearts can't be opened here",
                    style: TextStyle(
                        fontSize: 12.5, color: scheme.onSurfaceVariant)),
              ),
              TextButton(
                onPressed: () => _tidyBrokenHearts(broken),
                child: const Text('Tidy up'),
              ),
            ]),
          ),
        );
      },
    );
  }

  Future<void> _tidyBrokenHearts(List<int> ids) async {
    final n = ids.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(n == 1 ? 'Unpin this heart?' : 'Unpin $n hearts?'),
        content: const Text(
            "Their letters were cleared from the chat, so they can't be "
            'opened anymore. Everything else in Pinned stays.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Unpin')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    var failed = 0;
    for (final id in ids) {
      if (!await ApiService().deleteMoment(_id, id)) failed++;
    }
    if (!mounted) return;
    _brokenScans.clear();
    _load();
    if (failed > 0) {
      showToast(context, "Couldn't unpin $failed — try again",
          type: ToastType.error);
    }
  }

  /// The original heart is gone (the chat was cleared on both sides).
  /// Explain, and offer the honest ways out — never a dead-end toast.
  Future<void> _heartGoneSheet(Map<String, dynamic>? moment) async {
    final scheme = Theme.of(context).colorScheme;
    final partner = _others.isNotEmpty
        ? ContactNames.instance.displayName(
            of: _others.first,
            registered: (_others.first['username'] ?? '').toString())
        : 'your partner';
    final id = (moment?['id'] as num?)?.toInt();
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      // No theme outline — this sheet draws its own card.
      shape: const RoundedRectangleBorder(),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Container(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(24),
                  border:
                      Border.all(color: _accent.withValues(alpha: 0.25)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.heart_broken_rounded,
                          color: _accent, size: 24),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text("This heart can't be opened",
                            style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                                color: scheme.onSurface)),
                      ),
                    ]),
                    const SizedBox(height: 10),
                    Text(
                        'Its letter was cleared from your chat before it was '
                        'saved here. If $partner\'s phone still has it, it '
                        'comes back by itself the next time they open Pinned '
                        'moments — and then it stays for good.',
                        style: TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            color: scheme.onSurfaceVariant)),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (id != null)
                          TextButton.icon(
                            onPressed: () => Navigator.pop(ctx, 'unpin'),
                            icon: const Icon(Icons.push_pin_outlined,
                                size: 18),
                            label: const Text('Unpin'),
                          ),
                        const SizedBox(width: 6),
                        FilledButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Keep it'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (choice == 'unpin' && id != null && mounted) {
      await _confirmDeleteMoment(id);
    }
  }

  /// Older keeps were saved as a note "❤️ Secret heart · 24 Oct, 9:25 PM" —
  /// found by that time and reopened the same way.
  Widget? _legacyHeartCard(ColorScheme scheme, String caption,
      [Map<String, dynamic>? moment]) {
    final m = RegExp(r'^❤️ Secret heart · (.+)$').firstMatch(caption.trim());
    if (m == null) return null;
    return _keptHeartPanel(
      scheme,
      tint: HeartMood.love.color,
      icon: Icons.favorite_rounded,
      title: 'A secret heart',
      sub: 'sent ${m.group(1)}',
      onOpen: () => _openKeptHeart(stamp: m.group(1), moment: moment),
      brokenCheck: () =>
          _isHeartGone(moment ?? const {}, null, m.group(1)),
    );
  }

  Widget _keptHeartPanel(ColorScheme scheme,
      {required Color tint,
      required IconData icon,
      required String title,
      required String sub,
      required VoidCallback onOpen,
      Future<bool> Function()? brokenCheck}) {
    // A heart we know can't be opened reads as such (faded, honest line),
    // and a tap explains what happened instead of a dead-end toast.
    if (brokenCheck != null) {
      return FutureBuilder<bool>(
        future: brokenCheck(),
        builder: (_, snap) => _keptHeartPanel(scheme,
            tint: snap.data == true ? scheme.outline : tint,
            icon: snap.data == true ? Icons.heart_broken_rounded : icon,
            title: title,
            sub: snap.data == true
                ? 'Cleared from the chat · tap for options'
                : sub,
            onOpen: onOpen),
      );
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onOpen,
        child: Ink(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                tint.withValues(alpha: 0.20),
                tint.withValues(alpha: 0.06),
              ],
            ),
            border: Border.all(color: tint.withValues(alpha: 0.35)),
          ),
          child: Row(children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [
                  tint,
                  Color.lerp(tint, Colors.black, 0.35)!,
                ]),
                boxShadow: [
                  BoxShadow(
                      color: tint.withValues(alpha: 0.4),
                      blurRadius: 12,
                      offset: const Offset(0, 4)),
                ],
              ),
              child: Icon(icon, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14.5,
                          color: scheme.onSurface)),
                  const SizedBox(height: 3),
                  Text(sub,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: tint,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.lock_open_rounded, size: 15, color: Colors.white),
                SizedBox(width: 5),
                Text('Open',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 13)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  static DateTime? parseLocal(Object? raw) {
    final s = (raw ?? '').toString();
    if (s.isEmpty) return null;
    return parseServerTime(s);
  }
}


/// A heart's song / voice note inside its letter: plays from this device's
/// private song cache when Aluta saved it, else streams (saving as it goes).
class _HeartAudioPlayer extends StatefulWidget {
  const _HeartAudioPlayer({
    required this.url,
    required this.title,
    required this.voice,
    required this.fileName,
    required this.mime,
  });
  final String url, title, fileName, mime;
  final bool voice;

  @override
  State<_HeartAudioPlayer> createState() => _HeartAudioPlayerState();
}

class _HeartAudioPlayerState extends State<_HeartAudioPlayer> {
  final ja.AudioPlayer _p = ja.AudioPlayer();
  bool _playing = false, _ready = false, _failed = false;
  Duration _pos = Duration.zero, _dur = Duration.zero;

  @override
  void initState() {
    super.initState();
    _p.playerStateStream.listen((st) {
      if (!mounted) return;
      final done = st.processingState == ja.ProcessingState.completed;
      setState(() => _playing = st.playing && !done);
      if (done) {
        _p.seek(Duration.zero);
        _p.pause();
      }
    });
    _p.positionStream.listen((d) {
      if (mounted) setState(() => _pos = d);
    });
    _load();
  }

  Future<void> _load() async {
    try {
      final aid = SongCache.assetId(widget.url);
      String? path;
      if (aid != null && !kIsWeb) {
        path = await SongCache.ensureCached(
            aid, widget.url, mediaAuthHeaders(widget.url),
            filename: widget.fileName, mime: widget.mime);
      }
      Duration? d;
      try {
        d = path != null
            ? await _p.setFilePath(path)
            : await _p.setUrl(widget.url,
                headers: mediaAuthHeaders(widget.url));
      } catch (_) {
        // Streaming with headers isn't supported everywhere (desktop):
        // fetch the file once and play it from disk instead.
        if (kIsWeb) rethrow;
        final f = await MediaStore.instance
            .getFile(widget.url, mediaAuthHeaders(widget.url));
        if (f == null) rethrow;
        d = await _p.setFilePath(f.path);
      }
      if (!mounted) return;
      setState(() {
        _ready = true;
        _failed = false;
        _dur = d ?? Duration.zero;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _retry() {
    setState(() {
      _failed = false;
      _ready = false;
    });
    _load();
  }

  @override
  void dispose() {
    _p.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frac = _dur.inMilliseconds > 0
        ? (_pos.inMilliseconds / _dur.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 14, 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(children: [
        IconButton(
          tooltip: _failed ? 'Try again' : null,
          onPressed: _failed
              ? _retry
              : (!_ready ? null : () => _playing ? _p.pause() : _p.play()),
          icon: Icon(
              _failed
                  ? Icons.refresh_rounded
                  : (_playing
                      ? Icons.pause_circle_filled_rounded
                      : Icons.play_circle_fill_rounded),
              size: 38,
              color: Colors.white),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${widget.voice ? '🎤' : '🎵'} ${widget.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 14)),
              const SizedBox(height: 6),
              _failed
                  ? Text("Couldn't load it here · tap ↻ to try again",
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 11.5))
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: _ready ? frac : null,
                        minHeight: 4,
                        color: Colors.white,
                        backgroundColor: Colors.white.withValues(alpha: 0.22),
                      ),
                    ),
            ],
          ),
        ),
      ]),
    );
  }
}
