part of '../home_page.dart';

// The MOBILE two-layer switcher for the friend page. Instead of stacked headers,
// the two flagship layers live as compact toggle-PILLS in the header row (see
// _buildChatHeader): HARMONY and CIRCLE, each badged, the active one lit. Tapping
// a pill switches which layer fills the screen — so the lit pill IS the header
// and the whole area below is that layer's content, starting with its own
// contextual search bar. Both badges stay visible at all times, so any pending
// item (unread chats, a bond you can tune into) reaches the user at first glance.
// Desktop keeps both columns open (see home_friend_list.dart); this is narrow-only.
//
// A private extension on HomePageState (a library part). It never calls setState
// directly — the pill toggle delegates to HomePageState._setFriendLayer — so it
// stays clear of @protected.
extension _HomeHub on HomePageState {
  /// Mobile friend body: just the ACTIVE layer, its own contextual search at the
  /// top, content scrolling below. The Harmony/Circle pills that switch layers
  /// live in the header (_buildChatHeader).
  Widget _friendHubMobile(
      List<Map<String, dynamic>> harmonyEntries,
      List<Map<String, dynamic>> circleEntries,
      ColorScheme scheme,
      Color textColor) {
    final harmony = _friendLayer == 'harmony';
    if (_friendLayer == 'glow') return const GlowFeed();

    // HARMONY layer is unchanged: contextual search + a single scrolling list.
    if (harmony) {
      return Column(
        children: [
          _friendSearchField(
            scheme,
            _spaceSearchCtrl,
            'Search your spaces…',
            _filterSpaces,
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Stack(children: [
              RefreshIndicator(
                onRefresh: _onPullToRefresh,
                child: ListView.builder(
                  // Remembers where I'd scrolled: opening a chat replaces
                  // this list, and coming back rebuilds it — the key
                  // restores the position instead of jumping to the top.
                  key: const PageStorageKey<String>('harmony-list'),
                  controller: _harmonyScroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: harmonyEntries.length,
                  itemBuilder: (_, i) =>
                      _friendEntry(harmonyEntries, i, scheme, textColor),
                ),
              ),
              Positioned(
                right: 8,
                bottom: 14,
                child: _listTopChip(_harmonyScroll, scheme),
              ),
            ]),
          ),
        ],
      );
    }

    // CIRCLE layer — a space-savvy, consistent layout:
    //  • search (fixed)
    //  • Status & Stories: pinned but COLLAPSIBLE, so a user who just wants
    //    chats can reclaim the whole tray's height with one tap.
    //  • Listening now: still pops above the list when friends are live, but it
    //    sits in a HEIGHT-CAPPED box that scrolls internally once it passes a
    //    couple of rows — so many listeners can never shove the circle down.
    //  • "YOUR CIRCLE": a FIXED header above the scrolling chat list, so it is
    //    always pinned in view no matter what sits above it.
    //  • Any of the three can be maximised to the whole screen and minimised
    //    back (see _circleSections).
    final listening = <Map<String, dynamic>>[];
    final circle = <Map<String, dynamic>>[];
    var zone = '';
    for (final e in circleEntries) {
      if (e['kind'] == 'header') {
        final label = e['label'] as String? ?? '';
        zone = label == 'Listening now'
            ? 'listening'
            : label == 'Your circle'
                ? 'circle'
                : 'other';
        continue;
      }
      if (e['kind'] != 'tile') continue;
      (zone == 'listening' ? listening : circle).add(e);
    }

    return Column(
      children: [
        _friendSearchField(
          scheme,
          _searchCtrl,
          _circleSearchHint,
          _filterFriends,
        ),
        const SizedBox(height: 10),
        ..._circleSections(listening, circle, scheme, textColor, wide: false),
      ],
    );
  }

