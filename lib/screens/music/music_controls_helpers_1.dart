part of '../music_controls.dart';

// Split out of music_controls.dart (pure code movement, no behaviour change):
// helper methods of _MusicControlsState that don't call setState, moved into a
// private extension. A library `part`, so it shares the page's imports
// and reaches every private field and method.

extension _MusicControlsHelpers1 on _MusicControlsState {
  /// Keep the album disc rotating whenever audio is actually playing — from the
  /// LIVE player during a session, the local player otherwise. (Guarded so an
  /// already-spinning disc isn't restarted, which would jump its angle.)
  void _syncDiscSpin(bool playing) {
    if (playing) {
      if (!_discCtrl.isAnimating) _discCtrl.repeat();
    } else {
      _discCtrl.stop();
    }
  }

  String _liveTitle() {
    final live = _live;
    // Controller-tracked current title works for BOTH host and listener (the
    // listener has no local queue, so this is how its panel follows changes).
    if (live != null && live.currentTitle.isNotEmpty) {
      return live.currentTitle;
    }
    if (live != null &&
        live.currentIndex >= 0 &&
        live.currentIndex < live.queue.length) {
      return live.queue[live.currentIndex].title;
    }
    return activeLiveSession?.title ?? 'Live song';
  }

  // Keep the now-playing bar / footer / media notification showing the live
  // track (and its progress) while a session is active.
  void _pushLiveToAmbient() {
    final live = _live;
    if (!_liveActive || live == null) return;
    final playing = live.player.playing;
    ref.read(nowPlayingProvider.notifier).update(
        track: _liveTitle(), artist: 'Live', playing: playing);
    // Use the REAL song timeline (livePosition/liveDuration) so a listener who
    // joined a trimmed MP3 tail still shows the true position/duration, not the
    // partial buffer's.
    final dur = live.liveDuration;
    final pos = live.livePosition;
    playProgressNotifier.value = (dur != null && dur.inMilliseconds > 0)
        ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    playClockNotifier.value = PlayClock(pos, dur ?? Duration.zero);
    // Also drive the car / lock-screen media notification with the live track.
    audioHandler?.updateFromPlayer(
      id: 'live-session',
      title: _liveTitle(),
      artist: 'Live',
      playing: playing,
      position: pos,
      duration: dur,
    );
  }

  void _transportSeekBy(int seconds) {
    if (!_liveActive) return _seekBy(seconds);
    final c = _live!;
    final dur = c.player.duration ?? Duration.zero;
    var t = c.player.position + Duration(seconds: seconds);
    if (t < Duration.zero) t = Duration.zero;
    if (dur > Duration.zero && t > dur) t = dur;
    _transportSeek(t);
  }

  // Push the current track's favourite state to the ambient bar heart.
  void _syncFavoriteAmbient() {
    favoriteNotifier.value = _currentIndex >= 0 &&
        _currentIndex < _playlist.length &&
        _favorites.contains(_playlist[_currentIndex]);
  }

  // Re-apply saved equalizer settings so they affect playback from launch,
  // not only after the Equalizer screen is opened.
  Future<void> _restoreEqualizer() async {
    final eq = _equalizer;
    if (eq == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool('eq_enabled') ?? false;
      final params = await eq.parameters;
      await eq.setEnabled(enabled);
      await _loudness?.setEnabled(enabled);
      final saved = prefs.getStringList('eq_gains');
      final bass = prefs.getDouble('eq_bass') ?? 0;
      final loudV = prefs.getDouble('eq_loud') ?? 0;
      if (saved != null && saved.length == params.bands.length) {
        for (var i = 0; i < params.bands.length; i++) {
          final g = double.tryParse(saved[i]) ?? 0;
          final extra = i == 0 ? bass * (params.maxDecibels * 0.8) : 0.0;
          await params.bands[i].setGain(
              (g + extra).clamp(params.minDecibels, params.maxDecibels));
        }
      }
      await _loudness?.setTargetGain(loudV * 12);
    } catch (_) {}
  }

  // ── Setup ──────────────────────────────────────────────────────────────────

  Future<void> _configSession() async {
    final s = await AudioSession.instance;
    await s.configure(const AudioSessionConfiguration.music());
  }

