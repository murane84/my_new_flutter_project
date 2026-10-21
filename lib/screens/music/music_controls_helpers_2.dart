part of '../music_controls.dart';

// Split out of music_controls.dart (pure code movement, no behaviour change):
// helper methods of _MusicControlsState that don't call setState, moved into a
// private extension. A library `part`, so it shares the page's imports
// and reaches every private field and method.

extension _MusicControlsHelpers2 on _MusicControlsState {
  // Derive a usable accent from the current track's embedded artwork (mobile
  // only — desktop/web have no MediaStore art, so it stays on the theme colour).
  Future<void> _resolveArtAccent(int id) async {
    if (!_isMobile) return;
    if (_artAccentForId == id && _artAccentVN.value != null) return;
    try {
      final bytes = await _audioQuery.queryArtwork(
        id,
        ArtworkType.AUDIO,
        format: ArtworkFormat.JPEG,
        size: 200,
      );
      if (bytes == null || bytes.isEmpty) return;
      final palette = await PaletteGenerator.fromImageProvider(
        MemoryImage(bytes),
        size: const Size(120, 120),
        maximumColorCount: 8,
      );
      final picked = palette.vibrantColor?.color ??
          palette.lightVibrantColor?.color ??
          palette.dominantColor?.color;
      if (picked == null) return;
      final accent = _makeUsableAccent(picked);
      if (!mounted) return;
      _artAccentForId = id;
      _artAccentVN.value = accent;
    } catch (_) {}
  }

  // Nudge an extracted artwork colour into a usable accent: enough saturation to
  // read as a colour, and a mid lightness so it works on light AND dark.
  Color _makeUsableAccent(Color c) {
    final hsl = HSLColor.fromColor(c);
    var sat = hsl.saturation;
    if (sat < 0.38) sat = 0.52;
    final lig = hsl.lightness.clamp(0.42, 0.60);
    return hsl.withSaturation(sat).withLightness(lig).toColor();
  }

