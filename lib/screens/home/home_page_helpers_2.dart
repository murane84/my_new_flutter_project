part of '../home_page.dart';

// Split out of home_page.dart (pure code movement, no behaviour change):
// helper methods of HomePageState that don't call setState, moved into a
// private extension. A library `part`, so it shares the page's imports
// and reaches every private field and method.

extension _HomePageHelpers2 on HomePageState {
  Future<void> _startAlutaCall(
      int friendId, String name, String? avatar, String? phone) async {
    if (!ConnectionStatus.instance.isOnline) {
      if (mounted) {
        showToast(context, 'No internet — starting a phone call instead',
            type: ToastType.info);
      }
      _callNumber(phone, name);
      return;
    }
    if (friendId <= 0) return;
    final ok = await CallService.instance.startCall(
      peerId: friendId,
      peerName: name,
      peerAvatar: avatar,
      myName: _username.isNotEmpty ? _username : 'Aluta user',
      myAvatar: _myAvatar,
      fallbackPhone: phone,
    );
    if (!ok && mounted) {
      showToast(context, 'You’re already in a call', type: ToastType.info);
    }
  }

  // ── Panel helpers ─────────────────────────────────────────────────────────

  // Returns an always-in-tree panel container.
  // ClipRect hides the overflow; OverflowBox lets the child render at minRenderWidth
  // even when containerWidth < minRenderWidth — preserving widget state.
  Widget _animatedPanel({
    required double containerWidth,
    required double minRenderWidth,
    required Widget child,
    Duration duration = const Duration(milliseconds: 300),
  }) {
    final visible = containerWidth > 0.5;
    // Fade out quickly when collapsing to prevent OverflowBox visual artifact
    final opacity = (containerWidth / minRenderWidth).clamp(0.0, 1.0);

    return AnimatedContainer(
      // Zero duration while the user is actively dragging the divider, so the
      // panel tracks the pointer 1:1 (no chasing/lag); the smooth 300ms tween is
      // kept for collapse/expand toggles.
      duration: duration,
      curve: Curves.easeInOut,
      width: containerWidth,
      // Round the clip to match the inner card so there are NO triangular corner
      // gaps — previously a rectangular hard-edge clip cut the card's shadow into
      // hard dark wedges at the corners. The shadow lives on THIS container now
      // (outside the clip), so it renders as a soft halo instead.
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.xl),
        boxShadow: visible
            ? [
                BoxShadow(
                  color: Theme.of(context).shadowColor.withAlpha(30),
                  blurRadius: Depth.md,
                ),
              ]
            : const [],
      ),
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: opacity,
          duration: Motion.instant,
          curve: Curves.easeIn,
          child: OverflowBox(
            minWidth: 0,
            maxWidth: max(containerWidth, minRenderWidth),
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: max(containerWidth, minRenderWidth),
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  Widget _panelDecor(BuildContext context, Widget child,
      {bool isMusicPanel = false, EdgeInsetsGeometry? padding}) {
    final theme = Theme.of(context);
    // Both the music panel and the chat panels now follow the app's Light/Dark
    // theme (the music stage no longer forces a fixed near-black), so toggling
    // the theme recolours the player just like the chat area. PlayerTheme still
    // tints the controls with the chosen accent.
    final scheme = theme.colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final bgColor = scheme.surface;

    // In LIGHT mode the music panel's white layer takes on a faint breath of
    // the chosen accent (a soft diagonal wash) so it feels themed instead of
    // plain white. Dark mode keeps its usual near-black stage, and the chat
    // panels are left untouched.
    final Gradient? musicWash = (isMusicPanel && !isDark)
        ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.alphaBlend(scheme.primary.withAlpha(24), scheme.surface),
              Color.alphaBlend(scheme.primary.withAlpha(12), scheme.surface),
            ],
          )
        : null;

