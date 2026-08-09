import 'package:flutter/material.dart';

import 'api_service.dart';
import 'chat_page.dart';
import 'token_helper.dart';
import '../utils/toast_helper.dart';

/// Open a group conversation as a full-screen chat (reuses ChatPage in group
/// mode). `conv` is a ConversationOut map from the server.
Future<void> openGroupChat(BuildContext context, Map<String, dynamic> conv) {
  final scheme = Theme.of(context).colorScheme;
  final members = (conv['members'] as List?) ?? const [];
  return Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => ChatPage(
        friendName: (conv['title'] ?? 'Group').toString(),
        textColor: scheme.onSurface,
        showAppBar: true,
        conversationId: (conv['id'] as num).toInt(),
        isGroup: true,
        groupTitle: (conv['title'] ?? 'Group').toString(),
        groupAvatar: (conv['avatar_url'] ?? '').toString(),
        memberCount: members.length,
      ),
    ),
  );
}

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
    final created = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(builder: (_) => const GroupCreateScreen()),
    );
    if (!mounted) return;
    await _load();
    if (!mounted || created == null) return;
    openGroupChat(context, created);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Groups'),
        actions: [
          IconButton(
            tooltip: 'New group',
            icon: const Icon(Icons.group_add_rounded),
            onPressed: _newGroup,
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _groups.isEmpty
                ? _empty(scheme)
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.separated(
                      itemCount: _groups.length,
                      separatorBuilder: (_, _) => Divider(
                          height: 1,
                          color: scheme.outlineVariant.withAlpha(60)),
                      itemBuilder: (_, i) => _tile(_groups[i], scheme),
                    ),
                  ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newGroup,
        icon: const Icon(Icons.group_add_rounded),
        label: const Text('New group'),
      ),
    );
  }

  Widget _empty(ColorScheme scheme) => LayoutBuilder(
        builder: (_, cons) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox(
            height: cons.maxHeight,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.groups_rounded,
                      size: 64, color: scheme.primary.withAlpha(120)),
                  const SizedBox(height: 12),
                  const Text('No groups yet',
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text('Create one to chat with several friends at once.',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _tile(Map<String, dynamic> g, ColorScheme scheme) {
    final members = (g['members'] as List?) ?? const [];
    final unread = (g['unread_count'] as num?)?.toInt() ?? 0;
    final last = (g['last_message'] ?? '').toString();
    return ListTile(
      onTap: () async {
        await openGroupChat(context, g);
        _load();
      },
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
// Group creation (name + pick friends)
// ─────────────────────────────────────────────────────────────────────────────

class GroupCreateScreen extends StatefulWidget {
  const GroupCreateScreen({super.key});

  @override
  State<GroupCreateScreen> createState() => _GroupCreateScreenState();
}

class _GroupCreateScreenState extends State<GroupCreateScreen> {
  final _name = TextEditingController();
  List<Map<String, dynamic>> _friends = [];
  final Set<int> _selected = {};
  bool _loading = true;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _loadFriends();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _loadFriends() async {
    final token = await getToken();
    if (token == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final list = await ApiService().getFriendsList(token);
    if (!mounted) return;
    setState(() {
      _friends = list;
      _loading = false;
    });
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
      showToast(context, 'Could not create the group.',
          type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('New group'),
        actions: [
          TextButton(
            onPressed: _creating ? null : _create,
            child: _creating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.4))
                : Text('Create (${_selected.length})',
                    style: TextStyle(
                        color: scheme.primary, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
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
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text('Add members',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurfaceVariant)),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _friends.isEmpty
                      ? Center(
                          child: Text('No friends to add yet.',
                              style:
                                  TextStyle(color: scheme.onSurfaceVariant)))
                      : ListView.builder(
                          itemCount: _friends.length,
                          itemBuilder: (_, i) {
                            final f = _friends[i];
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
                                child: Text(
                                  name.isNotEmpty
                                      ? name[0].toUpperCase()
                                      : '?',
                                  style: TextStyle(
                                      color: scheme.onPrimaryContainer),
                                ),
                              ),
                              title: Text(name),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
