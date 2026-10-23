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
      _appliedVol = -1; // new source: re-apply the faded level
      _edgeFade = 0.2;
      _applyVolume();
      await _player.setSpeed(_speed);
      // play() completes at track END on Android — never await it.
      if (autoplay) unawaited(_player.play());
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

      // Room for everything → the controls live together in one glossy
      // card pinned to the bottom; a short panel keeps scrolling instead.
      final tall = box.maxHeight >= 480;
      final controlsBody = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
            // ── Position bar — accent colour, taller thumb ────────────
            Row(
              children: [
                SizedBox(
                  width: 40,
                  child: Text(_fmt(position),
                      textAlign: TextAlign.left,
                      maxLines: 1,
                      style: TextStyle(
                          color: onSurface.withAlpha(150),
                          fontSize: 11,
                          // Same-width digits: the clock ticking no longer
                          // nudges the waveform sideways every second.
                          fontFeatures: const [FontFeature.tabularFigures()])),
                ),
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
                      markA: _abFrac(_abA, sliderMax.toDouble()),
                      markB: _abFrac(_abB, sliderMax.toDouble()),
                    ),
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text(_fmt(duration),
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      style: TextStyle(
                          color: onSurface.withAlpha(150),
                          fontSize: 11,
                          // Same-width digits: the clock ticking no longer
                          // nudges the waveform sideways every second.
                          fontFeatures: const [FontFeature.tabularFigures()])),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // ── Transport: shuffle · prev · −10 · play · +10 · next · repeat
            // Sunk into a soft groove in the glass; the play button rises
            // out of it, so the buttons look fused into the surface.
            _controlsGroove(
              scheme,
              accent,
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
                            color: Colors.black.withValues(
                                alpha: isDark ? 0.5 : 0.18),
                            blurRadius: 8,
                            offset: const Offset(0, 4),
                          ),
                          BoxShadow(
                            color: accent
                                .withAlpha(isPlaying ? 150 : 70),
                            blurRadius: isPlaying ? 24 : 12,
                            spreadRadius: 2,
                          ),
                          BoxShadow(
                            color: Colors.white
                                .withValues(alpha: isDark ? 0.12 : 0.85),
                            blurRadius: 3,
                            offset: const Offset(-1.5, -2),
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
            ),

            const SizedBox(height: 12),
            _lightSeam(accent),
            const SizedBox(height: 12),

            // ── Tools: one compact row (no scrolling) ─────────────────
            // Playlist · Sleep · Equalizer · Lyrics · Identify — icon tiles
            // with tooltips; badges carry the counts. Volume and Speed live
            // on the bottom row, either side of the Now Playing pill.
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _utility(
                  scheme,
                  onSurface,
                  compact: true,
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
                  compact: true,
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
                  compact: true,
                  icon: Icons.graphic_eq_rounded,
                  label: 'Equalizer',
                  color: accent,
                  onTap: _openEqualizer,
                ),
                _utility(
                  scheme,
                  onSurface,
                  compact: true,
                  icon: Icons.lyrics_rounded,
                  label: 'Lyrics',
                  color: accent,
                  onTap: _openLyrics,
                ),
                Tooltip(
                  message: 'Identify song',
                  child: GestureDetector(
                    onTap: () => showSongIdentifier(context),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: accent.withAlpha(28),
                        shape: BoxShape.circle,
                        border: Border.all(color: accent.withAlpha(120)),
                      ),
                      child: Icon(Icons.hearing_rounded, size: 20, color: accent),
                    ),
                  ),
                ),
              ],
            ),
        ],
      );
      // Base motif — the soft dancing equalizer — is now a raised 3D
      // button: tapping it opens the full Now Playing page, a second way in
      // alongside tapping the spinning disc.
      // Volume (left) · Now Playing pill (centre) · Speed (right):
      // each popup genies in toward the centre.
      final bottomRow = Padding(
            padding: tall
                ? const EdgeInsets.fromLTRB(0, 2, 0, 12)
                : EdgeInsets.fromLTRB(16, 2, 16, isNarrow ? 8 : 14),
            // Two rows: Volume · A-B · Speed on top (nothing gets pushed off
            // the edge any more), the Now Playing pill centred beneath.
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
            Row(
              children: [
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
                        boxShadow: _showVolume
                            ? null
                            : _glassLift(scheme,
                                _muted ? scheme.error : scheme.primary),
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
                if (!live) ...[
                  _abChip(scheme, accent),
                  const SizedBox(width: 8),
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
                      boxShadow: _glassLift(scheme, scheme.primary,
                          active: _showSpeedPanel),
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
            const SizedBox(height: 10),
            Center(
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
                          BoxShadow(
                            color: Colors.white
                                .withValues(alpha: isDark ? 0.10 : 0.9),
                            blurRadius: 3,
                            offset: const Offset(-1.2, -1.8),
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
              ],
            ),
          );
      Widget discWidget(double side) =>
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
                        side: side,
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
                  );
      Widget sideActions() =>
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
                  );

      // ── Android tall hero: the song card grows to fill the space under
      // the header with a big spinning disc, the title, the live lyric line
      // and what's up next, so there is no empty band above the controls.
      Widget heroCard() {
        // Same prediction the skip uses (shuffle's pick is made ahead of
        // time), so Up next is always the song that really comes next.
        final nextIdx = (!live && hasTrack && _effRepeatMode != 'one')
            ? _peekNextIndex()
            : null;
        final upNextOn = nextIdx != null;
        final nextPath = nextIdx == null ? null : _playlist[nextIdx];
        final nextTitle = nextPath == null
            ? ''
            : metadataStore.title(nextPath, _nameFromPath(nextPath));
        return Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [accent.withAlpha(38), Colors.white.withAlpha(10)]
                  : [accent.withAlpha(28), accent.withAlpha(8)],
            ),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: isDark ? Colors.white.withAlpha(20) : accent.withAlpha(40),
            ),
          ),
          child: Column(
            children: [
              // Position · share · like
              Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: accent.withAlpha(isDark ? 40 : 26),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      live
                          ? 'LIVE'
                          : (_playlist.isNotEmpty
                              ? '${_currentIndex + 1} / ${_playlist.length}'
                              : 'No songs yet'),
                      style: TextStyle(
                        color: live ? accent : onSurface.withAlpha(170),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: live ? 1 : 0.2,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const Spacer(),
                  PresenceShareButton(color: accent, size: 20),
                  if (!live && hasTrack) BounceTap(
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
              ),
              // The disc takes whatever height is left, kept round.
              Expanded(
                child: LayoutBuilder(builder: (c, cc) {
                  // -26: room for the loading ring around the record.
                  final side = (cc.maxWidth * 0.66 < cc.maxHeight - 26
                          ? cc.maxWidth * 0.66
                          : cc.maxHeight - 26)
                      .clamp(80.0, 260.0)
                      .toDouble();
                  // While a song (or the app) is busy, a glowing ring sweeps
                  // around the record instead of a loader over the title.
                  return Center(
                    child: VisibilityDetector(
                      key: const ValueKey('aluta-hero-disc'),
                      onVisibilityChanged: (v) =>
                          _setHostingBusy(v.visibleFraction > 0.5),
                      child: SizedBox(
                        width: side + 18,
                        height: side + 18,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            discWidget(side),
                            ValueListenableBuilder<int>(
                              valueListenable: appBusy.major,
                              builder: (_, major, _) => _DiscLoadRing(
                                active: buffering || major > 0,
                                side: side + 18,
                                accent: accent,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ),
              // Everything under the disc lives in a FIXED-height area: the
              // title / artist / lyric line / Up next can appear, change or
              // vanish inside it without ever resizing the disc (that resize
              // was the shake on Android).
              // Every slot keeps a fixed height and the column hugs them (no
              // stretchy filler), so nothing jumps AND no empty band opens up
              // between Dedicate and the feel strip.
              Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                  SizedBox(
                    height: 24,
                    child: Align(
                      alignment: Alignment.center,
                      child: MarqueeText(
                        text: displayTitle,
                        height: 24,
                        style: TextStyle(
                          color: onSurface,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  // Always holds its line (empty until the artist is known), so
                  // the name arriving never nudges anything.
                  SizedBox(
                      height: 18,
                      child: displayArtist.isEmpty ? null : Align(
                        alignment: Alignment.center,
                        child: MarqueeText(
                          text: displayArtist,
                          height: 18,
                          style: TextStyle(
                            color: live ? accent : onSurface.withAlpha(160),
                            fontWeight: live ? FontWeight.w600 : FontWeight.normal,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    ),
                  SizedBox(
                      height: 26,
                      child: _syncedLyricLine(scheme, accent, false)),
                  // Dedicate this song ❤ — the people I chat with most. Its
                  // line is always reserved so it never nudges the record.
                  SizedBox(
                    height: 44,
                    child: (live || !hasTrack || _dedicateTo.isEmpty)
                        ? null
                        : _dedicateRow(scheme, accent),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 34,
                    child: !upNextOn ? null :
                    // Up next — tap to jump to it.
                    BounceTap(
                      onTap: _transportNext,
                      child: Container(
                        height: 34,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.white.withAlpha(10)
                              : Colors.white.withAlpha(150),
                          borderRadius: BorderRadius.circular(17),
                          border: Border.all(color: accent.withAlpha(50)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.queue_music_rounded,
                                size: 16, color: accent),
                            const SizedBox(width: 6),
                            Text('Up next',
                                style: TextStyle(
                                    color: accent,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: MarqueeText(
                                text: nextTitle,
                                height: 16,
                                style: TextStyle(
                                    color: onSurface.withAlpha(190),
                                    fontSize: 12),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(Icons.skip_next_rounded,
                                size: 18, color: onSurface.withAlpha(150)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (!live && hasTrack)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: SongFeelStrip(
                          title: _trackName,
                          artist: _artistName,
                          accent: accent,
                          framed: false),
                    ),
                  ],
                ),
            ],
          ),
        );
      }

      final topBlock = Column(
                mainAxisSize: MainAxisSize.min,
                children: [

            // ── Disc + track info card ────────────────────────────────
            Container(
              padding: const EdgeInsets.all(12),
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
              Row(
                children: [
                  // Spinning disc — swipe ←/→ to skip, double-tap to like,
                  // swipe up to open the queue.
                  discWidget(isNarrow ? 58.0 : 76.0),
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
                        // Always reserved (empty until known): no jump when the
                        // artist name arrives.
                        ...[
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
                  sideActions(),
                ],
              ),
              // How this song feels → who it's for, folded INTO the card
              // (one surface, no extra block to scroll past).
              if (!live && hasTrack)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SongFeelStrip(
                      title: _trackName,
                      artist: _artistName,
                      accent: accent,
                      framed: false),
                ),
                ],
              ),
            ),

            if (!tall) ...[
              const SizedBox(height: 14),
              _controlsGlass(scheme, accent, controlsBody),
            ],
                ],
              );
      final controlsCard = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: _controlsGlass(
          scheme,
          accent,
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              controlsBody,
              const SizedBox(height: 14),
              bottomRow,
            ],
          ),
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
        ),
      );
      if (tall && !kIsWeb && Platform.isAndroid) {
        return Padding(
          padding: EdgeInsets.fromLTRB(0, 6, 0, isNarrow ? 8 : 12),
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: LayoutBuilder(
                    builder: (c, cc) => cc.maxHeight >= 300
                        ? heroCard()
                        : Align(
                            alignment: Alignment.bottomCenter,
                            child: SingleChildScrollView(child: topBlock),
                          ),
                  ),
                ),
              ),
              SizedBox(height: 30, child: _fusionBridge(scheme, accent)),
              controlsCard,
            ],
          ),
        );
      }
      if (tall) {
        // Song card → a short fused neck → the controls glass, kept together
        // as one group, controls staying low for the thumb. Spare height
        // goes mostly above the song card, never as a big hole in the middle.
        return Padding(
          padding: EdgeInsets.fromLTRB(0, 10, 0, isNarrow ? 8 : 12),
          child: Column(
            children: [
              const Spacer(flex: 2),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: topBlock,
              ),
              Flexible(
                flex: 2,
                child: ConstrainedBox(
                  constraints:
                      const BoxConstraints(minHeight: 18, maxHeight: 52),
                  child: _fusionBridge(scheme, accent),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: _controlsGlass(
                  scheme,
                  accent,
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      controlsBody,
                      const SizedBox(height: 14),
                      bottomRow,
                    ],
                  ),
                  padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
                ),
              ),
              const Spacer(flex: 1),
            ],
          ),
        );
      }
      return Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(16, 14, 16, isNarrow ? 6 : 10),
              child: topBlock,
            ),
          ),
          bottomRow,
        ],
      );
    });
  }

  /// The glass the player controls sit in. It has no hard top edge: the
  /// surface condenses out of the panel (clear at the top, deepening
  /// downward) and its rim is lit along the top and fades away down the
  /// sides, so the card melts into the page instead of sitting on it.
  Widget _dedicateRow(ColorScheme scheme, Color accent) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.favorite_rounded, size: 14, color: accent),
          const SizedBox(width: 5),
          Text('Dedicate',
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: accent)),
          const SizedBox(width: 8),
          for (final f in _dedicateTo)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Tooltip(
                message: 'Dedicate to ${_nameOf(f)}',
                child: BounceTap(
                  onTap: () => _openDedicate(f, accent),
                  child: Container(
                    padding: const EdgeInsets.all(1.5),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: accent.withAlpha(110)),
                    ),
                    child: InitialsAvatar(
                      name: _nameOf(f),
                      radius: 14,
                      imageUrl: _avatarOf(f),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  double? _abFrac(Duration? d, double maxMs) =>
      (d == null || maxMs <= 0) ? null : (d.inMilliseconds / maxMs).clamp(0.0, 1.0);

  /// The A-B repeat key: "A-B" (off) → "A ⋯ B?" (A marked) → "0:42–1:05"
  /// (looping). Long-press clears it from any step.
  Widget _abChip(ColorScheme scheme, Color accent, {VoidCallback? after}) {
    final a = _abA, b = _abB;
    final on = a != null;
    final label = a == null
        ? 'A-B'
        : (b == null ? 'A ${_fmt(a)} · B?' : '${_fmt(a)}–${_fmt(b)}');
    final fg = on ? accent : scheme.onSurface.withAlpha(175);
    return Tooltip(
      message: 'Repeat a part (A-B) · hold to clear',
      child: Tactile(
        child: GestureDetector(
          onTap: () {
            _cycleAB();
            after?.call();
          },
          onLongPress: () {
            _clearAB();
            after?.call();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: on
                  ? accent.withAlpha(b != null ? 34 : 20)
                  : scheme.surfaceContainerHighest.withAlpha(
                      scheme.brightness == Brightness.dark ? 110 : 160),
              borderRadius: BorderRadius.circular(18),
              boxShadow: _glassLift(scheme, accent, active: b != null),
              border: Border.all(
                  color: on ? accent.withAlpha(150) : accent.withAlpha(50)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(b != null ? Icons.repeat_on_rounded : Icons.repeat_rounded,
                    size: 13, color: fg),
                const SizedBox(width: 4),
                Text(label,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: fg,
                        fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _controlsGlass(ColorScheme scheme, Color accent, Widget child,
      {EdgeInsets padding = const EdgeInsets.fromLTRB(10, 14, 10, 14)}) {
    final dark = scheme.brightness == Brightness.dark;
    return CustomPaint(
      painter: _MeltRimPainter(accent: accent, dark: dark),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: dark
                ? [
                    Colors.white.withAlpha(4),
                    Color.alphaBlend(
                        Colors.white.withAlpha(10), accent.withAlpha(16)),
                    Color.alphaBlend(
                        Colors.black.withAlpha(46), accent.withAlpha(22)),
                  ]
                : [
                    Colors.white.withAlpha(30),
                    Color.alphaBlend(accent.withAlpha(10), Colors.white),
                    Color.alphaBlend(accent.withAlpha(24), scheme.surface),
                  ],
            stops: const [0.0, 0.32, 1.0],
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(dark ? 80 : 22),
              blurRadius: 26,
              offset: const Offset(0, 14),
              spreadRadius: -8,
            ),
            BoxShadow(
              color: accent.withAlpha(dark ? 26 : 16),
              blurRadius: 34,
              spreadRadius: -10,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: child,
      ),
    );
  }

  /// A recessed channel in the glass: shaded at the top, catching light at
  /// the bottom lip, the way a groove pressed into a surface would.
  Widget _controlsGroove(ColorScheme scheme, Color accent, Widget child) {
    final dark = scheme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(40),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? [Colors.black.withAlpha(70), Colors.white.withAlpha(8)]
              : [accent.withAlpha(22), Colors.white.withAlpha(150)],
        ),
        border: Border(
          bottom: BorderSide(
              color: Colors.white.withAlpha(dark ? 26 : 160), width: 1),
          top: BorderSide(
              color: Colors.black.withAlpha(dark ? 60 : 16), width: 1),
        ),
      ),
      child: child,
    );
  }

  /// The liquid neck joining the song card to the controls glass.
  Widget _fusionBridge(ColorScheme scheme, Color accent) => IgnorePointer(
        child: CustomPaint(
          painter: _FusionPainter(
              accent: accent, dark: scheme.brightness == Brightness.dark),
          size: Size.infinite,
        ),
      );

  /// A thin seam of light between the transport and the tools.
  Widget _lightSeam(Color accent) => Container(
        height: 1,
        margin: const EdgeInsets.symmetric(horizontal: 28),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [
            accent.withAlpha(0),
            accent.withAlpha(110),
            Colors.white.withAlpha(90),
            accent.withAlpha(110),
            accent.withAlpha(0),
          ]),
          boxShadow: [
            BoxShadow(color: accent.withAlpha(70), blurRadius: 6),
          ],
        ),
      );

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
    // Compact: a 40px icon tile with a tooltip instead of a caption, so the
    // whole tools row fits on one line.
    bool compact = false,
  }) {
    return Tooltip(
      message: compact ? label : '',
      child: Tactile(child: GestureDetector(
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
                width: compact ? 40 : 46,
                height: compact ? 40 : 46,
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
                  boxShadow: _glassLift(
                      scheme, active ? color : scheme.primary,
                      active: active),
                ),
                child: Icon(
                  icon,
                  size: compact ? 19 : 21,
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
          if (!compact) ...[
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
        ],
      ),
    )),
    );
  }
}

