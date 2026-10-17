import 'dart:async';

import 'package:flutter/material.dart';

import 'api_service.dart';
import 'chat_page.dart';

/// Global message search across the user's DMs and groups. Type a term, see
/// recent matching messages grouped by nothing fancy — most-recent first — and
/// tap one to open that thread and jump to the message.
class MessageSearchScreen extends StatefulWidget {
  const MessageSearchScreen({super.key});

  @override
  State<MessageSearchScreen> createState() => _MessageSearchScreenState();
}

class _MessageSearchScreenState extends State<MessageSearchScreen> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>> _results = const [];
  bool _loading = false;
  String _lastTerm = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _run(v));
  }

  Future<void> _run(String term) async {
    final q = term.trim();
    if (q.length < 2) {
      setState(() {
        _results = const [];
        _loading = false;
        _lastTerm = q;
      });
      return;
    }
    setState(() {
      _loading = true;
      _lastTerm = q;
    });
    final res = await ApiService().searchMessages(q);
    if (!mounted || q != _lastTerm) return;
    setState(() {
      _results = res;
      _loading = false;
    });
  }

  String _when(String? iso) {
    final d = DateTime.tryParse(iso ?? '')?.toLocal();
    if (d == null) return '';
    final now = DateTime.now();
    final sameDay =
        d.year == now.year && d.month == now.month && d.day == now.day;
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    if (sameDay) return '$hh:$mm';
    return '${d.day}/${d.month}/${d.year}';
  }

  void _open(Map<String, dynamic> r) {
    final scheme = Theme.of(context).colorScheme;
    final jumpId = r['id']?.toString();
    final isGroup = r['is_group'] == true;
    Widget page;
    if (isGroup) {
      page = ChatPage(
        friendName: (r['group_title'] ?? 'Group').toString(),
        textColor: scheme.onSurface,
        isGroup: true,
        conversationId: (r['conversation_id'] as num?)?.toInt(),
        groupTitle: (r['group_title'] ?? 'Group').toString(),
        groupAvatar: (r['group_avatar'] ?? '').toString(),
        initialJumpMessageId: jumpId,
      );
    } else {
      final fid = (r['friend_id'] as num?)?.toInt() ?? 0;
      page = ChatPage(
        friendId: fid,
        friendName: (r['friend_name'] ?? '').toString(),
        friendAvatar: (r['friend_avatar'] ?? '').toString(),
        textColor: scheme.onSurface,
        initialJumpMessageId: jumpId,
      );
    }
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          onChanged: _onChanged,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Search messages…',
            border: InputBorder.none,
          ),
        ),
        actions: [
          if (_ctrl.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close_rounded),
              onPressed: () {
                _ctrl.clear();
                _run('');
              },
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _results.isEmpty
              ? Center(
                  child: Text(
                    _lastTerm.length < 2
                        ? 'Type at least 2 characters'
                        : 'No messages found',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              : ListView.separated(
                  itemCount: _results.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final r = _results[i];
                    final isGroup = r['is_group'] == true;
                    final name = (isGroup
                            ? r['group_title']
                            : r['friend_name'])
                        ?.toString() ??
                        '';
                    final content = (r['content'] ?? '').toString();
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: scheme.primaryContainer,
                        child: Icon(
                          isGroup ? Icons.groups_rounded : Icons.person_rounded,
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                      title: Text(
                        name.isEmpty ? (isGroup ? 'Group' : 'Chat') : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        content,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                      trailing: Text(
                        _when(r['timestamp']?.toString()),
                        style: TextStyle(
                            fontSize: 11, color: scheme.onSurfaceVariant),
                      ),
                      onTap: () => _open(r),
                    );
                  },
                ),
    );
  }
}