  Future<void> _saveFavorites() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('music_favorites', _favorites.toList());
  }

  Future<void> _saveGroups() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('music_groups', jsonEncode(_groups));
    } catch (_) {}
  }

  Future<void> _saveStats() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('music_playcounts', jsonEncode(_playCounts));
      await p.setString('music_lastplayed', jsonEncode(_lastPlayed));
    } catch (_) {}
  }

  // Count a play + stamp the time (drives the smart lists).
  void _recordPlay(String path) {
    _playCounts[path] = (_playCounts[path] ?? 0) + 1;
    _lastPlayed[path] = DateTime.now().millisecondsSinceEpoch;
    _saveStats();
  }

  Future<void> _saveLyrics() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('music_lyrics', jsonEncode(_lyrics));
    } catch (_) {}
  }

  // Best-available lyrics for a song: the in-app text if set, else a `.lrc`/`.txt`
  // file sitting next to the audio file. Returns '' if none.
  String _lyricsRaw(String path) {
    final stored = _lyrics[path];
    if (stored != null && stored.trim().isNotEmpty) return stored;
    try {
      final dot = path.lastIndexOf('.');
      final base = dot > 0 ? path.substring(0, dot) : path;
      for (final ext in const ['.lrc', '.txt']) {
        final f = File('$base$ext');
        if (f.existsSync()) return f.readAsStringSync();
      }
      // Lyrics Aluta exported on Android (the song's folder wasn't writable).
      if (Platform.isAndroid) {
        final name = base.split(RegExp(r'[\\/]')).last;
        final f =
            File('/storage/emulated/0/Documents/Aluta Lyrics/$name.lrc');
        if (f.existsSync()) return f.readAsStringSync();
      }
    } catch (_) {}
    return '';
  }

  // ── Scope-aware playback (play/shuffle a filter, e.g. a group) ───────────────

  // Ordered LIBRARY indices for the current playback scope: the active queue
  // (a filtered/shuffled subset) mapped to indices, or the whole library.
  List<int> _scopeIndices() {
    final q = _activeQueue;
    if (q == null) {
      return List<int>.generate(_playlist.length, (i) => i);
    }
    final out = <int>[];
    for (final p in q) {
      final i = _playlist.indexOf(p);
      if (i >= 0) out.add(i);
    }
    return out;
  }

  // ── Player listeners ───────────────────────────────────────────────────────

  // Mirror the player's state into the media session (notification + car /
  // Bluetooth / lock-screen controls). No-op when there's no media session.
  void _pushMediaState({bool buffering = false}) {
    final h = audioHandler;
    if (h == null) return;
    final hasTrack = _currentIndex >= 0 && _currentIndex < _playlist.length;
    h.updateFromPlayer(
      id: hasTrack ? _playlist[_currentIndex] : 'aluta',
      title: _trackName,
      artist: _artistName,
      playing: _player.playing,
      position: _player.position,
      duration: _player.duration,
      buffering: buffering,
    );
  }

  // ── Playback ───────────────────────────────────────────────────────────────

  /// Build (once) the raw-path -> content-URI map from the device library, so
  /// playback can use MediaStore URIs instead of unreadable raw paths. The first
  /// device query was already primed at launch (PreloadScreen), so this is fast.
  Future<void> _ensureUriMap() async {
    if (!_isMobile || _uriMapBuilt) return;
    try {
      final songs = await SongLibrary.songs();
      for (final s in songs) {
        final d = s.data;
        final u = s.uri;
        if (d.isNotEmpty && u != null && u.isNotEmpty) _uriByPath[d] = u;
      }
      _uriMapBuilt = true;
    } catch (_) {
      // Leave _uriMapBuilt false so a later play retries; _play falls back to
      // setFilePath meanwhile.
    }
  }

  // Centre content of the spinning full-screen disc: the big music-note glyph,
  // or the embedded album art inset inside the orb so a ring of the disc shows
  // around it. (No spindle hub — in dark mode its dark fill showed as a "black
  // dot" over the note whenever a track had an id but no embedded cover.)
  // Centre art/note sized to [d] for the disc styles — album cover when we
  // have one, else the music-note fallback.
  Widget _discCenter(double d, [Color? noteColor]) {
    final note = Center(
      child: Icon(Icons.music_note_rounded,
          color: noteColor ?? Colors.white.withValues(alpha: 0.95),
          size: (d * 0.42).clamp(14.0, 96.0)),
    );
    if (_currentArtId == null || !_isMobile) {
      return SizedBox(width: d, height: d, child: note);
    }
    return SizedBox(
      width: d,
      height: d,
      child: ClipOval(
        child: QueryArtworkWidget(
          id: _currentArtId!,
          type: ArtworkType.AUDIO,
          artworkWidth: 360,
          artworkHeight: 360,
          artworkFit: BoxFit.cover,
          keepOldArtwork: true,
          nullArtworkWidget: note,
        ),
      ),
    );
  }


  Widget _fullPlayerBody() {
    // Persists across Consumer/StatefulBuilder rebuilds (declared in the method
    // scope, above the builders): whether the in-page queue panel is open.
    bool queueOpen = false;
    return Consumer(builder: (context, ref, _) {
      final scheme = Theme.of(context).colorScheme;
      final isDark = scheme.brightness == Brightness.dark;
      final np = ref.watch(nowPlayingProvider);
      final live = _liveActive;
      final hasTrack = _currentIndex >= 0 && _playlist.isNotEmpty;
      final title = np.track.isNotEmpty ? np.track : _trackName;
      final artist = np.artist;

      return StatefulBuilder(builder: (context, setFull) {
        final isFav = hasTrack && _favorites.contains(_playlist[_currentIndex]);
        // Drive the queue open/close animation and keep the toggle state in sync.
        void setQueue(bool open) {
          if (queueOpen == open) return;
          queueOpen = open;
          open ? _queueCtrl.forward() : _queueCtrl.reverse();
          if (open) {
            // Open the queue already scrolled to the playing track, not the top.
            WidgetsBinding.instance
                .addPostFrameCallback((_) => _scrollQueueToCurrent());
          }
          setFull(() {});
        }
        // Album-art adaptive accent: when artwork gave us a colour the whole
        // page (disc, ring, waveform, buttons) tints to it; else theme accent.
        return ValueListenableBuilder<Color?>(
          valueListenable: _artAccentVN,
          builder: (context, artAccent, _) {
            final accent = artAccent ?? scheme.primary;
            return Scaffold(
          backgroundColor: scheme.surface,
          body: Stack(
            children: [
              // Accent wash backdrop.
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color.alphaBlend(
                            accent.withValues(alpha: isDark ? 0.24 : 0.16),
                            scheme.surface),
                        scheme.surface,
                      ],
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: LayoutBuilder(builder: (lctx, lc) {
                  final wideQ = lc.maxWidth >= 720;
                  // Desktop-wide (queue closed): split — the disc + title on
                  // the left, the feel strip, lyric, waveform and controls on
                  // the right — instead of one narrow centred column.
                  Widget playerCol(double openT, {bool split = false}) {
                  final topBar = <Widget>[
                      // Top bar.
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.keyboard_arrow_down_rounded),
                            iconSize: 30,
                            color: scheme.onSurface,
                            tooltip: 'Minimise',
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                          const Spacer(),
                          Text('NOW PLAYING',
                              style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.6)),
                          const Spacer(),
                          // Switch the spinning glyph style.
                          IconButton(
                            icon: const Icon(Icons.album_rounded),
                            iconSize: 24,
                            color: scheme.onSurfaceVariant,
                            tooltip: 'Player style',
                            onPressed: () =>
                                showPlayerStyleSheet(context, accent: accent),
                          ),
                          // Privacy: share "listening now" with friends on/off.
                          PresenceShareButton(color: accent, size: 22),
                          IconButton(
                            icon: Icon(
                                isFav
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                color: isFav
                                    ? Colors.pinkAccent
                                    : scheme.onSurface),
                            tooltip: isFav ? 'Unlike' : 'Like',
                            onPressed: hasTrack
                                ? () {
                                    _toggleFavorite(_playlist[_currentIndex]);
                                    setFull(() {});
                                  }
                                : null,
                          ),
                        ],
                      ),
                  ];
                  final art = <Widget>[
                      // Big art.
                      Expanded(
                        flex: 5,
                        child: Center(
                          child: LayoutBuilder(builder: (c, cc) {
                            // Wide split: leave room either side for the
                            // peeking records and a line for their names.
                            // …and, when the song has lyrics, a three-line
                            // lyric strip under them that follows the song.
                            final lyrH = split && _hasLyricsNow ? 100.0 : 0.0;
                            final side = split
                                ? min(cc.maxWidth * 0.8,
                                        cc.maxHeight - 64 - lyrH)
                                    .clamp(0.0, 360.0)
                                    .toDouble()
                                : (cc.maxWidth < cc.maxHeight
                                        ? cc.maxWidth
                                        : cc.maxHeight)
                                    .clamp(0.0,
                                        360.0 - 210.0 * openT.clamp(0.0, 1.0))
                                    .toDouble();
                            final discW = AnimatedBuilder(
                              animation: PlayerStyleController.instance,
                              builder: (context, _) {
                                final dStyle =
                                    PlayerStyleController.instance.style;
                                return StreamBuilder<bool>(
                                  stream: _player.playingStream,
                                  initialData: _player.playing,
                                  builder: (ctx, psnap) {
                                    final discPlaying =
                                        _liveActive || (psnap.data ?? false);
                                    return _wrapDisc(
                                      side,
                                      accent,
                                      isDark,
                                      setFull,
                                      roundRing: dStyle.roundRing,
                                      onTap: dStyle == PlayerDiscStyle.orb
                                          ? () => PlayerStyleController.instance
                                              .toggleOrbDim()
                                          : null,
                                      child: PlayerDisc(
                                        style: dStyle,
                                        side: side,
                                        accent: accent,
                                        scheme: scheme,
                                        isDark: isDark,
                                        spin: _discCtrl,
                                        playing: discPlaying,
                                        dimmed: PlayerStyleController
                                            .instance.orbDimmed,
                                        artBuilder: (d, [c]) => _discCenter(d, c),
                                      ),
                                    );
                                  },
                                );
                              },
                            );
                            return split
                                ? _peekStage(discW, side, cc.maxWidth, accent,
                                    scheme, setFull,
                                    lyricH: lyrH)
                                : discW;
                          }),
                        ),
                      ),
                  ];
                  final titleBlock = <Widget>[
                      const SizedBox(height: 10),
                      // Title + artist.
                      // Always reserve the title line's height (28) so the
                      // disc above never nudges when a song loads. With nothing
                      // playing, show a soft hint instead of a blank gap.
                      SizedBox(
                        height: 28,
                        child: Align(
                          alignment: Alignment.center,
                          child: MarqueeText(
                            text: title.trim().isNotEmpty
                                ? title
                                : 'Nothing playing',
                            height: 28,
                            style: TextStyle(
                              color: title.trim().isNotEmpty
                                  ? scheme.onSurface
                                  : scheme.onSurfaceVariant.withAlpha(140),
                              fontSize: 21,
                              fontWeight: title.trim().isNotEmpty
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      // Reserve the artist slot even when a track has no
                      // artist, so the Expanded disc above keeps a constant
                      // height and doesn't snap/resize when the song changes.
                      const SizedBox(height: 4),
                      SizedBox(
                        height: 20,
                        child: artist.isNotEmpty
                            ? MarqueeText(
                                text: artist,
                                height: 20,
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 14,
                                ),
                              )
                            : null,
                      ),
                      // Dedicate this song ❤ — phones and desktop (web plays
                      // in-memory files, nothing to send). Slot always held.
                      if (!kIsWeb && !live && hasTrack)
                        SizedBox(
                          height: 44,
                          child: _dedicateTo.isEmpty
                              ? null
                              : _dedicateRow(scheme, accent),
                        ),
                  ];
                  final rest = <Widget>[
                      // Lyric ticker (exact or auto timing); tap it to open
                      // the full sheet. Wide split shows the 3-line strip
                      // under the record instead.
                      _syncedLyricLine(scheme, accent, split),
                      // How this song feels → who it's for. Folds away with
                      // the utilities when the queue opens.
                      if (!live && title.trim().isNotEmpty)
                        ClipRect(
                          child: Align(
                            alignment: Alignment.topCenter,
                            heightFactor:
                                (1.0 - openT.clamp(0.0, 1.0) * 1.8)
                                    .clamp(0.0, 1.0),
                            child: Opacity(
                              opacity: (1.0 - openT.clamp(0.0, 1.0) * 1.8)
                                  .clamp(0.0, 1.0),
                              child: Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Center(
                                  child: ConstrainedBox(
                                    constraints:
                                        const BoxConstraints(maxWidth: 420),
                                    child: SongFeelStrip(
                                      title: title,
                                      artist: artist,
                                      accent: accent,
                                      centered: true,
                                      // Leaving for a chat / Space: close
                                      // the full player first.
                                      onLeave: () =>
                                          Navigator.of(context).maybePop(),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      SizedBox(height: 18 - 10 * openT.clamp(0.0, 1.0)),
                      // Waveform, transport and utilities share one glassy
                      // card (same as the home player) instead of floating.
                      _controlsGlass(
                        scheme,
                        accent,
                        padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                          // Waveform + times (live via the position stream).
                          StreamBuilder<Duration>(
                            stream: _player.positionStream,
                            builder: (ctx, snap) {
                              final pos = live
                                  ? (_live?.player.position ?? Duration.zero)
                                  : (snap.data ?? _player.position);
                              final dur = live
                                  ? (_live?.player.duration ?? Duration.zero)
                                  : (_player.duration ?? Duration.zero);
                              final maxMs = dur.inMilliseconds > 0
                                  ? dur.inMilliseconds.toDouble()
                                  : 1.0;
                              final frac =
                                  (pos.inMilliseconds / maxMs).clamp(0.0, 1.0);
                              return Column(
                                children: [
                                  _WaveformSeekBar(
                                    fraction: frac,
                                    accent: accent,
                                    inactive: accent.withAlpha(48),
                                    enabled: true,
                                    seed: _trackName.hashCode ^ _currentIndex,
                                    onSeek: (f) => _transportSeek(Duration(
                                        milliseconds: (f * maxMs).round())),
                                    labelFor: (f) => _fmt(Duration(
                                        milliseconds: (f * maxMs).round())),
                                    markA: live ? null : _abFrac(_abA, maxMs),
                                    markB: live ? null : _abFrac(_abB, maxMs),
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(_fmt(pos),
                                          style: TextStyle(
                                              color: scheme.onSurfaceVariant,
                                              fontSize: 12,
                                              fontFeatures: const [
                                                FontFeature.tabularFigures()
                                              ])),
                                      if (!live)
                                        _abChip(scheme, accent,
                                            after: () => setFull(() {})),
                                      Text(_fmt(dur),
                                          style: TextStyle(
                                              color: scheme.onSurfaceVariant,
                                              fontSize: 12)),
                                    ],
                                  ),
                                ],
                              );
                            },
                          ),
                          SizedBox(height: 16 - 8 * openT.clamp(0.0, 1.0)),
                          // Primary transport.
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _CtrlChip(
                                icon: Icons.shuffle_rounded,
                                active: _effShuffle,
                                activeColor: Colors.green,
                                onTap: () {
                                  _toggleShuffle();
                                  setFull(() {});
                                },
                                tooltip: 'Shuffle',
                              ),
                              _CtrlBtn(
                                icon: Icons.skip_previous_rounded,
                                size: 34,
                                color: scheme.onSurface,
                                onTap: _transportPrev,
                                tooltip: 'Previous',
                              ),
                              StreamBuilder<PlayerState>(
                                stream: _player.playerStateStream,
                                builder: (ctx, snap) {
                                  final playing = live
                                      ? (_live?.player.playing ?? false)
                                      : (snap.data?.playing ?? _player.playing);
                                  return Tactile(child: GestureDetector(
                                    onTap: _transportPlayPause,
                                    child: Container(
                                      width: 76 - 14 * openT.clamp(0.0, 1.0),
                                      height: 76 - 14 * openT.clamp(0.0, 1.0),
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        gradient: LinearGradient(
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                          colors: [
                                            Color.lerp(
                                                accent, Colors.white, 0.22)!,
                                            accent,
                                          ],
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color:
                                                accent.withValues(alpha: 0.5),
                                            blurRadius: 22,
                                            spreadRadius: 2,
                                          ),
                                        ],
                                      ),
                                      child: Icon(
                                          playing
                                              ? Icons.pause_rounded
                                              : Icons.play_arrow_rounded,
                                          size: 40 - 8 * openT.clamp(0.0, 1.0),
                                          color: Colors.white),
                                    ),
                                  ));
                                },
                              ),
                              _CtrlBtn(
                                icon: Icons.skip_next_rounded,
                                size: 34,
                                color: scheme.onSurface,
                                onTap: _transportNext,
                                tooltip: 'Next',
                              ),
                              _CtrlChip(
                                icon: _effRepeatMode == 'one'
                                    ? Icons.repeat_one_rounded
                                    : Icons.repeat_rounded,
                                active: _effRepeatMode != 'off',
                                activeColor: accent,
                                onTap: () {
                                  _cycleRepeat();
                                  setFull(() {});
                                },
                                tooltip: 'Repeat',
                              ),
                            ],
                          ),
                          // Secondary utilities collapse smoothly as the queue
                          // opens, so the disc above resizes without a jump.
                          ClipRect(
                            child: Align(
                              alignment: Alignment.topCenter,
                              heightFactor:
                                  (1.0 - openT.clamp(0.0, 1.0) * 1.8)
                                      .clamp(0.0, 1.0),
                              child: Opacity(
                                opacity: (1.0 - openT.clamp(0.0, 1.0) * 1.8)
                                    .clamp(0.0, 1.0),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox(height: 14),
                                    Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _fsUtil(
                                scheme,
                                Icons.speed_rounded,
                                'Speed',
                                () async {
                                  await _showSpeedSheet(context);
                                  if (mounted) setFull(() {});
                                },
                                accent: accent,
                                active: _speed != 1.0,
                                badge: _speed != 1.0
                                    ? _speedLabel(_speed)
                                    : null,
                              ),
                              ValueListenableBuilder<Duration?>(
                                valueListenable: _sleepVN,
                                builder: (_, left, _) => _fsUtil(
                                  scheme,
                                  Icons.bedtime_rounded,
                                  'Sleep',
                                  () {
                                    _showSleepTimerDialog();
                                    setFull(() {});
                                  },
                                  accent: accent,
                                  active: left != null,
                                  badge: left == null
                                      ? null
                                      : (left.inSeconds < 60
                                          ? '${left.inSeconds}s'
                                          : '${(left.inSeconds / 60).ceil()} min'),
                                ),
                              ),
                              _fsUtil(scheme, Icons.lyrics_rounded, 'Lyrics',
                                  _openLyrics,
                                  accent: accent),
                              _fsUtil(
                                scheme,
                                Icons.queue_music_rounded,
                                'Queue',
                                () => setQueue(!queueOpen),
                                accent: accent,
                                active: queueOpen,
                              ),
                              _fsUtil(scheme, Icons.graphic_eq_rounded, 'EQ',
                                  _openEqualizer,
                                  accent: accent),
                            ],
                          ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          ],
                        ),
                      ),
                  ];
                  final pad = EdgeInsets.fromLTRB(22, 6 - 4 * openT.clamp(0.0, 1.0),
                      22, 14 - 8 * openT.clamp(0.0, 1.0));
                  if (split) {
                    return Padding(
                      padding: pad,
                      child: Column(
                        children: [
                          ...topBar,
                          Expanded(
                            child: Row(
                              children: [
                                // The disc alone, centred in its half.
                                Expanded(
                                  flex: 11,
                                  child: Column(children: art),
                                ),
                                const SizedBox(width: 48),
                                Expanded(
                                  flex: 10,
                                  child: Center(
                                    child: ConstrainedBox(
                                      constraints:
                                          const BoxConstraints(maxWidth: 560),
                                      child: SingleChildScrollView(
                                        // Title + artist lead the controls.
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [...titleBlock, ...rest],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return Padding(
                  padding: pad,
                  child: Column(
                    children: [...topBar, ...art, ...titleBlock, ...rest],
                  ),
                );
                  }
                  // Animated open/close: the side panel grows + fades in on
                  // wide screens (player reflows to the left), and the bottom
                  // sheet rises + fades on phones (player shrinks up) — no more
                  // hard on/off switch.
                  return AnimatedBuilder(
                    animation: _queueCtrl,
                    builder: (actx, _) {
                      final t = Curves.easeInOutCubic
                          .transform(_queueCtrl.value.clamp(0.0, 1.0));
                      // Keep the panel mounted while it's logically open too, so
                      // a drag that reaches the bottom doesn't unmount mid-gesture.
                      final showPanel = queueOpen || t > 0.001;
                      if (wideQ) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              // Roomy desktop: the split layout stays put
                              // whether the queue is open or not, so opening /
                              // closing it is one continuous motion — the
                              // queue grows + fades in at the right while the
                              // controls column glides over (and back). Only
                              // windows too narrow for split + queue use the
                              // centred column.
                              child: lc.maxWidth >= 1260
                                  ? Center(
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                            maxWidth: 1240),
                                        child: playerCol(0.0, split: true),
                                      ),
                                    )
                                  : Center(
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                            maxWidth: 560),
                                        child: playerCol(0.0),
                                      ),
                                    ),
                            ),
                            if (showPanel)
                              SizedBox(
                                width: 360 * t,
                                child: ClipRect(
                                  child: OverflowBox(
                                    minWidth: 360,
                                    maxWidth: 360,
                                    alignment: Alignment.centerLeft,
                                    child: Opacity(
                                      opacity: t,
                                      child: _inlineQueuePanel(
                                          scheme, accent, isDark, setFull,
                                          () => setQueue(false),
                                          sidePanel: true),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        );
                      }
                      final queueH = lc.maxHeight * 0.52;
                      return Column(
                        children: [
                          Expanded(child: playerCol(t)),
                          if (showPanel)
                            SizedBox(
                              height: t * queueH,
                              child: ClipRect(
                                child: OverflowBox(
                                  minHeight: queueH,
                                  maxHeight: queueH,
                                  alignment: Alignment.topCenter,
                                  child: Opacity(
                                    opacity: t,
                                    child: _inlineQueuePanel(
                                        scheme, accent, isDark, setFull,
                                        () => setQueue(false),
                                        sidePanel: false,
                                        onDrag: (dy) {
                                          _queueCtrl.value =
                                              (_queueCtrl.value - dy / queueH)
                                                  .clamp(0.0, 1.0);
                                        },
                                        onDragEnd: (vy) {
                                          final open = vy < -250
                                              ? true
                                              : (vy > 250
                                                  ? false
                                                  : _queueCtrl.value >= 0.5);
                                          queueOpen = open;
                                          open
                                              ? _queueCtrl.forward()
                                              : _queueCtrl.reverse();
                                          setFull(() {});
                                        }),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  );
                }),
              ),
            ],
          ),
            );
          },
        );
      });
    });
  }

  /// The in-page "Up next" queue — shown beside the now-playing view on wide
  /// screens, or below it (with a minimised player above) on phones, instead of
  /// popping back to the playlist drawer. Tapping a row jumps to that track and
  /// the current one stays highlighted.
  Widget _inlineQueuePanel(ColorScheme scheme, Color accent, bool isDark,
      StateSetter setFull, VoidCallback onClose,
      {required bool sidePanel,
      void Function(double dy)? onDrag,
      void Function(double vy)? onDragEnd}) {
    final total = _playlist.length;
    final pos = total == 0 ? 0 : (_currentIndex + 1).clamp(1, total);
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: sidePanel
            ? Border(
                left: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.4)))
            : null,
        borderRadius: sidePanel
            ? null
            : const BorderRadius.vertical(top: Radius.circular(22)),
        boxShadow: sidePanel
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.40 : 0.12),
                  blurRadius: 18,
                  offset: const Offset(0, -4),
                ),
              ],
      ),
      child: Column(
        children: [
          // Header + grabber — on mobile this whole strip is a drag handle:
          // swipe it down to dismiss the queue sheet. (Side panel: no drag.)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Interactive drag: pull the header to shrink/grow the queue in real
            // time (the disc above resizes with it); a flick settles it open or
            // closed. Side panel (desktop) has no drag.
            onVerticalDragUpdate:
                sidePanel ? null : (d) => onDrag?.call(d.delta.dy),
            onVerticalDragEnd: sidePanel
                ? null
                : (d) => onDragEnd?.call(d.primaryVelocity ?? 0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!sidePanel)
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 2),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
            child: Row(
              children: [
                Icon(Icons.queue_music_rounded, size: 18, color: accent),
                const SizedBox(width: 8),
                Text('Up next',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurface)),
                const SizedBox(width: 8),
                if (total > 0)
                  Flexible(
                    child: Builder(builder: (_) {
                      _loadQueueDurations(setFull);
                      final left = _queueTimeLeft();
                      return Text(
                          left == null ? '$pos / $total' : '$pos / $total · $left',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurfaceVariant));
                    }),
                  ),
                const Spacer(),
                // Same tactile chips as the playlist header.
                AlutaTapChip(
                  icon: Icons.my_location_rounded,
                  tooltip: 'Find the playing song',
                  size: 34,
                  onTap: total == 0 ? null : () => _scrollQueueToCurrent(),
                ),
                AlutaTapChip(
                  icon: Icons.shuffle_rounded,
                  tooltip: 'Shuffle what\'s up next',
                  size: 34,
                  onTap: total - (_currentIndex + 1) < 2
                      ? null
                      : () => _shuffleUpcoming(setFull),
                ),
                // Side panel collapses toward its own edge (chevron) rather
                // than a close "X", which read as a duplicate of the desktop
                // window's close button sitting right above it.
                AlutaTapChip(
                  icon: sidePanel
                      ? Icons.chevron_right_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  tooltip: 'Hide queue',
                  size: 34,
                  onTap: onClose,
                ),
              ],
            ),
          ),
              ],
            ),
          ),
          Divider(
              height: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
          Expanded(
            child: total == 0
                ? Center(
                    child: Text('Nothing queued yet',
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  )
                : ReorderableListView.builder(
                    scrollController: _queueScrollCtrl,
                    padding: const EdgeInsets.only(top: 4, bottom: 16),
                    buildDefaultDragHandles: false,
                    itemCount: total,
                    onReorderItem: (o, n) => _reorderQueue(o, n, setFull),
                    itemBuilder: (_, i) =>
                        _queueRow(i, scheme, accent, isDark, setFull),
                    // Quiet hint so the hidden gestures are discoverable.
                    footer: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.touch_app_rounded,
                              size: 14,
                              color: scheme.onSurfaceVariant
                                  .withValues(alpha: 0.7)),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              'Hold a song to share it · drag ≡ to reorder',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant
                                      .withValues(alpha: 0.8)),
                            ),
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

  PopupMenuItem<String> _queueMenuItem(
      String value, IconData icon, String label, ColorScheme scheme,
      {Color? color}) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 18, color: color ?? scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Text(label),
        ],
      ),
    );
  }

  Widget _queueRow(int i, ColorScheme scheme, Color accent, bool isDark,
      StateSetter setFull) {
    final path = _playlist[i];
    final isNow = i == _currentIndex;
    final title = metadataStore.title(path, _nameFromPath(path));
    final artist = metadataStore.artist(path, '');
    // Small accent-tinted disc per row (a glowing one for the playing track) —
    // built from the main player's own helpers, no overlay-state dependency.
    final leading = Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isNow
              ? [
                  Color.lerp(accent, Colors.white, 0.45)!,
                  accent,
                  Color.lerp(accent, Colors.black, 0.30)!,
                ]
              : [
                  Color.alphaBlend(
                      accent.withValues(alpha: isDark ? 0.22 : 0.12),
                      scheme.surface),
                  Color.alphaBlend(
                      accent.withValues(alpha: isDark ? 0.30 : 0.18),
                      scheme.surfaceContainerHighest),
                ],
        ),
        border: Border.all(
            color: isNow
                ? Colors.white.withValues(alpha: 0.35)
                : accent.withValues(alpha: isDark ? 0.28 : 0.18)),
        boxShadow: isNow
            ? [
                BoxShadow(
                    color: accent.withValues(alpha: 0.45),
                    blurRadius: 10,
                    spreadRadius: 1),
              ]
            : null,
      ),
      child: isNow
          ? PlayingBars(color: scheme.onPrimary, scale: 0.72)
          : Icon(Icons.music_note_rounded,
              size: 16,
              color: Color.alphaBlend(
                  accent.withValues(alpha: 0.5), scheme.onSurfaceVariant)),
    );
    final row = Material(
      color: isNow
          ? accent.withValues(alpha: isDark ? 0.20 : 0.12)
          : Colors.transparent,
      child: InkWell(
        onTap: () {
          if (!isNow) _play(i);
          setFull(() {});
        },
        // Hold a song to send it to friends — same share sheet (multi-friend
        // picker) as the playlist's long-press.
        onLongPress: () {
          HapticFeedback.mediumImpact();
          _shareSong(path);
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 2, 9),
          child: Row(
            children: [
              leading,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: isNow ? FontWeight.w700 : FontWeight.w500,
                        color: isNow ? accent : scheme.onSurface,
                      ),
                    ),
                    if (artist.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11.5, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
              if (isNow)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(Icons.volume_up_rounded, size: 16, color: accent),
                ),
              GeniePopupMenuButton<String>(
                tooltip: 'Track options',
                padding: EdgeInsets.zero,
                icon: Icon(Icons.more_vert_rounded,
                    size: 20, color: scheme.onSurfaceVariant),
                onSelected: (v) {
                  if (v == 'next') {
                    _playNextInQueue(i, setFull);
                  } else if (v == 'share') {
                    _shareSong(path);
                  } else if (v == 'partner') {
                    _sendSongToPartner(path);
                  } else if (v == 'remove') {
                    _removeFromQueue(i, setFull);
                  }
                },
                itemBuilder: (_) => [
                  if (!isNow && i != _currentIndex + 1)
                    _queueMenuItem('next', Icons.playlist_play_rounded,
                        'Play next', scheme),
                  if (_partnerId != null)
                    _queueMenuItem('partner', Icons.favorite_rounded,
                        'Send to my partner', scheme,
                        color: accent),
                  _queueMenuItem('share', Icons.send_rounded,
                      'Share with friends', scheme),
                  if (!isNow)
                    _queueMenuItem('remove', Icons.remove_circle_outline_rounded,
                        'Remove from queue', scheme),
                ],
              ),
              // Explicit drag handle: grab-and-drag to reorder — the same
              // gesture works with a finger (mobile) or a mouse (desktop).
              ReorderableDragStartListener(
                index: i,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8, left: 2),
                  child: Icon(Icons.drag_handle_rounded,
                      size: 20,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.7)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // After "shuffle up next" every upcoming row deals back in like a card
    // (a short, staggered slide + fade); a new key replays it per shuffle.
    final upcoming = i > _currentIndex;
    // Only right after a shuffle (rows scrolled in later just appear).
    final fresh = _shuffleAt != null &&
        DateTime.now().difference(_shuffleAt!) <
            const Duration(milliseconds: 900);
    final dealt = upcoming && fresh
        ? TweenAnimationBuilder<double>(
            key: ValueKey('deal_$_shuffleTick'),
            tween: Tween(begin: 0, end: 1),
            duration: Duration(
                milliseconds:
                    260 + ((i - _currentIndex - 1).clamp(0, 10) * 45)),
            curve: Curves.easeOutBack,
            builder: (_, v, child) {
              final lag = ((i - _currentIndex - 1).clamp(0, 10)) / 12;
              final t = ((v - lag) / (1 - lag)).clamp(0.0, 1.0);
              return Opacity(
                opacity: t.clamp(0.0, 1.0),
                child: Transform.translate(
                  offset: Offset((1 - t) * 60, 0),
                  child: Transform.rotate(
                      angle: (1 - t) * 0.06, child: child),
                ),
              );
            },
            child: row,
          )
        : row;
    // ReorderableListView needs a stable key on each item.
    return KeyedSubtree(
      key: ValueKey('q_$path'),
      child: isNow ? KeyedSubtree(key: _nowQueueRowKey, child: row) : dealt,
    );
  }

  // Wrap the spinning full-screen disc with swipe/double-tap gestures and an
  // elapsed-progress ring hugging its edge. Same widget drives mobile + desktop.
  /// Wide Now Playing: the previous and next records peek in from the edges
  /// (click to skip; ← / → too), with their names, and the place in the list
  /// underneath. Works for Listening Together too (the session's queue).
  Widget _peekStage(Widget disc, double side, double width, Color accent,
      ColorScheme scheme, StateSetter setFull, {double lyricH = 0}) {
    String? prevTitle, nextTitle, prevBy, nextBy;
    VoidCallback? goPrev, goNext;
    int place = 0, total = 0;
    final live = _liveActive;
    // Shuffle has no order to show: the peeks, names and dots step aside
    // (the stage keeps its size, so the record doesn't move when toggled).
    final shuffled = _effShuffle;
    if (live && !shuffled) {
      final c = _live!;
      final host = _isLiveHost;
      final titles = host
          ? [for (final t in c.queue) t.title]
          : List<String>.from(c.remoteQueueTitles);
      final by = host
          ? [for (final t in c.queue) t.contributor]
          : List<String?>.from(c.remoteQueueBy);
      final idx = host ? c.currentIndex : c.remoteIndex;
      total = titles.length;
      if (idx >= 0 && idx < total) {
        place = idx + 1;
        final all = c.repeatMode == 'all' && total > 1;
        final pIdx = idx > 0 ? idx - 1 : (all ? total - 1 : -1);
        final nIdx = idx + 1 < total ? idx + 1 : (all ? 0 : -1);
        if (pIdx >= 0) {
          prevTitle = titles[pIdx];
          prevBy = pIdx < by.length ? by[pIdx] : null;
          // Exact index (not "prev"): with repeat-all at the top, "prev"
          // would only restart the song, not go to the record shown.
          final to = pIdx;
          goPrev = () => host
              ? c.playIndex(to)
              : c.requestControl('play_index', index: to);
        }
        if (nIdx >= 0) {
          nextTitle = titles[nIdx];
          nextBy = nIdx < by.length ? by[nIdx] : null;
          final to = nIdx;
          goNext = () => host
              ? c.playIndex(to)
              : c.requestControl('play_index', index: to);
        }
      }
    } else if (!live &&
        !shuffled &&
        _currentIndex >= 0 &&
        _currentIndex < _playlist.length) {
      final scope = _scopeIndices();
      total = scope.length;
      place = scope.indexOf(_currentIndex) + 1;
      final pIdx = _peekPrevIndex();
      final nIdx = _peekNextIndex();
      if (pIdx != null) {
        final path = _playlist[pIdx];
        prevTitle = metadataStore.title(path, _nameFromPath(path));
        goPrev = () => _play(pIdx);
      }
      if (nIdx != null) {
        final path = _playlist[nIdx];
        nextTitle = metadataStore.title(path, _nameFromPath(path));
        goNext = () => _play(nIdx);
      }
    }
    final h = side + 64 + lyricH;
    Widget name(String? title, String? by, VoidCallback? go, bool left) =>
        Expanded(
          child: _PeekName(
            onTap: title == null ? null : go,
            alignEnd: !left,
            accent: accent,
            child: AnimatedOpacity(
            opacity: title == null ? 0 : 1,
            duration: const Duration(milliseconds: 220),
            child: Column(
              crossAxisAlignment:
                  left ? CrossAxisAlignment.start : CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title == null
                      ? ''
                      : (left ? '‹  $title' : '$title  ›'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: left ? TextAlign.left : TextAlign.right,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface.withAlpha(150)),
                ),
                if (by != null && by.isNotEmpty)
                  Text('added by $by',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, color: accent)),
              ],
            ),
          ),
          ),
        );

    // A window of up to five dots around the current song + "12 / 240".
    Widget dots() {
      if (total < 2 || _effShuffle) return const SizedBox.shrink();
      final n = total < 5 ? total : 5;
      var first = place - 1 - n ~/ 2;
      first = first.clamp(0, total - n).toInt();
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = first; i < first + n; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == place - 1 ? 16 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == place - 1 ? accent : accent.withAlpha(60),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text('$place / $total',
              style: TextStyle(
                  fontSize: 10.5,
                  color: scheme.onSurface.withAlpha(120),
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      );
    }

    return TypingSafeShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => goPrev?.call(),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            goNext?.call(),
      },
      child: Focus(
        autofocus: true,
        child: SizedBox(
          width: width,
          height: h,
          child: Column(
            children: [
              SizedBox(height: side, child: Center(child: disc)),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    name(prevTitle, prevBy, goPrev, true),
                    const SizedBox(width: 12),
                    dots(),
                    const SizedBox(width: 12),
                    name(nextTitle, nextBy, goNext, false),
                  ],
                ),
              ),
              if (lyricH > 0) _lyricStrip(scheme, accent, lyricH),
            ],
          ),
        ),
      ),
    );
  }

  /// Whether the current song has lyrics that can follow it (exact or auto).
  bool get _hasLyricsNow =>
      !_liveActive &&
      _currentIndex >= 0 &&
      _currentIndex < _playlist.length &&
      _syncedLyricLines(_playlist[_currentIndex]).isNotEmpty;

  /// Under the record on wide screens: the line being sung, big and in the
  /// accent, with the one before (fading out) and the one coming next.
  /// Lines glide up as the song moves; tap to open the full lyrics.
  Widget _lyricStrip(ColorScheme scheme, Color accent, double height) {
    final lines = _syncedLyricLines(_playlist[_currentIndex]);
    return StreamBuilder<Duration>(
      stream: _player.positionStream,
      builder: (ctx, snap) {
        final pos = snap.data ?? _player.position;
        var i = -1;
        for (var k = 0; k < lines.length; k++) {
          if (lines[k].$1 <= pos) {
            i = k;
          } else {
            break;
          }
        }
        String at(int k) => k >= 0 && k < lines.length ? lines[k].$2 : '';
        final cur = i < 0 ? '♪' : at(i);
        Widget line(String t, double size, FontWeight w, Color c, Key key) =>
            Text(t,
                key: key,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: size, fontWeight: w, color: c));
        return GestureDetector(
          onTap: _openLyrics,
          child: SizedBox(
            height: height,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 360),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween<Offset>(
                            begin: const Offset(0, 0.25), end: Offset.zero)
                        .animate(anim),
                    child: child,
                  ),
                ),
                child: Column(
                  key: ValueKey(i),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    line(at(i - 1), 12.5, FontWeight.w500,
                        scheme.onSurface.withAlpha(80), const ValueKey('p')),
                    const SizedBox(height: 6),
                    line(cur, 18, FontWeight.w800, accent, const ValueKey('c')),
                    const SizedBox(height: 6),
                    line(at(i + 1), 13.5, FontWeight.w600,
                        scheme.onSurface.withAlpha(140), const ValueKey('n')),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _wrapDisc(double side, Color accent, bool isDark, StateSetter setFull,
      {required Widget child, bool roundRing = true, VoidCallback? onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onDoubleTap: () {
        if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
          _toggleFavorite(_playlist[_currentIndex]);
          setFull(() {});
        }
      },
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v < -120) {
          _transportNext();
        } else if (v > 120) {
          _transportPrev();
        }
      },
      child: SizedBox(
        width: side,
        height: side,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            child,
            if (roundRing)
              Positioned.fill(
              child: IgnorePointer(
                child: StreamBuilder<Duration>(
                  stream: _player.positionStream,
                  builder: (ctx, snap) {
                    final pos = _liveActive
                        ? (_live?.player.position ?? Duration.zero)
                        : (snap.data ?? _player.position);
                    final dur = _liveActive
                        ? (_live?.player.duration ?? Duration.zero)
                        : (_player.duration ?? Duration.zero);
                    final frac = dur.inMilliseconds > 0
                        ? (pos.inMilliseconds / dur.inMilliseconds)
                            .clamp(0.0, 1.0)
                            .toDouble()
                        : 0.0;
                    return CustomPaint(
                      painter: _DiscRingPainter(
                          fraction: frac, accent: accent, isDark: isDark),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // One synced-lyric line that follows playback, under the title. Hidden when
  // the song has no LRC timing, and on the compact (queue-open mobile) layout.
  Widget _syncedLyricLine(ColorScheme scheme, Color accent, bool compact) {
    if (compact) return const SizedBox.shrink();
    if (_currentIndex < 0 || _currentIndex >= _playlist.length) {
      return const SizedBox.shrink();
    }
    final lines = _syncedLyricLines(_playlist[_currentIndex]);
    if (lines.isEmpty) return const SizedBox.shrink();
    return StreamBuilder<Duration>(
      stream: _player.positionStream,
      builder: (ctx, snap) {
        final pos = _liveActive
            ? (_live?.player.position ?? Duration.zero)
            : (snap.data ?? _player.position);
        var text = '';
        for (final l in lines) {
          if (l.$1 <= pos) {
            text = l.$2;
          } else {
            break;
          }
        }
        // A song WITH lyrics keeps one fixed line for them, empty between
        // lines — so the layout never jumps as lines come and go.
        if (text.isEmpty) return const SizedBox(height: 26);
        return Container(
          height: 26,
          alignment: Alignment.bottomCenter,
          child: GestureDetector(
            onTap: _openLyrics,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(
                text,
                key: ValueKey(text),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: accent,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