  // ── In-page queue mutations (drag-reorder / remove / play-next) ──────────────
  // A manual reorder makes the list order authoritative, so we clear any active
  // scope and keep _currentIndex pinned to whatever is actually playing.
  // Jump the queue list so the currently-playing track is in view (a little
  // context above it) instead of resting at the top. Row heights vary slightly,
  // so this estimates — close enough to land the highlighted track on screen.
  void _scrollQueueToCurrent([int tries = 0]) {
    if (_currentIndex < 0) return;
    final attached =
        _queueScrollCtrl.hasClients && _queueScrollCtrl.positions.isNotEmpty;
    // Wait until the panel has finished revealing (its viewport is full height)
    // AND the list is attached — otherwise we'd centre against a half-open
    // viewport and land off. The reveal runs on _queueCtrl (0 -> 1).
    final ready = attached && _queueCtrl.value >= 0.995;
    if (!ready && tries < 28) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _scrollQueueToCurrent(tries + 1));
      return;
    }
    if (!attached) return;
    final pos = _queueScrollCtrl.position;
    // First jump roughly so the playing row is built near the viewport…
    const estRow = 58.0;
    final rough =
        (_currentIndex * estRow + estRow / 2 - pos.viewportDimension / 2)
            .clamp(0.0, pos.maxScrollExtent);
    _queueScrollCtrl.jumpTo(rough);
    // …then centre it precisely once it's laid out (alignment 0.5 = middle).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _nowQueueRowKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
      );
    });
  }

  Widget _fsUtil(ColorScheme scheme, IconData icon, String label,
      VoidCallback onTap,
      {bool active = false, required Color accent}) {
    final isDark = scheme.brightness == Brightness.dark;
    final c = active ? accent : scheme.onSurfaceVariant;
    return Tactile(child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active
                  ? accent.withValues(alpha: 0.14)
                  : scheme.surfaceContainerHighest
                      .withValues(alpha: isDark ? 0.5 : 0.7),
              border: Border.all(
                color: active
                    ? accent.withValues(alpha: 0.55)
                    : scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Icon(icon, size: 21, color: c),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: 62,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: c,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    ));
  }

  Future<void> _showSpeedSheet(BuildContext ctx) {
    final scheme = Theme.of(ctx).colorScheme;
    return showModalBottomSheet<void>(
      context: ctx,
      useRootNavigator: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (bctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Playback speed',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: scheme.onSurface)),
              ),
            ),
            for (final sp in _speeds)
              ListTile(
                dense: true,
                leading: Icon(
                    sp == _speed
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: sp == _speed
                        ? scheme.primary
                        : scheme.onSurfaceVariant),
                title: Text(_speedLabel(sp),
                    style: TextStyle(
                        color: scheme.onSurface,
                        fontWeight: sp == _speed
                            ? FontWeight.w700
                            : FontWeight.normal)),
                onTap: () {
                  _setSpeed(sp);
                  Navigator.of(bctx).pop();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Set the player source (content URI on mobile, path elsewhere) and start
  /// playback. Returns null on success, or an error string on failure ('format'
  /// for an unreadable/unsupported source, else the engine's message).
  Future<String?> _openSource(String path, {bool autoplay = true}) async {
    try {
      // A file that was moved or deleted since it was saved to the playlist
      // makes the native engine sit in "loading" forever instead of throwing.
      // Check the file is actually there first (fast-fail -> 'missing' so the
      // caller can prune + recover), and cap the load with a timeout as a
      // last-resort guard against any other stuck open.
      const loadTimeout = Duration(seconds: 15);
      if (_isMobile) {
        if (!_uriMapBuilt || !_uriByPath.containsKey(path)) {
          await _ensureUriMap();
        }
        final uri = _uriByPath[path];
        if (uri != null && uri.isNotEmpty) {
          await _player.setUrl(uri).timeout(loadTimeout);
        } else {
          if (!await _fileExists(path)) return 'missing';
          await _player.setFilePath(path).timeout(loadTimeout);
        }
      } else {
        if (!await _fileExists(path)) return 'missing';
        await _player.setFilePath(path).timeout(loadTimeout);
      }
      await _player.setVolume(_muted ? 0 : _volume);
      await _player.setSpeed(_speed);
      if (autoplay) await _player.play();
      return null;
    } on TimeoutException catch (_) {
      // Treat a stuck open as unplayable so the UI recovers instead of
      // spinning; _pruneIfMissing decides whether the file is actually gone.
      return 'missing';
    } on PlayerException catch (e) {
      return e.message ?? 'format';
    } catch (_) {
      return 'format';
    }
  }

  /// Whether [path] still exists on disk. Web has no real files, so assume yes.
  Future<bool> _fileExists(String path) async {
    if (kIsWeb) return true;
    try {
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }

  /// Mirror the current playlist to the global notifier so other features
  /// (e.g. starting a live session from loaded songs) can read it.
  void _publishPlaylist() {
    playlistNotifier.value = List<String>.unmodifiable(_playlist);
    _savePlaylist();
  }

  // Persist the loaded playlist so it survives a full app restart (no re-scan).
  Future<void> _savePlaylist() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList('music_playlist', _playlist);
    } catch (_) {}
  }

  /// Nudge the playback position by [seconds] (negative rewinds), clamped
  /// to the current track's bounds.
  void _seekBy(int seconds) {
    final dur = _player.duration ?? Duration.zero;
    var target = _player.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (dur > Duration.zero && target > dur) target = dur;
    _player.seek(target);
  }

  Widget _sleepOption(
    ColorScheme scheme, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary.withAlpha(30)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? scheme.primary.withAlpha(120)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? scheme.primary : scheme.onSurface,
                  ),
                ),
              ),
              if (selected)
                Icon(Icons.check_rounded, size: 18, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }

  // ── Overlays ───────────────────────────────────────────────────────────────

  void _openPlaylist() {
    if (_playlist.isEmpty) {
      _snack('No tracks — add music first');
      return;
    }
    _openPlaylistDrawer();
  }

  // Restart the idle countdown whenever the user touches the control.
  void _armVolumeHide() {
    _volumeHideTimer?.cancel();
    _volumeHideTimer =
        Timer(const Duration(milliseconds: 1500), _closeVolume);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _nameFromPath(String path) {
    final sep = Platform.pathSeparator;
    final name = path.contains(sep)
        ? path.substring(path.lastIndexOf(sep) + 1)
        : path.contains('/')
            ? path.substring(path.lastIndexOf('/') + 1)
            : path;
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    return _cleanTrackName(base);
  }

  String _fmt(Duration d) {
    final m = NumberFormat('00').format(d.inMinutes.remainder(60));
    final s = NumberFormat('00').format(d.inSeconds.remainder(60));
    return '$m:$s';
  }

  String _fmtSleep(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
  }

  void _snack(String msg, {bool isError = false}) {
    if (!mounted) return;
    showToast(context, msg,
        type: isError ? ToastType.error : ToastType.info);
  }

  Widget _buildMain(
      BuildContext context, ColorScheme scheme, bool isDark) {
    final accent = scheme.primary;
    final onSurface = scheme.onSurface;

    // When a live session is active the panel becomes its console: it shows
    // and drives the LIVE track instead of the local library.
    final live = _liveActive;
    final lc = _live;
    final isPlaying =
        live ? (lc?.player.playing ?? false) : _player.playing;
    final hasTrack = _currentIndex >= 0 && _playlist.isNotEmpty; // local
    final controlsOn = live || hasTrack;
    final position =
        live ? (lc?.player.position ?? Duration.zero) : _player.position;
    final duration = live
        ? (lc?.player.duration ?? Duration.zero)
        : (_player.duration ?? Duration.zero);
    final buffering = live
        ? (lc?.player.processingState == ProcessingState.buffering ||
            lc?.player.processingState == ProcessingState.loading)
        : (_player.processingState == ProcessingState.buffering ||
            _player.processingState == ProcessingState.loading);
    final sliderMax = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    final sliderVal =
        position.inMilliseconds.toDouble().clamp(0.0, sliderMax);
    final isFav =
        hasTrack && _favorites.contains(_playlist[_currentIndex]);
    final displayTitle =
        live ? _liveTitle() : (hasTrack ? _trackName : 'No track loaded');
    final displayArtist = live
        ? 'Live · ${_isLiveHost ? 'streaming to' : 'with'} ${activeLiveSession?.peerName ?? ''}'
        : _artistName;

    return LayoutBuilder(builder: (context, box) {
      final isNarrow = box.maxWidth < 220;

      return Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding:
                  EdgeInsets.fromLTRB(16, 14, 16, isNarrow ? 6 : 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [

            // ── Disc + track info card ────────────────────────────────
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                // Subtle brand-tinted wash: a whisper of red in the corner that
                // fades out — modern and "alive" without overpowering the text.
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isDark
                      ? [
                          accent.withAlpha(38),
                          Colors.white.withAlpha(10),
                        ]
                      : [
                          accent.withAlpha(28),
                          accent.withAlpha(8),
                        ],
                ),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withAlpha(20)
                      : accent.withAlpha(40),
                ),
              ),
              child: Row(
                children: [
                  // Spinning disc — swipe ←/→ to skip, double-tap to like,
                  // swipe up to open the queue.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    // Tap the art to open the immersive full-screen player.
                    onTap: (hasTrack || live)
                        ? _openFullPlayer
                        : _openOrScanPlaylist,
                    onDoubleTap: (!live && hasTrack)
                        ? () => _toggleFavorite(_playlist[_currentIndex])
                        : null,
                    onHorizontalDragEnd: controlsOn
                        ? (d) {
                            final v = d.primaryVelocity ?? 0;
                            if (v < -120) {
                              _transportNext();
                            } else if (v > 120) {
                              _transportPrev();
                            }
                          }
                        : null,
                    onVerticalDragEnd: (d) {
                      if ((d.primaryVelocity ?? 0) < -200) {
                        _openOrScanPlaylist();
                      }
                    },
                    child: AnimatedBuilder(
                    animation: PlayerStyleController.instance,
                    builder: (context, _) {
                      final mScheme = Theme.of(context).colorScheme;
                      return PlayerDisc(
                        style: PlayerStyleController.instance.style,
                        side: isNarrow ? 58.0 : 76.0,
                        accent: accent,
                        scheme: mScheme,
                        isDark: isDark,
                        spin: _discCtrl,
                        playing: isPlaying,
                        dimmed: PlayerStyleController.instance.orbDimmed,
                        artBuilder: (d, [c]) => _discCenter(d, c),
                      );
                    },
                  ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        MarqueeText(
                          text: displayTitle,
                          height: isNarrow ? 17 : 19,
                          style: TextStyle(
                            color: onSurface,
                            fontSize: isNarrow ? 12 : 13.5,
                            fontWeight: FontWeight.bold,
                            height: 1.3,
                          ),
                        ),
                        if (displayArtist.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          // Marquee (not ellipsis) so a long live line like
                          // "Live · streaming to <name>" scrolls fully instead
                          // of being cut off.
                          MarqueeText(
                            text: displayArtist,
                            height: 15,
                            style: TextStyle(
                                color: live
                                    ? accent
                                    : onSurface.withAlpha(160),
                                fontWeight: live
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                                fontSize: 11.5),
                          ),
                        ],
                        if (live) ...[
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: accent,
                                ),
                              ),
                              const SizedBox(width: 5),
                              Text('LIVE',
                                  style: TextStyle(
                                      color: accent,
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1)),
                            ],
                          ),
                        ] else if (_playlist.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            '${_currentIndex + 1} / ${_playlist.length}',
                            style: TextStyle(
                                color: onSurface.withAlpha(100),
                                fontSize: 10.5),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  // Stacked on the card's right edge: the listening-now share
                  // toggle on top (moved off the panel header, where tapping it
                  // minimised the player), the favourite heart below.
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PresenceShareButton(color: accent, size: 20),
                      if (!live && hasTrack) ...[
                        // Clear gap + a padded hit area so the heart and the
                        // broadcast toggle above it are distinct tap targets.
                        const SizedBox(height: 10),
                        BounceTap(
                          onTap: () =>
                              _toggleFavorite(_playlist[_currentIndex]),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 200),
                              child: Icon(
                                isFav
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                key: ValueKey(isFav),
                                color: isFav
                                    ? Colors.pinkAccent
                                    : onSurface.withAlpha(130),
                                size: 24,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),

            // How this song feels → who it's for (music ⇄ chat harmony).
            if (!live && hasTrack)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: SongFeelStrip(
                    title: _trackName, artist: _artistName, accent: accent),
              ),

            const SizedBox(height: 20),

            // ── Position bar — accent colour, taller thumb ────────────
            Row(
              children: [
                Text(_fmt(position),
                    style: TextStyle(
                        color: onSurface.withAlpha(150), fontSize: 11)),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    // A waveform that IS the seek control: drag/tap to scrub,
                    // bars fill with the accent up to the play head, with a
                    // time bubble following the finger.
                    child: _WaveformSeekBar(
                      fraction: sliderMax > 0 ? sliderVal / sliderMax : 0.0,
                      accent: accent,
                      inactive: accent.withAlpha(48),
                      enabled: controlsOn,
                      seed: _trackName.hashCode ^ _currentIndex,
                      onSeek: (f) => _transportSeek(
                          Duration(milliseconds: (f * sliderMax).round())),
                      labelFor: (f) =>
                          _fmt(Duration(milliseconds: (f * sliderMax).round())),
                    ),
                  ),
                ),
                Text(_fmt(duration),
                    style: TextStyle(
                        color: onSurface.withAlpha(150), fontSize: 11)),
              ],
            ),

            const SizedBox(height: 12),

            // ── Transport: shuffle · prev · −10 · play · +10 · next · repeat
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _CtrlChip(
                    icon: Icons.shuffle_rounded,
                    active: _effShuffle,
                    activeColor: Colors.green,
                    onTap: _toggleShuffle,
                    tooltip: _liveActive ? 'Shuffle · session' : 'Shuffle',
                  ),
                  const SizedBox(width: 14),
                  _CtrlBtn(
                    icon: Icons.skip_previous_rounded,
                    size: 32,
                    color: controlsOn ? onSurface : onSurface.withAlpha(40),
                    onTap: controlsOn ? _transportPrev : null,
                    tooltip: 'Previous',
                  ),
                  const SizedBox(width: 8),
                  _CtrlBtn(
                    icon: Icons.replay_10_rounded,
                    size: 28,
                    color: controlsOn ? onSurface : onSurface.withAlpha(40),
                    onTap: controlsOn ? () => _transportSeekBy(-10) : null,
                    tooltip: 'Back 10s',
                  ),
                  const SizedBox(width: 14),
                  Tactile(child: GestureDetector(
                    onTap: _transportPlayPause,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 68,
                      height: 68,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        // Glossy red gradient gives the transport a lively,
                        // "spark" feel instead of a flat maroon disc.
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color.lerp(accent, Colors.white, 0.22)!,
                            accent,
                            Color.lerp(accent, Colors.black, 0.14)!,
                          ],
                          stops: const [0.0, 0.55, 1.0],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: accent
                                .withAlpha(isPlaying ? 150 : 70),
                            blurRadius: isPlaying ? 24 : 12,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: buffering
                          ? const Padding(
                              padding: EdgeInsets.all(18),
                              child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2.5),
                            )
                          : Icon(
                              isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              size: 40,
                              color: Colors.white,
                            ),
                    ),
                  )),
                  const SizedBox(width: 14),
                  _CtrlBtn(
                    icon: Icons.forward_10_rounded,
                    size: 28,
                    color: controlsOn ? onSurface : onSurface.withAlpha(40),
                    onTap: controlsOn ? () => _transportSeekBy(10) : null,
                    tooltip: 'Forward 10s',
                  ),
                  const SizedBox(width: 8),
                  _CtrlBtn(
                    icon: Icons.skip_next_rounded,
                    size: 32,
                    color: controlsOn ? onSurface : onSurface.withAlpha(40),
                    onTap: controlsOn ? _transportNext : null,
                    tooltip: 'Next',
                  ),
                  const SizedBox(width: 14),
                  _CtrlChip(
                    icon: _effRepeatMode == 'one'
                        ? Icons.repeat_one_rounded
                        : Icons.repeat_rounded,
                    active: _effRepeatMode != 'off',
                    activeColor: accent,
                    onTap: _cycleRepeat,
                    tooltip: _effRepeatMode == 'one'
                        ? (_liveActive ? 'Repeat One · session' : 'Repeat One')
                        : _effRepeatMode == 'all'
                            ? (_liveActive ? 'Repeat All · session' : 'Repeat All')
                            : 'Repeat Off',
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ── Utilities ─────────────────────────────────────────────
            // Shuffle & repeat now live in the transport row, so this row
            // is reserved for the less-frequent library actions. Each one
            // is a labelled tile, evenly spaced to breathe across the width.
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _utility(
                  scheme,
                  onSurface,
                  // "Add" folded in here: first tap scans the device, later
                  // taps just open the playlist.
                  icon: Icons.queue_music_rounded,
                  label: 'Playlist',
                  color: accent,
                  active: _showPlaylist || _playlist.isNotEmpty,
                  badge: _playlist.isNotEmpty ? '${_playlist.length}' : null,
                  onTap: _openOrScanPlaylist,
                ),
                _utility(
                  scheme,
                  onSurface,
                  // Snooze "Zᶻ" glyph — deliberately distinct from the crescent
                  // moon used by the dark-theme toggle in the app header.
                  icon: Icons.snooze_rounded,
                  label: 'Sleep',
                  color: Colors.indigo,
                  active: _sleepRemaining != null,
                  badge: _sleepRemaining != null
                      ? _fmtSleep(_sleepRemaining!)
                      : null,
                  onTap: _showSleepTimerDialog,
                ),
                _utility(
                  scheme,
                  onSurface,
                  icon: Icons.graphic_eq_rounded,
                  label: 'Equalizer',
                  color: accent,
                  onTap: _openEqualizer,
                ),
                _utility(
                  scheme,
                  onSurface,
                  icon: Icons.lyrics_rounded,
                  label: 'Lyrics',
                  color: accent,
                  onTap: _openLyrics,
                ),
              ],
            ),

            const SizedBox(height: 18),
            Divider(height: 1, color: scheme.outlineVariant.withAlpha(50)),
            const SizedBox(height: 14),

            // ── Volume (left ~45%) + Speed button (right) on same row ────
            Row(
              children: [
                // Volume — tap to reveal a popup slider that auto-hides. Keeps
                // the row clean and stops the volume track from clashing with
                // the accent seek bar above it.
                CompositedTransformTarget(
                  link: _volumeLink,
                  child: GestureDetector(
                    onTap: _openVolume,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        // While the popup is open it sits over this spot, so the
                        // button box/icon fade out — the user sees one icon only.
                        gradient: (_showVolume || _muted)
                            ? null
                            : LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  Color.alphaBlend(
                                    scheme.primary.withAlpha(
                                        scheme.brightness == Brightness.dark
                                            ? 26
                                            : 18),
                                    scheme.surface,
                                  ),
                                  Color.alphaBlend(
                                    scheme.primary.withAlpha(
                                        scheme.brightness == Brightness.dark
                                            ? 46
                                            : 33),
                                    scheme.surfaceContainerHighest,
                                  ),
                                ],
                              ),
                        color: _showVolume
                            ? Colors.transparent
                            : (_muted ? scheme.error.withAlpha(28) : null),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _showVolume
                              ? Colors.transparent
                              : (_muted
                                  ? scheme.error.withAlpha(90)
                                  : scheme.primary.withAlpha(
                                      scheme.brightness == Brightness.dark
                                          ? 80
                                          : 60)),
                        ),
                      ),
                      child: Icon(
                        _muted || _volume == 0
                            ? Icons.volume_off_rounded
                            : _volume < 0.5
                                ? Icons.volume_down_rounded
                                : Icons.volume_up_rounded,
                        size: 18,
                        color: _showVolume
                            ? Colors.transparent
                            : (_muted
                                ? scheme.error
                                : Color.alphaBlend(
                                    scheme.primary.withAlpha(70),
                                    onSurface.withAlpha(190),
                                  )),
                      ),
                    ),
                  ),
                ),
                const Spacer(),

                // ── Identify song (Shazam-style) — centred between the volume
                // and speed controls. Listens via the mic and names the song.
                // Uses an "ear/listen" icon so it never reads like the Equalizer
                // (which is graphic-eq bars). ──
                Tooltip(
                  message: 'Identify song',
                  child: GestureDetector(
                    onTap: () => showSongIdentifier(context),
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: accent.withAlpha(28),
                        shape: BoxShape.circle,
                        border: Border.all(color: accent.withAlpha(120)),
                      ),
                      child: Icon(Icons.hearing_rounded, size: 20, color: accent),
                    ),
                  ),
                ),
                const Spacer(),

                const SizedBox(width: 10),

                // Sleep remaining (compact, inline)
                if (_sleepRemaining != null) ...[
                  Icon(Icons.timer_outlined,
                      size: 11, color: Colors.indigo.withAlpha(200)),
                  const SizedBox(width: 3),
                  Text(
                    _fmtSleep(_sleepRemaining!),
                    style: TextStyle(
                        fontSize: 10, color: Colors.indigo.withAlpha(200)),
                  ),
                  GestureDetector(
                    onTap: () => _setSleepTimer(null),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(Icons.close,
                          size: 11, color: onSurface.withAlpha(110)),
                    ),
                  ),
                ],

                // Speed button — anchored right so popup scales from here
                GestureDetector(
                  onTap: _toggleSpeedPanel,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 11, vertical: 7),
                    decoration: BoxDecoration(
                      gradient: _showSpeedPanel
                          ? null
                          : LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Color.alphaBlend(
                                  scheme.primary.withAlpha(
                                      scheme.brightness == Brightness.dark
                                          ? 26
                                          : 18),
                                  scheme.surface,
                                ),
                                Color.alphaBlend(
                                  scheme.primary.withAlpha(
                                      scheme.brightness == Brightness.dark
                                          ? 46
                                          : 33),
                                  scheme.surfaceContainerHighest,
                                ),
                              ],
                            ),
                      color: _showSpeedPanel ? accent.withAlpha(30) : null,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: _showSpeedPanel
                            ? accent
                            : scheme.primary.withAlpha(
                                scheme.brightness == Brightness.dark
                                    ? 80
                                    : 60),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.speed_rounded,
                            size: 14,
                            color: _showSpeedPanel
                                ? accent
                                : Color.alphaBlend(
                                    scheme.primary.withAlpha(80),
                                    onSurface.withAlpha(175),
                                  )),
                        const SizedBox(width: 4),
                        Text(
                          _speedLabel(_speed),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: _showSpeedPanel
                                ? accent
                                : Color.alphaBlend(
                                    scheme.primary.withAlpha(80),
                                    onSurface.withAlpha(185),
                                  ),
                          ),
                        ),
                        const SizedBox(width: 3),
                        Icon(
                          _showSpeedPanel
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 13,
                          color: _showSpeedPanel
                              ? accent
                              : onSurface.withAlpha(120),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),

                ],
              ),
            ),
          ),
          // Base motif — the soft dancing equalizer — is now a raised 3D
          // button: tapping it opens the full Now Playing page, a second way in
          // alongside tapping the spinning disc.
          Padding(
            padding: EdgeInsets.only(bottom: isNarrow ? 8 : 14, top: 2),
            child: Center(
              child: Tooltip(
                message: 'Open Now Playing',
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: (hasTrack || live) ? _openFullPlayer : null,
                    borderRadius: BorderRadius.circular(16),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: EdgeInsets.symmetric(
                          horizontal: isNarrow ? 14 : 20, vertical: 5),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: isDark
                              ? [
                                  Color.alphaBlend(
                                      accent.withValues(alpha: 0.12),
                                      scheme.surfaceContainerHighest),
                                  Color.alphaBlend(
                                      accent.withValues(alpha: 0.05),
                                      scheme.surfaceContainerHigh),
                                ]
                              : [
                                  Color.alphaBlend(
                                      accent.withValues(alpha: 0.05),
                                      Colors.white),
                                  Color.alphaBlend(
                                      accent.withValues(alpha: 0.10),
                                      scheme.surface),
                                ],
                        ),
                        border: Border.all(
                            color: accent.withValues(
                                alpha: isDark ? 0.22 : 0.16)),
                        boxShadow: [
                          // Accent lift — glows a touch brighter while playing.
                          BoxShadow(
                            color: accent.withValues(
                                alpha: isPlaying
                                    ? (isDark ? 0.20 : 0.22)
                                    : (isDark ? 0.10 : 0.14)),
                            blurRadius: isPlaying ? 16 : 10,
                            offset: const Offset(0, 5),
                          ),
                          // Tight contact shadow grounds the raised pill.
                          BoxShadow(
                            color: Colors.black
                                .withValues(alpha: isDark ? 0.30 : 0.06),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _MiniEqualizer(active: isPlaying, color: accent),
                          const SizedBox(width: 8),
                          Icon(Icons.keyboard_arrow_up_rounded,
                              size: 16,
                              color: accent.withValues(alpha: 0.65)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    });
  }

  /// A labelled utility tile — icon in a soft rounded chip with a caption
  /// underneath, and an optional corner badge (playlist count / sleep time).
  Widget _utility(
    ColorScheme scheme,
    Color onSurface, {
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
    bool active = false,
    String? badge,
  }) {
    return Tactile(child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  gradient: active
                      ? null
                      : LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          // Idle library tiles pick up the same faint accent
                          // wash as the transport chips so the whole panel
                          // reads as one energetic, themed surface.
                          colors: [
                            Color.alphaBlend(
                              scheme.primary.withAlpha(
                                  scheme.brightness == Brightness.dark
                                      ? 26
                                      : 18),
                              scheme.surface,
                            ),
                            Color.alphaBlend(
                              scheme.primary.withAlpha(
                                  scheme.brightness == Brightness.dark
                                      ? 46
                                      : 33),
                              scheme.surfaceContainerHighest,
                            ),
                          ],
                        ),
                  color: active ? color.withAlpha(38) : null,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: active
                        ? color.withAlpha(150)
                        : scheme.primary.withAlpha(
                            scheme.brightness == Brightness.dark ? 80 : 60),
                  ),
                  boxShadow: active
                      ? null
                      : [
                          BoxShadow(
                            color: scheme.primary.withAlpha(
                                scheme.brightness == Brightness.dark ? 46 : 30),
                            blurRadius: 7,
                            offset: const Offset(0, 3),
                          ),
                        ],
                ),
                child: Icon(
                  icon,
                  size: 21,
                  color: active
                      ? color
                      : Color.alphaBlend(
                          scheme.primary.withAlpha(80),
                          onSurface.withAlpha(200),
                        ),
                ),
              ),
              if (badge != null)
                Positioned(
                  top: -5,
                  right: -5,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: scheme.surface, width: 1.5),
                    ),
                    child: Text(
                      badge,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 8.5,
                        fontWeight: FontWeight.bold,
                        height: 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
              color: active ? color : onSurface.withAlpha(160),
            ),
          ),
        ],
      ),
    ));
  }
}
