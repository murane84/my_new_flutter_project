import 'package:flutter/material.dart';

import 'admin_api.dart';
import 'admin_widgets.dart';

/// Feedback from the app's "Send feedback" page: read, triage (Seen /
/// Planned / Done / Not planned) and reply — the person sees the status and
/// reply in the app, and gets a push.
class AdminFeedbackPage extends StatefulWidget {
  const AdminFeedbackPage({super.key, required this.onChanged});
  final VoidCallback onChanged;

  @override
  State<AdminFeedbackPage> createState() => _AdminFeedbackPageState();
}

class _AdminFeedbackPageState extends State<AdminFeedbackPage> {
  final _api = AdminApi.instance;
  final List<Map<String, dynamic>> _rows = [];
  Map<String, dynamic> _counts = const {};
  num? _avg;
  String? _status; // null = all
  bool _loading = false;
  bool _more = true;
  String? _error;

  static const _statuses = [
    (null, 'All', Icons.all_inbox_rounded),
    ('new', 'New', Icons.fiber_new_rounded),
    ('seen', 'Seen', Icons.visibility_rounded),
    ('planned', 'Planned', Icons.construction_rounded),
    ('done', 'Done', Icons.check_circle_rounded),
    ('wontfix', 'Not planned', Icons.do_not_disturb_on_rounded),
  ];

  static (Color, IconData, String) _kind(String? k) => switch (k) {
        'problem' => (const Color(0xFFEF5350), Icons.bug_report_rounded,
            'Problem'),
        'praise' => (const Color(0xFFE91E63), Icons.favorite_rounded,
            'Love it'),
        'idea' => (const Color(0xFFFF9100), Icons.lightbulb_rounded, 'Idea'),
        _ => (const Color(0xFF78909C), Icons.chat_bubble_rounded, 'Other'),
      };

