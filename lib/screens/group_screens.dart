import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';

import 'api_service.dart';
import 'token_helper.dart' show mediaAuthHeaders;
import '../utils/toast_helper.dart';
import '../utils/popup_shell.dart';
import '../utils/app_config.dart';

// Groups are presented as CARD POPUPS (AppPopupShell) — not full-window routes —
// so on desktop they never hide the music/chat panels. Selecting or creating a
// group pops back the conversation map; the caller (home_page) then opens it
// inside the chat panel (openGroupInPanel).

// ─────────────────────────────────────────────────────────────────────────────
// Groups list
// ─────────────────────────────────────────────────────────────────────────────

class GroupsScreen extends StatefulWidget {
  const GroupsScreen({super.key});

  @override
  State<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends State<GroupsScreen> {
  List<Map<String, dynamic>> _groups = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await ApiService().listConversations();
    if (!mounted) return;
    setState(() {
      _groups = all.where((c) => c['is_group'] == true).toList();
      _loading = false;
    });
  }

  Future<void> _newGroup() async {
    final created = await showAppPopup<Map<String, dynamic>>(
        context, const GroupCreateScreen());
    if (!mounted || created == null) return;
    // Bubble the new group up so home opens it in the chat panel.
    Navigator.pop(context, created);
  }

  @override
  Widget build(BuildContext context) {
    return AppPopupShell(
      title: 'Groups',
      icon: Icons.groups_rounded,
      headerAction: IconButton(
        tooltip: 'New group',
        icon: const Icon(Icons.group_add_rounded),
        onPressed: _newGroup,
      ),
      builder: (ctx, isWide) => _body(ctx),
    );
  }

