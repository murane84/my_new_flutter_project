part of '../relationship_space_page.dart';

// Split out of relationship_space_page.dart (pure code movement, no behaviour change):
// helper methods of _RelationshipSpacePageState that don't call setState, moved into a
// private extension. A library `part`, so it shares the page's imports
// and reaches every private field and method.

extension _SpacePageHelpers1 on _RelationshipSpacePageState {
  /// The global-space centre of a tile (via its key), or null if not laid out.
  Offset? _globalCenter(GlobalKey k) {
    final ctx = k.currentContext;
    final box = ctx?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  /// Schedule/cancel device reminders so they match the pinned future plans in
  /// the shared diary (fires the morning of each plan). Best-effort, guarded on
  /// unsupported platforms inside the service.
  void _syncReminders() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final reminders = <PlanReminder>[];
    for (final e in _plans) {
      if (e['pinned'] != true) continue;
      final d = DateTime.tryParse((e['plan_date'] ?? '').toString());
      if (d == null) continue;
      final day = DateTime(d.year, d.month, d.day);
      if (day.isBefore(today)) continue;
      final id = (e['id'] as num?)?.toInt();
      if (id == null) continue;
      final title = (e['title'] ?? '').toString().trim().isNotEmpty
          ? (e['title']).toString().trim()
          : (e['body'] ?? '').toString().trim();
      reminders.add(PlanReminder(id: id, title: title, date: day));
    }
    // Fire-and-forget; the service reconciles (schedules new, cancels stale).
    syncDiaryReminders(reminders);
  }

  String? _full(dynamic ref) {
    final s = ref?.toString() ?? '';
    if (s.isEmpty) return null;
    return s.startsWith('http') ? s : '${widget.apiBase}$s';
  }

  String _closeSince() {
    final raw = (_space['close_since'] ?? _space['stats']?['close_since'] ?? '')
        .toString();
    final dt = DateTime.tryParse(raw);
    if (dt == null) return '—';
    return DateFormat('MMM d, yyyy').format(dt.toLocal());
  }

  /// Whole days since the bond began (its close-since date) — the "X days
  /// together" headline of the Our World hub. Null if the date is unknown.
  int? _daysTogether() {
    final raw = (_space['close_since'] ?? _space['stats']?['close_since'] ?? '')
        .toString();
    final dt = DateTime.tryParse(raw);
    if (dt == null) return null;
    final d = DateTime.now().toUtc().difference(dt.toUtc()).inDays;
    return d < 0 ? 0 : d;
  }

