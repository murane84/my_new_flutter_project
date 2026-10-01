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
            child: RefreshIndicator(
              onRefresh: _onPullToRefresh,
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 12),
                itemCount: harmonyEntries.length,
                itemBuilder: (_, i) =>
                    _friendEntry(harmonyEntries, i, scheme, textColor),
              ),
            ),
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
          'Search chats & people…',
          _filterFriends,
        ),
        const SizedBox(height: 10),
        if (_myUserId != null) _collapsibleStories(scheme),
        if (listening.isNotEmpty) ...[
          _listHeader(scheme, 'Listening now', listening.length),
          // Cap the live-listeners block so a growing count scrolls WITHIN this
          // region instead of pushing "Your circle" off the screen.
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 190),
            child: ListView.builder(
              shrinkWrap: true,
              physics: const ClampingScrollPhysics(),
              padding: EdgeInsets.zero,
              itemCount: listening.length,
              itemBuilder: (_, i) =>
                  _friendEntry(listening, i, scheme, textColor),
            ),
          ),
        ],
        if (circle.isNotEmpty) _listHeader(scheme, 'Your circle'),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _onPullToRefresh,
            child: circle.isNotEmpty
                ? ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 12),
                    itemCount: circle.length,
                    itemBuilder: (_, i) =>
                        _friendEntry(circle, i, scheme, textColor),
                  )
                : (listening.isEmpty
                    ? _emptyConversations(scheme)
                    : ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [SizedBox(height: 220)],
                      )),
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
        Material(
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
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(width: 2),
                  AnimatedRotation(
                    turns: _storiesExpanded ? 0.0 : 0.5,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(Icons.keyboard_arrow_up_rounded,
                        size: 20, color: scheme.primary),
                  ),
                ],
              ),
            ),
          ),
        ),
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
      int badge) {
    final active = _friendLayer == key;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _setFriendLayer(key),
        borderRadius: BorderRadius.circular(20),
        // The badge FLOATS on the corner (Stack, no clip) instead of sitting
        // inline — so it adds zero width to the pill. A growing count (even
        // "99+") can never nudge the neighbouring pill; the two stay put.
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color:
                    active ? scheme.primary.withAlpha(30) : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: active
                      ? scheme.primary.withAlpha(130)
                      : scheme.outlineVariant.withAlpha(80),
                ),
                // The active pill lifts slightly with a soft accent glow.
                boxShadow: active
                    ? [
                        BoxShadow(
                          color: scheme.primary.withValues(alpha: 0.26),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon,
                      size: 15,
                      color:
                          active ? scheme.primary : scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                      color:
                          active ? scheme.onSurface : scheme.onSurfaceVariant,
                    ),
                  ),
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