  Widget _body(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(40),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_groups.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.groups_rounded,
                size: 56, color: scheme.primary.withAlpha(120)),
            const SizedBox(height: 12),
            const Text('No groups yet',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('Create one to chat with several friends at once.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _newGroup,
              icon: const Icon(Icons.group_add_rounded),
              label: const Text('New group'),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: _groups.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, color: scheme.outlineVariant.withAlpha(60)),
      itemBuilder: (_, i) => _tile(_groups[i], scheme),
    );
  }

  Widget _tile(Map<String, dynamic> g, ColorScheme scheme) {
    final members = (g['members'] as List?) ?? const [];
    final unread = (g['unread_count'] as num?)?.toInt() ?? 0;
    final last = (g['last_message'] ?? '').toString();
    return ListTile(
      onTap: () => Navigator.pop(context, g), // home opens it in the panel
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        child: Icon(Icons.groups_rounded, color: scheme.onPrimaryContainer),
      ),
      title: Text((g['title'] ?? 'Group').toString(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(
        last.isNotEmpty ? last : '${members.length} members',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: unread > 0
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(20)),
              child: Text('$unread',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold)),
            )
          : null,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Group creation (name + pick friends) — pops back the created conversation.
// ─────────────────────────────────────────────────────────────────────────────

class GroupCreateScreen extends StatefulWidget {
  const GroupCreateScreen({super.key});

  @override
  State<GroupCreateScreen> createState() => _GroupCreateScreenState();
}

class _GroupCreateScreenState extends State<GroupCreateScreen> {
  final _name = TextEditingController();
  final _search = TextEditingController();
  List<Map<String, dynamic>> _friends = [];
  final Set<int> _selected = {};
  bool _loading = true;
  bool _error = false;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _loadFriends();
  }

  @override
  void dispose() {
    _name.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadFriends() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      // Same source as the home chat list (the Friend table) → only the user's
      // own contacts, never every registered account.
      final list = await ApiService().getFriends();
      if (!mounted) return;
      setState(() {
        _friends = list;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  List<Map<String, dynamic>> get _visibleFriends {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return _friends;
    return _friends
        .where((f) => (f['username'] ?? '').toString().toLowerCase().contains(q))
        .toList();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      showToast(context, 'Give the group a name.', type: ToastType.error);
      return;
    }
    if (_selected.isEmpty) {
      showToast(context, 'Pick at least one member.', type: ToastType.error);
      return;
    }
    setState(() => _creating = true);
    final conv = await ApiService().createGroup(name, _selected.toList());
    if (!mounted) return;
    setState(() => _creating = false);
    if (conv != null) {
      Navigator.pop(context, conv); // caller opens the new group
    } else {
      showToast(context, 'Could not create the group.', type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppPopupShell(
      title: 'New group',
      icon: Icons.group_add_rounded,
      headerAction: TextButton(
        onPressed: _creating ? null : _create,
        child: _creating
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2.4))
            : Text('Create (${_selected.length})',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w700)),
      ),
      builder: (ctx, isWide) => _body(ctx),
    );
  }

  Widget _body(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Group name',
              prefixIcon: Icon(Icons.groups_rounded),
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
          child: Row(
            children: [
              Text('Add members',
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant)),
              const Spacer(),
              Text('from your contacts',
                  style:
                      TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
        if (!_loading && !_error && _friends.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                hintText: 'Search contacts…',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                filled: true,
                fillColor: scheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        Flexible(child: _membersArea(scheme)),
      ],
    );
  }

  Widget _membersArea(ColorScheme scheme) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(28),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off_rounded,
                size: 40, color: scheme.onSurfaceVariant),
            const SizedBox(height: 10),
            Text('Couldn’t load your contacts.',
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _loadFriends,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (_friends.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'No contacts yet. Start a 1:1 chat with someone first — then you can '
          'add them to a group.',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    final list = _visibleFriends;
    if (list.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text('No contacts match “${_search.text.trim()}”.',
            style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: list.length,
      itemBuilder: (_, i) {
        final f = list[i];
        final id = (f['id'] as num).toInt();
        final name = (f['username'] ?? 'Friend').toString();
        final checked = _selected.contains(id);
        return CheckboxListTile(
          value: checked,
          onChanged: (v) => setState(() {
            if (v == true) {
              _selected.add(id);
            } else {
              _selected.remove(id);
            }
          }),
          secondary: CircleAvatar(
            backgroundColor: scheme.primaryContainer,
            child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: TextStyle(color: scheme.onPrimaryContainer)),
          ),
          title: Text(name),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Group info / settings — avatar · name · members · add/remove · leave
// ─────────────────────────────────────────────────────────────────────────────

class GroupInfoScreen extends StatefulWidget {
  final int conversationId;
  const GroupInfoScreen({super.key, required this.conversationId});

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  Map<String, dynamic>? _conv;
  int? _myUid;
  String _apiBase = '';
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    AppConfig.baseUrl.then((b) {
      if (mounted) setState(() => _apiBase = b);
    });
    _load();
  }

  bool get _isAdmin => (_conv?['my_role']?.toString() ?? '') == 'admin';
  List _members() => (_conv?['members'] as List?) ?? const [];

  Future<void> _load() async {
    _myUid ??= (await ApiService().getUserData())['id'] as int?;
    final c = await ApiService().getConversation(widget.conversationId);
    if (!mounted) return;
    setState(() {
      _conv = c;
      _loading = false;
    });
  }

  String? _fullAvatar() {
    final a = (_conv?['avatar_url'] ?? '').toString();
    if (a.isEmpty) return null;
    return a.startsWith('http') ? a : '$_apiBase$a';
  }

  Future<void> _changeAvatar() async {
    if (!_isAdmin) return;
    try {
      final x = await ImagePicker()
          .pickImage(source: ImageSource.gallery, imageQuality: 80);
      if (x == null) return;
      setState(() => _busy = true);
      final bytes = await x.readAsBytes();
      final up = await ApiService()
          .uploadMedia(bytes: bytes, filename: x.name, mime: 'image/jpeg');
      if (up == null || up['url'] == null) {
        throw Exception('upload failed');
      }
      final ok = await ApiService().updateGroup(widget.conversationId,
          avatarUrl: up['url'].toString());
      if (!mounted) return;
      setState(() => _busy = false);
      if (ok) {
        await _load();
      } else {
        showToast(context, 'Could not update the photo.',
            type: ToastType.error);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        showToast(context, 'Could not update the photo.',
            type: ToastType.error);
      }
    }
  }

  Future<void> _rename() async {
    if (!_isAdmin) return;
    final ctrl =
        TextEditingController(text: (_conv?['title'] ?? '').toString());
    final newName = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Group name'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dctx, ctrl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (newName == null || newName.isEmpty) return;
    setState(() => _busy = true);
    final ok = await ApiService()
        .updateGroup(widget.conversationId, title: newName);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      await _load();
    } else {
      showToast(context, 'Could not rename.', type: ToastType.error);
    }
  }

  Future<void> _removeMember(int uid) async {
    setState(() => _busy = true);
    final ok = await ApiService().removeGroupMember(widget.conversationId, uid);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      await _load();
    } else {
      showToast(context, 'Could not remove member.', type: ToastType.error);
    }
  }

  Future<void> _addMembers() async {
    final existing =
        _members().map((m) => (m['user_id'] as num).toInt()).toSet();
    final picked = await showAppPopup<List<int>>(
      context,
      _AddMembersPicker(exclude: existing),
    );
    if (picked == null || picked.isEmpty) return;
    setState(() => _busy = true);
    final ok = await ApiService().addGroupMembers(widget.conversationId, picked);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      await _load();
    } else {
      showToast(context, 'Could not add members.', type: ToastType.error);
    }
  }

  Future<void> _leave() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Leave group?'),
        content: const Text(
            'You will stop receiving this group\'s messages.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: const Text('Leave')),
        ],
      ),
    );
    if (yes != true) return;
    final ok = await ApiService().leaveConversation(widget.conversationId);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, 'left'); // caller closes the panel
    } else {
      showToast(context, 'Could not leave the group.', type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppPopupShell(
      title: 'Group info',
      icon: Icons.info_outline_rounded,
      builder: (ctx, isWide) => _loading
          ? const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()))
          : _body(ctx),
    );
  }

  Widget _body(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = (_conv?['title'] ?? 'Group').toString();
    final avatar = _fullAvatar();
    final members = _members();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        children: [
          // Avatar (tap to change if admin)
          GestureDetector(
            onTap: (_isAdmin && !_busy) ? _changeAvatar : null,
            child: Stack(
              alignment: Alignment.bottomRight,
              children: [
                CircleAvatar(
                  radius: 44,
                  backgroundColor: scheme.primaryContainer,
                  backgroundImage: avatar != null
                      ? CachedNetworkImageProvider(avatar,
                          headers: mediaAuthHeaders(avatar))
                      : null,
                  child: avatar == null
                      ? Icon(Icons.groups_rounded,
                          size: 40, color: scheme.onPrimaryContainer)
                      : null,
                ),
                if (_isAdmin)
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                        color: scheme.primary, shape: BoxShape.circle),
                    child: const Icon(Icons.camera_alt_rounded,
                        size: 15, color: Colors.white),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Name (edit if admin)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis),
              ),
              if (_isAdmin)
                IconButton(
                  icon: const Icon(Icons.edit_rounded, size: 18),
                  onPressed: _busy ? null : _rename,
                  tooltip: 'Rename',
                ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text('${members.length} members',
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant)),
              const Spacer(),
              if (_isAdmin)
                TextButton.icon(
                  onPressed: _busy ? null : _addMembers,
                  icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                  label: const Text('Add'),
                ),
            ],
          ),
          const Divider(height: 8),
          ...members.map((m) => _memberTile(m, scheme)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _leave,
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Leave group'),
              style: OutlinedButton.styleFrom(
                foregroundColor: scheme.error,
                side: BorderSide(color: scheme.error.withAlpha(120)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _memberTile(dynamic m, ColorScheme scheme) {
    final uid = (m['user_id'] as num).toInt();
    final name = (m['username'] ?? 'User').toString();
    final role = (m['role'] ?? 'member').toString();
    final isSelf = uid == _myUid;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
            style: TextStyle(color: scheme.onPrimaryContainer)),
      ),
      title: Text(isSelf ? '$name (You)' : name),
      subtitle: role == 'admin'
          ? Text('Admin',
              style: TextStyle(fontSize: 11, color: scheme.primary))
          : null,
      trailing: (_isAdmin && !isSelf)
          ? IconButton(
              icon: Icon(Icons.remove_circle_outline_rounded,
                  color: scheme.error),
              tooltip: 'Remove',
              onPressed: _busy ? null : () => _removeMember(uid),
            )
          : null,
    );
  }
}

