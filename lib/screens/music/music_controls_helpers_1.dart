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
                  Widget playerCol(double openT) => Padding(
                  padding: EdgeInsets.fromLTRB(22, 6 - 4 * openT.clamp(0.0, 1.0),
                      22, 14 - 8 * openT.clamp(0.0, 1.0)),
                  child: Column(
                    children: [
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
                      // Big art.
                      Expanded(
                        flex: 5,
                        child: Center(
                          child: LayoutBuilder(builder: (c, cc) {
                            final side = (cc.maxWidth < cc.maxHeight
                                    ? cc.maxWidth
                                    : cc.maxHeight)
                                .clamp(
                                    0.0, 360.0 - 210.0 * openT.clamp(0.0, 1.0))
                                .toDouble();
                            return AnimatedBuilder(
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
                          }),
                        ),
                      ),
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
                      // Synced-lyric ticker — shows only when the song has LRC
                      // timing; tap it to open the full lyrics sheet.
                      _syncedLyricLine(scheme, accent, false),
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
                              ),
                              const SizedBox(height: 6),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(_fmt(pos),
                                      style: TextStyle(
                                          color: scheme.onSurfaceVariant,
                                          fontSize: 12)),
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
                            _speedLabel(_speed),
                            () async {
                              await _showSpeedSheet(context);
                              if (mounted) setFull(() {});
                            },
                            accent: accent,
                            active: _speed != 1.0,
                          ),
                          _fsUtil(
                            scheme,
                            Icons.bedtime_rounded,
                            _sleepRemaining != null
                                ? _fmtSleep(_sleepRemaining!)
                                : 'Sleep',
                            () {
                              _showSleepTimerDialog();
                              setFull(() {});
                            },
                            accent: accent,
                            active: _sleepRemaining != null,
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
                );
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
                              child: Center(
                                child: ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxWidth: 560),
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
                  Text('$pos / $total',
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurfaceVariant)),
                const Spacer(),
                IconButton(
                  // Side panel collapses toward its own edge (chevron) rather
                  // than a close "X", which read as a duplicate of the desktop
                  // window's close button sitting right above it.
                  icon: Icon(
                      sidePanel
                          ? Icons.chevron_right_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      color: scheme.onSurfaceVariant),
                  tooltip: 'Hide queue',
                  onPressed: onClose,
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
                  ),
          ),
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
      child: Icon(
        isNow ? Icons.equalizer_rounded : Icons.music_note_rounded,
        size: 16,
        color: isNow
            ? scheme.onPrimary
            : Color.alphaBlend(
                accent.withValues(alpha: 0.5), scheme.onSurfaceVariant),
      ),
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
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.volume_up_rounded, size: 16, color: accent),
                )
              else
                GeniePopupMenuButton<String>(
                  tooltip: 'Track options',
                  padding: EdgeInsets.zero,
                  icon: Icon(Icons.more_vert_rounded,
                      size: 20, color: scheme.onSurfaceVariant),
                  onSelected: (v) {
                    if (v == 'next') {
                      _playNextInQueue(i, setFull);
                    } else if (v == 'remove') {
                      _removeFromQueue(i, setFull);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'next', child: Text('Play next')),
                    PopupMenuItem(
                        value: 'remove', child: Text('Remove from queue')),
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
    // ReorderableListView needs a stable key on each item.
    return KeyedSubtree(
      key: ValueKey('q_$path'),
      child: isNow ? KeyedSubtree(key: _nowQueueRowKey, child: row) : row,
    );
  }

  // Wrap the spinning full-screen disc with swipe/double-tap gestures and an
  // elapsed-progress ring hugging its edge. Same widget drives mobile + desktop.
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
        if (text.isEmpty) return const SizedBox(height: 0);
        return Padding(
          padding: const EdgeInsets.only(top: 8),
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