  /// The CIRCLE sections below the search, shared by the phone layer and the
  /// desktop column. By default ('all') Status & Stories, Listening now and
  /// Your circle share the height. Each header carries a full-height control:
  /// that section then takes the whole column / screen (Status as a grid,
  /// Listening / chats as full lists) and the same control minimises it back.
  List<Widget> _circleSections(
      List<Map<String, dynamic>> listening,
      List<Map<String, dynamic>> circle,
      ColorScheme scheme,
      Color textColor,
      {required bool wide}) {
    // Status needs to know who "me" is (cold start may not yet): until then
    // the shared view stands in.
    final view =
        (_circleView == 'stories' && _myUserId == null) ? 'all' : _circleView;
    final storiesUnseen = _storyGroups
        .where((g) =>
            !g.isMe && g.hasUnseen && !StoryMute.instance.isMuted(g.authorId))
        .length;
    final pad = wide
        ? const EdgeInsets.fromLTRB(6, 0, 6, 12)
        : const EdgeInsets.only(bottom: 12);
    final k = wide ? 'wide-' : '';

    if (view == 'stories') {
      // The one Circle search box filters whichever section is maximised —
      // here, statuses by the name I know them by.
      final q = _searchQuery.trim().toLowerCase();
      final groups = q.isEmpty
          ? _storyGroups
          : _storyGroups.where((g) {
              if (g.isMe) return true;
              final saved =
                  ContactNames.instance.nameFor((g.phone ?? '').trim()) ?? '';
              return g.username.toLowerCase().contains(q) ||
                  saved.toLowerCase().contains(q);
            }).toList();
      return [
        _listHeader(scheme, 'Status & Stories',
            storiesUnseen > 0 ? storiesUnseen : null, 'stories'),
        _circleJumpBar(scheme, storiesUnseen, listening.length),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _fetchStories,
            child: StoriesTray(
              apiBase: _apiBase,
              myUserId: _myUserId,
              myName: _username.isNotEmpty ? _username : 'You',
              myAvatarUrl: _myAvatar,
              groups: groups,
              onReload: _fetchStories,
              grid: true,
              searching: q.isNotEmpty,
              controller: _circleMaxScroll,
            ),
          ),
        ),
      ];
    }

    if (view == 'listening') {
      return [
        _listHeader(scheme, 'Listening now', listening.length, 'listening'),
        _circleJumpBar(scheme, storiesUnseen, listening.length),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _onPullToRefresh,
            child: listening.isEmpty
                ? _emptyListening(scheme, _searchQuery.trim().isNotEmpty)
                : ListView.builder(
                    key: PageStorageKey<String>('${k}listening-full'),
                    controller: _circleMaxScroll,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: pad,
                    itemCount: listening.length,
                    itemBuilder: (_, i) =>
                        _friendEntry(listening, i, scheme, textColor),
                  ),
          ),
        ),
      ];
    }

    // 'chats' maximised = EVERY conversation in one full list (the live ones
    // first, as everywhere); 'all' keeps the listeners in their own zone.
    final chats = view == 'chats' ? [...listening, ...circle] : circle;
    final showListening = view == 'all' && listening.isNotEmpty;
    return [
      if (view == 'all' && _myUserId != null) _collapsibleStories(scheme),
      if (showListening) ...[
        _listHeader(scheme, 'Listening now', listening.length, 'listening'),
        // Capped so a growing listener count scrolls WITHIN this zone instead
        // of pushing "Your circle" down — maximise it for the full list.
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: wide ? 220 : 190),
          child: ListView.builder(
            key: PageStorageKey<String>('${k}listening-list'),
            shrinkWrap: true,
            physics: const ClampingScrollPhysics(),
            padding: wide
                ? const EdgeInsets.symmetric(horizontal: 6)
                : EdgeInsets.zero,
            itemCount: listening.length,
            itemBuilder: (_, i) =>
                _friendEntry(listening, i, scheme, textColor),
          ),
        ),
      ],
      // Pinned "Your circle" header (fixed above the scrolling list).
      if (chats.isNotEmpty || view == 'chats')
        _listHeader(scheme, 'Your circle',
            view == 'chats' ? chats.length : null, 'chats'),
      if (view == 'chats')
        _circleJumpBar(scheme, storiesUnseen, listening.length),
      Expanded(
        child: Stack(children: [
          NotificationListener<UserScrollNotification>(
            // My own scrolling → don't yank the list for a new message now.
            onNotification: (_) {
              _lastUserScroll = DateTime.now();
              return false;
            },
            child: RefreshIndicator(
              onRefresh: _onPullToRefresh,
              child: chats.isNotEmpty
                  ? ListView.builder(
                      // Back from a chat → right where I left the list.
                      key: PageStorageKey<String>(view == 'chats'
                          ? '${k}circle-full'
                          : '${k}circle-list'),
                      controller: _circleScroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: pad,
                      itemCount: chats.length,
                      itemBuilder: (_, i) =>
                          _friendEntry(chats, i, scheme, textColor),
                    )
                  : (!showListening
                      ? _emptyConversations(scheme)
                      : ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [SizedBox(height: 220)],
                        )),
            ),
          ),
          // "↑ Top" once well down; "↑ 3 new" when chats got new messages
          // above me.
          if (chats.isNotEmpty)
            Positioned(
              right: 8,
              bottom: 14,
              child: _listTopChip(_circleScroll, scheme, countsNew: true),
            ),
        ]),
      ),
    ];
  }

  /// The Circle search hint follows the maximised section, so the box says
  /// what it will filter.
  String get _circleSearchHint => switch (_circleView) {
        'stories' => 'Search statuses…',
        'listening' => 'Search who\'s listening…',
        _ => 'Search chats & people…',
      };

  /// Full-height control on a Circle section header: maximise this section,
  /// or (when it's the one maximised) minimise back to the shared view.
  Widget _maxControl(ColorScheme scheme, String key) {
    final on = _circleView == key;
    return Tooltip(
      message: on ? 'Minimise' : 'Full height',
      child: InkWell(
        onTap: () => _setCircleView(key),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (on) ...[
              Text(
                'Minimise',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: accentInk(scheme),
                ),
              ),
              const SizedBox(width: 3),
            ],
            Icon(
              on
                  ? Icons.close_fullscreen_rounded
                  : Icons.open_in_full_rounded,
              size: 15,
              color: accentInk(scheme),
            ),
          ]),
        ),
      ),
    );
  }

  /// Under a MAXIMISED section: the other two as small live chips (with
  /// what's waiting there — unseen statuses, people listening, unread chats)
  /// so nothing is out of mind while one section has the height. A tap
  /// maximises that one instead; "All" goes back to the shared view.
  Widget _circleJumpBar(ColorScheme scheme, int storiesUnseen, int live) {
    final unread = _circleBadge();
    Widget chip(String key, IconData icon, String label, int n) {
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ActionChip(
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(horizontal: 2),
          avatar: Icon(icon, size: 15, color: accentInk(scheme)),
          label: Text(n > 0 ? '$label · $n' : label,
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: n > 0 ? FontWeight.w800 : FontWeight.w600)),
          side: BorderSide(
              color: n > 0
                  ? scheme.primary.withAlpha(120)
                  : scheme.outlineVariant.withAlpha(90)),
          onPressed: () => _setCircleView(key),
        ),
      );
    }

    final view = _circleView;
    return SizedBox(
      height: 38,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        children: [
          chip(view, Icons.dashboard_rounded, 'All', 0),
          if (view != 'stories' && _myUserId != null)
            chip('stories', Icons.auto_stories_rounded, 'Status',
                storiesUnseen),
          if (view != 'listening')
            chip('listening', Icons.headphones_rounded, 'Listening', live),
          if (view != 'chats')
            chip('chats', Icons.forum_rounded, 'Chats', unread),
        ],
      ),
    );
  }

  /// Listening maximised, nobody live right now.
  Widget _emptyListening(ColorScheme scheme, bool searching) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 0),
      children: [
        Icon(Icons.headphones_rounded,
            size: 36, color: scheme.onSurfaceVariant.withAlpha(150)),
        const SizedBox(height: 10),
        Text(
          searching
              ? 'No one listening matches that name'
              : 'Nobody in your circle is listening right now',
          textAlign: TextAlign.center,
          style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurface),
        ),
        const SizedBox(height: 4),
        if (!searching)
          Text(
            'Play something — your friends see you here and can tune in.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
        const SizedBox(height: 14),
        Center(
          child: TextButton.icon(
            onPressed: () => _setCircleView('listening'),
            icon: const Icon(Icons.close_fullscreen_rounded, size: 16),
            label: const Text('Back to all'),
          ),
        ),
      ],
    );
  }

  /// The mobile CIRCLE "Status & Stories" tray — pinned at the top, but now
  /// COLLAPSIBLE. Its header is a tap target with a Hide/Show chevron; folding
  /// it away animates the tray shut and hands that height to the chat list.
  Widget _collapsibleStories(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _toggleStories,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 2, 6, 4),
                  child: Row(
                    children: [
                      Text(
                        'STATUS & STORIES',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.1,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _storiesExpanded ? 'Hide' : 'Show',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: accentInk(scheme),
                        ),
                      ),
                      const SizedBox(width: 2),
                      AnimatedRotation(
                        turns: _storiesExpanded ? 0.0 : 0.5,
                        duration: const Duration(milliseconds: 200),
                        child: Icon(Icons.keyboard_arrow_up_rounded,
                            size: 20, color: accentInk(scheme)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Full height: Status takes the whole column / screen as a grid.
          _maxControl(scheme, 'stories'),
        ]),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: _storiesExpanded
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(6, 2, 6, 0),
                  child: StoriesTray(
                    apiBase: _apiBase,
                    myUserId: _myUserId,
                    myName: _username.isNotEmpty ? _username : 'You',
                    myAvatarUrl: _myAvatar,
                    groups: _storyGroups,
                    onReload: _fetchStories,
                    compact: true,
                  ),
                )
              : const SizedBox(width: double.infinity, height: 0),
        ),
        const SizedBox(height: 6),
        Container(height: 1, color: scheme.outlineVariant.withAlpha(45)),
        const SizedBox(height: 2),
      ],
    );
  }

  /// One layer toggle-pill for the mobile header: icon + label + badge, lit when
  /// active and calm when not. Tapping switches the whole friend body to it.
  Widget _layerTab(ColorScheme scheme, String key, String label, IconData icon,
      int badge, {bool compact = false, VoidCallback? onTap}) {
    final active = _friendLayer == key;
    // Tight phones: the inactive pills drop their label (icon only).
    final showLabel = !compact || active;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Inactive pills read as real, tappable buttons too: a soft raised chip
    // with a brand-tinted hairline and an accent icon (not a faint outline).
    final idleBg = isDark
        ? scheme.surfaceContainerHigh
        : Color.alphaBlend(scheme.primary.withValues(alpha: 0.05), Colors.white);
    final idleFg = scheme.primary.withValues(alpha: isDark ? 0.85 : 0.78);
    return Tooltip(
      message: label,
      child: Material(
      color: Colors.transparent,
      child: InkWell(
        // Tapping the lit pill again → that list glides back to the top.
        onTap: onTap ??
            () => active ? _scrollLayerToTop(key) : _setFriendLayer(key),
        borderRadius: BorderRadius.circular(20),
        // The badge FLOATS on the corner (Stack, no clip) instead of sitting
        // inline — so it adds zero width to the pill. A growing count (even
        // "99+") can never nudge the neighbouring pill; the two stay put.
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: EdgeInsets.symmetric(
                  horizontal: showLabel ? 12 : 9, vertical: 7),
              decoration: BoxDecoration(
                color: active ? scheme.primary.withAlpha(30) : idleBg,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: active
                      ? scheme.primary.withAlpha(130)
                      : scheme.primary.withValues(alpha: isDark ? 0.40 : 0.30),
                  width: active ? 1 : 1.2,
                ),
                // Active lifts with an accent glow; idle sits on a soft shadow.
                boxShadow: active
                    ? [
                        BoxShadow(
                          color: scheme.primary.withValues(alpha: 0.26),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ]
                    : [
                        BoxShadow(
                          color: Colors.black
                              .withValues(alpha: isDark ? 0.30 : 0.08),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon,
                      size: showLabel ? 15 : 17,
                      color: active ? scheme.primary : idleFg),
                  if (showLabel) ...[
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                      color: active ? scheme.onSurface : idleFg,
                    ),
                  ),
                  ],
                ],
              ),
            ),
            if (badge > 0)
              Positioned(
                top: -6,
                right: -6,
                child: _hubBadgePill(scheme, badge),
              ),
          ],
        ),
      ),
      ),
    );
  }

  /// The little count pill used on the mobile layer pills AND the desktop column
  /// headers, so pending counts read the same everywhere.
  Widget _hubBadgePill(ColorScheme scheme, int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: TextStyle(
          color: scheme.onPrimary,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  /// CIRCLE badge — total unread across all DMs (Riverpod) + groups. This is the
  /// "pending to open" count that must reach the user at first glance.
  int _circleBadge() {
    final u = ref.watch(unreadProvider);
    int total = 0;
    for (final f in _allFriends) {
      final id = (f['id'] as num?)?.toInt();
      if (id != null) total += u.countFor(id);
    }
    for (final g in _groups) {
      // A muted group doesn't shout on the Circle tab either.
      final gid = (g['id'] as num?)?.toInt();
      if (gid != null && GroupMeta.instance.isMuted(gid)) continue;
      total += (g['unread_count'] as num?)?.toInt() ?? 0;
    }
    return total;
  }

  /// HARMONY badge — "pending to tune": distinct bonds in your Spaces who are
  /// listening RIGHT NOW (someone you could tune in with). Honest + live: it
  /// updates as presence changes, and reads 0 when nobody in your spaces is
  /// playing. (Live Rooms will add to this once C1 wires them up.)
  int _harmonyBadge() {
    final presence = NowPlayingPresence.instance;
    final seen = <int>{};
    for (final s in _spaces) {
      final members = (s['members'] as List?) ?? const [];
      for (final m in members) {
        if (m is Map) {
          final id = (m['id'] as num?)?.toInt();
          if (id != null &&
              id != _myUserId &&
              !seen.contains(id) &&
              presence.trackFor(id) != null) {
            seen.add(id);
          }
        }
      }
    }
    return seen.length;
  }
}
