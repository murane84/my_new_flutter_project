part of '../home_page.dart';

// The friend/chat list surface: the two-column (desktop) + single-stack
// (mobile) list, the Our Space hero + Your Spaces chips, the share banner,
// and the conversation tiles. Split out of home_page.dart as a private
// extension on HomePageState (a `part`, so it shares the library's imports
// and reaches every private field/method). Pure code-movement, no behaviour
// change. None of these methods call setState directly (mutations delegate to
// HomePageState methods), so the extension never touches @protected members.

extension _HomeFriendListView on HomePageState {
  Widget _buildFriendList(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textColor = scheme.onSurface;

    // Groups and DMs share one unified chat list (WhatsApp-style). Each item
    // carries is_group so the builder picks the right row.
    final combined = <Map<String, dynamic>>[
      ..._filteredGroups,
      ..._filteredFriends,
    ];
    // Order by MOST-RECENT activity, not group-first — a group must not pin
    // above a DM that has a newer message. Conversations with no messages yet
    // (no timestamp) fall to the bottom; ties break by name for a stable order
    // that doesn't reshuffle on every rebuild.
    int lastMillis(Map<String, dynamic> m) {
      final s = (m['last_timestamp'] ?? '').toString().trim();
      if (s.isEmpty) return 0;
      final dt = DateTime.tryParse(s);
      if (dt == null) return 0;
      // Timestamps arrive in TWO shapes: groups send tz-aware ISO
      // ("…T09:24:33+00:00"); DMs send a NAIVE "YYYY-MM-DD HH:MM" (UTC wall-
      // clock, no zone). Dart reads a no-zone string as LOCAL time, which shifts
      // DMs by the device's UTC offset and lets groups float above DMs that are
      // actually newer. If the string carried no zone, read it as UTC so both
      // sort on the same absolute scale.
      final hasZone = s.endsWith('Z') || RegExp(r'[+-]\d\d:?\d\d$').hasMatch(s);
      final norm = hasZone
          ? dt
          : DateTime.utc(dt.year, dt.month, dt.day, dt.hour, dt.minute,
              dt.second, dt.millisecond);
      return norm.millisecondsSinceEpoch;
    }
    String nameKey(Map<String, dynamic> m) => (m['is_group'] == true
            ? (m['title'] ?? '')
            : (m['username'] ?? ''))
        .toString()
        .toLowerCase();
    combined.sort((a, b) {
      final byTime = lastMillis(b).compareTo(lastMillis(a));
      return byTime != 0 ? byTime : nameKey(a).compareTo(nameKey(b));
    });

    // "Listening now" zone: friends currently playing music rise to the top,
    // everyone else drops to "Your circle" (presence over recency — the seed of
    // Concept 05). When nobody's listening, this collapses to the plain list.
    final presence = NowPlayingPresence.instance;
    final listening = <Map<String, dynamic>>[];
    final rest = <Map<String, dynamic>>[];
    for (final m in combined) {
      final id = m['is_group'] != true ? (m['id'] as num?)?.toInt() : null;
      if (id != null && presence.trackFor(id) != null) {
        listening.add(m);
      } else {
        rest.add(m);
      }
    }
    // The friend page is split into two named layers (the "branches" of the
    // friend list — like we branched the monolith file):
    //   • HARMONY  — Our Space hero → Your Spaces chips → Live Room. The
    //     presence/togetherness side. Shows an empty-state prompt when the user
    //     has pinned no bonds yet, so the column is never an ambiguous blank.
    //   • CIRCLE   — Status & Stories → Listening now → Your circle. The people
    //     & conversation side, where time-sensitive unread lives.
    // Desktop shows both side by side; mobile shows one at a time via the
    // header pills. Spaces are filtered by the HARMONY contextual search box
    // (_spaceQuery) — always applied, since on desktop both columns' searches
    // are live at once.
    final spaceQ = _spaceQuery;
    final visibleSpaces = spaceQ.isEmpty
        ? _spaces
        : _spaces
            .where((s) =>
                deriveSpaceName(s, _myUserId).toLowerCase().contains(spaceQ))
            .toList();
    Map<String, dynamic>? hero;
    if (spaceQ.isEmpty) {
      hero = _primarySpace;
    } else {
      for (final s in visibleSpaces) {
        if (s['is_primary'] == true) {
          hero = s;
          break;
        }
      }
      hero ??= visibleSpaces.isNotEmpty ? visibleSpaces.first : null;
    }
    final harmonyEntries = <Map<String, dynamic>>[];
    if (hero != null) {
      final heroSpace = hero;
      harmonyEntries.add({'kind': 'ourspace', 'space': heroSpace});
      final others =
          visibleSpaces.where((s) => !identical(s, heroSpace)).toList();
      harmonyEntries.add({'kind': 'spacechips', 'others': others});
    } else {
      harmonyEntries.add({'kind': 'nospaces'});
    }
    harmonyEntries.add({'kind': 'liveroom'});

    final circleEntries = <Map<String, dynamic>>[];
    // Story circles ("friend status" + Your story). A header keeps the row from
    // reading as orphaned.
    if (_myUserId != null) {
      circleEntries.add({'kind': 'header', 'label': 'Status & Stories'});
      circleEntries.add({'kind': 'stories'});
    }
    if (listening.isNotEmpty) {
      circleEntries.add({
        'kind': 'header',
        'label': 'Listening now',
        'count': listening.length,
      });
      for (final m in listening) {
        circleEntries.add({'kind': 'tile', 'item': m});
      }
    }
    // "Your circle" always heads the main conversation list (even when nobody is
    // listening), so the quiet list is never an unlabelled block.
    if (rest.isNotEmpty) {
      circleEntries.add({'kind': 'header', 'label': 'Your circle'});
    }
    for (final m in rest) {
      circleEntries.add({'kind': 'tile', 'item': m});
    }

    return Column(
      key: const ValueKey('friendList'),
      children: [
        if (_isSharing) _buildShareBanner(scheme),
        Expanded(
          child: _isLoadingFriends
              ? const Center(child: CircularProgressIndicator())
              : LayoutBuilder(
                  builder: (context, constraints) {
                    // Two columns as soon as there's more than phone-ish width,
                    // so both layers show at once. Only true phone widths — or
                    // the panel narrowed by the music pane — use the single
                    // layer + header pills.
                    final wide = constraints.maxWidth >= 600;
                    if (wide) {
                      // Desktop: each column carries its OWN contextual search
                      // (inside _friendListWide) — spaces on the left, chats on
                      // the right — so search matches the column it sits under.
                      return _friendListWide(harmonyEntries, circleEntries,
                          combined, scheme, textColor);
                    }
                    // Narrow (mobile): only the active layer, its own contextual
                    // search at the top; the Harmony/Circle switch pills live in
                    // the header. See home_hub.dart.
                    return _friendHubMobile(
                        harmonyEntries, circleEntries, scheme, textColor);
                  },
                ),
        ),
      ],
    );
  }