  static Color _statusColor(String s) => switch (s) {
        'new' => kAdminRed,
        'seen' => const Color(0xFF7C4DFF),
        'planned' => const Color(0xFF2979FF),
        'done' => const Color(0xFF00C853),
        _ => const Color(0xFF9E9E9E),
      };

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final qs = <String>[
        'limit=40',
        if (_status != null) 'status=$_status',
        if (!reset && _rows.isNotEmpty) 'before_id=${_rows.last['id']}',
      ].join('&');
      final r = await _api.get('/admin/api/feedback?$qs');
      final got = ((r['entries'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      if (!mounted) return;
      setState(() {
        if (reset) _rows.clear();
        _rows.addAll(got);
        _more = got.length == 40;
        _counts = (r['counts'] as Map?)?.cast<String, dynamic>() ?? const {};
        _avg = r['average_rating'] as num?;
        _error = null;
      });
    } on AdminApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _update(Map<String, dynamic> f,
      {String? status, String? reply}) async {
    try {
      final r = await _api.post('/admin/api/feedback/${f['id']}', {
        'status': ?status,
        'reply': ?reply,
      });
      if (!mounted) return;
      setState(() {
        final i = _rows.indexWhere((x) => x['id'] == f['id']);
        if (i >= 0) _rows[i] = {..._rows[i], ...r};
      });
      widget.onChanged();
      adminToast(context, 'Updated — they\'ll see it in the app');
      _load(reset: true);
    } on AdminApiException catch (e) {
      if (mounted) adminToast(context, e.message, error: true);
    }
  }

  Future<void> _reply(Map<String, dynamic> f) async {
    final ctl = TextEditingController(text: (f['reply'] ?? '').toString());
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reply to this feedback'),
        content: SizedBox(
          width: 460,
          child: TextField(
            controller: ctl,
            autofocus: true,
            minLines: 3,
            maxLines: 6,
            maxLength: 2000,
            decoration: const InputDecoration(
              hintText: 'Thanks! We\'re on it — it\'s coming in the next update.',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, ctl.text),
              icon: const Icon(Icons.send_rounded, size: 18),
              label: const Text('Send reply')),
        ],
      ),
    );
    if (text == null) return;
    await _update(f,
        reply: text,
        status: f['status'] == 'new' ? 'seen' : null);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.adm;
    final newCount = (_counts['new'] as num?)?.toInt() ?? 0;
    final total =
        _counts.values.fold<int>(0, (a, v) => a + ((v as num?)?.toInt() ?? 0));
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          decoration: BoxDecoration(
            color: p.bg,
            border: Border(bottom: BorderSide(color: p.border)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AdminPageTitle(
                icon: Icons.rate_review_rounded,
                title: 'Feedback',
                subtitle: '$total received · $newCount new'
                    '${_avg == null ? '' : ' · average ${_avg!.toStringAsFixed(1)} / 5'}',
                trailing: IconButton.filledTonal(
                  tooltip: 'Refresh',
                  onPressed: _loading ? null : () => _load(reset: true),
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ),
              // At a glance: 3D tiles for what needs you and how it feels.
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _statTile(p, 'New', '$newCount', Icons.fiber_new_rounded,
                        kAdminRed),
                    _statTile(p, 'Planned', '${_counts['planned'] ?? 0}',
                        Icons.construction_rounded, const Color(0xFF2979FF)),
                    _statTile(p, 'Done', '${_counts['done'] ?? 0}',
                        Icons.check_circle_rounded, const Color(0xFF00C853)),
                    _statTile(
                        p,
                        'Feeling',
                        _avg == null
                            ? '—'
                            : '${_faceFor(_avg!.round())} ${_avg!.toStringAsFixed(1)}',
                        Icons.mood_rounded,
                        const Color(0xFFFFB300)),
                  ],
                ),
              ),
              SizedBox(
                height: 46,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final s in _statuses)
                      Padding(
                        padding: const EdgeInsets.only(right: 8, bottom: 8),
                        child: _filterPill(p, s),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(reset: true),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              children: [
                if (_error != null) ...[
                  AdminInline(text: _error!, error: true),
                  const SizedBox(height: 12),
                ],
                if (_rows.isEmpty && !_loading)
                  Padding(
                    padding: const EdgeInsets.all(30),
                    child: Center(
                      child: Text('Nothing here yet.',
                          style: TextStyle(color: p.faint)),
                    ),
                  ),
                for (final f in _rows) ...[
                  _card(p, f),
                  const SizedBox(height: 10),
                ],
                if (_more && _rows.isNotEmpty)
                  Center(
                    child: OutlinedButton(
                      onPressed: _loading ? null : _load,
                      child: const Text('Load older'),
                    ),
                  ),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static String _faceFor(int r) =>
      const ['😞', '😕', '😐', '🙂', '😍'][(r.clamp(1, 5)) - 1];

  /// The raised surface used across this page (soft highlight + grounded
  /// shadow; a gradient + glow when [on]).
  static BoxDecoration _raised(AdminPalette p,
      {bool on = false, Color c = kAdminRed, double r = 16}) {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(r),
      gradient: on
          ? LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(c, Colors.white, 0.16)!,
                Color.lerp(c, Colors.black, 0.16)!,
              ])
          : LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: p.dark
                  ? [p.card2, p.card]
                  : [Colors.white, Color.alphaBlend(c.withValues(alpha: 0.04), p.card)],
            ),
      border: Border.all(
          color: on ? Color.lerp(c, Colors.white, 0.25)! : p.border),
      boxShadow: [
        BoxShadow(
          color: on
              ? c.withValues(alpha: 0.35)
              : Colors.black.withValues(alpha: p.dark ? 0.4 : 0.07),
          blurRadius: on ? 14 : 10,
          offset: Offset(0, on ? 5 : 4),
        ),
      ],
    );
  }

  Widget _statTile(
      AdminPalette p, String label, String value, IconData icon, Color c) {
    return Container(
      width: 150,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: _raised(p),
      child: Row(children: [
        Container(
          width: 34,
          height: 34,
          decoration: _raised(p, on: true, c: c, r: 11),
          child: Icon(icon, size: 18, color: Colors.white),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: p.text,
                      fontSize: 17,
                      fontWeight: FontWeight.w800)),
              Text(label,
                  style: TextStyle(color: p.muted, fontSize: 11.5)),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _filterPill(AdminPalette p, (String?, String, IconData) s) {
    final on = _status == s.$1;
    final c = s.$1 == null ? kAdminRed : _statusColor(s.$1!);
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () {
        setState(() => _status = s.$1);
        _load(reset: true);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: _raised(p, on: on, c: c, r: 20),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(s.$3, size: 15, color: on ? Colors.white : c),
          const SizedBox(width: 6),
          Text(s.$1 == null ? s.$2 : '${s.$2} · ${_counts[s.$1] ?? 0}',
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: on ? Colors.white : p.text)),
        ]),
      ),
    );
  }

  Widget _card(AdminPalette p, Map<String, dynamic> f) {
    final (kc, ki, kl) = _kind(f['kind'] as String?);
    final status = (f['status'] ?? 'new').toString();
    final sc = _statusColor(status);
    final rating = (f['rating'] as num?)?.toInt();
    final reply = (f['reply'] ?? '').toString().trim();
    final who = '${f['username'] ?? f['user_id']}';
    final meta = [
      if (f['area'] != null) '${f['area']}',
      if (f['platform'] != null) '${f['platform']}',
      if (f['app_version'] != null) 'v${f['app_version']}',
      fmtDateTime(f['created_at'] as String?),
    ].join(' · ');
    return Container(
      decoration: _raised(p, r: 20).copyWith(
        border: Border.all(
            color: status == 'new' ? kAdminRed : p.border,
            width: status == 'new' ? 1.3 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Kind-coloured edge.
            Container(
              width: 5,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [kc, Color.lerp(kc, Colors.black, 0.3)!],
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: _raised(p, on: true, c: kc, r: 12),
                          child: Icon(ki, size: 19, color: Colors.white),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Text(kl,
                                    style: TextStyle(
                                        color: p.text,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 14)),
                                if (rating != null) ...[
                                  const SizedBox(width: 8),
                                  Text(_faceFor(rating),
                                      style: const TextStyle(fontSize: 15)),
                                  const SizedBox(width: 3),
                                  Text('$rating/5',
                                      style: TextStyle(
                                          color: p.muted,
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w700)),
                                ],
                              ]),
                              Text('@$who',
                                  style: TextStyle(
                                      color: p.muted, fontSize: 12)),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: _raised(p, on: true, c: sc, r: 20),
                          child: Text(
                              (f['status_label'] ?? status).toString(),
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w800)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // The message in a quiet inset well.
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: p.dark
                            ? Colors.black.withValues(alpha: 0.25)
                            : p.card2,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: p.border),
                      ),
                      child: SelectableText((f['message'] ?? '').toString(),
                          style: TextStyle(
                              color: p.text, fontSize: 14, height: 1.45)),
                    ),
                    const SizedBox(height: 8),
                    Text(meta,
                        style: TextStyle(color: p.faint, fontSize: 11.5)),
                    if (reply.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: kAdminRed.withValues(
                              alpha: p.dark ? 0.12 : 0.06),
                          borderRadius: BorderRadius.circular(10),
                          border: const Border(
                              left: BorderSide(color: kAdminRed, width: 3)),
                        ),
                        child: Text('Your reply: $reply',
                            style: TextStyle(color: p.text, fontSize: 13)),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _action(p, reply.isEmpty ? 'Reply' : 'Edit reply',
                            Icons.reply_rounded, kAdminRed,
                            primary: true, onTap: () => _reply(f)),
                        for (final s in const [
                          ('seen', 'Seen', Icons.visibility_rounded),
                          ('planned', 'Planned', Icons.construction_rounded),
                          ('done', 'Done', Icons.check_circle_rounded),
                          ('wontfix', 'Not planned',
                              Icons.do_not_disturb_on_rounded),
                        ])
                          if (s.$1 != status)
                            _action(p, s.$2, s.$3, _statusColor(s.$1),
                                onTap: () => _update(f, status: s.$1)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _action(AdminPalette p, String label, IconData icon, Color c,
      {bool primary = false, required VoidCallback onTap}) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: _raised(p, on: primary, c: c, r: 14),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: primary ? Colors.white : c),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: primary ? Colors.white : p.text)),
        ]),
      ),
    );
  }
}
