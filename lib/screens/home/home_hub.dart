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

    // Swipe between sections like pages: ← next (All → Status → Listening
    // → Your circle), → previous — so a swipe right walks back to All (and
    // Android's back gesture still minimises in one go). Rows / the story
    // strip keep their own swipes; this catches the rest of the screen.
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v.abs() < 300) return;
        final order = HomePageState.kCircleViews
            .where((k) => k != 'stories' || _myUserId != null)
            .toList();
        final i = order.indexOf(_circleView);
        final j = (i + (v < 0 ? 1 : -1)).clamp(0, order.length - 1);
        if (j != i) _goCircleView(order[j]);
      },
      child: Column(
        children: [
          _friendSearchField(
            scheme,
            _searchCtrl,
            _circleSearchHint,
            _filterFriends,
          ),
          const SizedBox(height: 10),
          ..._circleSections(listening, circle, scheme, textColor,
              wide: false),
        ],
      ),
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
    // Once per launch: land on the section where something is waiting.
    _maybeSmartLanding(
        unread: _circleBadge(),
        newStatuses: storiesUnseen,
        live: listening.length);
    final k = wide ? 'wide-' : '';
    return [
      // A maximised section: the 3D switcher (the shared view keeps its own
      // per-section headers).
      if (view != 'all')
        _circleSwitcher(scheme, storiesUnseen, listening, circle, textColor),
      // Every change of section turns like a cube face (← forward, → back).
      Expanded(
        child: _CircleFlip(
          child: KeyedSubtree(
            key: ValueKey('${k}sec-$view'),
            child: _sectionBody(
                view, listening, circle, scheme, textColor, wide: wide),
          ),
        ),
      ),
    ];
  }

  /// The body of one Circle view, filling the height below the switcher.
  Widget _sectionBody(
      String view,
      List<Map<String, dynamic>> listening,
      List<Map<String, dynamic>> circle,
      ColorScheme scheme,
      Color textColor,
      {required bool wide}) {
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
      return RefreshIndicator(
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
      );
    }

    if (view == 'listening') {
      return RefreshIndicator(
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
      );
    }

    // 'chats' maximised = EVERY conversation in one full list (the live ones
    // first, as everywhere); 'all' keeps the listeners in their own zone.
    final chats = view == 'chats' ? [...listening, ...circle] : circle;
    final showListening = view == 'all' && listening.isNotEmpty;
    final list = Stack(children: [
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
                  key: PageStorageKey<String>(
                      view == 'chats' ? '${k}circle-full' : '${k}circle-list'),
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
    ]);
    if (view == 'chats') return list;
    return Column(children: [
      if (_myUserId != null) _collapsibleStories(scheme),
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
      if (chats.isNotEmpty) _listHeader(scheme, 'Your circle', null, 'chats'),
      Expanded(child: list),
    ]);
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

  /// The 3D section switcher above a maximised Circle section — one row:
  /// a sunken track with All · Status · Listening · Circle, the current one
  /// on a raised, lit "key" that SLIDES between segments (springy), each
  /// other segment showing what's waiting there (and breathing once when it
  /// grows). Tap → switch; tap the lit one or All → back to all; hold →
  /// peek; a compact ⤡ at the end minimises too. Narrow → icons + counts.
  Widget _circleSwitcher(
      ColorScheme scheme,
      int storiesUnseen,
      List<Map<String, dynamic>> listening,
      List<Map<String, dynamic>> circle,
      Color textColor) {
    final view = _circleView;
    final unread = _circleBadge();
    final isDark = scheme.brightness == Brightness.dark;
    final segs = <(String, IconData, String, int, String)>[
      ('all', Icons.dashboard_rounded, 'All', 0, ''),
      if (_myUserId != null)
        ('stories', Icons.auto_stories_rounded, 'Status', storiesUnseen,
            'new'),
      ('listening', Icons.headphones_rounded, 'Listening', listening.length,
          'live now'),
      ('chats', Icons.forum_rounded, 'Circle', unread, 'unread'),
    ];
    final sel = segs.indexWhere((s) => s.$1 == view).clamp(0, segs.length - 1);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 0, 8),
      child: LayoutBuilder(builder: (context, cons) {
        const minW = 34.0;
        final trackW = cons.maxWidth - minW - 4;
        final segW = trackW / segs.length;
        final labelled = segW >= 74;
        final wideKeys = cons.maxWidth >= 560;
        final thumbTop = Color.lerp(scheme.primary, Colors.white, 0.22)!;
        final thumbBot = Color.lerp(scheme.primary, Colors.black, 0.22)!;
        final onThumb = readableOn(scheme.primary);
        return Row(children: [
          SizedBox(
            width: trackW,
            height: 38,
            child: DecoratedBox(
              // The sunken track: darker at the top (an inset shadow).
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(19),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: isDark
                      ? [
                          Color.lerp(scheme.surface, Colors.black, 0.45)!,
                          scheme.surfaceContainerHigh,
                        ]
                      : [
                          Color.lerp(scheme.surfaceContainerHighest,
                              Colors.black, 0.10)!,
                          scheme.surfaceContainerHighest,
                        ],
                ),
                border: Border.all(
                    color: scheme.outlineVariant.withValues(alpha: 0.45)),
              ),
              child: Stack(children: [
                // The raised, lit key — slides (with a little spring).
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 360),
                  curve: Curves.easeOutBack,
                  left: sel * segW + 3,
                  top: 3,
                  bottom: 3,
                  width: segW - 6,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [thumbTop, scheme.primary, thumbBot],
                        stops: const [0.0, 0.55, 1.0],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: scheme.primary.withValues(alpha: 0.45),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.30),
                          blurRadius: 3,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    // A glassy highlight along its top edge.
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Container(
                        height: 1.2,
                        margin: const EdgeInsets.symmetric(horizontal: 10),
                        color: Colors.white.withValues(alpha: 0.35),
                      ),
                    ),
                  ),
                ),
                Row(children: [
                  for (var i = 0; i < segs.length; i++)
                    SizedBox(
                      width: segW,
                      child: _switchSeg(
                        scheme,
                        segs[i],
                        selected: i == sel,
                        labelled: labelled,
                        onThumb: onThumb,
                        tip: wideKeys
                            ? '   Alt+${HomePageState.kCircleViews.indexOf(segs[i].$1) + 1}'
                            : '',
                        peek: () => _peekContent(
                            segs[i].$1, listening, circle, scheme, textColor),
                      ),
                    ),
                ]),
              ]),
            ),
          ),
          const SizedBox(width: 4),
          // ⤡ — minimise, for those who learned it (All does the same).
          SizedBox(
            width: minW,
            child: IconButton(
              tooltip: 'Minimise',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              icon: Icon(Icons.close_fullscreen_rounded,
                  size: 17, color: accentInk(scheme)),
              onPressed: () => _goCircleView('all'),
            ),
          ),
        ]);
      }),
    );
  }

  Widget _switchSeg(
    ColorScheme scheme,
    (String, IconData, String, int, String) s, {
    required bool selected,
    required bool labelled,
    required Color onThumb,
    required String tip,
    required Widget Function() peek,
  }) {
    final (key, icon, text, n, what) = s;
    final hot = n > 0 && !selected;
    final fg = selected
        ? onThumb
        : hot
            ? accentInk(scheme)
            : scheme.onSurfaceVariant;
    // Tooltips use the shared view's full names ("Your circle", "Status &
    // Stories", "Listening now") — the segment shows the short one.
    final full = switch (key) {
      'stories' => 'Status & Stories',
      'listening' => 'Listening now',
      'chats' => 'Your circle',
      _ => 'All',
    };
    final message = (selected && key != 'all')
        ? 'Back to all'
        : (n > 0 && what.isNotEmpty ? '$full · $n $what' : full);
    return Tooltip(
      message: message + tip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => selected ? _goCircleView('all') : _goCircleView(key),
        // Hold → that section peeks over this one; let go → gone.
        onLongPressStart: selected
            ? null
            : (_) => _CirclePeek.show(context, peek(), text),
        onLongPressEnd: (_) => _CirclePeek.hide(),
        onLongPressCancel: _CirclePeek.hide,
        child: _PulseOnRise(
          value: n,
          color: scheme.primary,
          child: SizedBox(
            height: 38,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedScale(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutBack,
                  scale: selected ? 1.12 : 1,
                  child: Icon(icon, size: 15, color: fg),
                ),
                if (labelled) ...[
                  const SizedBox(width: 5),
                  Flexible(
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 200),
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight:
                              selected ? FontWeight.w800 : FontWeight.w600,
                          color: fg),
                      child: Text(text,
                          maxLines: 1, overflow: TextOverflow.fade,
                          softWrap: false),
                    ),
                  ),
                ],
                if (hot) ...[
                  const SizedBox(width: 4),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(n > 99 ? '99+' : '$n',
                        style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w800,
                            color: readableOn(scheme.primary))),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// What a held pill peeks: that section, read-only, in a floating card.
  Widget _peekContent(
      String key,
      List<Map<String, dynamic>> listening,
      List<Map<String, dynamic>> circle,
      ColorScheme scheme,
      Color textColor) {
    if (key == 'stories') {
      return StoriesTray(
        apiBase: _apiBase,
        myUserId: _myUserId,
        myName: _username.isNotEmpty ? _username : 'You',
        myAvatarUrl: _myAvatar,
        groups: _storyGroups,
        onReload: _fetchStories,
        grid: true,
      );
    }
    final rows = key == 'listening'
        ? listening
        : key == 'chats'
            ? [...listening, ...circle]
            : const <Map<String, dynamic>>[];
    if (rows.isEmpty) {
      return Center(
        child: Text(
            key == 'listening'
                ? 'Nobody is listening right now'
                : 'Nothing here yet',
            style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      itemCount: rows.length.clamp(0, 12),
      itemBuilder: (_, i) => _friendEntry(rows, i, scheme, textColor),
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

/// A Circle pill that BREATHES once when its count goes up (a new status,
/// someone started playing, a new unread) — the same gentle swell as the
/// ⌖ glow, never a flashing badge. Nothing moves in the list.
class _PulseOnRise extends StatefulWidget {
  const _PulseOnRise(
      {required this.value, required this.color, required this.child});
  final int value;
  final Color color;
  final Widget child;

  @override
  State<_PulseOnRise> createState() => _PulseOnRiseState();
}

class _PulseOnRiseState extends State<_PulseOnRise>
    with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1000));

  @override
  void didUpdateWidget(_PulseOnRise old) {
    super.didUpdateWidget(old);
    if (widget.value > old.value) _a.forward(from: 0);
  }

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _a,
      child: widget.child,
      builder: (_, child) {
        final t = _a.value;
        if (t == 0 || t == 1) return child!;
        final i = t < 0.35
            ? Curves.easeOut.transform(t / 0.35)
            : 1 - Curves.easeInOut.transform((t - 0.35) / 0.65);
        return Transform.scale(
          scale: 1 + 0.08 * i,
          child: DecoratedBox(
            decoration: ShapeDecoration(
              shape: const StadiumBorder(),
              shadows: [
                BoxShadow(
                    color: widget.color.withValues(alpha: 0.45 * i),
                    blurRadius: 14,
                    spreadRadius: 1),
              ],
            ),
            child: child,
          ),
        );
      },
    );
  }
}

