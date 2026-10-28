import 'dart:async';

import 'package:flutter/material.dart';

import 'admin_api.dart';
import 'admin_widgets.dart';

/// Phase 1 — read-only metrics: users, online now, activity, device split,
/// storage. Refreshes every minute while you're actually using the page.
class AdminOverview extends StatefulWidget {
  const AdminOverview({super.key, required this.onOpenDevices});
  final VoidCallback onOpenDevices;

  @override
  State<AdminOverview> createState() => _AdminOverviewState();
}

class _AdminOverviewState extends State<AdminOverview> {
  final _api = AdminApi.instance;
  Map<String, dynamic>? _overview;
  Map<String, dynamic>? _signups;
  Map<String, dynamic>? _devices;
  Map<String, dynamic>? _storage;
  Map<String, dynamic>? _activity;
  Map<String, dynamic>? _online;
  Map<String, dynamic>? _relay;
  String? _error;
  bool _loading = false;
  DateTime? _loadedAt;
  int _signupDays = 30;
  bool _showOnline = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!_api.userIdle) _load(quiet: true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<Map<String, dynamic>?> _try(String path) async {
    try {
      return await _api.get(path);
    } on AdminApiException catch (e) {
      _error ??= e.message;
      return null;
    }
  }

  Future<void> _load({bool quiet = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      if (!quiet) _error = null;
    });
    _error = null;
    final r = await Future.wait([
      _try('/admin/api/metrics/overview'),
      _try('/admin/api/metrics/signups?days=$_signupDays'),
      _try('/admin/api/metrics/devices'),
      _try('/admin/api/metrics/storage'),
      _try('/admin/api/metrics/activity'),
      _try('/admin/api/metrics/online'),
      _try('/admin/api/metrics/relay'),
    ]);
    if (!mounted) return;
    setState(() {
      _overview = r[0] ?? _overview;
      _signups = r[1] ?? _signups;
      _devices = r[2] ?? _devices;
      _storage = r[3] ?? _storage;
      _activity = r[4] ?? _activity;
      _online = r[5] ?? _online;
      _relay = r[6] ?? _relay;
      _loading = false;
      _loadedAt = DateTime.now();
    });
  }

  List<Map<String, dynamic>> _days(Map<String, dynamic>? m, String key) =>
      ((m?[key] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();

  int _sum(List<Map<String, dynamic>> d) =>
      d.fold<int>(0, (a, e) => a + ((e['count'] as num?)?.toInt() ?? 0));

  @override
  Widget build(BuildContext context) {
    final p = context.adm;
    final o = _overview;
    return Column(
      children: [
        // Sticky page header — stays put while the content scrolls.
        Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          decoration: BoxDecoration(
            color: context.adm.bg,
            border: Border(bottom: BorderSide(color: context.adm.border)),
          ),
          child: AdminPageTitle(
            icon: Icons.space_dashboard_rounded,
            title: 'Overview',
            subtitle: _loadedAt == null
                ? 'How Aluta is doing'
                : 'Updated ${fmtAgo(_loadedAt!.toUtc().toIso8601String())}',
            trailing: IconButton.filledTonal(
              tooltip: 'Refresh',
              onPressed: _loading ? null : _load,
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh_rounded),
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              children: [
          if (_error != null) ...[
            AdminInline(text: _error!, error: true),
            const SizedBox(height: 12),
          ],
          if (o == null && _loading)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (o != null) ..._usersBlock(o, p),
          if (_signups != null) ...[
            const SizedBox(height: 14),
            _signupsBlock(),
          ],
          if (_devices != null) ...[
            const SizedBox(height: 14),
            _devicesBlock(p),
          ],
          if (_activity != null) ...[
            const SizedBox(height: 14),
            _activityBlock(p),
          ],
          if (_storage != null) ...[
            const SizedBox(height: 14),
            _storageBlock(p),
          ],
          if (_relay != null) ...[
            const SizedBox(height: 14),
            _relayBlock(p),
          ],
          const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _usersBlock(Map<String, dynamic> o, AdminPalette p) {
    String n(String k) => fmtInt(o[k] as num?);
    final ret = (o['retention'] as Map?)?.cast<String, dynamic>() ?? const {};
    String r(String k) {
      final m = (ret[k] as Map?)?.cast<String, dynamic>();
      final pct = m?['pct'];
      if (pct == null) return '—';
      return '$pct%';
    }

    String rh(String k) {
      final m = (ret[k] as Map?)?.cast<String, dynamic>();
      if (m == null) return '';
      return '${m['returned']} of ${m['cohort']} people';
    }

    final online = ((_online?['online'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    return [
      AdminStatGrid(children: [
        AdminStat(
            label: 'Registered users',
            value: n('users_total'),
            icon: Icons.groups_rounded,
            accent: const Color(0xFF7C4DFF)),
        AdminStat(
            label: 'Online now',
            value: n('online_now'),
            icon: Icons.wifi_tethering_rounded,
            accent: const Color(0xFF00C853),
            hint: 'Tap to see who',
            onTap: () => setState(() => _showOnline = !_showOnline)),
        AdminStat(
            label: 'New today',
            value: n('new_today'),
            icon: Icons.person_add_alt_1_rounded,
            accent: const Color(0xFF2979FF),
            hint: '${n('new_7d')} this week · ${n('new_30d')} in 30 d'),
        AdminStat(
            label: 'Active in 24 h',
            value: n('active_24h'),
            icon: Icons.bolt_rounded,
            accent: const Color(0xFFFF9100),
            hint: '${n('active_7d')} in 7 d · ${n('active_30d')} in 30 d'),
        AdminStat(
            label: 'Came back after 1 day',
            value: r('d1'),
            icon: Icons.replay_rounded,
            accent: const Color(0xFF00BFA5),
            hint: rh('d1')),
        AdminStat(
            label: 'Came back after 7 days',
            value: r('d7'),
            icon: Icons.event_repeat_rounded,
            accent: const Color(0xFF00ACC1),
            hint: rh('d7')),
        AdminStat(
            label: 'Came back after 30 days',
            value: r('d30'),
            icon: Icons.favorite_rounded,
            accent: const Color(0xFFE91E63),
            hint: rh('d30')),
        AdminStat(
            label: 'Listening together now',
            value: o['listen_together_now'] == null
                ? '—'
                : n('listen_together_now'),
            icon: Icons.headphones_rounded,
            accent: kAdminRed),
      ]),
      const SizedBox(height: 12),
      Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            ListTile(
              leading: const AdminIconChip(
                  icon: Icons.wifi_tethering_rounded,
                  color: Color(0xFF00C853),
                  size: 30),
              title: Text('Who’s online (${online.length})',
                  style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
              trailing: Icon(
                  _showOnline
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: p.muted),
              onTap: () => setState(() => _showOnline = !_showOnline),
            ),
            if (_showOnline)
              for (final u in online)
                ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 15,
                    backgroundColor: kAdminRed.withValues(alpha: 0.15),
                    child: Text(
                      '${u['username'] ?? '?'}'.isNotEmpty
                          ? '${u['username']}'[0].toUpperCase()
                          : '?',
                      style: const TextStyle(
                          color: kAdminRed,
                          fontWeight: FontWeight.w700,
                          fontSize: 13),
                    ),
                  ),
                  title: Text('@${u['username']}',
                      style: TextStyle(color: p.text)),
                  subtitle: Text(_platformLabel(u['platform'] as String?),
                      style: TextStyle(color: p.muted)),
                  trailing: Icon(_platformIcon(u['platform'] as String?),
                      size: 18, color: p.muted),
                ),
            if (_showOnline && online.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Text('Nobody is connected right now.',
                    style: TextStyle(color: p.muted)),
              ),
          ],
        ),
      ),
      if ((o['note'] ?? '').toString().isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(o['note'].toString(),
            style: TextStyle(color: p.faint, fontSize: 11)),
      ],
    ];
  }

  IconData _platformIcon(String? p) => switch (p) {
        'android' || 'web-android' => Icons.android_rounded,
        'ios' || 'web-ios' => Icons.phone_iphone_rounded,
        'windows' || 'web-desktop' || 'macos' || 'linux' =>
          Icons.computer_rounded,
        _ => Icons.devices_other_rounded,
      };

  static const _labels = {
    'android': 'Android app',
    'windows': 'Windows app',
    'ios': 'iPhone app',
    'macos': 'Mac app',
    'linux': 'Linux app',
    'web-ios': 'Web · iPhone/iPad',
    'web-android': 'Web · Android',
    'web-desktop': 'Web · computer',
  };

  String _platformLabel(String? p) =>
      p == null ? 'device not reported yet' : (_labels[p] ?? p);

  Widget _signupsBlock() {
    final d = _days(_signups, 'days');
    return AdminSection(
      title: 'Sign-ups',
      icon: Icons.person_add_alt_1_rounded,
      color: const Color(0xFF2979FF),
      subtitle: '${fmtInt(_sum(d))} in the last $_signupDays days',
      trailing: Wrap(
        spacing: 6,
        children: [
          for (final n in const [7, 30, 90])
            ChoiceChip(
              label: Text('${n}d'),
              selected: _signupDays == n,
              onSelected: (_) {
                setState(() => _signupDays = n);
                _load(quiet: true);
              },
            ),
        ],
      ),
      child: AdminDailyBars(days: d, color: const Color(0xFF2979FF)),
    );
  }

  Widget _devicesBlock(AdminPalette p) {
    final m = _devices!;
    final plats = ((m['platforms'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    final vers = ((m['versions'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    final iphone = plats
        .where((x) => x['platform'] == 'web-ios' || x['platform'] == 'ios')
        .fold<int>(0, (a, x) => a + ((x['users'] as num?)?.toInt() ?? 0));
    final reporting = (m['users_reporting'] as num?)?.toInt() ?? 0;
    return AdminSection(
      title: 'Devices',
      icon: Icons.devices_rounded,
      color: const Color(0xFF7C4DFF),
      subtitle: '${fmtInt(reporting)} people active in the last '
          '${m['window_days']} days reported their device',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AdminShareBars(color: const Color(0xFF7C4DFF), rows: [
            for (final pl in plats)
              (
                (pl['label'] ?? pl['platform']).toString(),
                (pl['users'] as num?) ?? 0,
                fmtInt(pl['users'] as num?)
              ),
          ]),
          const SizedBox(height: 10),
          AdminInline(
            text: reporting == 0
                ? 'iPhone signal: no data yet.'
                : 'iPhone signal: $iphone of $reporting people '
                    '(${(100 * iphone / reporting).round()}%) use Aluta from '
                    'an iPhone or iPad — the number that decides when a native '
                    'iOS app is worth it.',
          ),
          if (vers.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('App versions in use',
                style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            AdminShareBars(
              color: const Color(0xFF5C6BC0),
              rows: [
                for (final v in vers)
                  (
                    v['version'].toString(),
                    (v['users'] as num?) ?? 0,
                    fmtInt(v['users'] as num?)
                  ),
              ],
            ),
          ],
          if ((m['note'] ?? '').toString().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(m['note'].toString(),
                style: TextStyle(color: p.faint, fontSize: 11)),
          ],
        ],
      ),
    );
  }

  Widget _activityBlock(AdminPalette p) {
    final msgs = _days(_activity, 'messages');
    final hearts = _days(_activity, 'hearts');
    final voice = _days(_activity, 'voice_notes');
    return AdminSection(
      title: 'Activity',
      icon: Icons.forum_rounded,
      color: const Color(0xFF00B0FF),
      subtitle: '${fmtInt(_sum(msgs))} messages · ${fmtInt(_sum(hearts))} '
          'hearts · ${fmtInt(_sum(voice))} voice notes in ${msgs.length} days',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Messages per day',
              style: TextStyle(color: p.muted, fontSize: 12)),
          const SizedBox(height: 6),
          AdminDailyBars(days: msgs, color: const Color(0xFF00B0FF)),
          const SizedBox(height: 14),
          Text('Hearts per day',
              style: TextStyle(color: p.muted, fontSize: 12)),
          const SizedBox(height: 6),
          AdminDailyBars(
              days: hearts, height: 70, color: const Color(0xFFE91E63)),
        ],
      ),
    );
  }

  /// The call relay (turn.ozilane.com): pushed by the relay box every minute.
  Widget _relayBlock(AdminPalette p) {
    final relays = ((_relay?['relays'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    const color = Color(0xFF2979FF);
    if (relays.isEmpty) {
      return AdminSection(
        title: 'Call relay',
        icon: Icons.settings_input_antenna_rounded,
        color: color,
        subtitle: 'turn.ozilane.com',
        child: Text(
          _relay?['configured'] == true
              ? 'No report from the relay yet. On the relay run: '
                  'bash /root/ozilane-turn/add-reporter.sh'
              : 'TURN_SHARED_SECRET is not set on the API.',
          style: TextStyle(color: p.muted, fontSize: 13),
        ),
      );
    }
    final r = relays.first;
    final d = (r['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final online = r['online'] == true && d['active'] == true;
    final t = (d['traffic'] as Map?)?.cast<String, dynamic>() ?? const {};
    num both(String k) {
      final m = (t[k] as Map?)?.cast<String, dynamic>();
      return ((m?['rx'] as num?) ?? 0) + ((m?['tx'] as num?) ?? 0);
    }

    final certDays = (d['cert_days'] as num?)?.toInt();
    final errs = (d['errors_1h'] as num?)?.toInt() ?? 0;
    final recent = ((d['recent_errors'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
    final memTotal = (d['mem_total'] as num?) ?? 0;
    final memAvail = (d['mem_avail'] as num?) ?? 0;
    final memPct =
        memTotal > 0 ? ((1 - memAvail / memTotal) * 100).round() : null;
    final diskTotal = (d['disk_total'] as num?) ?? 0;
    final diskFree = (d['disk_free'] as num?) ?? 0;
    final diskPct =
        diskTotal > 0 ? ((1 - diskFree / diskTotal) * 100).round() : null;
    return AdminSection(
      title: 'Call relay',
      icon: Icons.settings_input_antenna_rounded,
      color: color,
      subtitle: '${d['host'] ?? 'turn.ozilane.com'} · '
          '${online ? 'online' : 'NOT REPORTING'} · '
          'last report ${fmtAgo(r['reported_at'] as String?)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AdminStatGrid(children: [
            AdminStat(
              label: 'Status',
              value: online ? 'Online' : 'Offline',
              icon: online
                  ? Icons.check_circle_rounded
                  : Icons.error_rounded,
              accent: online
                  ? const Color(0xFF00C853)
                  : const Color(0xFFE53935),
              hint: online ? 'coturn running' : 'No report in 3 min',
            ),
            AdminStat(
              label: 'Live relays',
              value: fmtInt(d['relays'] as num?),
              icon: Icons.call_rounded,
              accent: color,
              hint: 'Calls / sessions going through it now',
            ),
            AdminStat(
              label: 'Traffic today',
              value: fmtBytes(both('today')),
              icon: Icons.swap_vert_rounded,
              accent: const Color(0xFF7C4DFF),
            ),
            AdminStat(
              label: 'This month',
              value: fmtBytes(both('month')),
              icon: Icons.calendar_month_rounded,
              accent: const Color(0xFFAB47BC),
              hint: 'Vultr plan includes plenty — watch this',
            ),
            AdminStat(
              label: 'Certificate',
              value: certDays == null ? '—' : '$certDays days',
              icon: Icons.lock_rounded,
              accent: (certDays ?? 99) < 14
                  ? const Color(0xFFE53935)
                  : const Color(0xFF00BFA5),
              hint: 'Renews itself',
            ),
            AdminStat(
              label: 'Errors (1 h)',
              value: fmtInt(errs),
              icon: Icons.report_rounded,
              accent: errs > 0
                  ? const Color(0xFFFF6D00)
                  : const Color(0xFF78909C),
              hint: '${fmtInt(d['denied_private_1h'] as num?)} private '
                  'addresses refused (normal)',
            ),
          ]),
          const SizedBox(height: 8),
          Text(
            'Load ${d['load1'] ?? '—'}'
            '${memPct == null ? '' : ' · memory $memPct%'}'
            '${diskPct == null ? '' : ' · disk $diskPct%'}',
            style: TextStyle(color: p.faint, fontSize: 11),
          ),
          if (recent.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Recent errors',
                style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            for (final e in recent)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(e,
                    style: TextStyle(
                        color: p.muted,
                        fontSize: 11,
                        fontFamily: 'monospace')),
              ),
          ],
        ],
      ),
    );
  }

  Widget _storageBlock(AdminPalette p) {
    final s = _storage!;
    final kinds = ((s['media_by_kind'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    final top = ((s['top_uploaders'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    final tables = ((s['largest_tables'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    return AdminSection(
      title: 'Storage',
      icon: Icons.cloud_rounded,
      color: const Color(0xFF00BFA5),
      subtitle: 'Media still on the server: '
          '${fmtBytes(s['media_live_bytes'] as num?)} in '
          '${fmtInt(s['media_live_files'] as num?)} files'
          '${s['database_bytes'] == null ? '' : ' · database ${fmtBytes(s['database_bytes'] as num?)}'}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AdminShareBars(
            color: const Color(0xFF26A69A),
            rows: [
              for (final k in kinds)
                (
                  k['kind'].toString(),
                  (k['bytes'] as num?) ?? 0,
                  fmtBytes(k['bytes'] as num?)
                ),
            ],
          ),
          if (top.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('Biggest uploaders (media still on server)',
                style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            AdminShareBars(
              color: const Color(0xFFAB47BC),
              rows: [
                for (final u in top)
                  (
                    '@${u['username'] ?? u['user_id']}',
                    (u['bytes'] as num?) ?? 0,
                    fmtBytes(u['bytes'] as num?)
                  ),
              ],
            ),
          ],
          if (tables.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('Largest tables',
                style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            AdminShareBars(
              color: const Color(0xFF78909C),
              rows: [
                for (final t in tables)
                  (
                    t['table'].toString(),
                    (t['bytes'] as num?) ?? 0,
                    fmtBytes(t['bytes'] as num?)
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Text(
            '${fmtInt(s['media_purged_rows'] as num?)} older files already left '
            'the server (kept on people’s devices).',
            style: TextStyle(color: p.faint, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