  /// Open a live session as host playing `path` for the partner in sync. Shared
  /// by the Listen-together button, the tune-in card, and the playlist rows.
  Future<void> _hostSession(String path, int startPos,
      {String? titleOverride, bool gated = false}) async {
    final others = _others;
    if (others.isEmpty) return;
    final partner = others.first;
    final partnerId = (partner['id'] as num?)?.toInt();
    final partnerName = ContactNames.instance.displayName(of: partner, registered: (partner['username'] ?? 'them').toString());
    final myUserId = widget.myUserId;
    if (partnerId == null || myUserId == null) return;
    // Playlist rows / crate start here directly — same presence check.
    if (!gated) {
      final go = await listenTogetherGate(context,
          friendId: partnerId, name: partnerName);
      if (!go || !mounted) return;
    }

    Uint8List bytes;
    try {
      bytes = Uint8List.fromList(await readFileBytes(path));
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not read that track.', type: ToastType.error);
      }
      return;
    }
    if (bytes.isEmpty) {
      if (mounted) {
        showToast(context, 'That track appears to be empty.',
            type: ToastType.error);
      }
      return;
    }
    final token = await getToken();
    if (token == null || !mounted) return;
    // Stop the local player so the song isn't heard twice.
    playbackBus.onPause?.call();

    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => LiveSessionScreen.host(
        token: token,
        myUserId: myUserId,
        receiverId: partnerId,
        audioBytes: bytes,
        title: titleOverride ?? _songTitle(path),
        peerName: partnerName,
        startPositionMs: startPos,
      ),
    ));
  }

  String _audioMimeFor(String path) {
    final e = path.toLowerCase();
    if (e.endsWith('.mp3')) return 'audio/mpeg';
    if (e.endsWith('.m4a') || e.endsWith('.aac')) return 'audio/mp4';
    if (e.endsWith('.wav')) return 'audio/wav';
    if (e.endsWith('.ogg')) return 'audio/ogg';
    if (e.endsWith('.flac')) return 'audio/flac';
    return 'audio/mpeg';
  }

  // Cache every crate track that has shared audio, so a Listen Together can
  // quick-start from the local copy on either partner's device.
  void _prefetchPlaylistAudio() {
    if (kIsWeb) return;
    final tracks =
        ((_space['playlist'] as List?) ?? const []).whereType<Map>();
    for (final t in tracks) {
      final au = (t['audio_url'] ?? '').toString().trim();
      if (au.isEmpty) continue;
      final full = resolveAvatarUrl(au, widget.apiBase) ?? au;
      // Fire-and-forget: download + cache; ignore failures.
      MediaStore.instance.getFile(full, mediaAuthHeaders(full));
    }
  }

  Future<void> _removeTrackFromCrate(int trackId) async {
    final code = await ApiService().removeTrack(_id, trackId);
    if (!mounted) return;
    // 2xx = removed; a 404 means it's already gone, which for a delete is also
    // success — just refresh. Anything else surfaces the exact reason.
    if ((code >= 200 && code < 300) || code == 404) {
      _load();
    } else {
      showToast(context,
          'Could not remove (${code == -1 ? 'network' : code})',
          type: ToastType.error);
    }
  }

  /// Play a crate track together — if I have that song in my own loaded library
  /// (matched by title), host it in sync; otherwise nudge me to load it first.
  Future<void> _playCrateTrack(Map<String, dynamic> track) async {
    final title = (track['title'] ?? '').toString().trim();
    final audioUrl = (track['audio_url'] ?? '').toString().trim();
    // Shared durable audio: EITHER partner can start from the cached copy,
    // whether or not they have the song in their own library.
    if (!kIsWeb && audioUrl.isNotEmpty) {
      final full = resolveAvatarUrl(audioUrl, widget.apiBase) ?? audioUrl;
      if (mounted) {
        showToast(context, 'Getting the song ready…', type: ToastType.info);
      }
      final f =
          await MediaStore.instance.getFile(full, mediaAuthHeaders(full));
      if (!mounted) return;
      if (f != null) {
        await _hostSession(f.path, 0,
            titleOverride: title.isEmpty ? null : title);
        return;
      }
    }
    final ref = (track['ref'] ?? '').toString().trim();
    // Fall back to the adder's local path / a title match in my own library.
    final local = _localPathFor(ref, title);
    if (local == null) {
      showToast(
        context,
        'You do not have "$title" loaded — add it to your player to listen '
        'together.',
        type: ToastType.info,
      );
      return;
    }
    await _hostSession(local, 0);
  }

  String? _localPathFor(String ref, String title) {
    final paths = List<String>.from(playlistNotifier.value);
    if (ref.isNotEmpty && paths.contains(ref)) return ref;
    if (title.isEmpty) return null;
    final want = title.toLowerCase();
    for (final p in paths) {
      if (_songTitle(p).toLowerCase() == want) return p;
    }
    return null;
  }

  Future<void> _unpin() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unpin this Space?'),
        content: const Text(
            'The relationship profile and its pinned moments are removed. Your '
            'friendship and chats stay exactly as they are.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Unpin'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final done = await ApiService().deleteSpace(_id);
    if (!mounted) return;
    if (done) {
      widget.onChanged?.call();
      Navigator.pop(context);
    } else {
      showToast(context, 'Could not unpin — try again', type: ToastType.error);
    }
  }

  /// The page's ambient backdrop: a barely-there vertical wash of the Space
  /// colour top and bottom, plus two large soft glows drifting in from the
  /// corners — subtle atmosphere so the hero and tiles read as floating.
  Widget _pageBackdrop(ColorScheme scheme) {
    // Custom PHOTO background overrides the default motif theme.
    final bgUrl = (_space['background_url'] ?? '').toString().trim();
    if (bgUrl.isNotEmpty) {
      return _photoBackdrop(scheme, resolveAvatarUrl(bgUrl, widget.apiBase) ?? bgUrl);
    }
    Widget glow(double size, double alpha) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                _accent.withValues(alpha: alpha),
                _accent.withValues(alpha: 0),
              ],
            ),
          ),
        );
    // The whole motif scales with the user's chosen concentration (motifStrength)
    // and repaints live when they move the slider.
    return ValueListenableBuilder<double>(
      valueListenable: motifStrength,
      builder: (context, _, _) {
        final patBase = Theme.of(context).brightness == Brightness.dark
            ? 0.06
            : 0.055;
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                _accent.withValues(alpha: motifAccentAlpha(0.07)),
                _accent.withValues(alpha: 0.0),
                _accent.withValues(alpha: motifAccentAlpha(0.05)),
              ],
              stops: const [0.0, 0.45, 1.0],
            ),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // DEFAULT theme: a dense, whisper-faint confetti of tiny hearts,
              // music notes, cherry blossoms + sparkle-hearts across the WHOLE
              // page. The motifs inherit the Space's colour (_accent) at an
              // opacity the user controls via motifStrength.
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: RomanticPatternPainter(
                      color: _accent.withValues(alpha: motifAccentAlpha(patBase)),
                    ),
                  ),
                ),
              ),
              Positioned(
                  top: -110,
                  right: -90,
                  child: glow(300, motifAccentAlpha(0.12))),
              Positioned(
                  bottom: -140,
                  left: -110,
                  child: glow(340, motifAccentAlpha(0.09))),
            ],
          ),
        );
      },
    );
  }
  Future<File?> _bgFileFuture(String url, Map<String, String> headers) {
    if (_bgFutureUrl != url || _bgFuture == null) {
      _bgFutureUrl = url;
      _bgFuture = MediaStore.instance.getFile(url, headers);
    }
    return _bgFuture!;
  }

  // If [url] points at a gallery preset that has a landscape companion, the
  // matching /wide URL; otherwise null.
  String? _widePresetUrl(String url) {
    final m = RegExp(r'/wallpapers/(w\d+)(?:/wide)?\$').firstMatch(url);
    if (m == null) return null;
    final id = m.group(1)!;
    if (!_wideWallpaperIds.contains(id)) return null;
    return url.replaceFirst(RegExp(r'/wallpapers/w\d+(?:/wide)?\$'),
        '/wallpapers/$id/wide');
  }

  Widget _photoBackdrop(ColorScheme scheme, String url) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final veil = isDark ? Colors.black : Colors.white;
    return LayoutBuilder(
      builder: (ctx, c) {
        final wide = c.maxWidth > c.maxHeight;
        // On a wide screen, prefer a real landscape wallpaper (cover, no tiling)
        // when this preset ships one; otherwise keep the portrait (tiled wide).
        final widthUrl = wide ? _widePresetUrl(url) : null;
        final effUrl = widthUrl ?? url;
        final headers = mediaAuthHeaders(effUrl);
        final fit = (wide && widthUrl != null)
            ? BoxFit.cover
            : (wide ? BoxFit.fitHeight : BoxFit.cover);
        final repeat = (wide && widthUrl == null)
            ? ImageRepeat.repeatX
            : ImageRepeat.noRepeat;
        return FutureBuilder<File?>(
          // Prefer the on-device copy (survives offline / a desktop restart);
          // fall back to the network image on the first, online view while it
          // downloads + persists.
          future: _bgFileFuture(effUrl, headers),
          builder: (ctx, snap) {
            final ImageProvider provider = snap.data != null
                ? FileImage(snap.data!)
                : authNetworkImageProvider(effUrl, headers);
            return Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    image: DecorationImage(
                      image: provider,
                      fit: fit,
                      repeat: repeat,
                      onError: (Object e, StackTrace? st) {},
                    ),
                  ),
                ),
                ValueListenableBuilder<double>(
                  valueListenable: wallpaperClarity,
                  builder: (_, _, _) => DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          veil.withValues(
                              alpha: wallpaperVeilAlpha(isDark ? 0.46 : 0.58)),
                          veil.withValues(
                              alpha: wallpaperVeilAlpha(isDark ? 0.34 : 0.42)),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ── feature tiles (each opens a floating card) ────────────────────────────
  Widget _tilesSection(ColorScheme scheme, List<Map<String, dynamic>> moments) {
    // Prefer the server COUNT fields (present in the light list payload too), so
    // the badges are correct on the very first paint instead of waiting for the
    // full lists to arrive on the follow-up fetch.
    int countOf(String key, int fallback) =>
        (_space[key] as num?)?.toInt() ?? fallback;
    final playlistCount = countOf(
        'playlist_count', ((_space['playlist'] as List?) ?? const []).length);
    final dedicationsCount =
        ((_space['dedications'] as List?) ?? const []).length;
    // The moments wall now also carries dedications, so the badge counts both.
    final momentsCount =
        countOf('moment_count', moments.length) + dedicationsCount;
    final diaryCount = countOf('diary_count', _diary.length);
    final capsulesWaiting = ((_space['capsules'] as List?) ?? const [])
        .where((c) => c is Map && c['locked'] == true)
        .length;
    final tiles = <Widget>[
      if (_partnerId != null)
        _featureTile(scheme,
            tileKey: _kPlaylist,
            icon: Icons.queue_music_rounded,
            label: 'Our Playlist',
            count: playlistCount,
            subtitle: 'Songs + listen together',
            onTap: () => _openPlaylist(_globalCenter(_kPlaylist))),
      _featureTile(scheme,
          tileKey: _kMoments,
          icon: Icons.favorite_rounded,
          label: 'Pinned moments',
          count: momentsCount,
          subtitle: 'Dedications & notes',
          onTap: () => _openMoments(_globalCenter(_kMoments))),
      if (_partnerId != null)
        _featureTile(scheme,
            tileKey: _kDiary,
            icon: Icons.menu_book_rounded,
            label: 'Our Diary',
            count: diaryCount,
            subtitle: 'Memories & plans ahead',
            onTap: () => _openDiary(_globalCenter(_kDiary))),
      if (_partnerId != null)
        _featureTile(scheme,
            tileKey: _kCapsule,
            icon: Icons.card_giftcard_rounded,
            label: 'Love capsule',
            count: capsulesWaiting > 0 ? capsulesWaiting : null,
            subtitle: 'A song sealed for later',
            onTap: () => _openCapsules(_globalCenter(_kCapsule))),
    ];
    return LayoutBuilder(
      builder: (ctx, c) {
        // Compact horizontal tiles: full-width rows on a phone (roomy for the
        // title + subtitle), two-up only once there's real width (tablet/
        // desktop). No CrossAxisAlignment.stretch anywhere — the tiles size to
        // content, which also avoids the release-web intrinsic-measure bug.
        final twoCol = c.maxWidth >= 560;
        if (!twoCol) {
          return Column(
            children: [
              for (final t in tiles)
                Padding(padding: const EdgeInsets.only(bottom: 10), child: t),
            ],
          );
        }
        final rows = <Widget>[];
        for (var i = 0; i < tiles.length; i += 2) {
          // NB: no CrossAxisAlignment.stretch here. The tiles have a fixed
          // height (see _featureTile), so the two cells already match — and
          // stretch would force an intrinsic-height measurement of a tile whose
          // header row contains a Spacer/Expanded, which is illegal for a Flex
          // and silently breaks sizing + hit-testing in a release web build.
          rows.add(Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Expanded(child: tiles[i]),
                const SizedBox(width: 10),
                Expanded(
                    child: i + 1 < tiles.length
                        ? tiles[i + 1]
                        : const SizedBox()),
              ],
            ),
          ));
        }
        return Column(children: rows);
      },
    );
  }

  Widget _featureTile(
    ColorScheme scheme, {
    Key? tileKey,
    required IconData icon,
    required String label,
    required int? count,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    // Compact horizontal tile with depth: a raised, gently top-lit card (soft
    // drop shadow + faint top highlight + hairline rim) carrying a 3D icon chip,
    // the title + subtitle beside it, and the count/chevron trailing. Half the
    // height of the old stacked tile.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      key: tileKey,
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [scheme.surface, scheme.surfaceContainerHighest],
          ),
          border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.35)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
            BoxShadow(
              color: Colors.white.withValues(alpha: isDark ? 0.04 : 0.7),
              blurRadius: 1,
              spreadRadius: -1,
              offset: const Offset(0, -1),
            ),
          ],
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          hoverColor: _accent.withValues(alpha: 0.06),
          highlightColor: _accent.withValues(alpha: 0.05),
          splashColor: _accent.withValues(alpha: 0.10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                // 3D icon chip.
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(13),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        _accent.withValues(alpha: 0.24),
                        _accent.withValues(alpha: 0.12),
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: _accent.withValues(alpha: 0.22),
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(icon, color: _accent, size: 22),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                              color: scheme.onSurface)),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                // Fade + scale the count in when the fetch lands, rather than
                // snapping a badge out of nowhere.
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: ScaleTransition(scale: anim, child: child),
                  ),
                  child: (count != null && count > 0)
                      ? Padding(
                          key: ValueKey('badge$count'),
                          padding: const EdgeInsets.only(left: 8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: _accent.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text('$count',
                                style: TextStyle(
                                    color: _accent,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 12.5)),
                          ),
                        )
                      : const SizedBox.shrink(key: ValueKey('noBadge')),
                ),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right_rounded,
                    size: 20, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }


  /// A quiet "thinking of you" pill — the lightest touch across the bond, kept
  /// as its own one-tap action (it has no details to open).
  Widget _quickPill(ColorScheme scheme) {
    // Opaque + bordered so it stands clear over any wallpaper (never dissolves).
    final fill =
        Color.alphaBlend(_accent.withValues(alpha: 0.16), scheme.surface);
    return Center(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Material(
          color: fill,
          borderRadius: BorderRadius.circular(24),
          child: InkWell(
            onTap: _nudging ? null : _nudge,
            borderRadius: BorderRadius.circular(24),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                    color: _accent.withValues(alpha: 0.45), width: 1.2),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _nudging
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: _accent),
                      )
                    : Icon(Icons.chat_bubble_rounded,
                        size: 16, color: _accent),
                const SizedBox(width: 8),
                Text('Thinking of you',
                    style: TextStyle(
                        color: _accent,
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5)),
              ],
            ),
            ),
          ),
        ),
      ),
    );
  }

  // Feature tiles now open IN-BODY as sections (see _sectionScaffold), so a
  // sidebar/drawer can jump between them without returning to the dashboard.
  void _openPlaylist([Offset? origin]) => _goSection('playlist');

  void _openMoments([Offset? origin]) => _goSection('moments');
  void _openCapsules([Offset? origin]) => _goSection('capsule');

  /// The section list rail: couple badge on top, then the sections with the
  /// active one highlighted. [onClose] (drawer mode) adds a minimize button.
  Widget _sectionSidebar(ColorScheme scheme, {VoidCallback? onClose}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // In DRAWER mode (onClose != null) the card is flush to the screen edge and
    // runs the full page height, so rounding its OUTER (left/top/bottom) corners
    // just exposes the dimmed page behind as dark notches. Square those; round
    // only the inner RIGHT edge that floats over the content.
    final drawer = onClose != null;
    final radius = drawer
        ? const BorderRadius.horizontal(right: Radius.circular(18))
        : BorderRadius.circular(18);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? [scheme.surfaceContainerHigh, scheme.surfaceContainer]
              : [Colors.white, scheme.surfaceContainerHighest],
        ),
        border: Border.all(color: _accent.withValues(alpha: 0.20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.42 : 0.14),
            blurRadius: 18,
            // Cast the shadow to the RIGHT (over the content) in drawer mode so
            // it never darkens the flush left edge; straight down for the rail.
            offset: drawer ? const Offset(6, 0) : const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (onClose != null)
                Align(
                  alignment: Alignment.topRight,
                  child: HeaderActionButton(
                    icon: Icons.chevron_left_rounded,
                    tooltip: 'Hide',
                    onPressed: onClose,
                  ),
                ),
              _sidebarCoupleHeader(scheme),
              const SizedBox(height: 10),
              Divider(
                  height: 1,
                  color: scheme.outlineVariant.withValues(alpha: 0.5)),
              const SizedBox(height: 8),
              // Overview (the dashboard) leads, so the drawer can always take
              // you home; Settings closes the list as an option like the rest.
              _sidebarItem(scheme,
                  ('overview', Icons.space_dashboard_rounded, 'Overview')),
              // Sections with nothing in them yet (a new couple's capsule,
              // an empty diary) wait behind "More…" so the list grows with
              // the relationship. The open one always shows.
              ...() {
                const core = {'playlist', 'moments'};
                bool empty((String, IconData, String) s) =>
                    !core.contains(s.$1) &&
                    _section != s.$1 &&
                    _totalCount(s.$1) == 0;
                final all = _visibleSections();
                final shown = all.where((s) => !empty(s)).toList();
                final hidden = all.where(empty).toList();
                return [
                  for (final s in shown) _sidebarItem(scheme, s),
                  if (hidden.isNotEmpty) ...[
                    if (_drawerMore)
                      for (final s in hidden) _sidebarItem(scheme, s),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                          foregroundColor: scheme.onSurfaceVariant,
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.fromLTRB(19, 8, 10, 8)),
                      onPressed: _toggleDrawerMore,
                      icon: Icon(
                          _drawerMore
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 18),
                      label: Text(
                          _drawerMore ? 'Less' : 'More (${hidden.length})',
                          style: const TextStyle(
                              fontSize: 12.5, fontWeight: FontWeight.w700)),
                    ),
                  ],
                ];
              }(),
              const SizedBox(height: 2),
              Divider(
                  height: 1,
                  color: scheme.outlineVariant.withValues(alpha: 0.5)),
              const SizedBox(height: 8),
              _sidebarItem(
                  scheme, ('settings', Icons.tune_rounded, 'Settings')),
              // The "Thinking of you 💭" nudge — the lightest touch across the
              // bond — sits below the section list as a special action, so it's
              // always one tap away from any section (wide rail AND mobile
              // drawer), not just the dashboard.
              if (_partnerId != null) ...[
                const SizedBox(height: 6),
                Divider(
                    height: 1,
                    color: scheme.outlineVariant.withValues(alpha: 0.5)),
                const SizedBox(height: 12),
                _quickPill(scheme),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _sidebarCoupleHeader(ColorScheme scheme) {
    final title = deriveSpaceName(_space, widget.myUserId);
    final partner = _others.isNotEmpty ? _others.first : null;
    // A little HERO cap in the Space's own colour — the same warm gradient as
    // the dashboard banner — so the couple badges sit on their bond's colour
    // instead of a flat panel, giving the sidebar/drawer a bright anchor on top.
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _accent,
            _accent.withValues(alpha: 0.74),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: _accent.withValues(alpha: 0.34),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          SizedBox(
            width: 70,
            height: 44,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                    left: 0,
                    top: 1,
                    child: diaryAuthorBadge(
                        name: widget.myName ?? 'You',
                        imageUrl: widget.myAvatarUrl,
                        radius: 19)),
                Positioned(
                    right: 0,
                    top: 1,
                    child: diaryAuthorBadge(
                        name: ContactNames.instance.displayName(of: partner, registered: (partner?['username'] ?? '?').toString()),
                        imageUrl: _full(partner?['avatar_url']),
                        radius: 19)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          MarqueeText(
              text: title,
              height: 18,
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  color: readableOn(_accent))),
        ],
      ),
    );
  }

  /// How many items a section holds, for the sidebar badges (null = no count,
  /// e.g. Song & milestones). Uses the server COUNT fields with a live fallback.
  int? _sectionCount(String key) {
    switch (key) {
      case 'playlist':
        return (_space['playlist_count'] as num?)?.toInt() ??
            ((_space['playlist'] as List?) ?? const []).length;
      case 'moments':
        return (_space['moment_count'] as num?)?.toInt() ??
            ((_space['moments'] as List?) ?? const []).length;
      case 'diary':
        return (_space['diary_count'] as num?)?.toInt() ?? _diary.length;
      case 'capsule':
        final n = ((_space['capsules'] as List?) ?? const [])
            .where((c) => c is Map && c['locked'] == true)
            .length;
        return n > 0 ? n : null;
      case 'dedications':
        return ((_space['dedications'] as List?) ?? const []).length;
      default:
        return null;
    }
  }

  Widget _sidebarItem(ColorScheme scheme, (String, IconData, String) s) {
    final active = switch (s.$1) {
      'overview' => _section == null && !_settingsOpen,
      'settings' => _settingsOpen,
      _ => _section == s.$1,
    };
    final count = _sectionCount(s.$1);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: active
              ? null
              : () {
                  if (s.$1 == 'overview') {
                    _goOverview();
                  } else if (s.$1 == 'settings') {
                    _openSettings();
                  } else {
                    _goSection(s.$1);
                  }
                },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: const EdgeInsets.fromLTRB(8, 11, 10, 11),
            decoration: BoxDecoration(
              color:
                  active ? _accent.withValues(alpha: 0.14) : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: active
                      ? _accent.withValues(alpha: 0.5)
                      : Colors.transparent),
            ),
            child: Row(
              children: [
                // Active "rail" indicator — a short accent bar on the left. A
                // fixed-width slot (transparent when idle) keeps every icon
                // aligned whether or not the bar is showing.
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 3,
                  height: active ? 18 : 0,
                  decoration: BoxDecoration(
                    color: active ? _accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(s.$2,
                    size: 18,
                    color: active ? _accent : scheme.onSurfaceVariant),
                const SizedBox(width: 10),
                // Too long for the drawer? It glides (marquee) instead of
                // being cut with "…".
                Expanded(
                  child: MarqueeText(
                      text: s.$3,
                      height: 20,
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight:
                              active ? FontWeight.w800 : FontWeight.w600,
                          color: active ? _accent : scheme.onSurface)),
                ),
                // New since your last visit: a small pulsing accent dot.
                if (!active && _hasNew(s.$1)) ...[
                  const SizedBox(width: 6),
                  const _NewDot(),
                ],
                if (count != null && count > 0) ...[
                  const SizedBox(width: 8),
                  _sidebarCountBadge(count, active),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A small count pill on a sidebar row — filled accent on the active row,
  /// a faint accent tint on the others.
  Widget _sidebarCountBadge(int count, bool active) {
    return Container(
      constraints: const BoxConstraints(minWidth: 22),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: active ? _accent : _accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('$count',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: active ? Colors.white : _accent)),
    );
  }

  /// The content for a section. Diary keeps its own book header; the others use
  /// a shared panel (back to dashboard + optional list button + body + footer).
  Widget _sectionContent(ColorScheme scheme, bool isWide, String section,
      {VoidCallback? onMenu}) {
    switch (section) {
      case 'diary':
        return _diaryBookView(scheme, isWide, onMenu: onMenu);
      case 'playlist':
        final tracks = ((_space['playlist'] as List?) ?? const [])
            .whereType<Map>()
            .map((t) => Map<String, dynamic>.from(t))
            .toList();
        return _sectionPanel(
          scheme,
          Icons.queue_music_rounded,
          'Our Playlist',
          onMenu: onMenu,
          body: Column(
            children: [
              _songMilestoneCard(scheme),
              const SizedBox(height: 16),
              if (tracks.isEmpty)
                _playlistEmpty(scheme)
              else
                ...[for (final t in tracks) _trackRow(scheme, t)],
            ],
          ),
          footer: Row(
            children: [
              Expanded(
                child: _footerPrimary(
                    'Listen together', Icons.play_arrow_rounded,
                    _listenTogether),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _footerSecondary(
                    scheme, 'Add song', Icons.add_rounded, _addToPlaylist),
              ),
            ],
          ),
        );
      case 'moments':
        final moments = ((_space['moments'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
        final dedications = ((_space['dedications'] as List?) ?? const [])
            .whereType<Map>()
            .map((d) => Map<String, dynamic>.from(d))
            .toList();
        // One warm feed: pinned moments + dedications together, newest first.
        final feed = <Map<String, dynamic>>[
          for (final m in moments)
            {'_t': 'moment', '_d': m, '_ts': (m['created_at'] ?? '').toString()},
          for (final d in dedications)
            {
              '_t': 'dedication',
              '_d': d,
              '_ts': (d['created_at'] ?? '').toString()
            },
        ]..sort((a, b) =>
            (b['_ts'] as String).compareTo(a['_ts'] as String));
        return _sectionPanel(
          scheme,
          Icons.favorite_rounded,
          'Pinned moments',
          onMenu: onMenu,
          body: feed.isEmpty
              ? _momentsEmpty(scheme)
              : Column(
                  children: [
                    for (final item in feed)
                      item['_t'] == 'dedication'
                          ? _dedicationCard(
                              scheme, item['_d'] as Map<String, dynamic>)
                          : _momentCard(
                              scheme, item['_d'] as Map<String, dynamic>),
                  ]),
          footer: _footerPrimary(
              'Send a moment', Icons.favorite_border_rounded, _sendMoment),
        );
      case 'dedications':
        return _sectionPanel(
          scheme,
          Icons.favorite_border_rounded,
          'Dedications',
          onMenu: onMenu,
          body: _dedicationsBody(scheme),
          footer: _footerPrimary(
              'Dedicate a song', Icons.favorite_rounded, _composeDedication),
        );
      case 'capsule':
        final capsules = ((_space['capsules'] as List?) ?? const [])
            .whereType<Map>()
            .map((c) => Map<String, dynamic>.from(c))
            .toList();
        return _sectionPanel(
          scheme,
          Icons.card_giftcard_rounded,
          'Love capsule',
          onMenu: onMenu,
          body: capsules.isEmpty
              ? _capsuleEmpty(scheme)
              : Column(children: [
                  for (final c in capsules) _capsuleCard(scheme, c)
                ]),
          footer: _footerPrimary(
              'Seal a capsule', Icons.schedule_send_rounded, _composeCapsule),
        );
      case 'letters':
        return _loveLettersSection(scheme, onMenu: onMenu);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _sectionPanel(
    ColorScheme scheme,
    IconData icon,
    String title, {
    required Widget body,
    Widget? footer,
    VoidCallback? onMenu,
  }) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 2, 2, 8),
          child: Row(
            children: [
              // The same connected nav pill the Diary page uses (Sections | Back)
              // so every section header reads as one unit, not two loose chips.
              _diaryNavCluster(scheme, onMenu),
              const SizedBox(width: 10),
              Icon(icon, color: _accent, size: 20),
              const SizedBox(width: 6),
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: scheme.onSurface)),
              ),
              _guideButton(scheme),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(2, 2, 2, 8),
            child: body,
          ),
        ),
        if (footer != null) _footerBar(footer),
      ],
    );
  }
}

/// A small accent dot that softly pulses — "something new here".
class _NewDot extends StatefulWidget {
  const _NewDot();
  @override
  State<_NewDot> createState() => _NewDotState();
}

class _NewDotState extends State<_NewDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: 'New since your last visit',
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) => Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: a,
              boxShadow: [
                BoxShadow(
                    color: a.withValues(alpha: 0.25 + 0.35 * _c.value),
                    blurRadius: 4 + 4 * _c.value,
                    spreadRadius: 1 * _c.value),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
