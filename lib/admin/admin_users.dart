import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'admin_api.dart';
import 'admin_widgets.dart';
import '../utils/radii.dart';

/// People (Admin Phase 2): find someone, see their card (profile, devices,
/// last seen, storage, plan) and — from a full (non-probation) device, with
/// your password — reset their sign-in, pause / un-pause the account, or
/// delete it (typed username → 7 days frozen and restorable → gone).
class AdminUsersPage extends StatefulWidget {
  const AdminUsersPage({super.key});

  @override
  State<AdminUsersPage> createState() => _AdminUsersPageState();
}

class _AdminUsersPageState extends State<AdminUsersPage> {
  final _api = AdminApi.instance;
  final _q = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>> _rows = const [];
  Map<String, dynamic>? _open; // the person whose card is shown
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await _api.get(
          '/admin/api/users?q=${Uri.encodeQueryComponent(_q.text.trim())}');
      if (!mounted) return;
      setState(() => _rows = ((r['users'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList());
    } on AdminApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openUser(int id) async {
    try {
      final r = await _api.get('/admin/api/users/$id');
      if (mounted) setState(() => _open = r);
    } on AdminApiException catch (e) {
      if (mounted) adminToast(context, e.message, error: true);
    }
  }

  Future<void> _act(String what, Map<String, dynamic> body,
      {required String done}) async {
    final id = _open?['id'];
    if (id == null) return;
    try {
      final r = await _api.post('/admin/api/users/$id/$what', body);
      if (!mounted) return;
      if (what == 'reset-signin') {
        await _showTempPassword((r['username'] ?? '').toString(),
            (r['temp_password'] ?? '').toString());
      } else {
        adminToast(context, done);
      }
      await _openUser(id as int);
      await _search();
    } on AdminApiException catch (e) {
      if (mounted) adminToast(context, e.message, error: true);
    }
  }

  // ── actions ────────────────────────────────────────────────────────────────
  Future<void> _reset() async {
    final name = _open?['username'];
    final pw = await askPassword(context,
        title: 'Reset $name’s sign-in?',
        message: 'Signs them out on every device and gives them a one-time '
            'password (shown once). The app asks them to choose their own '
            'right after signing in. Nothing is deleted.',
        action: 'Reset sign-in');
    if (pw == null) return;
    await _act('reset-signin', {'password': pw}, done: 'Signed out');
  }

  Future<void> _showTempPassword(String user, String temp) => showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('One-time password'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Give this to $user over a trusted channel (a call, in '
                  'person). It is shown only now.',
                  style: TextStyle(color: ctx.adm.muted)),
              const SizedBox(height: 14),
              SelectableText(temp,
                  style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2,
                      fontFamily: 'monospace')),
            ],
          ),
          actions: [
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: temp));
                adminToast(ctx, 'Copied');
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy'),
            ),
            FilledButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
          ],
        ),
      );

  Future<void> _pause() async {
    final name = _open?['username'];
    final reason = TextEditingController();
    final pw = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Pause $name’s account?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('They can’t sign in and every device is cut off until you '
                'un-pause. Nothing is deleted.',
                style: TextStyle(color: ctx.adm.muted)),
            const SizedBox(height: 12),
            TextField(
              controller: reason,
              decoration: InputDecoration(
                labelText: 'Why (kept in the activity log)',
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Radii.md)),
              ),
            ),
            const SizedBox(height: 10),
            AdminPasswordField(controller: pw),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Pause account')),
        ],
      ),
    );
    if (ok != true) return;
    await _act('pause', {'password': pw.text, 'reason': reason.text},
        done: 'Account paused');
  }

  Future<void> _unpause() async {
    final pw = await askPassword(context,
        title: 'Un-pause ${_open?['username']}?',
        message: 'They can sign in again.',
        action: 'Un-pause');
    if (pw == null) return;
    await _act('unpause', {'password': pw}, done: 'Account active again');
  }

  Future<void> _delete() async {
    final name = (_open?['username'] ?? '').toString();
    final typed = TextEditingController();
    final reason = TextEditingController();
    final pw = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('Delete $name’s account?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  'Only when they asked, or for abuse. The account is frozen '
                  'for 7 days (you can restore it), then deleted for good. '
                  'Shared chats then show a deleted user; the other person’s '
                  'own messages and memories stay.',
                  style: TextStyle(color: ctx.adm.muted)),
              const SizedBox(height: 12),
              TextField(
                controller: reason,
                decoration: InputDecoration(
                  labelText: 'Why (kept in the activity log)',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(Radii.md)),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: typed,
                onChanged: (_) => set(() {}),
                decoration: InputDecoration(
                  labelText: 'Type $name to confirm',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(Radii.md)),
                ),
              ),
              const SizedBox(height: 10),
              AdminPasswordField(controller: pw),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kAdminRed),
              onPressed: typed.text.trim() == name
                  ? () => Navigator.pop(ctx, true)
                  : null,
              child: const Text('Delete in 7 days'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _act(
        'delete',
        {'password': pw.text, 'confirm': typed.text.trim(), 'reason': reason.text},
        done: 'Frozen — deleted for good in 7 days');
  }

  Future<void> _restore() async {
    final pw = await askPassword(context,
        title: 'Restore ${_open?['username']}?',
        message: 'Cancels the deletion; the account works again.',
        action: 'Restore');
    if (pw == null) return;
    await _act('restore', {'password': pw}, done: 'Account restored');
  }

  // ── UI ────────────────────────────────────────────────────────────────────
  static (Color, String) _status(Map<String, dynamic> u) =>
      switch (u['status']) {
        'paused' => (const Color(0xFFFFA000), 'Paused'),
        'deleting' => (kAdminRed,
            'Deleting ${fmtDateTime(u['delete_after'] as String?)}'),
        _ => u['online'] == true
            ? (const Color(0xFF00C853), 'Online')
            : (const Color(0xFF9E9E9E), 'Seen ${fmtAgo(u['last_seen'] as String?)}'),
      };

  Widget _pill(Color c, String t) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: c.withValues(alpha: 0.45)),
        ),
        child: Text(t,
            style: TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w700, color: c)),
      );

  Widget _list(AdminPalette p) {
    if (_error != null) {
      return Center(child: Text(_error!, style: TextStyle(color: p.muted)));
    }
    if (_rows.isEmpty && !_loading) {
      return Center(
          child: Text('No one matches', style: TextStyle(color: p.muted)));
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: _rows.length,
      separatorBuilder: (_, _) => Divider(height: 1, color: p.border),
      itemBuilder: (_, i) {
        final u = _rows[i];
        final (c, t) = _status(u);
        final sel = _open?['id'] == u['id'];
        return ListTile(
          selected: sel,
          selectedTileColor: kAdminRed.withValues(alpha: 0.08),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Radii.md)),
          leading: CircleAvatar(
            backgroundColor: kAdminRed.withValues(alpha: 0.14),
            child: Text(
                ((u['username'] ?? '?').toString().characters.firstOrNull ?? '?')
                    .toUpperCase(),
                style: const TextStyle(
                    color: kAdminRed, fontWeight: FontWeight.w800)),
          ),
          title: Text((u['username'] ?? '').toString(),
              style: TextStyle(color: p.text, fontWeight: FontWeight.w700)),
          subtitle: Text(
              [u['phone'], u['email']].whereType<String>().join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: p.muted, fontSize: 12)),
          trailing: _pill(c, t),
          onTap: () => _openUser(u['id'] as int),
        );
      },
    );
  }

  Widget _card(AdminPalette p, Map<String, dynamic> u) {
    final (c, t) = _status(u);
    final isYou = u['is_you'] == true;
    final status = u['status'];
    final storage = (u['storage'] as Map?) ?? const {};
    final app = (u['app'] as Map?)?.cast<String, dynamic>();
    final devices = ((u['devices'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    Widget line(IconData i, String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Icon(i, size: 16, color: p.muted),
            const SizedBox(width: 8),
            SizedBox(
                width: 110,
                child: Text(k, style: TextStyle(color: p.muted, fontSize: 13))),
            Expanded(
                child: SelectableText(v,
                    style: TextStyle(color: p.text, fontSize: 13))),
          ]),
        );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        AdminSection(
          icon: Icons.person_rounded,
          title: (u['username'] ?? '').toString(),
          subtitle: 'User #${u['id']}${isYou ? ' · you' : ''}',
          trailing: _pill(c, t),
          child: Column(children: [
            line(Icons.phone_rounded, 'Phone', (u['phone'] ?? '—').toString()),
            line(Icons.alternate_email_rounded, 'Email',
                (u['email'] ?? '—').toString()),
            line(Icons.event_rounded, 'Joined',
                fmtDateTime(u['created_at'] as String?)),
            line(Icons.schedule_rounded, 'Last seen',
                fmtDateTime(u['last_seen'] as String?)),
            line(Icons.workspace_premium_rounded, 'Plan',
                (u['plan'] ?? 'free').toString()),
            line(Icons.group_rounded, 'Friends',
                '${u['friends'] ?? '—'}'),
            line(Icons.cloud_rounded, 'Storage',
                '${fmtBytes(storage['bytes'] as num?)} · '
                '${storage['files'] ?? 0} files'),
            line(Icons.verified_user_rounded, 'Security',
                '${u['two_factor'] == true ? '2-step on' : '2-step off'} · '
                '${u['ozilane_key'] == true ? 'Ozilane Key linked' : 'no Ozilane Key'}'),
            line(Icons.system_update_rounded, 'Aluta',
                app == null ? '—' : '${app['version']} · ${app['slot']}'),
            if ((u['reason'] ?? '').toString().isNotEmpty)
              line(Icons.info_outline_rounded, 'Reason',
                  u['reason'].toString()),
          ]),
        ),
        const SizedBox(height: 12),
        if (devices.isNotEmpty)
          AdminSection(
            icon: Icons.devices_rounded,
            title: 'Devices',
            child: Column(children: [
              for (final d in devices)
                line(Icons.smartphone_rounded, (d['platform'] ?? '').toString(),
                    '${d['app_version'] ?? ''} · seen ${fmtAgo(d['last_seen'] as String?)}'),
            ]),
          ),
        const SizedBox(height: 12),
        if (!isYou)
          AdminSection(
            icon: Icons.manage_accounts_rounded,
            title: 'Actions',
            subtitle: 'Each one asks for your password and is logged.',
            child: Wrap(spacing: 10, runSpacing: 10, children: [
              if (status != 'deleting')
                OutlinedButton.icon(
                  onPressed: _reset,
                  icon: const Icon(Icons.key_rounded, size: 18),
                  label: const Text('Reset sign-in'),
                ),
              if (status == 'active')
                OutlinedButton.icon(
                  onPressed: _pause,
                  icon: const Icon(Icons.pause_circle_rounded, size: 18),
                  label: const Text('Pause account'),
                ),
              if (status == 'paused')
                FilledButton.tonalIcon(
                  onPressed: _unpause,
                  icon: const Icon(Icons.play_circle_rounded, size: 18),
                  label: const Text('Un-pause'),
                ),
              if (status != 'deleting')
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: kAdminRed),
                  onPressed: _delete,
                  icon: const Icon(Icons.delete_forever_rounded, size: 18),
                  label: const Text('Delete account'),
                ),
              if (status == 'deleting')
                FilledButton.icon(
                  onPressed: _restore,
                  icon: const Icon(Icons.restore_rounded, size: 18),
                  label: const Text('Restore account'),
                ),
            ]),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.adm;
    final wide = MediaQuery.sizeOf(context).width >= 980;
    final search = Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AdminPageTitle(
            icon: Icons.people_alt_rounded,
            title: 'People',
            subtitle: 'Find someone by name, phone or email',
            trailing: IconButton.filledTonal(
              tooltip: 'Refresh',
              onPressed: _loading ? null : _search,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ),
          TextField(
            controller: _q,
            onChanged: (_) {
              _debounce?.cancel();
              _debounce =
                  Timer(const Duration(milliseconds: 350), _search);
            },
            decoration: InputDecoration(
              hintText: 'Name, phone or email',
              prefixIcon: const Icon(Icons.search_rounded),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.xl)),
              isDense: true,
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
        ],
      ),
    );
    final open = _open;
    if (wide) {
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: 420,
          child: Column(children: [search, Expanded(child: _list(p))]),
        ),
        VerticalDivider(width: 1, color: p.border),
        Expanded(
          child: open == null
              ? Center(
                  child: Text('Pick someone to see their card',
                      style: TextStyle(color: p.muted)))
              : _card(p, open),
        ),
      ]);
    }
    // Phones: the list, and a person's card on top when one is picked.
    if (open != null) {
      return Column(children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _open = null),
            icon: const Icon(Icons.arrow_back_rounded),
            label: const Text('People'),
          ),
        ),
        Expanded(child: _card(p, open)),
      ]);
    }
    return Column(children: [search, Expanded(child: _list(p))]);
  }
}
