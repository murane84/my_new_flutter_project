import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'admin_api.dart';
import 'admin_widgets.dart';

/// Admin devices: approve / deny requests (6-character code + password),
/// remove devices, end a probation early, new recovery codes.
class AdminDevicesPage extends StatefulWidget {
  const AdminDevicesPage({super.key, required this.onChanged});
  final VoidCallback onChanged;

  @override
  State<AdminDevicesPage> createState() => _AdminDevicesPageState();
}

class _AdminDevicesPageState extends State<AdminDevicesPage> {
  final _api = AdminApi.instance;
  List<Map<String, dynamic>> _devices = const [];
  bool _loading = false;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    // Requests appear while you're on this page.
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_api.userIdle) _load(quiet: true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    if (_loading) return;
    if (!quiet) setState(() => _loading = true);
    try {
      final r = await _api.get('/admin/api/devices');
      if (!mounted) return;
      setState(() {
        _devices = ((r['devices'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
        _error = null;
      });
    } on AdminApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      _loading = false;
      if (mounted && !quiet) setState(() {});
    }
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    try {
      await action();
      if (!mounted) return;
      adminToast(context, done);
      widget.onChanged();
      await _load(quiet: true);
    } on AdminApiException catch (e) {
      if (mounted) adminToast(context, e.message, error: true);
    }
  }

  Future<void> _approve(Map<String, dynamic> d) async {
    final code = TextEditingController();
    final pw = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Approve this device?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${d['name']} · ${d['browser']}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            Text('Requested from IP ${d['request_ip'] ?? '—'} · '
                '${fmtAgo(d['created_at'] as String?)}',
                style: const TextStyle(color: Colors.white60, fontSize: 12)),
            const SizedBox(height: 12),
            const AdminInline(
              text: 'Only approve a device you are holding or can see right '
                  'now. Type the code it shows.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: code,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                  labelText: 'Code on the new device',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: pw,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'Your Aluta password',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            const Text('It stays read-only for 24 hours.',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Approve')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(
      () => _api.post('/admin/api/devices/${d['id']}/approve',
          {'pair_code': code.text.trim(), 'password': pw.text}),
      'Device approved (read-only for 24 h)',
    );
  }

  Future<void> _deny(Map<String, dynamic> d) => _run(
      () => _api.post('/admin/api/devices/${d['id']}/deny'), 'Request denied');

  Future<void> _revoke(Map<String, dynamic> d) async {
    final me = d['is_this_device'] == true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(me ? 'Remove this device?' : 'Remove ${d['name']}?'),
        content: Text(me
            ? 'You will be signed out and this browser will need approval '
                'again.'
            : 'It is signed out at once and must be approved again to return.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kAdminRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => _api.post('/admin/api/devices/${d['id']}/revoke'),
        'Device removed');
  }

  Future<void> _endProbation(Map<String, dynamic> d) async {
    final pw = await askPassword(context,
        title: 'Give ${d['name']} full access now?',
        message: 'Ends its 24-hour read-only period early.',
        action: 'Give full access');
    if (pw == null) return;
    await _run(
        () => _api.post(
            '/admin/api/devices/${d['id']}/end-probation', {'password': pw}),
        'Full access granted');
  }

  Future<void> _rename(Map<String, dynamic> d) async {
    final ctl = TextEditingController(text: (d['name'] ?? '').toString());
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename device'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(ctx, v),
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctl.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await _run(
        () => _api.post(
            '/admin/api/devices/${d['id']}/rename', {'name': name.trim()}),
        'Renamed');
  }

  Future<void> _revokeOthers() async {
    final pw = await askPassword(context,
        title: 'Remove every other device?',
        message: 'All other admin devices are signed out and must be approved '
            'again. Pending requests are cancelled.',
        action: 'Remove all others');
    if (pw == null) return;
    await _run(
        () => _api.post('/admin/api/devices/revoke-others', {'password': pw}),
        'All other devices removed');
  }

  Future<void> _newCodes() async {
    final pw = await askPassword(context,
        title: 'Make new recovery codes?',
        message: 'Your old recovery codes stop working.',
        action: 'Make new codes');
    if (pw == null) return;
    try {
      final r = await _api
          .post('/admin/api/recovery-codes/regenerate', {'password': pw});
      final codes = List<String>.from(r['recovery_codes'] as List? ?? const []);
      if (!mounted) return;
      widget.onChanged();
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('New recovery codes'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Shown once. Write them down and keep them offline.',
                  style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 12),
              AdminCodesGrid(codes: codes),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: codes.join('\n'))),
              child: const Text('Copy all'),
            ),
            FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('I’ve saved them')),
          ],
        ),
      );
    } on AdminApiException catch (e) {
      if (mounted) adminToast(context, e.message, error: true);
    }
  }

  static const _order = {
    'pending': 0,
    'recovering': 1,
    'trusted': 2,
    'denied': 3,
    'revoked': 4,
  };

  @override
  Widget build(BuildContext context) {
    final list = [..._devices]..sort((a, b) =>
        (_order[a['status']] ?? 9).compareTo(_order[b['status']] ?? 9));
    final active =
        list.where((d) => d['status'] != 'denied' && d['status'] != 'revoked');
    final past =
        list.where((d) => d['status'] == 'denied' || d['status'] == 'revoked');
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Devices',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text(
            'Only these browsers can open admin. A new one needs your approval '
            'here, then stays read-only for 24 hours.',
            style: TextStyle(color: Colors.white60),
          ),
          const SizedBox(height: 12),
          if (_error != null) ...[
            AdminInline(text: _error!, error: true),
            const SizedBox(height: 12),
          ],
          if (_loading && _devices.isEmpty)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            ),
          for (final d in active) ...[
            _DeviceCard(
              d: d,
              onApprove: () => _approve(d),
              onDeny: () => _deny(d),
              onRevoke: () => _revoke(d),
              onEndProbation: () => _endProbation(d),
              onRename: () => _rename(d),
            ),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 6),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: _newCodes,
                icon: const Icon(Icons.key_outlined, size: 18),
                label: const Text('New recovery codes'),
              ),
              OutlinedButton.icon(
                onPressed: _revokeOthers,
                icon: const Icon(Icons.phonelink_erase_outlined, size: 18),
                label: const Text('Remove all other devices'),
              ),
            ],
          ),
          if (past.isNotEmpty) ...[
            const SizedBox(height: 22),
            const Text('Removed & denied',
                style: TextStyle(color: Colors.white54)),
            const SizedBox(height: 6),
            for (final d in past.take(20))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.block, color: Colors.white38, size: 18),
                title: Text('${d['name']}'),
                subtitle: Text('${d['status']} · ${d['browser']} · last IP '
                    '${d['last_ip'] ?? d['request_ip'] ?? '—'}'),
              ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.d,
    required this.onApprove,
    required this.onDeny,
    required this.onRevoke,
    required this.onEndProbation,
    required this.onRename,
  });
  final Map<String, dynamic> d;
  final VoidCallback onApprove;
  final VoidCallback onDeny;
  final VoidCallback onRevoke;
  final VoidCallback onEndProbation;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final status = (d['status'] ?? '').toString();
    final me = d['is_this_device'] == true;
    final probation = d['on_probation'] == true;
    final expired = status == 'pending' &&
        (parseTime(d['pair_expires_at'] as String?)
                ?.isBefore(DateTime.now()) ??
            true);
    final (Color color, String label) = switch (status) {
      'pending' => expired
          ? (Colors.white38, 'Request expired')
          : (kAdminRed, 'Waiting for your approval'),
      'recovering' => (const Color(0xFFF9A825), 'Recovery (72 h wait)'),
      'trusted' => probation
          ? (const Color(0xFFF9A825), 'Read-only (probation)')
          : (const Color(0xFF66BB6A), 'Trusted'),
      _ => (Colors.white38, status),
    };
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: status == 'pending' && !expired
            ? const BorderSide(color: kAdminRed)
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  (d['browser'] ?? '').toString().contains('iPhone') ||
                          (d['browser'] ?? '').toString().contains('Android')
                      ? Icons.smartphone
                      : Icons.computer,
                  color: color,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${d['name']}${me ? '  (this device)' : ''}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(label,
                      style: TextStyle(color: color, fontSize: 11)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              [
                d['browser'],
                if (status == 'pending')
                  'asked ${fmtAgo(d['created_at'] as String?)} from IP '
                      '${d['request_ip'] ?? '—'}'
                else
                  'last used ${fmtAgo(d['last_used_at'] as String?)} · IP '
                      '${d['last_ip'] ?? '—'}',
                if (probation)
                  'full access from ${fmtDateTime(d['probation_until'] as String?)}',
                if (status == 'recovering')
                  'becomes active ${fmtDateTime(d['activate_at'] as String?)}',
              ].join(' · '),
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (status == 'pending' && !expired)
                  FilledButton(onPressed: onApprove, child: const Text('Approve')),
                if (status == 'pending' || status == 'recovering')
                  TextButton(
                    onPressed: onDeny,
                    child: Text(status == 'recovering' ? 'Cancel recovery' : 'Deny'),
                  ),
                if (status == 'trusted' && probation && !me)
                  TextButton(
                      onPressed: onEndProbation,
                      child: const Text('Give full access now')),
                if (status == 'trusted')
                  TextButton(onPressed: onRename, child: const Text('Rename')),
                if (status == 'trusted')
                  TextButton(
                    onPressed: onRevoke,
                    child: const Text('Remove',
                        style: TextStyle(color: Color(0xFFEF5350))),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The audit trail: every sign-in, request, approval, lock and admin action.
class AdminAuditPage extends StatefulWidget {
  const AdminAuditPage({super.key});

  @override
  State<AdminAuditPage> createState() => _AdminAuditPageState();
}

class _AdminAuditPageState extends State<AdminAuditPage> {
  final _api = AdminApi.instance;
  final List<Map<String, dynamic>> _rows = [];
  bool _loading = false;
  bool _more = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final before = reset || _rows.isEmpty ? '' : '&before_id=${_rows.last['id']}';
      final r = await _api.get('/admin/api/audit?limit=60$before');
      final got = ((r['entries'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      if (!mounted) return;
      setState(() {
        if (reset) _rows.clear();
        _rows.addAll(got);
        _more = got.length == 60;
        _error = null;
      });
    } on AdminApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static const _names = {
    'login': 'Signed in',
    'logout': 'Signed out',
    'login_wrong_password': 'Wrong password',
    'login_rejected': 'Sign-in refused (not an admin account)',
    'login_bad_signature': 'Bad device signature',
    'device_requested': 'New device asked for access',
    'device_request_throttled': 'Too many device requests',
    'device_approved': 'Device approved',
    'device_approve_wrong_code': 'Approval with a wrong code',
    'device_denied': 'Device request denied',
    'device_revoked': 'Device removed',
    'device_renamed': 'Device renamed',
    'device_expired': 'Device expired (30 days unused)',
    'device_probation_ended': 'Probation ended early',
    'devices_revoked_others': 'All other devices removed',
    'bootstrap_enrolled': 'First device set up',
    'bootstrap_rejected': 'Setup code refused',
    'recovery_started': 'Recovery started',
    'recovery_completed': 'Recovery completed',
    'recovery_rejected': 'Recovery code refused',
    'recovery_codes_regenerated': 'New recovery codes',
    'admin_frozen': 'Admin locked',
    'admin_unfrozen': 'Admin unlocked',
  };

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Activity log',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text('Everything done in or to the admin panel.',
              style: TextStyle(color: Colors.white60)),
          const SizedBox(height: 12),
          if (_error != null) ...[
            AdminInline(text: _error!, error: true),
            const SizedBox(height: 12),
          ],
          Card(
            child: Column(
              children: [
                for (final e in _rows)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      e['ok'] == false
                          ? Icons.warning_amber_rounded
                          : Icons.check_circle_outline,
                      color: e['ok'] == false
                          ? const Color(0xFFEF5350)
                          : Colors.white38,
                      size: 20,
                    ),
                    title: Text(_names[e['action']] ?? '${e['action']}'),
                    subtitle: Text([
                      fmtDateTime(e['at'] as String?),
                      if (e['device'] != null) '${e['device']}',
                      if (e['ip'] != null) 'IP ${e['ip']}',
                      if (e['target'] != null) 'target ${e['target']}',
                    ].join(' · ')),
                  ),
                if (_rows.isEmpty && !_loading)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('Nothing yet.',
                        style: TextStyle(color: Colors.white54)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
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
    );
  }
}
