part of '../home_page.dart';

// Split out of home_page.dart (pure code-movement, no behaviour change):
// Our Space + friend action flows (open/pin/unpin/moment + sheets). A private extension on HomePageState — a library `part`, so it
// shares the file's imports and reaches every private field/method. None
// of these methods call setState directly, so the extension stays clear of
// @protected members.

extension _HomeSpaceActions on HomePageState {
  /// Open the "Aluta Together" paywall, refreshing plan + spaces on return.
  Future<void> _openTogether() async {
    await showAppPopup(
      navigatorKey.currentContext ?? context,
      TogetherScreen(
        initialTogether: _isTogether,
        onChanged: () {
          _loadPlan();
          _loadSpaces();
        },
      ),
    );
    _loadPlan();
  }

  /// The primary (hero) Space, if one is pinned.
  Map<String, dynamic>? get _primarySpace {
    for (final s in _spaces) {
      if (s['is_primary'] == true) return s;
    }
    return _spaces.isNotEmpty ? _spaces.first : null;
  }

  /// Open a Space's relationship profile, then refresh the hero on return.
  Future<void> _openSpace(Map<String, dynamic> space) async {
    await showAppPopup(
      navigatorKey.currentContext ?? context,
      RelationshipSpacePage(
        space: space,
        apiBase: _apiBase,
        myUserId: _myUserId,
        myName: _username.isNotEmpty ? _username : 'You',
        myAvatarUrl: _avatarFull(_myAvatar),
        onChanged: _loadSpaces,
      ),
      // Dismiss reads as "minimize back down" rather than a hard close, so the
      // user can duck out to Circle/chat and reopen without feeling cut off.
      minimizeStyle: true,
    );
    _loadSpaces();
  }

  /// The Space (if any) that pins this friend.
  Map<String, dynamic>? _spaceWithFriend(int friendId) {
    for (final s in _spaces) {
      for (final m in ((s['members'] as List?) ?? const []).whereType<Map>()) {
        if ((m['id'] as num?)?.toInt() == friendId) return s;
      }
    }
    return null;
  }

  /// BRIDGE — Listening now → Harmony ("tune in"): from a friend who's playing
  /// right now, jump to the Harmony layer (on mobile) and open the Space you
  /// share, so their space (where Listen Together / the Live Room live) is one
  /// tap from their now-playing row. No shared Space yet → nudge to pin a bond.
  void _tuneInto(int friendId, String name) {
    _setFriendLayer('harmony');
    final space = _spaceWithFriend(friendId);
    if (space != null) {
      _openSpace(space);
    } else {
      showToast(context, 'Pin a bond with $name to tune in together',
          type: ToastType.info);
    }
  }

  /// BRIDGE — Harmony → Circle ("message"): open the chat with the other person
  /// in a Space, using the existing conversation surface (chat_page untouched).
  /// Prefers the full friend record; falls back to the Space's member snapshot.
  void _messageSpacemate(Map<String, dynamic> space) {
    final other = ((space['members'] as List?) ?? const [])
        .whereType<Map>()
        .firstWhere(
          (m) => (m['id'] as num?)?.toInt() != _myUserId,
          orElse: () => const {},
        );
    final otherId = (other['id'] as num?)?.toInt();
    if (otherId == null) return;
    final full = _allFriends.firstWhere(
      (f) => (f['id'] as num?)?.toInt() == otherId,
      orElse: () => <String, dynamic>{},
    );
    openChat(full.isNotEmpty
        ? full
        : {
            'id': otherId,
            'username': (other['username'] ?? '').toString(),
            'avatar_url': other['avatar_url'],
          });
  }

  /// 🎁 Send a moment (dedication/song/note) to a friend: open their Our Space
  /// to compose it, pinning one first if the bond isn't a Space yet (respecting
  /// the free-tier cap — which routes to the Together paywall).
  Future<void> _sendMomentToFriend(int friendId, String name) async {
    final existing = _spaceWithFriend(friendId);
    if (existing != null) {
      _openSpace(existing);
      return;
    }
    showToast(context, 'Send $name a bond request first to share moments',
        type: ToastType.info);
    _requestBond(friendId, name);
  }