// A small popup that returns the selected friend ids to add to a group.
class _AddMembersPicker extends StatefulWidget {
  final Set<int> exclude;
  const _AddMembersPicker({required this.exclude});

  @override
  State<_AddMembersPicker> createState() => _AddMembersPickerState();
}

class _AddMembersPickerState extends State<_AddMembersPicker> {
  List<Map<String, dynamic>> _friends = [];
  final Set<int> _selected = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    List<Map<String, dynamic>> list = [];
    try {
      list = await ApiService().getFriends();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _friends = list
          .where((f) => !widget.exclude.contains((f['id'] as num).toInt()))
          .toList();
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppPopupShell(
      title: 'Add members',
      icon: Icons.person_add_alt_1_rounded,
      headerAction: TextButton(
        onPressed:
            _selected.isEmpty ? null : () => Navigator.pop(context, _selected.toList()),
        child: Text('Add (${_selected.length})',
            style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700)),
      ),
      builder: (ctx, isWide) {
        final scheme = Theme.of(ctx).colorScheme;
        if (_loading) {
          return const Padding(
            padding: EdgeInsets.all(30),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (_friends.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Everyone in your contacts is already here.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant)),
          );
        }
        return ListView.builder(
          shrinkWrap: true,
          itemCount: _friends.length,
          itemBuilder: (_, i) {
            final f = _friends[i];
            final id = (f['id'] as num).toInt();
            final name = (f['username'] ?? 'Friend').toString();
            return CheckboxListTile(
              value: _selected.contains(id),
              onChanged: (v) => setState(() {
                if (v == true) {
                  _selected.add(id);
                } else {
                  _selected.remove(id);
                }
              }),
              secondary: CircleAvatar(
                backgroundColor: scheme.primaryContainer,
                child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: TextStyle(color: scheme.onPrimaryContainer)),
              ),
              title: Text(name),
            );
          },
        );
      },
    );
  }
}