    return Container(
      decoration: BoxDecoration(
        color: musicWash == null ? bgColor : null,
        gradient: musicWash,
        // Rounded on ALL FOUR corners so the panel reads as one floating card —
        // the bottom corners emerge from the footer just like the top corners
        // emerge from the header (both sit on the same surfaceContainerHighest
        // background), for a smoother, symmetric look.
        borderRadius: BorderRadius.circular(Radii.xl),
        boxShadow: [
          BoxShadow(
            color: theme.shadowColor.withAlpha(35),
            blurRadius: Depth.md,
            offset: const Offset(0, 0),
          ),
        ],
      ),
      // Clip the child to the rounded shape so scrolling content can never
      // paint into the corners (which was flickering faint pockets at the top
      // during a fast scroll; the same clip now also cleans the bottom corners).
      clipBehavior: Clip.antiAlias,
      padding: padding ?? const EdgeInsets.all(14),
      child: child,
    );
  }

  Widget _buildMusicContent(BuildContext context) {
    // Now Playing is a dark "stage" regardless of app Light/Dark mode; the
    // accent colours its controls (PlayerTheme).
    return PlayerTheme(
      child: Builder(builder: (context) {
    final scheme = Theme.of(context).colorScheme;
    return _panelDecor(
      context,
      Stack(
        children: [
          Column(
            children: [
              _buildMusicHeader(context),
              const SizedBox(height: 10),
              Expanded(
                // Own paint layer: the player ticks many times a second (position,
                // spinning disc) — keep those repaints from spreading into the chat.
                child: PixelSnap(child: RepaintBoundary(child: kIsWeb
                    ? WebMusicPanel(
                        key: _webMusicPanelKey, textColor: scheme.onSurface)
                    : MusicControls(
                        key: _musicPanelKey, textColor: scheme.onSurface))),
              ),
            ],
          ),
          // The playlist takes over the whole panel as a page (covers the
          // "Now Playing" header); its own header + back arrow return here.
          Positioned.fill(child: _playlistDrawerHost(context, music: true)),
        ],
      ),
      isMusicPanel: true,
    );
      }),
    );
  }

  /// The DM header's trailing controls (Wallpaper · Playlist · Call) folded
  /// into ONE connected 3D pill — the same segmented treatment as the Our Space
  /// header cluster — instead of three loose icon buttons.
  Widget _dmHeaderCluster(ColorScheme scheme) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final name = _contactDisplayName(_activeFriendPhone, _activeFriendName ?? '');
    Widget seg(IconData icon, String tip, VoidCallback onTap,
            {bool active = false}) =>
        Tooltip(
          message: tip,
          child: InkResponse(
            onTap: onTap,
            radius: 22,
            // Active = a raised, lit key inside the pill: accent gradient
            // (light top → deeper base), a fine top-light rim and a soft
            // accent drop shadow, with the icon in white.
            child: AnimatedContainer(
              duration: Motion.standard,
              curve: Curves.easeOutCubic,
              margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.md),
                gradient: active
                    ? LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color.lerp(scheme.primary, Colors.white, 0.30)!,
                          scheme.primary,
                          Color.lerp(scheme.primary, Colors.black, 0.18)!,
                        ],
                        stops: const [0.0, 0.55, 1.0],
                      )
                    : null,
                border: Border.all(
                    width: 0.8,
                    color: active
                        ? Colors.white.withValues(alpha: 0.38)
                        : Colors.transparent),
                boxShadow: active
                    ? [
                        BoxShadow(
                          color: scheme.primary.withValues(alpha: 0.40),
                          blurRadius: Depth.xs,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : const [],
              ),
              child: Icon(icon,
                  size: 20,
                  color: active
                      ? readableOn(scheme.primary)
                      : scheme.onSurfaceVariant),
            ),
          ),
        );
    Widget divider() => Container(
        width: 1, height: 20, color: scheme.outlineVariant.withValues(alpha: 0.5));
    void openWallpaper() => showChatWallpaperSheet(
          context,
          convKey: chatConvKey(
              friendId: int.tryParse(_activeFriendId ?? '') ?? 0),
          title: name,
          bonded: _bondWith(int.tryParse(_activeFriendId ?? '') ?? -1) != null,
        );
    void search() => chatSearchRequest.value++;
    // Phones: the name + last-seen need the room, so only the two most-used
    // actions stay in the pill (Playlist — the Aluta one — and Call); Search
    // and Wallpaper fold into a ⋯ genie menu. Wider screens show them all.
    final compact = MediaQuery.sizeOf(context).width < 600;
    final fid = int.tryParse(_activeFriendId ?? '') ?? -1;
    final blocked = BlockList.instance.isBlocked(fid);
    void toggleBlock() => BlockList.instance.toggle(
        context,
        fid,
        _contactDisplayName(_activeFriendPhone, _activeFriendName ?? name),
        person: {
          'id': fid,
          'username': _activeFriendName ?? name,
          'phone': _activeFriendPhone,
          'avatar_url': _activeFriendAvatar,
        });
    // Phones fold everything into ⋯; wider screens keep their segments and
    // the ⋯ carries just Block / Unblock.
    Widget more() => Builder(
          builder: (bctx) => seg(Icons.more_horiz_rounded, 'More', () {
            final box = bctx.findRenderObject() as RenderBox?;
            if (box == null) return;
            final o = box.localToGlobal(Offset.zero);
            showGenieMenu(
              bctx,
              anchor: o & box.size,
              width: 220,
              entries: [
                if (compact) ...[
                  GenieMenuEntry(
                      icon: Icons.search_rounded,
                      label: 'Search in chat',
                      onTap: search),
                  GenieMenuEntry(
                      icon: Icons.library_music_rounded,
                      label: 'Songs, media & docs',
                      onTap: () => chatMediaRequest.value++),
                  GenieMenuEntry(
                      icon: Icons.wallpaper_rounded,
                      label: 'Wallpaper',
                      onTap: openWallpaper),
                ],
                if (fid > 0)
                  GenieMenuEntry(
                      icon: blocked
                          ? Icons.lock_open_rounded
                          : Icons.block_rounded,
                      label: blocked ? 'Unblock' : 'Block',
                      destructive: !blocked,
                      onTap: toggleBlock),
              ],
            );
          }),
        );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.lg),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [scheme.surfaceContainerHigh, scheme.surfaceContainer]
              : [Colors.white, scheme.surfaceContainerHighest],
        ),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.30)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.36 : 0.10),
            blurRadius: Depth.sm,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.lg),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!compact) ...[
              seg(Icons.search_rounded, 'Search in chat', search),
              divider(),
              ValueListenableBuilder<bool>(
                valueListenable: chatMediaOpen,
                builder: (_, open, _) => seg(
                  Icons.library_music_rounded,
                  open ? 'Hide songs, media & docs' : 'Songs, media & docs',
                  () => chatMediaRequest.value++,
                  active: open,
                ),
              ),
              divider(),
              seg(Icons.wallpaper_rounded, 'Wallpaper', openWallpaper),
              divider(),
            ],
            ValueListenableBuilder<bool>(
              valueListenable: playlistDrawerBus.isOpen,
              builder: (_, open, _) => seg(
                Icons.queue_music_rounded,
                open ? 'Hide playlist' : 'Playlist',
                _openChatPlaylist,
                active: open,
              ),
            ),
            divider(),
            seg(Icons.call_rounded, 'Call $name', () {
              _showCallChoice(
                friendId: int.tryParse(_activeFriendId ?? '') ?? -1,
                name: _contactDisplayName(
                    _activeFriendPhone, _activeFriendName ?? 'This user'),
                avatar: _activeFriendAvatar,
                phone: _activeFriendPhone,
              );
            }),
            divider(),
            more(),
          ],
        ),
      ),
    );
  }

  /// Inside an open GROUP: a "Group call in progress · Join" bar shown when a
  /// call is ringing/ongoing in THIS group and the user isn't in it yet — so a
  /// member who missed or declined the ring can still reconnect. Backed by
  /// GroupCallService.ongoingCalls (seeded from the ring + a REST check on open).
  Widget _buildGroupJoinBanner(BuildContext context) {
    final g = _activeGroup;
    if (g == null) return const SizedBox.shrink();
    final room = (g['id'] as num?)?.toInt();
    if (room == null) return const SizedBox.shrink();
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _groupCallJoinBar(g, room),
      _groupListenJoinBar(room),
    ]);
  }

  /// "🎧 `host` is playing `song` · Join" — a member's Listen Together room
  /// live in this group (hidden once I'm in it, or when it's mine).
  Widget _groupListenJoinBar(int room) {
    return ListenableBuilder(
      listenable: LiveRoomsRegistry.instance,
      builder: (context, _) {
        final r = LiveRoomsRegistry.instance.roomForConversation(room);
        if (r == null) return const SizedBox.shrink();
        final sid = (r['session_id'] ?? '').toString();
        if (activeLiveSession?.controller.sessionId == sid) {
          return const SizedBox.shrink();
        }
        final scheme = Theme.of(context).colorScheme;
        final host = ContactNames.instance.displayName(
            userId: r['host_id'],
            registered: (r['host_username'] ?? 'Someone').toString());
        final t = (r['track'] as Map?)?['title']?.toString().trim() ?? '';
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Material(
            color: scheme.primary,
            borderRadius: BorderRadius.circular(Radii.md),
            child: InkWell(
              borderRadius: BorderRadius.circular(Radii.md),
              onTap: () => _dropIntoRoom(r),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                child: Row(children: [
                  Icon(Icons.headphones_rounded,
                      size: 18, color: scheme.onPrimary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      t.isEmpty
                          ? '$host is playing for the group'
                          : '$host is playing “$t”',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: scheme.onPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _dropIntoRoom(r),
                    style: TextButton.styleFrom(
                      foregroundColor: scheme.onPrimary,
                      backgroundColor: scheme.onPrimary.withAlpha(38),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Join',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _groupCallJoinBar(Map<String, dynamic> g, int room) {
    return ValueListenableBuilder<Map<int, String>>(
      valueListenable: GroupCallService.instance.ongoingCalls,
      builder: (context, ongoing, _) {
        final call = GroupCallService.instance;
        // If I'm already in this room's call, the global return bar covers it.
        final inThisCall = call.isActive && call.room == room;
        if (!ongoing.containsKey(room) || inThisCall) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Material(
            color: const Color(0xFF1F8B4C),
            borderRadius: BorderRadius.circular(Radii.md),
            child: InkWell(
              borderRadius: BorderRadius.circular(Radii.md),
              onTap: () => _joinGroupCall(g),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                child: Row(
                  children: [
                    const Icon(Icons.call_rounded,
                        size: 18, color: Colors.white),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Group call in progress',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: () => _joinGroupCall(g),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        backgroundColor: Colors.white.withAlpha(38),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Join',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// The playlist drawer, hosted BELOW the active header so the header (and the
  /// chat's playlist toggle) stay visible above it. Slides/fades in from the
  /// right on [_playlistDrawerCtrl]; swipe right or tap the scrim to close.
  /// [music] hosts live on the music surface, the other on the chat surface —
  /// only the front-most one builds content, so it's never duplicated.
  Widget _playlistDrawerHost(BuildContext context, {required bool music}) {
    final builder = playlistDrawerBus.contentBuilder;
    if (builder == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _playlistDrawerCtrl,
      builder: (context, _) {
        final t = _playlistDrawerCtrl.value;
        if (t <= 0.001 || music != _musicIsFront) {
          return const SizedBox.shrink();
        }
        // Tell the playlist body which surface it's on: chat surface (music:false)
        // has the app now-playing bar, so the body drops its inline strip there.
        playlistDrawerBus.hostIsChatSurface = !music;
        final scheme = Theme.of(context).colorScheme;
        final eased = Curves.easeOutCubic.transform(t);
        // Music surface: the playlist is a full PAGE, not a drawer. It fills the
        // whole panel (the Positioned.fill host already covers the "Now Playing"
        // header), needs no scrim. It slides in from the LEFT to its resting
        // position (so the motion agrees with the back ← arrow) and fades as it
        // goes; tapping the arrow reverses it back out to the left. The
        // overlay's own header (back arrow + controls) becomes the page's top bar.
        if (music) {
          return IgnorePointer(
            ignoring: t < 0.05,
            child: Opacity(
              opacity: eased,
              child: FractionalTranslation(
                translation: Offset(-(1 - eased) * 0.12, 0),
                child: Material(
                  // Transparent so only the overlay's own rounded card shows
                  // (no square surface behind its rounded corners).
                  color: Colors.transparent,
                  child: ValueListenableBuilder<int>(
                    valueListenable: playlistDrawerBus.revision,
                    builder: (c, _, _) => builder(c),
                  ),
                ),
              ),
            ),
          );
        }
        return LayoutBuilder(
          builder: (ctx, cons) {
            final isPhone = cons.maxWidth < 520;
            final double panelW =
                isPhone ? cons.maxWidth : cons.maxWidth.clamp(0.0, 460.0).toDouble();
            // Full-width (phone): sharp corners so no dimmed layer peeks through
            // the rounding. Narrower (desktop): keep the soft left "curtain" edge.
            final bool fullWidth = panelW >= cons.maxWidth - 0.5;
            final BorderRadius panelRadius = fullWidth
                ? BorderRadius.zero
                : const BorderRadius.only(
                    topLeft: Radius.circular(Radii.xl),
                    bottomLeft: Radius.circular(Radii.xl),
                  );
            return Stack(
              children: [
                // Dim scrim — fades with the drawer; tap to close.
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: t < 0.05,
                    child: Opacity(
                      opacity: 0.5 * eased,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => playlistDrawerBus.close?.call(),
                        child: const ColoredBox(color: Colors.black),
                      ),
                    ),
                  ),
                ),
                // The sliding panel — glides in from the right edge.
                Align(
                  alignment: Alignment.centerRight,
                  child: FractionalTranslation(
                    translation: Offset(1 - eased, 0),
                    // A passive Listener (not a GestureDetector) tracks a RIGHT
                    // swipe to close the drawer like a curtain. Because it never
                    // enters the gesture arena, it works EVERYWHERE on the panel
                    // — including over the swipe-to-delete rows — without blocking
                    // taps, vertical scrolling, or the rows' left-swipe delete.
                    child: Listener(
                      onPointerDown: (e) {
                        _drawerPointer = e.pointer;
                        _drawerSwipeDx = 0;
                        _drawerSwipeDy = 0;
                      },
                      onPointerMove: (e) {
                        if (e.pointer != _drawerPointer) return;
                        _drawerSwipeDx += e.delta.dx;
                        _drawerSwipeDy += e.delta.dy;
                      },
                      onPointerUp: (e) {
                        if (e.pointer != _drawerPointer) return;
                        // Rightward + clearly horizontal = a close swipe.
                        if (_drawerSwipeDx > 64 &&
                            _drawerSwipeDx > _drawerSwipeDy.abs() * 1.4) {
                          playlistDrawerBus.close?.call();
                        }
                        _drawerPointer = null;
                        _drawerSwipeDx = 0;
                        _drawerSwipeDy = 0;
                      },
                      onPointerCancel: (e) {
                        if (e.pointer == _drawerPointer) {
                          _drawerPointer = null;
                          _drawerSwipeDx = 0;
                          _drawerSwipeDy = 0;
                        }
                      },
                      child: SizedBox(
                        width: panelW,
                        height: double.infinity,
                        child: Material(
                          color: scheme.surface,
                          elevation: Depth.high,
                          shadowColor: Colors.black.withAlpha(120),
                          borderRadius: panelRadius,
                          clipBehavior: Clip.antiAlias,
                          child: ValueListenableBuilder<int>(
                            valueListenable: playlistDrawerBus.revision,
                            builder: (c, _, _) => builder(c),
                          ),
                        ),
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

  /// The header status dot. Normally a solid [color] dot; while any background
  /// task is running (see [appBusy]) it becomes a small spinner in the same
  /// colour, so the user can see the app IS working (not frozen). Fixed 11×11
  /// footprint so the pill doesn't jump between states.
  Widget _statusDot(Color color) {
    return SizedBox(
      width: 11,
      height: 11,
      child: ValueListenableBuilder<int>(
        valueListenable: appBusy.count,
        builder: (_, busy, _) {
          if (busy > 0) {
            return CircularProgressIndicator(
              strokeWidth: 1.6,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            );
          }
          return Center(
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            ),
          );
        },
      ),
    );
  }

  // mm:ss (or h:mm:ss for long tracks).
  String _fmtClock(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$s';
    return '$m:$s';
  }

  Widget _buildFooter(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return rp.Consumer(
      builder: (context, ref, _) {
        // Pure status strip: a connection dot + online-friends count on the
        // left, profile pill on the right. The "Connected" label is dropped —
        // seeing your online friends (plus the toast) already tells you you're
        // back online, so the word was redundant.
        final np = ref.watch(nowPlayingProvider);
        // The wide two-pane layout already shows the music PANE (unless chat is
        // maximised), so the footer pill would be redundant there.
        final musicPaneVisible =
            MediaQuery.of(context).size.width >= 640 && !_isChatFullScreen;
        // The collapsed now-playing BAR is up only when a track is loaded and
        // not dismissed; while it's up, the pill would just duplicate it.
        final barShowing =
            np.track.isNotEmpty && !_barDismissed && !_playerExpanded;
        // Persistent entry point to the player: show the pill whenever the pane
        // isn't on screen and neither the bar nor the full player is up —
        // INCLUDING when no track is loaded yet (fresh launch scans the library
        // lazily), so portrait always has a way into music. This was the gap:
        // the pill used to require a loaded track, so a fresh phone had no music
        // entry point until rotated to landscape (where the pane always shows).
        final showMusicPill =
            !_playerExpanded && !musicPaneVisible && !barShowing;
        return Container(
          // Fill the footer colour behind the system navigation bar area too,
          // then SafeArea lifts the 44px status row up above the 3-button nav
          // bar (or the gesture pill) so the footer — and, because this is the
          // Scaffold's bottomNavigationBar, the whole body above it (chat
          // composer + now-playing bar) — never hides under the system controls.
          color: scheme.surfaceContainerHighest,
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 44,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
            children: [
              // Song-detail chip on the FAR LEFT (only while a track is loaded
              // and the bar is collapsed) — it balances the profile pill on the
              // right for a clean two-pill footer. The old server-connection dot
              // was removed: it duplicated the "N online" pill in the Messages
              // header, and server config now lives in Tools & settings.
              // Fixed-width pill (no Flexible — a flex here would split the row
              // with the Spacer and leave the profile pill mid-row instead of
              // far right). Hidden when the desktop music PANE is already on
              // screen (wide layout, chat not maximised) — the pane makes the
              // footer chip redundant — and when there's no real track.
              if (showMusicPill) _footerMusicChip(scheme),

              const Spacer(),

              // ── Right: profile pill only (online count now sits by the dot) ─
              // Tap the name (a pill-shaped button) to open your profile.
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () async {
                    await showAppPopup(context, const ProfileScreen(),
                    avatarFlight: true);
                    // Refresh the cached username in case it changed.
                    if (mounted) _loadUserData();
                  },
                  borderRadius: BorderRadius.circular(Radii.xl),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: scheme.primary.withAlpha(22),
                      borderRadius: BorderRadius.circular(Radii.xl),
                      border: Border.all(color: scheme.primary.withAlpha(70)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.person_rounded,
                            size: 14, color: accentInk(scheme)),
                        const SizedBox(width: 5),
                        Text(
                          // Narrow layouts (phones, or a shrunk web window)
                          // show just the first name so a full "First Last"
                          // doesn't eat the footer's space; wide screens
                          // (desktop) have room for the full name.
                          MediaQuery.of(context).size.width < 640
                              ? _username.trim().split(RegExp(r'\s+')).first
                              : _username,
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 3),
                        Icon(Icons.expand_less_rounded,
                            size: 14,
                            color: scheme.onSurface.withAlpha(130)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Desktop has no push service, so while its window is in the background a
  /// socket event a phone would get as a push showed only an in-app toast —
  /// playing to an empty room. Mirror those as local notifications, with the
  /// same words and taps as the phone's. (Phones: FCM does it; web: none.)
  void _mirrorForDesktop(String? type, Map<String, dynamic> event) {
    if (fcmSupported || _appForeground || type == null) return;
    final d = (event['data'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    String who(String key, String fallback) {
      final reg = (d[key] ?? '').toString();
      final id = int.tryParse('${d['from_id'] ?? d['user_id'] ?? d['by_id']}');
      if (id != null &&
          _allFriends.any((f) => (f['id'] as num?)?.toInt() == id)) {
        return _nameForUser(id);
      }
      return reg.isEmpty ? fallback : reg;
    }

    void show(String title, String body,
        {required String slot,
        required Map<String, dynamic> payload,
        String channel = alutaSpaceChannel,
        List<(String, String)> actions = const [(kOpen, 'Open')],
        String? person,
        String? personName}) {
      unawaited(showAlutaNotification(
        channel: channel,
        title: title,
        body: body,
        id: alutaNotifId('desk', slot),
        payload: payload,
        actions: actions,
        personKey: person,
        personName: personName,
      ));
    }

    final fromId = '${d['from_id'] ?? ''}';
    switch (type) {
      case 'live_invite':
        final sid = (d['session_id'] ?? '').toString();
        final hostId = '${d['host_id'] ?? ''}';
        final host = who('host_username', 'Your friend');
        final song = ((d['track'] as Map?)?['title'] ?? '').toString().trim();
        if (sid.isEmpty) return;
        // Already in it (a re-delivery after a blip): no notification.
        if (activeLiveSession?.controller.sessionId == sid) return;
        show('🎧 $host wants to listen with you',
            song.isEmpty ? "You'll hear the same song, in sync"
                : '$song · you\'ll hear it in sync',
            slot: 'live$hostId',
            channel: alutaListenChannel,
            payload: {
              'kind': 'live_invite',
              'session_id': sid,
              'host_id': hostId,
              'host_name': host,
              'track_title': song,
            },
            actions: const [(kLiveJoin, 'Join'), (kLiveLater, 'Not now')],
            person: 's$hostId',
            personName: host);
      case 'live_room_available':
        // Only a GROUP jam is announced to phones by push; a circle room
        // stays a quiet card. A muted group stays quiet.
        final cid = (d['conversation_id'] as num?)?.toInt();
        final hostId = (d['host_id'] as num?)?.toInt();
        if (cid == null || hostId == _myUserId) return;
        if (GroupMeta.instance.isMuted(cid)) return;
        final g = _groups.firstWhere(
            (x) => (x['id'] as num?)?.toInt() == cid,
            orElse: () => const <String, dynamic>{});
        final gTitle = (g['title'] ?? '').toString();
        final host = hostId != null &&
                _allFriends.any((f) => (f['id'] as num?)?.toInt() == hostId)
            ? _nameForUser(hostId)
            : (d['host_username'] ?? 'Someone').toString();
        final song = ((d['track'] as Map?)?['title'] ?? '').toString().trim();
        show('🎧 $host started a jam${gTitle.isEmpty ? '' : ' in $gTitle'}',
            song.isEmpty ? 'Drop in — everyone hears the same song, in sync'
                : '$song · you\'ll hear it in sync',
            slot: 'jam$cid',
            channel: alutaListenChannel,
            payload: {
              'kind': 'live_invite',
              'session_id': '${d['session_id'] ?? ''}',
              'host_id': '$hostId',
              'host_name': host,
              'track_title': song,
              'conversation_id': '$cid',
              'group_title': gTitle,
            },
            actions: const [(kLiveJoin, 'Join'), (kLiveLater, 'Not now')],
            person: 'c$cid',
            personName: gTitle.isEmpty ? host : gTitle);
      case 'space_moment' ||
            'space_playlist_add' ||
            'dedication_received' ||
            'space_diary' ||
            'space_diary_comment' ||
            'space_moment_comment' ||
            'space_capsule' ||
            'capsule_unlocked' ||
            'space_nudge' ||
            'prompt_answered':
        final line = (d['line'] ?? '').toString();
        if (line.isEmpty) return;
        final name = who('from_username', 'Your partner');
        show(_inMyNames(d, line), 'Our Space 💞',
            slot: '$type$fromId',
            payload: {'kind': 'space', 'from': fromId},
            person: fromId.isEmpty ? null : 's$fromId',
            personName: name);
      case 'bond_request' || 'bond_request_accepted':
        final line = (d['line'] ?? '').toString();
        if (line.isEmpty) return;
        show(_inMyNames(d, line), 'Our Space 💞',
            slot: '$type$fromId', payload: {'kind': 'open'});
      case 'heartbeat_tap':
        final name = who('from_name', 'Your partner');
        show('💓 $name', '$name is thinking of you',
            slot: 'beat$fromId',
            payload: {'kind': 'chat', 'from': fromId, 'from_name': name},
            person: fromId.isEmpty ? null : 's$fromId',
            personName: name);
      case 'friend_started_playing':
        final id = '${d['user_id'] ?? ''}';
        final name = who('username', 'Your friend');
        final song = (d['title'] ?? '').toString().trim();
        show(song.isEmpty ? '🎶 $name is playing music'
                : '🎶 $name is playing "$song"',
            'Tune in — you join right where they are',
            slot: 'play$id',
            channel: alutaListenChannel,
            payload: {
              'kind': 'play_watch',
              'from': id,
              'from_name': name,
              'title': song,
            },
            actions: const [(kTuneAsk, 'Tune in')],
            person: id.isEmpty ? null : 's$id',
            personName: name);
      case 'friend_came_online':
        final id = '${d['user_id'] ?? ''}';
        final name = who('username', 'Your friend');
        show('$name is online now 🟢',
            d['purpose'] == 'listen'
                ? 'Ready to listen together? 🎧'
                : "Say hi while they're here 👋",
            slot: 'online$id',
            channel: alutaListenChannel,
            payload: {'kind': 'chat', 'from': id, 'from_name': name},
            person: id.isEmpty ? null : 's$id',
            personName: name);
      case 'heart_opened':
        final id = '${d['by_id'] ?? ''}';
        final phone = (d['by_phone'] ?? '').toString();
        final saved =
            phone.isNotEmpty ? ContactNames.instance.nameFor(phone) : null;
        final name = (saved != null && saved.isNotEmpty)
            ? saved
            : (d['by_name'] ?? 'Someone').toString();
        show(name, 'opened your secret heart 💗',
            slot: 'heart$id',
            payload: {'kind': 'chat', 'from': id, 'from_name': name},
            person: id.isEmpty ? null : 's$id',
            personName: name);
    }
  }
}
