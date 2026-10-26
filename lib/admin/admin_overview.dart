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
    ]);
    if (!mounted) return;
    setState(() {
      _overview = r[0] ?? _overview;
      _signups = r[1] ?? _signups;
      _devices = r[2] ?? _devices;
      _storage = r[3] ?? _storage;
      _activity = r[4] ?? _activity;
      _online = r[5] ?? _online;
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
    final o = _overview;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Overview',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              ),
              if (_loadedAt != null)
                Text('Updated ${fmtAgo(_loadedAt!.toUtc().toIso8601String())}',
                    style: const TextStyle(color: Colors.white38, fontSize: 12)),
              IconButton(
                onPressed: _loading ? null : _load,
                icon: _loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh),
              ),
            ],
          ),
          if (_error != null) ...[
            AdminInline(text: _error!, error: true),
            const SizedBox(height: 12),
          ],
          if (o == null && _loading)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (o != null) ..._usersBlock(o),
          if (_signups != null) ...[
            const SizedBox(height: 14),
            _signupsBlock(),
          ],
          if (_devices != null) ...[
            const SizedBox(height: 14),
            _devicesBlock(),
          ],
          if (_activity != null) ...[
            const SizedBox(height: 14),
            _activityBlock(),
          ],
          if (_storage != null) ...[
            const SizedBox(height: 14),
            _storageBlock(),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  List<Widget> _usersBlock(Map<String, dynamic> o) {
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
      return '${m['returned']} of ${m['cohort']}';
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
            icon: Icons.people_alt_outlined),
        AdminStat(
            label: 'Online now',
            value: n('online_now'),
            icon: Icons.circle,
            accent: const Color(0xFF66BB6A),
            hint: 'Tap below to see who'),
        AdminStat(
            label: 'New today',
            value: n('new_today'),
            icon: Icons.person_add_alt,
            hint: '${n('new_7d')} this week · ${n('new_30d')} in 30 d'),
        AdminStat(
            label: 'Active 24 h',
            value: n('active_24h'),
            icon: Icons.bolt,
            hint: '${n('active_7d')} in 7 d · ${n('active_30d')} in 30 d'),
        AdminStat(
            label: 'Came back after 1 day',
            value: r('d1'),
            icon: Icons.replay,
            hint: rh('d1')),
        AdminStat(
            label: 'After 7 days',
            value: r('d7'),
            icon: Icons.replay,
            hint: rh('d7')),
        AdminStat(
            label: 'After 30 days',
            value: r('d30'),
            icon: Icons.replay,
            hint: rh('d30')),
        AdminStat(
            label: 'Listening together now',
            value: o['listen_together_now'] == null
                ? '—'
                : n('listen_together_now'),
            icon: Icons.headphones),
      ]),
      const SizedBox(height: 10),
      Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.circle, color: Color(0xFF66BB6A), size: 14),
              title: Text('Who’s online (${online.length})'),
              trailing: Icon(_showOnline ? Icons.expand_less : Icons.expand_more),
              onTap: () => setState(() => _showOnline = !_showOnline),
            ),
            if (_showOnline)
              for (final u in online)
                ListTile(
                  dense: true,
                  title: Text('@${u['username']}'),
                  subtitle: Text(_platformLabel(u['platform'] as String?)),
                ),
            if (_showOnline && online.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Text('Nobody is connected right now.',
                    style: TextStyle(color: Colors.white54)),
              ),
          ],
        ),
      ),
      if ((o['note'] ?? '').toString().isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(o['note'].toString(),
            style: const TextStyle(color: Colors.white38, fontSize: 11)),
      ],
    ];
  }

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
      child: AdminDailyBars(days: d),
    );
  }

  Widget _devicesBlock() {
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
        .where((p) => p['platform'] == 'web-ios' || p['platform'] == 'ios')
        .fold<int>(0, (a, p) => a + ((p['users'] as num?)?.toInt() ?? 0));
    final reporting = (m['users_reporting'] as num?)?.toInt() ?? 0;
    return AdminSection(
      title: 'Devices',
      subtitle: '${fmtInt(reporting)} people active in the last '
          '${m['window_days']} days reported their device',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AdminShareBars(rows: [
            for (final p in plats)
              (
                (p['label'] ?? p['platform']).toString(),
                (p['users'] as num?) ?? 0,
                fmtInt(p['users'] as num?)
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
            const Text('App versions in use',
                style: TextStyle(fontWeight: FontWeight.w600)),
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
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
          ],
        ],
      ),
    );
  }

  Widget _activityBlock() {
    final msgs = _days(_activity, 'messages');
    final hearts = _days(_activity, 'hearts');
    final voice = _days(_activity, 'voice_notes');
    return AdminSection(
      title: 'Activity',
      subtitle: '${fmtInt(_sum(msgs))} messages · ${fmtInt(_sum(hearts))} '
          'hearts · ${fmtInt(_sum(voice))} voice notes in ${msgs.length} days',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Messages per day',
              style: TextStyle(color: Colors.white60, fontSize: 12)),
          const SizedBox(height: 6),
          AdminDailyBars(days: msgs, color: const Color(0xFF42A5F5)),
          const SizedBox(height: 14),
          const Text('Hearts per day',
              style: TextStyle(color: Colors.white60, fontSize: 12)),
          const SizedBox(height: 6),
          AdminDailyBars(days: hearts, height: 70),
        ],
      ),
    );
  }

  Widget _storageBlock() {
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
            const Text('Biggest uploaders (media still on server)',
                style: TextStyle(fontWeight: FontWeight.w600)),
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
            const Text('Largest tables',
                style: TextStyle(fontWeight: FontWeight.w600)),
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
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
