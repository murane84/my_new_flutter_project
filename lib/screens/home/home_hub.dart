part of '../home_page.dart';

// The MOBILE two-tile accordion hub for the friend page. Both layer headers —
// HARMONY and CIRCLE — with their badges stay visible at all times, so any
// pending item (unread chats, a bond you can tune into) reaches the user at
// first glance without scrolling. One tile is expanded and fills the screen with
// its own internal scroll; the other collapses to just its header bar. Tapping a
// header swaps which is open. Desktop keeps both columns open (see
// home_friend_list.dart); this hub is only for narrow widths.
//
// A private extension on HomePageState (a library part), so it reaches every
// field/method. It never calls setState directly — the open/collapse toggle
// delegates to HomePageState._setFriendLayer — so it stays clear of @protected.
extension _HomeHub on HomePageState {
  Widget _friendHubMobile(
      List<Map<String, dynamic>> harmonyEntries,
      List<Map<String, dynamic>> circleEntries,
      List<Map<String, dynamic>> combined,
      ColorScheme scheme,
      Color textColor) {
    final open = _friendLayer;
    final hBadge = _harmonyBadge();
    final cBadge = _circleBadge();

    Widget tile(String key, String name, IconData icon, String tagline,
        int badge, List<Map<String, dynamic>> entries) {
      final isOpen = open == key;
      final header = _hubHeader(scheme, key, name, icon, tagline, badge, isOpen);
      if (!isOpen) return header;
      // The open tile takes the remaining height and scrolls INSIDE itself.
      return Expanded(
        child: Column(
          children: [
            header,
            Expanded(
              child: RefreshIndicator(
                onRefresh: _onPullToRefresh,
                child: ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(top: 6, bottom: 12),
                  itemCount: entries.length,
                  itemBuilder: (_, i) =>
                      _friendEntry(entries, i, scheme, textColor),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Exactly one Expanded (the open tile) + one bare header (the collapsed one)
    // → the column fills the screen, both headers + badges always visible.
    return Column(
      children: [
        tile('harmony', 'Harmony', Icons.favorite_rounded,
            'your closest, in tune', hBadge, harmonyEntries),
        tile('circle', 'Circle', Icons.forum_rounded, 'your people & chats',
            cBadge, circleEntries),
      ],
    );
  }

  /// One accordion header bar: accent icon + layer name + tagline + a persistent
  /// badge + an open/closed chevron. Tapping swaps which layer is expanded.
  Widget _hubHeader(ColorScheme scheme, String layerKey, String name,
      IconData icon, String tagline, int badge, bool open) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _setFriendLayer(layerKey),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 13),
          decoration: BoxDecoration(
            color: open ? scheme.primary.withAlpha(12) : null,
            border: Border(
              bottom:
                  BorderSide(color: scheme.outlineVariant.withAlpha(70)),
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                name.toUpperCase(),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.4,
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
                      fontSize: 11.5, color: scheme.onSurfaceVariant),
                ),
              ),
              if (badge > 0) ...[
                _hubBadgePill(scheme, badge),
                const SizedBox(width: 8),
              ],
              Icon(
                open
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 22,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The little count pill used on both the mobile hub headers and the desktop
  /// column headers, so pending counts read the same everywhere.
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
