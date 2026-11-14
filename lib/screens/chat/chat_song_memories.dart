part of '../chat_page.dart';

// ── Song memories (music · love · bonding) ──────────────────────────────────
//  • A day you listened together keeps its song: the date label reads
//    "Yesterday · ♪ Mgambo" and tapping the song plays it.
//  • "Listened together" opens as a keepsake: play it again, listen again
//    together, add it to Our Playlist, keep it as a moment.
//  • Missed their call → a voice note with your song playing softly under it.
//  • Good night → the sealed heart carries a short lullaby from Our Playlist.
//  • After a long call → "play our song together?".
//  • Bonded chats: "seen" is a tiny heartbeat.
// The song under a voice note / the lullaby travels as message meta
// {"bed": {"title", "url", "clip"}} and is played on the reader's device.

typedef _SongChip = ({
  IconData icon,
  String label,
  VoidCallback onTap,
  VoidCallback onClose,
});

/// One quiet player for song beds (under a voice note, or a lullaby). Plays
/// only while asked to, fades in and out, and never runs in the background.
class _SongBed {
  _SongBed._();

  /// Turns a stored "/attachments/…" into a full URL (set by the chat).
  static String Function(String rel)? fullUrl;
  static ja.AudioPlayer? _p;
  static String? _owner;
  static Timer? _clip;
  static int _gen = 0;

  static Future<bool> play(String owner, Map<String, dynamic> bed,
      {double volume = 0.16}) async {
    if (_owner == owner && (_p?.playing ?? false)) return true;
    await stop(fadeMs: 150);
    final gen = ++_gen;
    _owner = owner;
    final title = (bed['title'] ?? '').toString();
    final p = _p ??= ja.AudioPlayer();
    try {
      final local = kIsWeb ? null : loadedPathForTitle(title);
      if (local != null) {
        await p.setFilePath(local);
      } else {
        final rel = (bed['url'] ?? '').toString();
        final resolve = fullUrl;
        if (rel.isEmpty || resolve == null) {
          if (gen == _gen) _owner = null;
          return false;
        }
        final full = resolve(rel);
        final headers = mediaAuthHeaders(full);
        final f = kIsWeb ? null : await MediaStore.instance.getFile(full, headers);
        if (gen != _gen) return false;
        if (f != null) {
          await p.setFilePath(f.path);
        } else {
          await p.setUrl(full, headers: headers);
        }
      }
      if (gen != _gen) return false;
      await p.setVolume(0);
      // Never await play(): its future completes when the song ENDS.
      p.play();
      unawaited(_ramp(gen, 0, volume, 900));
      final clip = (bed['clip'] as num?)?.toInt();
      if (clip != null && clip > 0) {
        _clip = Timer(Duration(seconds: clip), () {
          if (gen == _gen) stop();
        });
      }
      return true;
    } catch (_) {
      if (gen == _gen) _owner = null;
      return false;
    }
  }

  /// Fade out and stop ([owner] given → only if it's still theirs).
  static Future<void> stop({String? owner, int fadeMs = 1200}) async {
    if (owner != null && owner != _owner) return;
    final gen = ++_gen;
    _owner = null;
    _clip?.cancel();
    _clip = null;
    final p = _p;
    if (p == null || !p.playing) return;
    await _ramp(gen, p.volume, 0, fadeMs);
    if (gen == _gen) await p.pause();
  }

  static Future<void> _ramp(int gen, double from, double to, int ms) async {
    const steps = 12;
    for (var i = 1; i <= steps; i++) {
      await Future<void>.delayed(Duration(milliseconds: ms ~/ steps));
      final p = _p;
      if (gen != _gen || p == null) return;
      await p.setVolume(from + (to - from) * i / steps);
    }
  }
}

extension _ChatSongMemories on _ChatPageState {
  // ── The song of a day ──────────────────────────────────────────────────────

  static String _dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