/// Hold-to-peek: a Circle section floating over the current one while a
/// pill is held (read-only — the finger is still down); let go → gone.
class _CirclePeek {
  static OverlayEntry? _entry;

  static void show(BuildContext context, Widget content, String title) {
    hide();
    HapticFeedback.selectionClick();
    final overlay = Overlay.of(context);
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    _entry = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: IgnorePointer(
          child: ColoredBox(
            color: Colors.black.withValues(alpha: 0.25),
            child: Center(
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutBack,
                builder: (_, t, child) => Opacity(
                  opacity: t.clamp(0.0, 1.0),
                  child: Transform.scale(scale: 0.9 + 0.1 * t, child: child),
                ),
                child: Material(
                  color: scheme.surface,
                  elevation: 12,
                  borderRadius: BorderRadius.circular(20),
                  clipBehavior: Clip.antiAlias,
                  child: SizedBox(
                    width: (size.width < 472 ? size.width : 472.0) - 32,
                    height: size.height * 0.55,
                    child: Column(children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                        child: Row(children: [
                          Icon(Icons.visibility_rounded,
                              size: 16, color: scheme.primary),
                          const SizedBox(width: 6),
                          Text('Peek · $title',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w800, fontSize: 13)),
                        ]),
                      ),
                      Expanded(child: content),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_entry!);
  }

  static void hide() {
    _entry?.remove();
    _entry = null;
  }
}

/// A Circle section change, in the user's chosen transition (Appearance →
/// Section transitions; default slide + wave). The new view comes from the
/// side it lives on (← forward: All → Status → Listening → Circle; → back).
/// [forward] is set by HomePageState._goCircleView.
class _CircleFlip extends StatelessWidget {
  const _CircleFlip({required this.child});
  final Widget child;
  static bool forward = true;
  // Ripple starts at the switcher segment I picked (its centre, 0..1).
  static double? rippleFrom;

  @override
  Widget build(BuildContext context) => SectionSwitch(
      forward: forward, rippleFrom: rippleFrom, child: child);
}