  /// Quick manage menu for a Space (long-press the hero or a chip): open, make
  /// hero, or unpin — so a mistaken/duplicate Space can be removed without
  /// digging into the profile.
  void _showSpaceManageSheet(Map<String, dynamic> space) {
    final scheme = Theme.of(context).colorScheme;
    final title = deriveSpaceName(space, _myUserId);
    final isPrimary = space['is_primary'] == true;
    final id = (space['id'] as num).toInt();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 8, bottom: 6),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              child: Row(
                children: [
                  Text(title,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: scheme.onSurface)),
                ],
              ),
            ),
            ListTile(
              leading:
                  Icon(Icons.chat_bubble_rounded, color: scheme.primary),
              title: const Text('Message'),
              subtitle: const Text('Open your chat with them'),
              onTap: () {
                Navigator.pop(ctx);
                _messageSpacemate(space);
              },
            ),
            ListTile(
              leading: Icon(Icons.open_in_full_rounded, color: scheme.primary),
              title: const Text('Open Space'),
              onTap: () {
                Navigator.pop(ctx);
                _openSpace(space);
              },
            ),
            if (!isPrimary)
              ListTile(
                leading: Icon(Icons.push_pin_rounded, color: scheme.primary),
                title: const Text('Make hero'),
                subtitle: const Text('Show at the top of your list'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final ok = await ApiService().updateSpace(id, isPrimary: true);
                  if (ok != null) _loadSpaces();
                },
              ),
            ListTile(
              leading: Icon(Icons.link_off_rounded, color: scheme.error),
              title: Text('Unpin Space',
                  style: TextStyle(color: scheme.error)),
              subtitle: const Text('Removes this Space — your chats stay'),
              onTap: () {
                Navigator.pop(ctx);
                _confirmUnpinSpace(space);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmUnpinSpace(Map<String, dynamic> space) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Unpin this Space?'),
        content: const Text(
            'The relationship profile and its pinned moments are removed. Your '
            'friendship and chats stay exactly as they are.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Unpin'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final done = await ApiService().deleteSpace((space['id'] as num).toInt());
    if (!mounted) return;
    if (done) {
      _loadSpaces();
      showToast(context, 'Space unpinned', type: ToastType.success);
    } else {
      showToast(context, 'Could not unpin — try again',
          type: ToastType.error);
    }
  }

  /// Ask a friend to pin a bond. The Space is NOT created now — it's born for
  /// both partners only when they accept. Handles the free-tier cap with a
  /// gentle upsell instead of a dead error.
  Future<void> _requestBond(int friendId, String name) async {
    final res = await ApiService().requestBond(memberId: friendId);
    if (!mounted) return;
    if (res == null) {
      showToast(context, 'Could not send the request — try again',
          type: ToastType.error);
      return;
    }
    if (res['error'] == 'together_required') {
      showToast(context,
          (res['detail'] ?? 'Upgrade to Together to pin more Spaces.').toString(),
          type: ToastType.info);
      _openTogether();
      return;
    }
    if (res['error'] != null) {
      // e.g. already sharing / already pending / they invited you first.
      showToast(context,
          (res['detail'] ?? 'Could not send that request.').toString(),
          type: ToastType.info);
      _loadBondRequests();
      return;
    }
    showToast(context, 'Bond request sent — waiting for $name to accept 💞',
        type: ToastType.success);
    _loadBondRequests();
  }

  /// Accept an incoming bond request → the Space is created for both of you.
  Future<void> _acceptBondRequest(Map<String, dynamic> req) async {
    final id = (req['id'] as num?)?.toInt();
    if (id == null) return;
    final res = await ApiService().acceptBondRequest(id);
    if (!mounted) return;
    if (res == null) {
      showToast(context, 'Could not accept — try again', type: ToastType.error);
      return;
    }
    if (res['error'] == 'together_required') {
      showToast(context,
          (res['detail'] ?? 'Upgrade to Together to accept this bond.')
              .toString(),
          type: ToastType.info);
      _openTogether();
      return;
    }
    if (res['error'] != null) {
      showToast(context,
          (res['detail'] ?? 'Could not accept that request.').toString(),
          type: ToastType.info);
      _loadBondRequests();
      return;
    }
    await _loadBondRequests();
    await _loadSpaces();
    if (!mounted) return;
    showToast(context, 'Bond pinned 💞', type: ToastType.success);
    _openSpace(res); // the freshly created Space
  }

  /// Politely decline an incoming bond request.
  Future<void> _declineBondRequest(Map<String, dynamic> req) async {
    final id = (req['id'] as num?)?.toInt();
    if (id == null) return;
    await ApiService().declineBondRequest(id);
    if (!mounted) return;
    _loadBondRequests();
  }

  /// A friend row's long-press quick sheet: pin as Our Space, call, or open chat.
  void _showFriendQuickSheet(Map<String, dynamic> f, String name) {
    final scheme = Theme.of(context).colorScheme;
    final fid = int.tryParse(f['id'].toString()) ?? -1;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Row(
                children: [
                  Text(name,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: scheme.onSurface)),
                ],
              ),
            ),
            ListTile(
              leading: Icon(Icons.favorite_rounded, color: scheme.primary),
              title: const Text('Pin as Our Space'),
              subtitle: const Text('Send a bond request — they confirm to pin'),
              onTap: () {
                Navigator.pop(ctx);
                if (fid > 0) _requestBond(fid, name);
              },
            ),
            ListTile(
              leading:
                  Icon(Icons.card_giftcard_rounded, color: scheme.primary),
              title: const Text('Send a moment'),
              subtitle: const Text('Dedicate a song or a note to them'),
              onTap: () {
                Navigator.pop(ctx);
                if (fid > 0) _sendMomentToFriend(fid, name);
              },
            ),
            ListTile(
              leading: Icon(Icons.call_rounded, color: scheme.primary),
              title: const Text('Call'),
              onTap: () {
                Navigator.pop(ctx);
                _showCallChoice(
                  friendId: fid,
                  name: name,
                  avatar: f['avatar_url'] as String?,
                  phone: f['phone'] as String?,
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.chat_bubble_rounded, color: scheme.primary),
              title: const Text('Open chat'),
              onTap: () {
                Navigator.pop(ctx);
                openChat(f);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