  /// The song we listened to together on [iso]'s day (newest that day).
  String? _songOnDay(String iso) {
    if (_isGroup || iso.isEmpty) return null;
    final sig = _messages.length ^
        (_messages.isEmpty ? 0 : _messages.first['id'].hashCode);
    var memo = _songDaysMemo;
    if (memo == null || sig != _songDaysSig) {
      memo = <String, String>{};
      for (final m in _messages) {
        if ((m['message_type'] ?? '') != 'live' || m['is_deleted'] == true) {
          continue;
        }
        if ((m['content'] ?? '').toString().trim() != 'listened') continue;
        final t = (m['media_name'] ?? '').toString().trim();
        final d = _ts(m['timestamp']);
        if (t.isEmpty || d == null) continue;
        memo.putIfAbsent(_dayKey(d), () => t); // newest-first → newest wins
      }
      _songDaysMemo = memo;
      _songDaysSig = sig;
    }
    final d = _ts(iso);
    return d == null ? null : memo[_dayKey(d)];
  }

  void _playSongAgain(String title) {
    Haptics.selectionClick();
    final ok = playLoadedSongByTitle(title);
    showToast(
        context,
        ok
            ? 'Playing “$title” 💞'
            : '“$title” isn’t in your loaded songs yet',
        type: ToastType.info);
  }

  // ── "Listened together" keepsake ───────────────────────────────────────────

