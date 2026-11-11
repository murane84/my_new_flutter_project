import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'api_service.dart';
import 'chat_page.dart';
import '../services/contact_names.dart';
import '../utils/avatar_widget.dart';
import '../utils/readable.dart';
import '../utils/time_utils.dart' show parseServerTime;

/// Global search across my chats: the PEOPLE and GROUPS whose names match
/// first ("Chats"), then the MESSAGES grouped by chat (best matches first,
/// the term highlighted), and the automatic jam / poll lines last
/// ("Activity", folded). A tapped hit opens in the normal chat panel and
/// lands on the message.
class MessageSearchScreen extends StatefulWidget {
  /// Home passes this so a tapped hit opens in the normal chat panel (same
  /// header as the chat list) and lands with the jump rings. Without it the
  /// thread is pushed as its own page.
  final void Function(Map<String, dynamic> hit)? onOpen;

  /// My friends and groups (Home's lists) for the "Chats" strip, and how to
  /// open each in the chat panel.
  final List<Map<String, dynamic>> people;
  final List<Map<String, dynamic>> groups;
  final void Function(Map<String, dynamic> friend)? onOpenChat;
  final void Function(Map<String, dynamic> group)? onOpenGroup;

  /// A server-relative avatar path → full URL.
  final String? Function(dynamic rel)? avatarOf;

  /// Me (a group hit I sent reads "You: …").
  final int? myUserId;

  const MessageSearchScreen({
    super.key,
    this.onOpen,
    this.people = const [],
    this.groups = const [],
    this.onOpenChat,
    this.onOpenGroup,
    this.avatarOf,
    this.myUserId,
  });

  @override
  State<MessageSearchScreen> createState() => _MessageSearchScreenState();
}

/// One chat's matches.
class _Hits {
  _Hits(this.key);
  final String key; // 'g<cid>' / 's<friendId>'
  final List<Map<String, dynamic>> items = [];
  int best = 0; // best match score
}