  /// The rounded search field — reused by each desktop column and the mobile
  /// contextual search. The controller, hint and handler change per context
  /// (Circle: _searchCtrl/_filterFriends; Harmony: _spaceSearchCtrl/_filterSpaces)
  /// so the two searches never mirror each other.
  Widget _friendSearchField(ColorScheme scheme, TextEditingController controller,
      String hint, ValueChanged<String> onChanged) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(Icons.search, size: 20),
        isDense: true,
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  /// Wide (desktop / web) friend-list layout: the two named layers side by side
  /// — HARMONY (Our Space, Your Spaces, Live Room) on the left, CIRCLE (Stories,
  /// Listening now, Your circle) on the right — each under its own header, split
  /// by a hairline. Desktop has the room to show both at once, so there's no hub
  /// here; the wide screen surfaces conversations immediately AND keeps the
  /// spaces/rooms in view. Collapses to the single mobile stack below 600px.
  Widget _friendListWide(
      List<Map<String, dynamic>> harmonyEntries,
      List<Map<String, dynamic>> circleEntries,
      List<Map<String, dynamic>> combined,
      ColorScheme scheme,
      Color textColor) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // LEFT — HARMONY: Our Space + Your Spaces + Live Room.
        Expanded(
          flex: 5,
          child: Column(
            children: [
              _layerColumnHeader(scheme, 'Harmony', Icons.favorite_rounded,
                  'your closest, in tune', _harmonyBadge()),
              Padding(
                padding: const EdgeInsets.only(right: 6, bottom: 8),
                child: _friendSearchField(scheme, _spaceSearchCtrl,
                    'Search your spaces…', _filterSpaces),
              ),
              Expanded(
                child: ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(right: 6),
                  itemCount: harmonyEntries.length,
                  itemBuilder: (_, i) =>
                      _friendEntry(harmonyEntries, i, scheme, textColor),
                ),
              ),
            ],
          ),
        ),
        VerticalDivider(
          width: 17,
          thickness: 1,
          color: scheme.outlineVariant.withAlpha(60),
        ),
        // RIGHT — CIRCLE: Status & Stories + Listening now + Your circle.
        Expanded(
          flex: 6,
          child: Column(
            children: [
              _layerColumnHeader(scheme, 'Circle', Icons.forum_rounded,
                  'your people & chats', _circleBadge()),
              Padding(
                padding: const EdgeInsets.only(left: 6, bottom: 8),
                child: _friendSearchField(scheme, _searchCtrl,
                    'Search chats & people…', _filterFriends),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _onPullToRefresh,
                  child: combined.isEmpty
                      ? _emptyConversations(scheme)
                      : ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.only(left: 6),
                          itemCount: circleEntries.length,
                          itemBuilder: (_, i) =>
                              _friendEntry(circleEntries, i, scheme, textColor),
                        ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// The header atop each desktop layer column: an accent icon + the layer's
  /// flagship name + a soft one-line tagline + the same persistent badge the
  /// mobile hub uses, over a hairline.
  Widget _layerColumnHeader(ColorScheme scheme, String name, IconData icon,
      String tagline, int badge) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                name.toUpperCase(),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.6,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tagline,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (badge > 0) _hubBadgePill(scheme, badge),
            ],
          ),
          const SizedBox(height: 8),
          Container(height: 1, color: scheme.outlineVariant.withAlpha(70)),
        ],
      ),
    );
  }

  /// Harmony empty-state — shown when the user has pinned no bonds yet, so the
  /// column reads as an invitation instead of a mysterious blank.
  Widget _noSpacesCard(ColorScheme scheme) {
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 2, 6, 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: scheme.surfaceContainerHighest,
        border: Border.all(color: scheme.primary.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.favorite_border_rounded,
                  size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Text('No spaces yet',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Pin a bond to share a space — a song, moments, your streak — just '
            'the two of you.',
            style: TextStyle(
                fontSize: 12.5, height: 1.35, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => _newSpaceFlow(),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Pin a bond'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
          ),
        ],
      ),
    );
  }

  /// Renders one entry (hero / space chips / stories / header / tile) from a
  /// friend-list entry list — shared by the narrow single-column stack and both
  /// wide columns so a row looks identical either way.
  Widget _friendEntry(List<Map<String, dynamic>> entries, int i,
      ColorScheme scheme, Color textColor) {
    final e = entries[i];
    if (e['kind'] == 'ourspace') {
      return _buildOurSpaceHero(e['space'] as Map<String, dynamic>, scheme);
    }
    if (e['kind'] == 'spacechips') {
      return _buildSpaceChips(
          scheme, (e['others'] as List).cast<Map<String, dynamic>>());
    }
    if (e['kind'] == 'liveroom') {
      return const LiveRoomHeroShell();
    }
    if (e['kind'] == 'nospaces') {
      return _noSpacesCard(scheme);
    }
    if (e['kind'] == 'stories') {
      return Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 6),
        child: StoriesTray(
          apiBase: _apiBase,
          myUserId: _myUserId,
          myName: _username.isNotEmpty ? _username : 'You',
          myAvatarUrl: _myAvatar,
          groups: _storyGroups,
          onReload: _fetchStories,
        ),
      );
    }
    if (e['kind'] == 'header') {
      return _listHeader(scheme, e['label'] as String, e['count'] as int?);
    }
    final item = e['item'] as Map<String, dynamic>;
    final tile = item['is_group'] == true
        ? _buildGroupTile(item, textColor, scheme)
        : _buildFriendTile(item, textColor, scheme);
    // A divider only between two consecutive tiles (not before a header, not
    // after the last row).
    final next = i + 1 < entries.length ? entries[i + 1] : null;
    final showDiv = next != null && next['kind'] == 'tile';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        tile,
        if (showDiv)
          Divider(
            height: 1,
            indent: 68,
            color: scheme.outlineVariant.withAlpha(70),
          ),
      ],
    );
  }

  /// The empty-conversation placeholder (pull-to-refresh friendly).
  Widget _emptyConversations(ColorScheme scheme) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 110),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chat_bubble_outline,
                  size: 48, color: scheme.outlineVariant),
              const SizedBox(height: 10),
              Text('No conversations yet',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 6),
              Text('Pull down to refresh',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant.withAlpha(150))),
            ],
          ),
        ),
      ],
    );
  }

  /// A zone header in the conversation list ("LISTENING NOW · 2", "YOUR
  /// CIRCLE") — a small caps label, an optional coral count, and a hairline.
  Widget _listHeader(ColorScheme scheme, String label, [int? count]) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 16, 6, 8),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 6),
            Text(
              '· $count',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                color: scheme.primary,
              ),
            ),
          ],
          const SizedBox(width: 10),
          Expanded(
            child: Container(
                height: 1, color: scheme.outlineVariant.withAlpha(70)),
          ),
        ],
      ),
    );
  }

  /// The "Our Space" hero wedge at the top of the friend list — a compact,
  /// themed card for the pinned bond. Tapping opens the relationship profile.
  /// Renders from the light Space map already in memory (no extra fetch).
  Widget _buildOurSpaceHero(Map<String, dynamic> space, ColorScheme scheme) {
    final accent = spaceThemeColor(space['theme'] as String?);
    final title = deriveSpaceName(space, _myUserId);
    final others = ((space['members'] as List?) ?? const [])
        .whereType<Map>()
        .where((m) => (m['id'] as num?)?.toInt() != _myUserId)
        .toList();
    final otherName =
        others.isNotEmpty ? (others.first['username'] ?? '').toString() : '';
    final otherAvatar =
        others.isNotEmpty ? _avatarFull(others.first['avatar_url']) : null;
    final together = _isTogether;
    final momentCount = (space['moment_count'] as num?)?.toInt() ?? 0;
    // Live: the actual track a member is playing right now (not just a flag).
    final presence = NowPlayingPresence.instance;
    Map<String, dynamic>? liveTrack;
    for (final m in others) {
      final t = presence.trackFor((m['id'] as num?)?.toInt() ?? -1);
      if (t != null) {
        liveTrack = t;
        break;
      }
    }
    final someoneListening = liveTrack != null;
    String? liveLine;
    if (liveTrack != null) {
      final t = (liveTrack['title'] ?? '').toString().trim();
      final a = (liveTrack['artist'] ?? '').toString().trim();
      if (t.isNotEmpty) liveLine = a.isNotEmpty ? '$t — $a' : t;
    }
    final dt = DateTime.tryParse((space['close_since'] ?? '').toString());
    final closeLabel = _closeSinceLabel(dt);
    final meta = <String>[
      if (closeLabel.isNotEmpty) closeLabel,
      if (momentCount > 0) '$momentCount moment${momentCount == 1 ? '' : 's'}',
    ].join('  ·  ');
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => _openSpace(space),
          onLongPress: () => _showSpaceManageSheet(space),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  accent.withValues(alpha: 0.95),
                  Color.lerp(accent, Colors.black, 0.42)!
                      .withValues(alpha: 0.95),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: 0.32),
                  blurRadius: 16,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Row(
              children: [
                _heroOverlapAvatars(
                    otherName, otherAvatar, 21, someoneListening),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.push_pin_rounded,
                              size: 11,
                              color: Colors.white.withValues(alpha: 0.8)),
                          const SizedBox(width: 4),
                          Text(
                            'OUR SPACE',
                            style: TextStyle(
                              fontSize: 9,
                              letterSpacing: 1.3,
                              fontWeight: FontWeight.w800,
                              color: Colors.white.withValues(alpha: 0.85),
                            ),
                          ),
                          if (together) ...[
                            const SizedBox(width: 8),
                            _togetherBadge(),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (meta.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.9),
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                      if (someoneListening) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(Icons.graphic_eq_rounded,
                                size: 13, color: Colors.white),
                            const SizedBox(width: 5),
                            Expanded(
                              child: _scrollingText(
                                liveLine ?? 'listening now',
                                const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                _heroEnterButton(accent),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _heroAvatarRing(Widget child) => Container(
        padding: const EdgeInsets.all(2),
        decoration: const BoxDecoration(
            shape: BoxShape.circle, color: Colors.white),
        child: child,
      );

  /// The two overlapped, white-ringed avatars (me + the other) used on the hero.
  /// When [listening] the front avatar gains a slowly-spinning "record" ring so
  /// motion always means someone's playing right now.
  Widget _heroOverlapAvatars(
      String otherName, String? otherAvatar, double r, bool listening) {
    Widget front = _heroAvatarRing(
      InitialsAvatar(
        name: otherName.isEmpty ? '?' : otherName,
        radius: r,
        imageUrl: otherAvatar,
      ),
    );
    if (listening) {
      front = SpinningVinylRing(
        color: Colors.white,
        child: front,
      );
    }
    return SizedBox(
      width: r * 3 + 8,
      height: r * 2 + 8,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          Positioned(
            left: 0,
            child: _heroAvatarRing(
              InitialsAvatar(
                name: _username.isNotEmpty ? _username : 'You',
                radius: r,
                imageUrl: _avatarFull(_myAvatar),
              ),
            ),
          ),
          Positioned(left: r + 4, child: front),
        ],
      ),
    );
  }

  /// Human-friendly "close since" phrasing: recent bonds read as freshly pinned;
  /// older ones show the month (and year if not this year).
  String _closeSinceLabel(DateTime? dt) {
    if (dt == null) return '';
    final local = dt.toLocal();
    final days = DateTime.now().difference(local).inDays;
    if (days <= 1) return 'Pinned just now';
    if (days <= 14) return 'Pinned this week';
    final sameYear = local.year == DateTime.now().year;
    return 'Close since '
        '${DateFormat(sameYear ? 'MMMM' : 'MMM yyyy').format(local)}';
  }

  /// Golden "TOGETHER" plan badge on the hero.
  Widget _togetherBadge() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFFF6D77A),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Text(
          'TOGETHER',
          style: TextStyle(
            fontSize: 8.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.5,
            color: Color(0xFF3A2A00),
          ),
        ),
      );

  /// The white "Enter" pill on the hero (the whole card is tappable; this is the
  /// clear call-to-action).
  Widget _heroEnterButton(Color accent) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(30),
        ),
        child: Text(
          'Enter',
          style: TextStyle(
            color: Color.lerp(accent, Colors.black, 0.18),
            fontWeight: FontWeight.w800,
            fontSize: 13,
          ),
        ),
      );

  /// "Your Spaces" — a horizontal row of the non-hero pinned bonds as small
  /// chips, plus a "＋ New" chip. Renders from the in-memory Space list (no
  /// fetch). Scarce by design, so it stays a short, deliberate row.
  Widget _buildSpaceChips(
      ColorScheme scheme, List<Map<String, dynamic>> others) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 6, 8),
            child: Text(
              'YOUR SPACES',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          SizedBox(
            height: 72,
            child: ListView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 2),
              children: [
                for (final s in others) _spaceChip(s, scheme),
                _newSpaceChip(scheme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A Space chip: TWO overlapping avatars (you + the other) — a deliberate
  /// "pair/bond" mark that reads as distinct from the single-avatar story
  /// circles — plus a live status dot (listening beats online). Not a circle.
  Widget _spaceChip(Map<String, dynamic> space, ColorScheme scheme) {
    final accent = spaceThemeColor(space['theme'] as String?);
    final title = deriveSpaceName(space, _myUserId);
    final others = ((space['members'] as List?) ?? const [])
        .whereType<Map>()
        .where((m) => (m['id'] as num?)?.toInt() != _myUserId)
        .toList();
    final otherName =
        others.isNotEmpty ? (others.first['username'] ?? '').toString() : '';
    final otherAvatar =
        others.isNotEmpty ? _avatarFull(others.first['avatar_url']) : null;
    final otherId =
        others.isNotEmpty ? (others.first['id'] as num?)?.toInt() : null;
    final listening = otherId != null &&
        NowPlayingPresence.instance.trackFor(otherId) != null;
    final online =
        otherId != null && ref.watch(presenceProvider).isOnline(otherId);

    Widget frontAvatar = _spaceMiniAvatar(
      name: otherName.isEmpty ? '?' : otherName,
      imageUrl: otherAvatar,
      radius: 15,
      ringColor: accent,
    );
    if (listening) {
      // A spinning "record" ring signals they're playing right now.
      frontAvatar = SpinningVinylRing(ring: 2, color: accent, child: frontAvatar);
    }

    return GestureDetector(
      onTap: () => _openSpace(space),
      onLongPress: () => _showSpaceManageSheet(space),
      child: Container(
        width: 80,
        margin: const EdgeInsets.only(right: 8),
        child: Column(
          children: [
            SizedBox(
              width: 60,
              height: 40,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  // Two equal, side-by-side photos — me + the other — exactly
                  // like the hero (my profile pic on the left; name initials as
                  // the only fallback, never the literal word "You").
                  Positioned(
                    left: 3,
                    child: _spaceMiniAvatar(
                      name: _username.isNotEmpty ? _username : 'Me',
                      imageUrl: _avatarFull(_myAvatar),
                      radius: 15,
                      ringColor: scheme.surface,
                    ),
                  ),
                  Positioned(
                    left: 25,
                    child: frontAvatar,
                  ),
                  // Live status: listening (accent + eq) beats online (green).
                  if (listening || online)
                    Positioned(
                      right: 0,
                      top: -2,
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: listening ? accent : Colors.green,
                          shape: BoxShape.circle,
                          border: Border.all(color: scheme.surface, width: 2),
                        ),
                        child: listening
                            ? const Icon(Icons.graphic_eq_rounded,
                                size: 7, color: Colors.white)
                            : null,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 5),
            Text(
              title.replaceFirst('You & ', ''),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }

  Widget _spaceMiniAvatar({
    required String name,
    String? imageUrl,
    required double radius,
    required Color ringColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(shape: BoxShape.circle, color: ringColor),
      child: InitialsAvatar(name: name, radius: radius, imageUrl: imageUrl),
    );
  }

  Widget _newSpaceChip(ColorScheme scheme) {
    return GestureDetector(
      onTap: _newSpaceFlow,
      child: SizedBox(
        width: 80,
        child: Column(
          children: [
            // Same avatar-area height (40) as the pair chips so every label sits
            // on one row; the "+" circle matches the friend-avatar size.
            SizedBox(
              height: 40,
              child: Center(
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.surfaceContainerHighest,
                    border: Border.all(
                        color: scheme.outlineVariant.withValues(alpha: 0.6)),
                  ),
                  child: Icon(Icons.add_rounded, color: scheme.primary),
                ),
              ),
            ),
            const SizedBox(height: 5),
            Text('New',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  /// Pick a friend to pin as a new Space. Only people already in your circle
  /// appear — Spaces are always within the circle.
  Future<void> _newSpaceFlow() async {
    // Friends not already pinned in any Space (a bond is pinned once).
    final pinnedIds = <int>{};
    for (final s in _spaces) {
      for (final m in ((s['members'] as List?) ?? const []).whereType<Map>()) {
        final id = (m['id'] as num?)?.toInt();
        if (id != null && id != _myUserId) pinnedIds.add(id);
      }
    }
    final candidates = _allFriends.where((f) {
      final id = (f['id'] as num?)?.toInt();
      return id != null && !pinnedIds.contains(id);
    }).toList();

    if (candidates.isEmpty) {
      showToast(context, 'Everyone in your circle is already pinned',
          type: ToastType.info);
      return;
    }

    final chosen = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Text('Pin a new Space',
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      color: scheme.onSurface)),
              const SizedBox(height: 8),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: candidates.length,
                  itemBuilder: (_, i) {
                    final f = candidates[i];
                    final nm = _contactDisplayName(
                        f['phone']?.toString(), f['username'] as String? ?? '');
                    return ListTile(
                      leading: InitialsAvatar(
                        name: nm,
                        radius: 20,
                        imageUrl: _avatarFull(f['avatar_url']),
                      ),
                      title: Text(nm),
                      onTap: () => Navigator.pop(ctx, f),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (chosen == null) return;
    final fid = int.tryParse(chosen['id'].toString()) ?? -1;
    final nm = _contactDisplayName(
        chosen['phone']?.toString(), chosen['username'] as String? ?? '');
    if (fid > 0) _pinAsSpace(fid, nm);
  }

  /// Banner shown across the top of the chat list while a photo shared into
  /// Aluta is waiting for the user to pick a recipient.
  Widget _buildShareBanner(ColorScheme scheme) {
    final n = ShareInbox.instance.pending.length;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.primary.withAlpha(120)),
      ),
      child: Row(
        children: [
          Icon(Icons.photo_library_rounded,
              size: 20, color: scheme.onPrimaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  n > 1 ? 'Sharing $n photos' : 'Sharing a photo',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                Text(
                  'Tap a chat below to send it',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onPrimaryContainer.withAlpha(200),
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: _cancelShare,
            style: TextButton.styleFrom(
              foregroundColor: scheme.onPrimaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
            ),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Widget _buildFriendTile(
      Map<String, dynamic> f, Color textColor, ColorScheme scheme) {
    // Show your saved phone-book name for this number when you have it saved,
    // otherwise their app username.
    final name = _contactDisplayName(
        f['phone']?.toString(), f['username'] as String? ?? '');
    // Online dot now comes from Riverpod (single source of truth for presence).
    final isOnline = ref.watch(presenceProvider).isOnline((f['id'] as num).toInt());
    final lastMsg = _previewText(f['last_message'] as String? ?? '');
    final lastTime = f['last_timestamp'] as String? ?? '';
    // Unread now comes from Riverpod (single source of truth for the badge).
    final unread = ref.watch(unreadProvider).countFor((f['id'] as num).toInt());
    final hasUnread = unread > 0;
    // Live "Listening now": if this friend is playing music right now, show the
    // track in place of the last-message preview (seed of Concept 05).
    final npTrack =
        NowPlayingPresence.instance.trackFor((f['id'] as num).toInt());
    String? npLine;
    if (npTrack != null) {
      final t = (npTrack['title'] ?? '').toString().trim();
      final a = (npTrack['artist'] ?? '').toString().trim();
      if (t.isNotEmpty) npLine = a.isNotEmpty ? '$t — $a' : t;
    }
    final isTyping = _typingTimers.containsKey((f['id'] as num).toInt());

    return Slidable(
      key: ValueKey('friend-${f['id']}'),
      // Swipe RIGHT (drag from the left edge) → Call.
      startActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.26,
        children: [
          SlidableAction(
            onPressed: (_) => _showCallChoice(
              friendId: int.tryParse(f['id'].toString()) ?? -1,
              name: name,
              avatar: f['avatar_url'] as String?,
              phone: f['phone'] as String?,
            ),
            backgroundColor: scheme.primary,
            foregroundColor: scheme.onPrimary,
            icon: Icons.call_rounded,
            label: 'Call',
          ),
        ],
      ),
      // Swipe LEFT → open the message thread.
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.26,
        children: [
          SlidableAction(
            onPressed: (_) =>
                _isSharing ? _sendShareTo(friend: f) : openChat(f),
            backgroundColor: scheme.secondaryContainer,
            foregroundColor: scheme.onSecondaryContainer,
            icon: Icons.chat_bubble_rounded,
            label: 'Message',
          ),
        ],
      ),
      child: InkWell(
      onTap: () => _isSharing ? _sendShareTo(friend: f) : openChat(f),
      onLongPress: _isSharing ? null : () => _showFriendQuickSheet(f, name),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
        child: Row(
          children: [
            _storyRingAvatar(f, name, isOnline),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontWeight:
                          hasUnread ? FontWeight.bold : FontWeight.w500,
                      fontSize: 14,
                      color: textColor,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  _tileSubtitle(
                      scheme, textColor, npLine, isTyping, lastMsg, hasUnread),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _formatFriendTimestamp(lastTime),
                  style: TextStyle(
                    fontSize: 11,
                    color: hasUnread
                        ? scheme.primary
                        : textColor.withAlpha(110),
                    fontWeight: hasUnread
                        ? FontWeight.w600
                        : FontWeight.normal,
                  ),
                ),
                if (hasUnread) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      unread > 99 ? '99+' : '$unread',
                      style: TextStyle(
                        color: scheme.onPrimary,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            IconButton(
              tooltip: 'Call $name',
              icon: Icon(Icons.call_rounded, color: scheme.primary, size: 20),
              visualDensity: VisualDensity.compact,
              onPressed: () => _showCallChoice(
                friendId: int.tryParse(f['id'].toString()) ?? -1,
                name: name,
                avatar: f['avatar_url'] as String?,
                phone: f['phone'] as String?,
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  /// A group conversation row in the unified chat list. Tapping opens the group
  /// inside the chat panel (never a full-window route).
  Widget _buildGroupTile(
      Map<String, dynamic> g, Color textColor, ColorScheme scheme) {
    final title = (g['title'] as String?)?.trim();
    final name = (title == null || title.isEmpty) ? 'Group' : title;
    final lastMsg = _previewText(g['last_message'] as String? ?? '');
    final lastTime = (g['last_timestamp'] ?? '').toString();
    final unread = (g['unread_count'] as num?)?.toInt() ?? 0;
    final hasUnread = unread > 0;
    final avatar = _avatarFull(g['avatar_url']);

    return InkWell(
      onTap: () => _isSharing ? _sendShareTo(group: g) : openGroupInPanel(g),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: scheme.primaryContainer,
              backgroundImage: avatar != null
                  ? authNetworkImageProvider(avatar, mediaAuthHeaders(avatar))
                  : null,
              child: avatar == null
                  ? Icon(Icons.groups_rounded,
                      color: scheme.onPrimaryContainer, size: 24)
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.groups_rounded,
                          size: 14, color: textColor.withAlpha(120)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          name,
                          style: TextStyle(
                            fontWeight:
                                hasUnread ? FontWeight.bold : FontWeight.w500,
                            fontSize: 14,
                            color: textColor,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    lastMsg.isEmpty ? 'Tap to open the group' : lastMsg,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: hasUnread
                          ? textColor.withAlpha(200)
                          : textColor.withAlpha(110),
                      fontWeight:
                          hasUnread ? FontWeight.w500 : FontWeight.normal,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _formatFriendTimestamp(lastTime),
                  style: TextStyle(
                    fontSize: 11,
                    color:
                        hasUnread ? scheme.primary : textColor.withAlpha(110),
                    fontWeight:
                        hasUnread ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
                if (hasUnread) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      unread > 99 ? '99+' : '$unread',
                      style: TextStyle(
                        color: scheme.onPrimary,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            // Quick group call — same flow as starting one from inside the
            // group (rings every member, opens the group-call screen).
            IconButton(
              tooltip: 'Group call · $name',
              icon: Icon(Icons.call_rounded, color: scheme.primary, size: 20),
              visualDensity: VisualDensity.compact,
              onPressed: () => _startGroupCall(g),
            ),
          ],
        ),
      ),
    );
  }
}