/// The controls glass's rim: brightest along the top curve, dissolving down
/// the sides and picking up a faint accent at the bottom — no closed outline.
class _MeltRimPainter extends CustomPainter {
  _MeltRimPainter({required this.accent, required this.dark});
  final Color accent;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
        (Offset.zero & size).deflate(0.5), const Radius.circular(26));
    final rect = Offset.zero & size;
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withAlpha(dark ? 60 : 200),
            Colors.white.withAlpha(0),
            Colors.white.withAlpha(0),
            accent.withAlpha(dark ? 50 : 70),
          ],
          stops: const [0.0, 0.3, 0.7, 1.0],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_MeltRimPainter o) => o.accent != accent || o.dark != dark;
}

/// Two glass bodies melting into each other: the shape leaves the bottom of
/// the song card at its full width, pinches to a soft waist and swells back
/// out into the top of the controls glass, like a drop about to merge.
class _FusionPainter extends CustomPainter {
  _FusionPainter({required this.accent, required this.dark});
  final Color accent;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    if (h < 6) return;
    final w = size.width;
    final cx = w / 2;
    // Overlap a little into both cards so there is no seam.
    const over = 12.0;
    final top = -over, bot = h + over;
    final topHalf = (w - 32) / 2 - 18;
    final botHalf = (w - 24) / 2 - 14;
    // The waist narrows more when the gap is long, stays plump when short.
    final waist = (topHalf * (0.72 - (h / 900).clamp(0.0, 0.34)));
    final midY = h * 0.55;
    final path = Path()
      ..moveTo(cx - topHalf, top)
      ..cubicTo(cx - topHalf, midY * 0.5, cx - waist, midY * 0.7, cx - waist,
          midY)
      ..cubicTo(cx - waist, midY + (h - midY) * 0.35, cx - botHalf,
          h - (h - midY) * 0.4, cx - botHalf, bot)
      ..lineTo(cx + botHalf, bot)
      ..cubicTo(cx + botHalf, h - (h - midY) * 0.4, cx + waist,
          midY + (h - midY) * 0.35, cx + waist, midY)
      ..cubicTo(cx + waist, midY * 0.7, cx + topHalf, midY * 0.5, cx + topHalf,
          top)
      ..close();
    final rect = Rect.fromLTRB(0, top, w, bot);
    // Body: a faint accent glass, brightest where the two meet.
    canvas.drawPath(
      path,
      Paint()
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10)
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? [
                  accent.withAlpha(30),
                  Colors.white.withAlpha(8),
                  accent.withAlpha(26),
                ]
              : [
                  accent.withAlpha(22),
                  Colors.white.withAlpha(120),
                  accent.withAlpha(20),
                ],
        ).createShader(rect),
    );
    // A glowing core running down the neck — the "current" between them.
    canvas.drawPath(
      Path()
        ..moveTo(cx, top + over)
        ..lineTo(cx, bot - over),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            accent.withAlpha(0),
            accent.withAlpha(dark ? 90 : 60),
            accent.withAlpha(0),
          ],
        ).createShader(rect),
    );
    // A few motes of light caught inside the glass.
    final r = Random(3);
    for (var i = 0; i < 7; i++) {
      final y = h * (0.15 + 0.7 * r.nextDouble());
      final t = (y / h);
      final half = t < 0.55
          ? topHalf + (waist - topHalf) * (t / 0.55)
          : waist + (botHalf - waist) * ((t - 0.55) / 0.45);
      final x = cx + (r.nextDouble() * 2 - 1) * half * 0.7;
      canvas.drawCircle(
        Offset(x, y),
        0.8 + r.nextDouble() * 1.6,
        Paint()
          ..color = (i.isEven ? Colors.white : accent)
              .withAlpha(dark ? 70 : 110)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
      );
    }
  }

  @override
  bool shouldRepaint(_FusionPainter o) => o.accent != accent || o.dark != dark;
}