  Future<void> _listenedSheet(Map<String, dynamic> msg) async {
    final title = (msg['media_name'] ?? '').toString().trim();
    final secs = (msg['media_duration'] as num?)?.toInt() ?? 0;
    final sid = _defaultKeepSpaceId;
    final scheme = Theme.of(context).colorScheme;
    Haptics.selectionClick();
    final pick = await showAdaptiveSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: CircleAvatar(
                backgroundColor: scheme.primary.withValues(alpha: 0.14),
                child: Icon(Icons.headphones_rounded,
                    color: accentInk(scheme)),
              ),
              title: Text(title.isEmpty ? 'Listened together' : title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text(secs > 0
                  ? 'You two listened for ${_ChatPageState._fmtCallDur(secs)}'
                  : 'You two listened together'),
            ),
            const Divider(height: 8),
            if (title.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.play_arrow_rounded),
                title: const Text('Play it again'),
                onTap: () => Navigator.pop(c, 'play'),
              ),
            if (!_isGroup && widget.friendId > 0)
              ListTile(
                leading: const Icon(Icons.headphones_rounded),
                title: const Text('Listen together again'),
                onTap: () => Navigator.pop(c, 'again'),
              ),
            if (sid != null && title.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.queue_music_rounded),
                title: const Text('Add to Our Playlist'),
                onTap: () => Navigator.pop(c, 'playlist'),
              ),
            if (_canHarmony)
              ListTile(
                leading: const Icon(Icons.favorite_rounded),
                title: const Text('Keep as a moment'),
                onTap: () => Navigator.pop(c, 'keep'),
              ),
          ]),
        ),
      ),
    );
    if (!mounted || pick == null) return;
    switch (pick) {
      case 'play':
        _playSongAgain(title);
      case 'again':
        unawaited(_startListenTogether(presetTitle: title));
      case 'playlist':
        final res = await ApiService()
            .addTrack(sid!, title: title, source: 'listen_together');
        if (!mounted) return;
        if (res != null) spaceEventBus.value++;
        showToast(
            context,
            res != null ? 'Added to Our Playlist 🎵' : 'Could not add that',
            type: res != null ? ToastType.success : ToastType.error);
      case 'keep':
        unawaited(_keepsakeMessage(msg));
    }
  }

  // ── Song beds: under a voice note, or a good-night lullaby ─────────────────

  /// Our Space's "your song" with this partner, if there is one.
  String? get _yourSongTitle {
    final sid = _defaultKeepSpaceId;
    if (sid == null) return null;
    for (final s in _mySpaces) {
      if ((s['id'] as num?)?.toInt() != sid) continue;
      final ys = (s['stats'] as Map?)?['your_song'];
      final t = ys is Map ? (ys['title'] ?? '').toString().trim() : '';
      return t.isEmpty ? null : t;
    }
    return null;
  }

  /// A bed for [title] (default: your song, else the newest in Our
  /// Playlist), with the playlist's shared copy so their device can play it.
  Future<Map<String, dynamic>?> _ourSongBed({String? title, int? clip}) async {
    final sid = _defaultKeepSpaceId;
    if (sid == null) return null;
    final tracks = await ApiService().getPlaylist(sid);
    String norm(String s) =>
        s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    final want = norm(title ?? _yourSongTitle ?? '');
    Map<String, dynamic>? hit;
    for (final t in tracks) {
      if (want.isNotEmpty && norm('${t['title'] ?? ''}') == want) {
        hit = t;
        break;
      }
    }
    // No match → the newest song with a shared copy, else just the title.
    hit ??= tracks.firstWhere(
        (t) => '${t['audio_url'] ?? ''}'.isNotEmpty,
        orElse: () => tracks.isEmpty ? <String, dynamic>{} : tracks.first);
    final name = (hit['title'] ?? title ?? _yourSongTitle ?? '').toString();
    if (name.trim().isEmpty) return null;
    final url = (hit['audio_url'] ?? '').toString();
    return {
      'title': name.trim(),
      if (url.startsWith('/attachments/')) 'url': url,
      'clip': ?clip,
    };
  }

  /// Change the song under the voice note / the lullaby.
  Future<void> _pickBedSong() async {
    final sid = _defaultKeepSpaceId;
    final cur = _pendingBed;
    if (sid == null || cur == null) return;
    final tracks = await ApiService().getPlaylist(sid);
    if (!mounted) return;
    if (tracks.isEmpty) {
      showToast(context, 'Add songs to Our Playlist to choose one here',
          type: ToastType.info);
      return;
    }
    final lullaby = cur['kind'] == 'lullaby';
    final picked = await showAdaptiveSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(),
      builder: (c) => _alutaSheet(
        c,
        icon: lullaby ? Icons.bedtime_rounded : Icons.queue_music_rounded,
        title: 'Our Playlist',
        subtitle: lullaby
            ? 'Pick the lullaby — it plays softly as the heart opens'
            : 'Pick the song that plays softly under your voice',
        // Named, and pictured, the way my playlist shows them.
        children: [
          for (final (i, t) in tracks.indexed) ...[
            if (i > 0) const SizedBox(height: 6),
            Builder(builder: (_) {
              final (title, artist, local) =
                  sharedTrackNames(t, playlistNotifier.value);
              final scheme = Theme.of(c).colorScheme;
              final icon = Icon(Icons.music_note_rounded,
                  size: 18, color: accentInk(scheme));
              return _sheetRow(
                c,
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.md),
                  child: SizedBox(
                    width: 42,
                    height: 42,
                    child: ColoredBox(
                      color: scheme.primary.withValues(alpha: 0.12),
                      child: local == null
                          ? icon
                          : SongArt(
                              path: local,
                              title: title,
                              artist: artist,
                              size: 42,
                              fallback: icon),
                    ),
                  ),
                ),
                title: title,
                subtitle: artist,
                on: '${t['title']}' == cur['title'],
                onTap: () => Navigator.pop(c, t),
              );
            }),
          ],
        ],
      ),
    );
    if (picked == null || !mounted) return;
    final url = (picked['audio_url'] ?? '').toString();
    rebuildWith(() => _pendingBed = {
          'kind': cur['kind'],
          'title': '${picked['title'] ?? ''}'.trim(),
          if (url.startsWith('/attachments/')) 'url': url,
          'clip': ?cur['clip'],
        });
  }

  /// The bed a received message carries, or null.
  Map<String, dynamic>? _bedOf(Map<String, dynamic> msg) {
    final raw = msg['meta'];
    if (raw == null) return null;
    try {
      final m = raw is String ? jsonDecode(raw) : raw;
      final b = m is Map ? m['bed'] : null;
      return b is Map ? Map<String, dynamic>.from(b) : null;
    } catch (_) {
      return null;
    }
  }

  /// A good-night heart that carries a lullaby: play it softly as it opens.
  void _playLullaby(Map<String, dynamic> msg) {
    final bed = _bedOf(msg);
    if (bed == null) return;
    unawaited(_SongBed.play('lullaby-${msg['id']}', bed, volume: 0.35)
        .then((ok) {
      if (!ok || !mounted) return;
      final from = msg['sender_id']?.toString() == _myId
          ? 'Your'
          : '${_livePeerLabel.trim().split(RegExp(r'\s+')).first}’s';
      showToast(context, '🎶 $from lullaby — “${bed['title']}”',
          type: ToastType.info);
    }));
  }

  // ── Call moments ───────────────────────────────────────────────────────────

  /// The newest message, if it's a call log.
  Map<String, dynamic>? get _newestCall {
    if (_isGroup || _messages.isEmpty) return null;
    final m = _messages.first;
    if ((m['message_type'] ?? '') != 'call' || m['is_deleted'] == true) {
      return null;
    }
    return m;
  }

  /// Their call I missed in the last 12 hours (still the newest message).
  Map<String, dynamic>? get _missedCallToAnswer {
    final m = _newestCall;
    if (m == null || !_bondedDm) return null;
    if (_songChipsDone.contains('mc-${m['id']}')) return null;
    final secs = (m['media_duration'] as num?)?.toInt() ?? 0;
    if (secs > 0 || m['sender_id']?.toString() == _myId) return null;
    final d = _ts(m['timestamp']);
    if (d == null || DateTime.now().difference(d).inHours >= 12) return null;
    return m;
  }

  /// A call of 10+ minutes that just ended (within the half hour).
  Map<String, dynamic>? get _longCallJustEnded {
    final m = _newestCall;
    if (m == null || !_bondedDm) return null;
    if (_songChipsDone.contains('lc-${m['id']}')) return null;
    final secs = (m['media_duration'] as num?)?.toInt() ?? 0;
    if (secs < 600) return null;
    final d = _ts(m['timestamp']);
    if (d == null || DateTime.now().difference(d).inMinutes >= 30) return null;
    return m;
  }

  /// Missed call → record a voice note with our song softly underneath.
  Future<void> _startBedVoiceNote(Map<String, dynamic> call) async {
    _songChipsDone.add('mc-${call['id']}');
    final bed = await _ourSongBed();
    if (!mounted) return;
    if (bed == null) {
      showToast(context, 'Add a song to Our Playlist to send it under your voice',
          type: ToastType.info);
      return;
    }
    rebuildWith(() => _pendingBed = {'kind': 'voice', ...bed});
    await _startRecording();
  }

  /// The chips this file adds above the composer (ritual chip row).
  List<_SongChip> _songMemoryChips({required bool rituals}) {
    final out = <_SongChip>[];
    // A lullaby only means something while the heart is being written.
    final bed = (_pendingBed?['kind'] == 'lullaby' && !_heartMode)
        ? null
        : _pendingBed;
    if (bed != null) {
      final lullaby = bed['kind'] == 'lullaby';
      // The tidy name my playlist uses, not the raw file name.
      final (bt, _, _) = sharedTrackNames(bed, playlistNotifier.value);
      final t = _clip(bt, 32);
      out.add((
        icon: lullaby ? Icons.bedtime_rounded : Icons.music_note_rounded,
        label: lullaby
            ? 'Lullaby: “$t” plays as it opens'
            : '“$t” plays softly under your voice',
        onTap: _pickBedSong,
        onClose: () => rebuildWith(() => _pendingBed = null),
      ));
    }
    if (!rituals || bed != null || _isRecording || _heartMode) return out;
    final first = _livePeerLabel.trim().split(RegExp(r'\s+')).first;
    final missed = _missedCallToAnswer;
    if (missed != null) {
      out.add((
        icon: Icons.mic_rounded,
        label: 'Missed $first — leave a voice note with your song',
        onTap: () => _startBedVoiceNote(missed),
        onClose: () =>
            rebuildWith(() => _songChipsDone.add('mc-${missed['id']}')),
      ));
    }
    final long = _longCallJustEnded;
    if (long != null) {
      final song = _yourSongTitle;
      out.add((
        icon: Icons.headphones_rounded,
        label: song == null
            ? 'Lovely talk — play a song together?'
            : 'Lovely talk — play “${_clip(song, 24)}” together?',
        onTap: () {
          rebuildWith(() => _songChipsDone.add('lc-${long['id']}'));
          unawaited(_startListenTogether(presetTitle: song));
        },
        onClose: () =>
            rebuildWith(() => _songChipsDone.add('lc-${long['id']}')),
      ));
    }
    // "when can I see you?" → plan the day; the header counts down to it.
    final ask = _meetAsk;
    if (ask != null) {
      out.add((
        icon: Icons.event_rounded,
        label: 'Plan a date 💞',
        onTap: () => _planDate(ask),
        onClose: () =>
            rebuildWith(() => _songChipsDone.add('md-${ask['id']}')),
      ));
    }
    return out;
  }
}
