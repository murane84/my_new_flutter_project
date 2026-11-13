import 'package:flutter/material.dart';

import 'admin_api.dart';
import 'admin_widgets.dart';
import '../utils/radii.dart';

/// System → "Server health" + "Clean-up tools" (Admin Phase 3).
///
/// Each tool previews first (what it would free) and only runs after you
/// confirm with your password from a full-access device. Nothing here
/// touches a live shared memory — see the server side (admin_panel.py).
class AdminToolsSection extends StatefulWidget {
  const AdminToolsSection({super.key});

  @override
  State<AdminToolsSection> createState() => _AdminToolsSectionState();
}

class _Tool {
  const _Tool(this.path, this.icon, this.color, this.title, this.blurb,
      this.runLabel, this.audit);
  final String path;
  final IconData icon;
  final Color color;
  final String title;
  final String blurb;
  final String runLabel;
  final String audit;
}

const _tools = [
  _Tool(
      'sweep-expired',
      Icons.cleaning_services_rounded,
      Color(0xFF00897B),
      'Sweep expired files now',
      'Chat files past their 24 h on the server (Our Playlist songs: 7 days). '
          'The same rule the hourly sweep uses — Our Space keepsakes are never '
          'touched.',
      'Sweep now',
      'files cleared'),
  _Tool(
      'orphans',
      Icons.link_off_rounded,
      Color(0xFF7C4DFF),
      'Orphaned files',
      'Stored files nothing points to any more (no message, moment, story, '
          'photo or setting mentions them), older than 2 days. Only the bytes '
          'go — nothing anyone can still open.',
      'Free them',
      'files freed'),
  _Tool(
      'vacuum',
      Icons.compress_rounded,
      Color(0xFF2979FF),
      'Tidy the database',
      'Lets Postgres reuse the space freed by the clean-ups (VACUUM ANALYZE of '
          'the biggest tables). Safe while Aluta runs.',
      'Tidy now',
      'tables tidied'),
];