class _MessageSearchScreenState extends State<MessageSearchScreen> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>> _results = const [];
  bool _loading = false;
  String _lastTerm = '';
  // Chats whose "Show all" is open; the folded Activity section.
  final Set<String> _expanded = {};
  bool _activityOpen = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _run(v));
  }

  Future<void> _run(String term) async {
    final q = term.trim();
    if (q.length < 2) {
      setState(() {
        _results = const [];
        _loading = false;
        _lastTerm = q;
        _expanded.clear();
        _activityOpen = false;
      });
      return;
    }
    // The previous results STAY while the new ones load (a thin line on
    // top says it's working) — no blank flash on every key.
    setState(() {
      _loading = true;
      _lastTerm = q;
    });
    final res = await ApiService().searchMessages(q, limit: 100);
    if (!mounted || q != _lastTerm) return;
    setState(() {
      _results = res;
      _loading = false;
      _expanded.clear();
      _activityOpen = false;
    });
  }

  // ── Ranking ─────────────────────────────────────────────────────────────

  /// 3 = the whole word, 2 = a word starts with it, 1 = inside a word.
  int _score(String text, String q) {
    final t = text.toLowerCase(), k = q.toLowerCase();
    final e = RegExp.escape(k);
    if (RegExp('(^|[^\\p{L}\\p{N}])$e(\$|[^\\p{L}\\p{N}])', unicode: true)
        .hasMatch(t)) {
      return 3;
    }
    if (RegExp('(^|[^\\p{L}\\p{N}])$e', unicode: true).hasMatch(t)) return 2;
    return t.contains(k) ? 1 : 0;
  }

  /// Automatic lines (jam polls, "… won — now playing for the group").
  bool _isActivity(Map<String, dynamic> r) {
    if ((r['message_type'] ?? '').toString() == 'poll') return true;
    final c = (r['content'] ?? '').toString();
    return c.startsWith('🏆') && c.contains('now playing for the group');
  }

  String _keyOf(Map<String, dynamic> r) => r['is_group'] == true
      ? 'g${r['conversation_id']}'
      : 's${r['friend_id']}';

  /// The name I know a chat by (my saved name for a friend).
  String _chatName(Map<String, dynamic> r) {
    if (r['is_group'] == true) {
      return (r['group_title'] ?? 'Group').toString();
    }
    final id = r['friend_id']?.toString();
    final f = widget.people.firstWhere((p) => p['id']?.toString() == id,
        orElse: () => const <String, dynamic>{});
    final registered = (r['friend_name'] ?? 'Chat').toString();
    return f.isEmpty
        ? registered
        : ContactNames.instance.displayName(of: f, registered: registered);
  }

  // ── Chats strip: people + groups whose names match ──────────────────────

  List<(Map<String, dynamic>, String, bool)> _chatMatches(String q) {
    if (q.length < 2) return const [];
    final out = <(Map<String, dynamic>, String, bool, int)>[];
    for (final f in widget.people) {
      final reg = (f['username'] ?? '').toString();
      final shown = ContactNames.instance.displayName(of: f, registered: reg);
      final sc = _score(shown, q) > _score(reg, q)
          ? _score(shown, q)
          : _score(reg, q);
      if (sc > 0) out.add((f, shown, false, sc));
    }
    for (final g in widget.groups) {
      final t = (g['title'] ?? '').toString();
      final sc = _score(t, q);
      if (sc > 0) out.add((g, t, true, sc));
    }
    out.sort((a, b) => b.$4.compareTo(a.$4));
    return [for (final o in out.take(12)) (o.$1, o.$2, o.$3)];
  }

  // ── Friendly time ───────────────────────────────────────────────────────

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  String _when(String? iso) {
    final raw = iso ?? '';
    if (raw.isEmpty) return '';
    final DateTime d;
    try {
      // Server time → this phone's local time (same reading as the chats).
      d = parseServerTime(raw).toLocal();
    } catch (_) {
      return '';
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final ago = today.difference(day).inDays;
    if (ago == 0) {
      return '${d.hour.toString().padLeft(2, '0')}:'
          '${d.minute.toString().padLeft(2, '0')}';
    }
    if (ago == 1) return 'Yesterday';
    if (ago < 7) return _days[d.weekday - 1];
    final md = '${d.day} ${_months[d.month - 1]}';
    return d.year == now.year ? md : '$md ${d.year}';
  }

  // ── Opening ─────────────────────────────────────────────────────────────

  void _openChat(Map<String, dynamic> c, bool isGroup) {
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop();
    if (isGroup) {
      widget.onOpenGroup?.call(c);
    } else {
      widget.onOpenChat?.call(c);
    }
  }

  void _open(Map<String, dynamic> r) {
    if (widget.onOpen != null) {
      FocusScope.of(context).unfocus();
      Navigator.of(context).pop();
      widget.onOpen!(r);
      return;
    }
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

  Widget _glassBar(ColorScheme scheme, bool isDark) {
    final ink = isDark ? Colors.white : const Color(0xFF2B2829);
    final soft = ink.withValues(alpha: 0.55);
    final none =
        !_loading && _lastTerm.length >= 2 && _results.isEmpty;
    return ClipRRect(
      borderRadius: BorderRadius.circular(19),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 38, // compact, like every search pill
          padding: const EdgeInsets.only(left: 6, right: 4),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.black.withValues(alpha: 0.42)
                : Colors.white.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(19),
            border: Border.all(
              color: none
                  ? scheme.error.withValues(alpha: 0.45)
                  : scheme.primary.withValues(alpha: isDark ? 0.5 : 0.4),
            ),
            boxShadow: [
              BoxShadow(
                color: scheme.primary.withValues(alpha: 0.14),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              // Aluta signature: the logo disc leads the pill.
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: [
                    scheme.primary,
                    Color.lerp(scheme.primary, Colors.white, 0.25)!,
                  ]),
                ),
                child: const Icon(Icons.search_rounded,
                    size: 16, color: Colors.white),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  autofocus: true,
                  onChanged: (v) {
                    setState(() {}); // × appears / hides
                    _onChanged(v);
                  },
                  textInputAction: TextInputAction.search,
                  cursorColor: scheme.primary,
                  style: TextStyle(color: ink, fontSize: 15),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    hintText: 'Search all your chats',
                    hintStyle: TextStyle(color: soft, fontSize: 14),
                  ),
                ),
              ),
              if (_ctrl.text.isNotEmpty)
                IconButton(
                  tooltip: 'Clear',
                  visualDensity: VisualDensity.compact,
                  constraints:
                      const BoxConstraints(minWidth: 34, minHeight: 34),
                  icon: Icon(Icons.close_rounded, size: 20, color: ink),
                  onPressed: () {
                    _ctrl.clear();
                    _run('');
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Pieces ──────────────────────────────────────────────────────────────

  /// [text] with every match of [q] in bold accent; long text is cut to a
  /// window around the first match so the match is always visible.
  Widget _highlight(String text, String q, ColorScheme scheme,
          {TextStyle? base, int maxLines = 2}) =>
      Text.rich(_hlSpan(text, q, scheme, base: base),
          maxLines: maxLines, overflow: TextOverflow.ellipsis);

  TextSpan _hlSpan(String text, String q, ColorScheme scheme,
      {TextStyle? base}) {
    final style =
        base ?? TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant);
    var t = text.replaceAll('\n', ' ');
    final lower = t.toLowerCase(), k = q.toLowerCase();
    final first = lower.indexOf(k);
    if (first > 40) {
      final from = t.lastIndexOf(' ', first - 20);
      t = '…${t.substring(from < 0 ? first - 20 : from + 1)}';
    }
    final spans = <TextSpan>[];
    final lt = t.toLowerCase();
    var at = 0;
    while (k.isNotEmpty) {
      final i = lt.indexOf(k, at);
      if (i < 0) break;
      if (i > at) spans.add(TextSpan(text: t.substring(at, i)));
      spans.add(TextSpan(
          text: t.substring(i, i + k.length),
          style: TextStyle(
              fontWeight: FontWeight.w800,
              color: accentInk(scheme),
              backgroundColor: scheme.primary.withValues(alpha: 0.10))));
      at = i + k.length;
    }
    if (at < t.length) spans.add(TextSpan(text: t.substring(at)));
    return TextSpan(style: style, children: spans);
  }

  Widget _sectionLabel(ColorScheme scheme, String label, {String? trailing}) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
        child: Row(children: [
          Text(label.toUpperCase(),
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: scheme.onSurfaceVariant)),
          if (trailing != null) ...[
            const SizedBox(width: 6),
            Text(trailing,
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    color: accentInk(scheme))),
          ],
        ]),
      );

  Widget _chatsStrip(ColorScheme scheme, String q) {
    final m = _chatMatches(q);
    if (m.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionLabel(scheme, 'Chats', trailing: '· ${m.length}'),
      SizedBox(
        height: 92,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          itemCount: m.length,
          separatorBuilder: (_, _) => const SizedBox(width: 6),
          itemBuilder: (_, i) {
            final (c, name, isGroup) = m[i];
            return InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => _openChat(c, isGroup),
              child: SizedBox(
                width: 74,
                child: Column(children: [
                  const SizedBox(height: 4),
                  Stack(clipBehavior: Clip.none, children: [
                    InitialsAvatar(
                        name: name,
                        radius: 24,
                        imageUrl: widget.avatarOf?.call(c['avatar_url'])),
                    if (isGroup)
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                              color: scheme.primary,
                              shape: BoxShape.circle,
                              border:
                                  Border.all(color: scheme.surface, width: 2)),
                          child: Icon(Icons.groups_rounded,
                              size: 10, color: readableOn(scheme.primary)),
                        ),
                      ),
                  ]),
                  const SizedBox(height: 6),
                  _highlight(name, q, scheme,
                      maxLines: 1,
                      base: TextStyle(fontSize: 12, color: scheme.onSurface)),
                ]),
              ),
            );
          },
        ),
      ),
    ]);
  }

  /// One chat's card: its name + "N matches", the best few hits, Show all.
  Widget _chatCard(ColorScheme scheme, _Hits h, String q) {
    final first = h.items.first;
    final isGroup = first['is_group'] == true;
    final name = _chatName(first);
    final open = _expanded.contains(h.key);
    final shown = open ? h.items : h.items.take(3).toList();
    final avatar = widget.avatarOf
        ?.call(isGroup ? first['group_avatar'] : first['friend_avatar']);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Row(children: [
              InitialsAvatar(name: name, radius: 15, imageUrl: avatar),
              const SizedBox(width: 10),
              Expanded(
                child: Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                        color: scheme.onSurface)),
              ),
              Text(
                  '${h.items.length} match${h.items.length == 1 ? '' : 'es'}',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: accentInk(scheme))),
            ]),
          ),
          for (final r in shown) _hitRow(scheme, r, q, isGroup),
          if (h.items.length > 3)
            TextButton(
              onPressed: () => setState(() =>
                  open ? _expanded.remove(h.key) : _expanded.add(h.key)),
              child: Text(open ? 'Show fewer' : 'Show all ${h.items.length}'),
            ),
          const SizedBox(height: 4),
        ]),
      ),
    );
  }

  Widget _hitRow(
      ColorScheme scheme, Map<String, dynamic> r, String q, bool isGroup) {
    // In a group, who said it ("Lorraine: …" / "You: …").
    String who = '';
    if (isGroup) {
      final sid = r['sender_id']?.toString();
      if (sid != null && sid == widget.myUserId?.toString()) {
        who = 'You';
      } else {
        final f = widget.people.firstWhere(
            (p) => p['id']?.toString() == sid,
            orElse: () => const <String, dynamic>{});
        final reg = (r['sender_name'] ?? '').toString();
        who = (f.isNotEmpty
                ? ContactNames.instance.displayName(of: f, registered: reg)
                : reg)
            .split(' ')
            .first;
      }
    }
    return InkWell(
      onTap: () => _open(r),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(52, 6, 12, 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                if (who.isNotEmpty)
                  TextSpan(
                      text: '$who: ',
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface)),
                _hlSpan((r['content'] ?? '').toString(), q, scheme),
              ]),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(_when(r['timestamp']?.toString()),
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final q = _lastTerm;

    // Group by chat; best match first, then the most recent.
    final chats = <String, _Hits>{};
    final activity = <Map<String, dynamic>>[];
    for (final r in _results) {
      if (_isActivity(r)) {
        activity.add(r);
        continue;
      }
      final h = chats.putIfAbsent(_keyOf(r), () => _Hits(_keyOf(r)));
      h.items.add(r); // already newest first
      final sc = _score((r['content'] ?? '').toString(), q);
      if (sc > h.best) h.best = sc;
    }
    final ordered = chats.values.toList()
      ..sort((a, b) {
        final c = b.best.compareTo(a.best);
        if (c != 0) return c;
        return (b.items.first['timestamp'] ?? '')
            .toString()
            .compareTo((a.items.first['timestamp'] ?? '').toString());
      });
    for (final h in ordered) {
      // Inside a chat: whole words before word-starts before inside-words.
      h.items.sort((a, b) {
        final c = _score((b['content'] ?? '').toString(), q)
            .compareTo(_score((a['content'] ?? '').toString(), q));
        if (c != 0) return c;
        return (b['timestamp'] ?? '')
            .toString()
            .compareTo((a['timestamp'] ?? '').toString());
      });
    }
    final strip = _chatsStrip(scheme, q);
    final nothing = q.length >= 2 &&
        !_loading &&
        _results.isEmpty &&
        _chatMatches(q).isEmpty;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        toolbarHeight: 64,
        // Same frosted pill as the in-chat search.
        title: Padding(
          padding: const EdgeInsets.only(right: 12),
          child: _glassBar(scheme, isDark),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: _loading
              ? LinearProgressIndicator(
                  minHeight: 2, color: scheme.primary,
                  backgroundColor: Colors.transparent)
              : const SizedBox(height: 2),
        ),
      ),
      body: q.length < 2
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.manage_search_rounded,
                      size: 44, color: accentInk(scheme)),
                  const SizedBox(height: 10),
                  Text('Search your messages, people and groups',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface)),
                  const SizedBox(height: 4),
                  Text('Type at least 2 letters',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ]),
              ),
            )
          : nothing
              ? Center(
                  child: Text('Nothing matches “$q”',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    strip,
                    if (ordered.isNotEmpty)
                      _sectionLabel(scheme, 'Messages',
                          trailing: '· ${_results.length - activity.length}'),
                    for (final h in ordered) _chatCard(scheme, h, q),
                    // The automatic jam / poll lines: kept, but out of the way.
                    if (activity.isNotEmpty) ...[
                      InkWell(
                        onTap: () =>
                            setState(() => _activityOpen = !_activityOpen),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(0, 4, 12, 0),
                          child: Row(children: [
                            Expanded(
                              child: _sectionLabel(scheme, 'Activity',
                                  trailing:
                                      '· ${activity.length} jam & poll lines'),
                            ),
                            Icon(
                                _activityOpen
                                    ? Icons.expand_less_rounded
                                    : Icons.expand_more_rounded,
                                color: scheme.onSurfaceVariant),
                          ]),
                        ),
                      ),
                      if (_activityOpen)
                        for (final r in activity)
                          ListTile(
                            dense: true,
                            leading: Icon(
                                (r['message_type'] ?? '') == 'poll'
                                    ? Icons.poll_rounded
                                    : Icons.emoji_events_rounded,
                                size: 18,
                                color: scheme.onSurfaceVariant),
                            title: Text(_chatName(r),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13)),
                            subtitle: _highlight(
                                (r['content'] ?? '').toString(), q, scheme,
                                maxLines: 1),
                            trailing: Text(_when(r['timestamp']?.toString()),
                                style: TextStyle(
                                    fontSize: 11,
                                    color: scheme.onSurfaceVariant)),
                            onTap: () => _open(r),
                          ),
                    ],
                  ],
                ),
    );
  }
}
