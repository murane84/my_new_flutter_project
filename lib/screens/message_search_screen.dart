import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'api_service.dart';
import 'chat_page.dart';
import '../services/contact_names.dart';
import '../utils/avatar_widget.dart';
import '../utils/readable.dart';
import '../utils/time_utils.dart' show parseServerTime;
import '../utils/prefs_now.dart';
import '../widgets/genie_menu.dart';
import '../widgets/edge_scroll_row.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

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

  // ── Stage 2: browse by kind + filters + recent + keys ──
  String? _kind; // media · link · voice · song · file
  String? _sender; // 'me' | 'others'
  Map<String, dynamic>? _inChat; // {'group': bool, 'id': int, 'name': str}
  int? _sinceDays; // 7 · 30
  List<String> _recent = const [];
  static const _kRecent = 'msg_search_recent_v1';
  // Keyboard: the highlighted hit (↑ ↓ Enter) in what's on screen.
  int _cursor = -1;
  String _sig = '';
  List<Map<String, dynamic>> _flat = const [];

  bool get _filtered =>
      _kind != null || _sender != null || _inChat != null || _sinceDays != null;

  @override
  void initState() {
    super.initState();
    _recent = prefsNow?.getStringList(_kRecent) ?? const [];
  }

  void _remember(String term) {
    final t = term.trim();
    if (t.length < 2) return;
    final next = [t, ..._recent.where((e) => e.toLowerCase() != t.toLowerCase())]
        .take(8)
        .toList();
    _recent = next;
    prefsNow?.setStringList(_kRecent, next);
  }

  void _clearRecent() {
    setState(() => _recent = const []);
    prefsNow?.remove(_kRecent);
  }

  void _setFilter(VoidCallback change) {
    setState(change);
    _run(_ctrl.text);
  }

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
    if (q.length < 2 && _kind == null) {
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
    final sig = '$q|$_kind|$_sender|${_inChat?['id']}|$_sinceDays';
    _sig = sig;
    final res = await ApiService().searchMessages(q,
        limit: 100,
        kind: _kind,
        sender: _sender,
        conversationId:
            _inChat?['group'] == true ? _inChat!['id'] as int : null,
        friendId: _inChat != null && _inChat!['group'] != true
            ? _inChat!['id'] as int
            : null,
        sinceDays: _sinceDays);
    if (!mounted || q != _lastTerm || sig != _sig) return;
    setState(() {
      _cursor = -1;
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
    _remember(_ctrl.text);
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop();
    if (isGroup) {
      widget.onOpenGroup?.call(c);
    } else {
      widget.onOpenChat?.call(c);
    }
  }

  void _open(Map<String, dynamic> r) {
    _remember(_ctrl.text);
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
                child: CallbackShortcuts(
                  // Desktop: ↑ ↓ walk the hits, Enter opens, Esc closes.
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                        _moveCursor(1),
                    const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                        _moveCursor(-1),
                    const SingleActivator(LogicalKeyboardKey.escape): () =>
                        Navigator.of(context).maybePop(),
                  },
                  child: TextField(
                  onSubmitted: (v) {
                    if (_cursor >= 0 && _cursor < _flat.length) {
                      _open(_flat[_cursor]);
                    } else {
                      setState(() => _remember(v));
                    }
                  },
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
                    hintText: _kind != null
                        ? 'Search in ${_kindLabel(_kind!).toLowerCase()}…'
                        : 'Search all your chats',
                    hintStyle: TextStyle(color: soft, fontSize: 14),
                  ),
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

  // ── Stage 2 helpers ─────────────────────────────────────────────────────

  void _moveCursor(int by) {
    if (_flat.isEmpty) return;
    setState(() {
      _cursor = (_cursor + by).clamp(0, _flat.length - 1);
    });
  }

  static String _kindLabel(String k) => switch (k) {
        'media' => 'Photos & videos',
        'link' => 'Links',
        'voice' => 'Voice notes',
        'song' => 'Songs',
        _ => 'Files',
      };

  static IconData _kindIcon(String k) => switch (k) {
        'media' => Icons.photo_library_rounded,
        'link' => Icons.link_rounded,
        'voice' => Icons.mic_rounded,
        'song' => Icons.music_note_rounded,
        _ => Icons.insert_drive_file_rounded,
      };

  /// What a hit says: its words, or for media its name / kind.
  String _rowText(Map<String, dynamic> r) {
    final c = (r['content'] ?? '').toString().trim();
    final name = (r['media_name'] ?? '').toString().trim();
    final t = (r['message_type'] ?? 'text').toString();
    final mime = (r['media_mime'] ?? '').toString();
    String label() {
      if (t == 'song') return '🎵 ${name.isEmpty ? 'Song' : name}';
      if (t == 'audio' || t == 'voice') return '🎤 Voice note';
      if (t == 'gif' || t == 'sticker') return '🎞️ GIF';
      if (mime.startsWith('video/') || t == 'video') return '🎬 Video';
      if (t == 'image' || mime.startsWith('image/')) return '📷 Photo';
      if (t == 'file') return '📎 ${name.isEmpty ? 'File' : name}';
      return '';
    }

    final l = label();
    if (c.isEmpty) return l.isEmpty ? name : l;
    return l.isEmpty ? c : '$l · $c';
  }

  /// The chips under the bar: what kind, from whom, which chat, when.
  Widget _filterBar(ColorScheme scheme) {
    // Every chip first glides fully into view (its neighbours peek in, so
    // the row reveals the rest by itself), then acts — a menu chip opens
    // its dropdown from where it now sits.
    Widget chip(String label, bool on, void Function(BuildContext c) onTap,
            {IconData? icon, bool menu = false}) =>
        Builder(builder: (c) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Material(
            color: on
                ? scheme.primary.withValues(alpha: 0.16)
                : scheme.surfaceContainerHighest,
            shape: StadiumBorder(
                side: BorderSide(
                    color: on
                        ? scheme.primary.withValues(alpha: 0.6)
                        : scheme.outlineVariant.withValues(alpha: 0.45))),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () async {
                await EdgeScrollRow.reveal(c);
                if (c.mounted) onTap(c);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 11),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (icon != null) ...[
                    Icon(icon,
                        size: 15,
                        color: on ? accentInk(scheme) : scheme.onSurfaceVariant),
                    const SizedBox(width: 5),
                  ],
                  Text(label,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                          color: on ? accentInk(scheme) : scheme.onSurface)),
                  if (menu)
                    Icon(Icons.arrow_drop_down_rounded,
                        size: 18, color: scheme.onSurfaceVariant),
                ]),
              ),
            ),
          ),
        ));
    final from = switch (_sender) {
      'me' => 'From me',
      'others' => 'From others',
      _ => 'From anyone',
    };
    final when = switch (_sinceDays) {
      7 => 'Last 7 days',
      30 => 'Last 30 days',
      _ => 'Any time',
    };
    return SizedBox(
      height: 32,
      child: EdgeScrollRow(
        builder: (context, ctrl) => ListView(
          controller: ctrl,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: [
            for (final k in const ['media', 'link', 'voice', 'song', 'file'])
              chip(_kindLabel(k), _kind == k,
                  (_) => _setFilter(() => _kind = _kind == k ? null : k),
                  icon: _kindIcon(k)),
            chip(
                from,
                _sender != null,
                (c) => _pick<String>(c, _sender ?? '', [
                      ('', 'From anyone', Icons.people_outline_rounded),
                      ('me', 'From me', Icons.person_rounded),
                      ('others', 'From others', Icons.person_outline_rounded),
                    ], (v) => _setFilter(() => _sender = v.isEmpty ? null : v)),
                icon: Icons.person_outline_rounded,
                menu: true),
            chip(_inChat == null ? 'In any chat' : 'In ${_inChat!['name']}',
                _inChat != null, _pickChat,
                icon: Icons.forum_outlined, menu: true),
            chip(
                when,
                _sinceDays != null,
                (c) => _pick<int>(c, _sinceDays ?? 0, [
                      (0, 'Any time', Icons.all_inclusive_rounded),
                      (7, 'Last 7 days', Icons.date_range_rounded),
                      (30, 'Last 30 days', Icons.calendar_month_rounded),
                    ], (v) => _setFilter(() => _sinceDays = v == 0 ? null : v)),
                icon: Icons.schedule_rounded,
                menu: true),
            if (_filtered)
              chip('Clear', false, (_) => _setFilter(() {
                    _kind = null;
                    _sender = null;
                    _inChat = null;
                    _sinceDays = null;
                  }), icon: Icons.close_rounded),
          ],
        ),
      ),
    );
  }

  Rect? _rectOf(BuildContext c) {
    final box = c.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// The ✓ on the option in force.
  Widget _tick() => Icon(Icons.check_rounded,
      size: 18, color: accentInk(Theme.of(context).colorScheme));

  /// A small dropdown growing out of a chip (Aluta's genie menu), the
  /// option in force ticked.
  void _pick<T>(BuildContext c, T current, List<(T, String, IconData)> options,
      void Function(T value) onPick) {
    final rect = _rectOf(c);
    if (rect == null) return;
    showGenieMenu(c, anchor: rect, width: 210, entries: [
      for (final o in options)
        GenieMenuEntry(
            icon: o.$3,
            label: o.$2,
            trailing: o.$1 == current ? _tick() : null,
            onTap: () {
              if (mounted) onPick(o.$1);
            }),
    ]);
  }

  /// "In …": pick one chat (my friends and groups) — the same dropdown as
  /// the other chips, capped in height; a long list scrolls inside it.
  void _pickChat(BuildContext c) {
    final rect = _rectOf(c);
    if (rect == null) return;
    final scheme = Theme.of(context).colorScheme;
    final curGroup = _inChat?['group'] == true;
    final curId = _inChat?['id'];
    Widget row(Widget lead, String name, {Widget? trailing}) => Row(children: [
          lead,
          const SizedBox(width: 10),
          Expanded(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, color: scheme.onSurface)),
          ),
          ?trailing,
        ]);
    void choose(Map<String, dynamic>? v) {
      if (mounted) _setFilter(() => _inChat = v);
    }

    final entries = <GenieMenuEntry>[
      GenieMenuEntry(
        icon: Icons.all_inclusive_rounded,
        label: 'Any chat',
        trailing: _inChat == null ? _tick() : null,
        onTap: () => choose(null),
      ),
      if (widget.groups.isNotEmpty || widget.people.isNotEmpty)
        const GenieMenuEntry.divider(),
    ];
    for (final g in widget.groups) {
      final id = (g['id'] as num).toInt();
      final name = (g['title'] ?? 'Group').toString();
      entries.add(GenieMenuEntry(
        label: name,
        custom: row(
            InitialsAvatar(
                name: name,
                radius: 14,
                imageUrl: widget.avatarOf?.call(g['avatar_url'])),
            name,
            trailing: curGroup && curId == id
                ? _tick()
                : Icon(Icons.groups_rounded,
                    size: 16, color: scheme.onSurfaceVariant)),
        onTap: () => choose({'group': true, 'id': id, 'name': name}),
      ));
    }
    for (final f in widget.people) {
      final id = (f['id'] as num).toInt();
      final name = ContactNames.instance
          .displayName(of: f, registered: (f['username'] ?? '').toString());
      entries.add(GenieMenuEntry(
        label: name,
        custom: row(
            InitialsAvatar(
                name: name,
                radius: 14,
                imageUrl: widget.avatarOf?.call(f['avatar_url'])),
            name,
            trailing: !curGroup && curId == id ? _tick() : null),
        onTap: () => choose({'group': false, 'id': id, 'name': name}),
      ));
    }
    showGenieMenu(c,
        anchor: rect, width: 260, maxHeight: 360, entries: entries);
  }

  /// Before typing: recent searches and one-tap browsing by kind.
  Widget _startScreen(ColorScheme scheme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
      children: [
        if (_recent.isNotEmpty) ...[
          Row(children: [
            Expanded(child: _sectionLabel(scheme, 'Recent')),
            TextButton(onPressed: _clearRecent, child: const Text('Clear')),
            const SizedBox(width: 8),
          ]),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final t in _recent)
                ActionChip(
                  avatar: const Icon(Icons.history_rounded, size: 16),
                  label: Text(t),
                  shape: const StadiumBorder(),
                  onPressed: () {
                    _ctrl.text = t;
                    _ctrl.selection =
                        TextSelection.collapsed(offset: t.length);
                    _run(t);
                  },
                ),
            ]),
          ),
        ],
        _sectionLabel(scheme, 'Browse'),
        for (final k in const ['media', 'link', 'voice', 'song', 'file'])
          ListTile(
            leading: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle),
              child: Icon(_kindIcon(k), size: 19, color: accentInk(scheme)),
            ),
            title: Text(_kindLabel(k)),
            subtitle: Text('Across all your chats',
                style: TextStyle(
                    fontSize: 12, color: scheme.onSurfaceVariant)),
            onTap: () => _setFilter(() => _kind = k),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
          child: Text(
              'Or type at least 2 letters to search messages, people and '
              'groups.',
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
      ],
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
        child: EdgeScrollRow(
          builder: (context, ctrl) => ListView.separated(
          controller: ctrl,
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
    final active = _cursor >= 0 &&
        _cursor < _flat.length &&
        identical(_flat[_cursor], r);
    return InkWell(
      onTap: () => _open(r),
      child: Container(
        color: active ? scheme.primary.withValues(alpha: 0.10) : null,
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
                _hlSpan(_rowText(r), q, scheme),
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
    final browsing = q.length >= 2 || _kind != null;
    final nothing = browsing &&
        !_loading &&
        _results.isEmpty &&
        _chatMatches(q).isEmpty;
    // What ↑ ↓ walk through: the hits as shown, top to bottom.
    _flat = [
      for (final h in ordered)
        ...(_expanded.contains(h.key) ? h.items : h.items.take(3)),
      if (_activityOpen) ...activity,
    ];
    if (_cursor >= _flat.length) _cursor = _flat.length - 1;

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
          preferredSize: const Size.fromHeight(42),
          child: Column(children: [
            _filterBar(scheme),
            const SizedBox(height: 8),
            _loading
                ? LinearProgressIndicator(
                    minHeight: 2,
                    color: scheme.primary,
                    backgroundColor: Colors.transparent)
                : const SizedBox(height: 2),
          ]),
        ),
      ),
      body: !browsing
          ? _startScreen(scheme)
          : nothing
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                        q.length >= 2
                            ? 'Nothing matches “$q”'
                                '${_filtered ? ' with these filters' : ''}'
                            : 'No ${_kindLabel(_kind!).toLowerCase()} found'
                                '${_filtered ? ' with these filters' : ''}',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  ),
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