class _AdminToolsSectionState extends State<AdminToolsSection> {
  final _api = AdminApi.instance;
  Map<String, dynamic>? _health;
  final Map<String, Map<String, dynamic>> _preview = {};
  final Set<String> _busy = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadHealth();
  }

  Future<void> _loadHealth() async {
    try {
      final h = await _api.get('/admin/api/tools/health');
      if (mounted) setState(() => _health = h);
    } on AdminApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _run(_Tool t, {required bool dry}) async {
    String? pw;
    if (!dry) {
      pw = await askPassword(context,
          title: '${t.title}?',
          message: _previewText(t) ?? 'Runs it now.',
          action: t.runLabel);
      if (pw == null) return;
    }
    setState(() => _busy.add(t.path));
    try {
      final r = await _api.post('/admin/api/tools/${t.path}',
          {'dry_run': dry, 'password': ?pw});
      if (!mounted) return;
      if (dry) {
        setState(() => _preview[t.path] = r);
      } else {
        final n = t.path == 'vacuum'
            ? ((r['vacuumed'] as List?)?.length ?? 0)
            : (r['files'] as num?)?.toInt() ?? 0;
        adminToast(context, 'Done — $n ${t.audit}');
        _preview.remove(t.path);
        await _loadHealth();
      }
    } on AdminApiException catch (e) {
      if (mounted) adminToast(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(t.path));
    }
  }

  String? _previewText(_Tool t) {
    final r = _preview[t.path];
    if (r == null) return null;
    if (t.path == 'vacuum') {
      if (r['supported'] == false) return 'Only on the live (Postgres) server.';
      final tables = ((r['tables'] as List?) ?? const [])
          .whereType<Map>()
          .toList();
      final dead = tables.fold<int>(
          0, (a, e) => a + ((e['dead_rows'] as num?)?.toInt() ?? 0));
      return '${tables.length} tables · ${fmtInt(dead)} rows of freed space '
          'to reuse';
    }
    final n = (r['files'] as num?)?.toInt() ?? 0;
    if (n == 0) return 'Nothing to clean right now.';
    return 'Would free ${fmtInt(n)} file${n == 1 ? '' : 's'} · '
        '${fmtBytes(r['bytes'] as num?)}';
  }

  String _uptime(num? s) {
    final v = (s ?? 0).toInt();
    final d = v ~/ 86400, h = (v % 86400) ~/ 3600, m = (v % 3600) ~/ 60;
    return d > 0 ? '${d}d ${h}h' : h > 0 ? '${h}h ${m}m' : '${m}m';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.adm;
    final h = _health;
    final server = (h?['server'] as Map?)?.cast<String, dynamic>() ?? const {};
    final media = (h?['media'] as Map?)?.cast<String, dynamic>() ?? const {};
    final errors = (h?['errors'] as Map?)?.cast<String, dynamic>() ?? const {};
    final apps = (h?['apps'] as Map?)?.cast<String, dynamic>() ?? const {};
    final expired = (h?['expired_now'] as Map?)?.cast<String, dynamic>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdminSection(
          icon: Icons.monitor_heart_rounded,
          color: const Color(0xFF00C853),
          title: 'Server health',
          subtitle: _error ??
              (server['commit'] == null
                  ? 'Running'
                  : 'Running ${server['commit']}'
                      '${server['commit_message'] == null ? '' : ' · ${server['commit_message']}'}'),
          trailing: IconButton(
            tooltip: 'Refresh',
            onPressed: _loadHealth,
            icon: const Icon(Icons.refresh_rounded),
          ),
          child: h == null
              ? const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CircularProgressIndicator()))
              : AdminStatGrid(children: [
                  AdminStat(
                      label: 'Up since the last deploy',
                      value: _uptime(server['uptime_s'] as num?),
                      hint: fmtDateTime(server['started_at'] as String?),
                      icon: Icons.timer_rounded,
                      accent: const Color(0xFF00C853)),
                  AdminStat(
                      label: 'Open app connections',
                      value: fmtInt(h['live_connections'] as num?),
                      icon: Icons.cable_rounded,
                      accent: const Color(0xFF2979FF)),
                  AdminStat(
                      label: 'Files on the server',
                      value: fmtBytes(media['bytes'] as num?),
                      hint: '${fmtInt(media['files'] as num?)} files',
                      icon: Icons.perm_media_rounded,
                      accent: const Color(0xFF7C4DFF)),
                  AdminStat(
                      label: 'Database',
                      value: h['database_bytes'] == null
                          ? '—'
                          : fmtBytes(h['database_bytes'] as num?),
                      icon: Icons.storage_rounded,
                      accent: const Color(0xFFFF9100)),
                  AdminStat(
                      label: 'Expired, waiting for the sweep',
                      value: expired == null
                          ? '—'
                          : fmtBytes(expired['bytes'] as num?),
                      hint: expired == null
                          ? null
                          : '${fmtInt(expired['files'] as num?)} files',
                      icon: Icons.hourglass_bottom_rounded,
                      accent: const Color(0xFF00897B)),
                  AdminStat(
                      label: 'Error reports',
                      value: errors['sentry'] == true ? 'Sentry on' : 'Off',
                      hint: errors['link'] == null
                          ? 'Set SENTRY_ISSUES_URL for a link'
                          : errors['link'].toString(),
                      icon: Icons.bug_report_rounded,
                      accent: kAdminRed),
                  AdminStat(
                      label: 'Published apps',
                      value: apps.isEmpty
                          ? '—'
                          : (apps['android'] as Map?)?['version']?.toString() ??
                              '—',
                      hint: apps.entries
                          .map((e) =>
                              '${e.key} ${(e.value as Map?)?['version'] ?? ''}')
                          .join(' · '),
                      icon: Icons.system_update_rounded,
                      accent: const Color(0xFF00897B)),
                ]),
        ),
        const SizedBox(height: 14),
        AdminSection(
          icon: Icons.build_circle_rounded,
          title: 'Clean-up tools',
          subtitle: 'Preview first · running asks for your password · logged',
          child: Column(children: [
            for (final t in _tools) _toolTile(p, t),
          ]),
        ),
      ],
    );
  }

  Widget _toolTile(AdminPalette p, _Tool t) {
    final busy = _busy.contains(t.path);
    final preview = _previewText(t);
    final r = _preview[t.path];
    final canRun = r != null &&
        (t.path == 'vacuum'
            ? r['supported'] != false
            : ((r['files'] as num?)?.toInt() ?? 0) > 0);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.color.withValues(alpha: p.dark ? 0.10 : 0.06),
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: t.color.withValues(alpha: 0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            AdminIconChip(icon: t.icon, color: t.color, size: 30),
            const SizedBox(width: 10),
            Expanded(
              child: Text(t.title,
                  style: TextStyle(
                      color: p.text,
                      fontWeight: FontWeight.w700,
                      fontSize: 14.5)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(t.blurb, style: TextStyle(color: p.muted, fontSize: 12.5)),
          if (preview != null) ...[
            const SizedBox(height: 8),
            Text(preview,
                style: TextStyle(
                    color: p.text,
                    fontWeight: FontWeight.w600,
                    fontSize: 13)),
          ],
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              onPressed: busy ? null : () => _run(t, dry: true),
              icon: busy && r == null
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.visibility_rounded, size: 18),
              label: Text(r == null ? 'Preview' : 'Check again'),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: t.color),
              onPressed: busy || !canRun ? null : () => _run(t, dry: false),
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: Text(t.runLabel),
            ),
          ]),
        ],
      ),
    );
  }
}
