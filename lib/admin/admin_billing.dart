import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'admin_api.dart';
import 'admin_widgets.dart';
import '../utils/radii.dart';

/// Admin Phase 4 — Money: what came in, payments to check, who has a plan,
/// and the prices. Anything that changes money or plans asks for the owner
/// password (and a device past probation); the server audits every step.
enum AdminBillingView { overview, payments, subscribers, prices }

String fmtTzs(num? n) =>
    'TZS ${NumberFormat.decimalPattern().format(n ?? 0)}';

String _planName(String? code) => switch (code) {
      'together' => 'Aluta Together',
      'space_plus' => 'Bigger Our Space',
      _ => code ?? '—',
    };

String _day(String? iso) {
  final d = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  return d == null ? '—' : DateFormat('d MMM yyyy').format(d);
}

const Color _kGold = Color(0xFFE6A700);
const Color _kGreen = Color(0xFF2E9E6A);

class AdminBillingPage extends StatefulWidget {
  const AdminBillingPage(
      {super.key, this.view = AdminBillingView.overview, this.onChanged});
  final AdminBillingView view;
  final VoidCallback? onChanged;

  @override
  State<AdminBillingPage> createState() => _AdminBillingPageState();
}

class _AdminBillingPageState extends State<AdminBillingPage> {
  final _api = AdminApi.instance;
  Map<String, dynamic>? _ov;
  List<Map<String, dynamic>> _pays = const [];
  List<Map<String, dynamic>> _subs = const [];
  List<Map<String, dynamic>> _plans = const [];
  Map<String, dynamic> _settings = const {};
  String _payFilter = 'pending';
  final _q = TextEditingController();
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant AdminBillingPage old) {
    super.didUpdateWidget(old);
    if (old.view != widget.view) _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _list(dynamic v) => ((v as List?) ?? const [])
      .whereType<Map>()
      .map((e) => e.cast<String, dynamic>())
      .toList();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      switch (widget.view) {
        case AdminBillingView.overview:
          final o = await _api.get('/admin/api/billing/overview');
          final p = await _api.get('/admin/api/billing/payments?status=pending');
          if (!mounted) return;
          setState(() {
            _ov = o;
            _pays = _list(p['payments']);
          });
        case AdminBillingView.payments:
          final p =
              await _api.get('/admin/api/billing/payments?status=$_payFilter');
          if (mounted) setState(() => _pays = _list(p['payments']));
        case AdminBillingView.subscribers:
          final s = await _api.get(
              '/admin/api/billing/subscribers?q=${Uri.encodeQueryComponent(_q.text.trim())}');
          if (mounted) setState(() => _subs = _list(s['entitlements']));
        case AdminBillingView.prices:
          final s = await _api.get('/admin/api/billing/plans');
          if (!mounted) return;
          setState(() {
            _plans = _list(s['plans']);
            _settings =
                (s['settings'] as Map?)?.cast<String, dynamic>() ?? const {};
          });
      }
    } on AdminApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool> _post(String path, Map<String, dynamic> body,
      {required String done}) async {
    try {
      await _api.post(path, body);
      if (!mounted) return false;
      adminToast(context, done);
      widget.onChanged?.call();
      await _load();
      return true;
    } on AdminApiException catch (e) {
      if (mounted) adminToast(context, e.message, error: true);
      return false;
    }
  }

  // ── Payments ──────────────────────────────────────────────────────────────

  Future<void> _confirm(Map<String, dynamic> p) async {
    final pw = await askPassword(context,
        title: 'Confirm ${fmtTzs(p['amount_tzs'])}?',
        message: 'Check your ${p['network'] ?? 'M-Pesa'} messages for code '
            '${p['txn_code']} and this amount first. Confirming starts '
            '${_planName(p['plan_code'] as String?)} for '
            '${p['months'] == 12 ? '12 months' : '${p['months']} month(s)'} '
            'and tells ${p['username']}.',
        action: 'Confirm payment');
    if (pw == null) return;
    await _post('/admin/api/billing/payments/${p['id']}/confirm',
        {'password': pw},
        done: 'Confirmed — ${p['username']} is on '
            '${_planName(p['plan_code'] as String?)}');
  }

  Future<void> _reject(Map<String, dynamic> p) async {
    final why = TextEditingController(
        text: 'We couldn’t find code ${p['txn_code']} — check it and send '
            'it again.');
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject this payment?'),
        content: TextField(
          controller: why,
          maxLines: 3,
          decoration: InputDecoration(
              labelText: 'What they’ll see',
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.md))),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, why.text),
              child: const Text('Next')),
        ],
      ),
    );
    why.dispose();
    if (reason == null || !mounted) return;
    final pw = await askPassword(context,
        title: 'Reject ${p['txn_code']}?', action: 'Reject');
    if (pw == null) return;
    await _post('/admin/api/billing/payments/${p['id']}/reject',
        {'password': pw, 'reason': reason},
        done: 'Rejected — ${p['username']} was told');
  }

  Widget _payTile(Map<String, dynamic> p) {
    final c = context.adm;
    final status = (p['status'] ?? '').toString();
    final pending = status == 'pending';
    final pair = p['partner_username'] != null
        ? ' · with ${p['partner_username']}'
        : '';
    final color = switch (status) {
      'confirmed' => _kGreen,
      'rejected' => kAdminRed,
      _ => _kGold,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Row(children: [
          AdminIconChip(
              icon: pending
                  ? Icons.hourglass_top_rounded
                  : status == 'confirmed'
                      ? Icons.check_rounded
                      : Icons.close_rounded,
              color: color,
              size: 34),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${fmtTzs(p['amount_tzs'])} · ${p['username'] ?? '?'}',
                      style: TextStyle(
                          color: c.text,
                          fontWeight: FontWeight.w700,
                          fontSize: 14.5)),
                  Text(
                      '${_planName(p['plan_code'] as String?)} · '
                      '${p['months'] == 12 ? '12 months' : '${p['months']} mo'}'
                      '$pair',
                      style: TextStyle(color: c.muted, fontSize: 12.5)),
                  const SizedBox(height: 2),
                  Row(children: [
                    SelectableText('${p['network'] ?? ''} ${p['txn_code']}',
                        style: TextStyle(
                            color: c.text,
                            fontFamily: 'monospace',
                            fontSize: 12.5)),
                    IconButton(
                      tooltip: 'Copy code',
                      visualDensity: VisualDensity.compact,
                      iconSize: 15,
                      onPressed: () => Clipboard.setData(
                          ClipboardData(text: '${p['txn_code']}')),
                      icon: const Icon(Icons.copy_rounded),
                    ),
                  ]),
                  Text(
                      '${fmtAgo(p['created_at'] as String?)}'
                      '${p['payer_phone'] != null ? ' · from ${p['payer_phone']}' : ''}'
                      '${p['note'] != null ? ' · ${p['note']}' : ''}',
                      style: TextStyle(color: c.faint, fontSize: 11.5)),
                ]),
          ),
          if (pending) ...[
            IconButton(
                tooltip: 'Reject',
                onPressed: () => _reject(p),
                icon: const Icon(Icons.close_rounded, color: kAdminRed)),
            const SizedBox(width: 4),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: _kGreen),
              onPressed: () => _confirm(p),
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('Confirm'),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(status,
                  style: TextStyle(color: color, fontWeight: FontWeight.w700)),
            ),
        ]),
      ),
    );
  }

  // ── Subscribers ───────────────────────────────────────────────────────────

  Future<void> _extend(Map<String, dynamic> e) async {
    final months = await _pickMonths('Add time to '
        '${e['pair'] ?? e['username']}’s ${_planName(e['plan_code'] as String?)}');
    if (months == null || !mounted) return;
    final pw = await askPassword(context,
        title: 'Add $months month(s)?', action: 'Extend');
    if (pw == null) return;
    await _post('/admin/api/billing/entitlements/${e['id']}/extend',
        {'password': pw, 'months': months},
        done: 'Extended');
  }

  Future<void> _revoke(Map<String, dynamic> e) async {
    final pw = await askPassword(context,
        title: 'End ${_planName(e['plan_code'] as String?)} now?',
        message: 'For ${e['pair'] ?? e['username']} — including any time '
            'already paid ahead. Nothing they made is deleted; they go back '
            'to the free rules (extra Spaces and storage become read-only).',
        action: 'End plan');
    if (pw == null) return;
    await _post('/admin/api/billing/entitlements/${e['id']}/revoke',
        {'password': pw},
        done: 'Plan ended');
  }

  Future<int?> _pickMonths(String title) => showDialog<int>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(title),
          children: [
            for (final m in const [1, 2, 3, 6, 12])
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, m),
                child: Text(m == 12 ? '12 months' : '$m month(s)'),
              ),
          ],
        ),
      );

  Future<void> _grant() async {
    final r = await showDialog<Map<String, dynamic>>(
        context: context, builder: (_) => const _GrantDialog());
    if (r == null || !mounted) return;
    final pw = await askPassword(context,
        title: 'Give ${_planName(r['plan_code'] as String?)}?',
        message: 'Free of charge, ${r['months']} month(s), '
            'for ${r['label']}. They are told it’s a gift from Aluta.',
        action: 'Give plan');
    if (pw == null) return;
    r.remove('label');
    await _post('/admin/api/billing/grant', {...r, 'password': pw},
        done: 'Plan given');
  }

  Widget _subTile(Map<String, dynamic> e) {
    final c = context.adm;
    final upcoming = e['upcoming'] == true;
    final src = (e['source'] ?? '').toString();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(children: [
          AdminIconChip(
              icon: e['plan_code'] == 'space_plus'
                  ? Icons.favorite_rounded
                  : Icons.workspace_premium_rounded,
              color: e['plan_code'] == 'space_plus' ? kAdminRed : _kGold,
              size: 34),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${e['pair'] ?? e['username'] ?? '?'}',
                      style: TextStyle(
                          color: c.text,
                          fontWeight: FontWeight.w700,
                          fontSize: 14.5)),
                  Text(
                      '${_planName(e['plan_code'] as String?)} · '
                      '${upcoming ? 'starts ${_day(e['starts_at'] as String?)} · ' : ''}'
                      'until ${e['ends_at'] == null ? 'no end' : _day(e['ends_at'] as String?)}',
                      style: TextStyle(color: c.muted, fontSize: 12.5)),
                  Text(
                      switch (src) {
                        'payment' => 'Paid',
                        'legacy' => 'Trial carried over',
                        _ => 'Given by admin',
                      } +
                          (e['note'] != null ? ' · ${e['note']}' : ''),
                      style: TextStyle(color: c.faint, fontSize: 11.5)),
                ]),
          ),
          PopupMenuButton<String>(
            tooltip: 'Actions',
            onSelected: (v) => v == 'extend' ? _extend(e) : _revoke(e),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'extend', child: Text('Add time')),
              PopupMenuItem(value: 'revoke', child: Text('End now')),
            ],
          ),
        ]),
      ),
    );
  }

  // ── Prices ────────────────────────────────────────────────────────────────

  Future<void> _editPlan(Map<String, dynamic> p) async {
    final r = await showDialog<Map<String, dynamic>>(
        context: context, builder: (_) => _PlanDialog(plan: p));
    if (r == null || !mounted) return;
    final pw = await askPassword(context,
        title: 'Save ${p['name']}?',
        message: 'New payments use the new price. People already paid keep '
            'what they paid for.',
        action: 'Save');
    if (pw == null) return;
    await _post('/admin/api/billing/plans/${p['code']}', {...r, 'password': pw},
        done: 'Saved');
  }

  Future<void> _editSettings() async {
    final r = await showDialog<Map<String, dynamic>>(
        context: context, builder: (_) => _PayDialog(settings: _settings));
    if (r == null || !mounted) return;
    final pw = await askPassword(context,
        title: 'Save where people pay?', action: 'Save');
    if (pw == null) return;
    await _post('/admin/api/billing/settings', {...r, 'password': pw},
        done: 'Saved');
  }

  Widget _planTile(Map<String, dynamic> p) {
    final c = context.adm;
    final active = p['active'] == true;
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
        leading: AdminIconChip(
            icon: p['code'] == 'space_plus'
                ? Icons.favorite_rounded
                : Icons.workspace_premium_rounded,
            color: active ? _kGold : c.faint,
            size: 36),
        title: Text('${p['name']}${active ? '' : ' (hidden)'}',
            style: TextStyle(color: c.text, fontWeight: FontWeight.w700)),
        subtitle: Text(
            '${fmtTzs(p['price_tzs'])} a month · 12 months ${fmtTzs(p['year_price_tzs'])}'
            '${p['space_mb'] != null ? ' · ${p['space_mb']} MB per pair' : ''}'
            '\n${p['scope'] == 'pair' ? 'Per pair (both people)' : 'Per person'}',
            style: TextStyle(color: c.muted, fontSize: 12.5)),
        isThreeLine: true,
        trailing: IconButton(
            tooltip: 'Edit',
            onPressed: () => _editPlan(p),
            icon: const Icon(Icons.edit_rounded)),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = context.adm;
    final (icon, title, sub) = switch (widget.view) {
      AdminBillingView.overview => (
          Icons.payments_rounded,
          'Money',
          'What came in, payments to check, plans running out'
        ),
      AdminBillingView.payments => (
          Icons.receipt_rounded,
          'Payments',
          'Codes people sent — check your phone, then confirm'
        ),
      AdminBillingView.subscribers => (
          Icons.workspace_premium_rounded,
          'Subscribers',
          'Who has a plan — give, add time, or end'
        ),
      AdminBillingView.prices => (
          Icons.sell_rounded,
          'Prices',
          'Plans, prices and where people pay'
        ),
    };
    final body = <Widget>[
      AdminPageTitle(
        icon: icon,
        title: title,
        subtitle: sub,
        trailing: IconButton(
            tooltip: 'Refresh',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded)),
      ),
      if (_error != null)
        AdminInline(text: _error!, error: true)
      else if (_loading && _ov == null && _pays.isEmpty && _subs.isEmpty &&
          _plans.isEmpty)
        const Padding(
            padding: EdgeInsets.all(40),
            child: Center(child: CircularProgressIndicator())),
    ];

    switch (widget.view) {
      case AdminBillingView.overview:
        final o = _ov;
        if (o != null) {
          final noNumber =
              ((o['settings'] as Map?)?['pay_number'] ?? '').toString().isEmpty;
          body.addAll([
            if (noNumber)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: AdminInline(
                    text: 'Add the number people pay to (Prices → Where '
                        'people pay) — the app shows it on the pay screen.',
                    error: true),
              ),
            AdminStatGrid(children: [
              AdminStat(
                  label: 'This month',
                  value: fmtTzs(o['revenue_month_tzs']),
                  icon: Icons.calendar_month_rounded,
                  accent: _kGreen,
                  hint: 'Last 30 days ${fmtTzs(o['revenue_30d_tzs'])}'),
              AdminStat(
                  label: 'Payments to check',
                  value: fmtInt(o['pending_payments'] as num?),
                  icon: Icons.hourglass_top_rounded,
                  accent: _kGold),
              AdminStat(
                  label: 'Aluta Together',
                  value: fmtInt(o['active_together'] as num?),
                  icon: Icons.workspace_premium_rounded,
                  accent: _kGold,
                  hint: 'people'),
              AdminStat(
                  label: 'Bigger Our Space',
                  value: fmtInt(o['active_space_plus'] as num?),
                  icon: Icons.favorite_rounded,
                  hint: 'pairs · all time ${fmtTzs(o['revenue_total_tzs'])}'),
            ]),
            const SizedBox(height: 14),
            AdminSection(
              title: 'Payments to check',
              icon: Icons.hourglass_top_rounded,
              color: _kGold,
              child: _pays.isEmpty
                  ? Text('Nothing waiting.', style: TextStyle(color: c.muted))
                  : Column(children: [for (final p in _pays) _payTile(p)]),
            ),
            const SizedBox(height: 14),
            AdminSection(
              title: 'Running out in 7 days',
              icon: Icons.timelapse_rounded,
              child: _list(o['expiring']).isEmpty
                  ? Text('No plans end this week.',
                      style: TextStyle(color: c.muted))
                  : Column(children: [
                      for (final e in _list(o['expiring'])) _subTile(e)
                    ]),
            ),
          ]);
        }
      case AdminBillingView.payments:
        body.addAll([
          Wrap(spacing: 8, children: [
            for (final f in const ['pending', 'confirmed', 'rejected', 'all'])
              ChoiceChip(
                label: Text(switch (f) {
                  'pending' => 'Waiting',
                  'confirmed' => 'Confirmed',
                  'rejected' => 'Rejected',
                  _ => 'All',
                }),
                selected: _payFilter == f,
                onSelected: (_) {
                  setState(() => _payFilter = f);
                  _load();
                },
              ),
          ]),
          const SizedBox(height: 12),
          if (!_loading && _pays.isEmpty)
            Text('No payments here.', style: TextStyle(color: c.muted)),
          for (final p in _pays) _payTile(p),
        ]);
      case AdminBillingView.subscribers:
        body.addAll([
          Row(children: [
            Expanded(
              child: TextField(
                controller: _q,
                onSubmitted: (_) => _load(),
                decoration: InputDecoration(
                  hintText: 'Search a name',
                  prefixIcon: const Icon(Icons.search_rounded),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(Radii.md)),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton.icon(
              onPressed: _grant,
              icon: const Icon(Icons.card_giftcard_rounded, size: 18),
              label: const Text('Give a plan'),
            ),
          ]),
          const SizedBox(height: 12),
          if (!_loading && _subs.isEmpty)
            Text('Nobody has a plan yet.', style: TextStyle(color: c.muted)),
          for (final e in _subs) _subTile(e),
        ]);
      case AdminBillingView.prices:
        body.addAll([
          for (final p in _plans) _planTile(p),
          const SizedBox(height: 10),
          AdminSection(
            title: 'Where people pay',
            icon: Icons.phone_android_rounded,
            color: _kGreen,
            trailing: IconButton(
                tooltip: 'Edit',
                onPressed: _editSettings,
                icon: const Icon(Icons.edit_rounded)),
            child: Text(
                (_settings['pay_number'] ?? '').toString().isEmpty
                    ? 'Not set yet — the app can’t show people where to pay.'
                    : '${_settings['pay_network']} · ${_settings['pay_number']}'
                        '${(_settings['pay_name'] ?? '').toString().isEmpty ? '' : ' · ${_settings['pay_name']}'}'
                        '${(_settings['instructions'] ?? '').toString().isEmpty ? '' : '\n${_settings['instructions']}'}',
                style: TextStyle(color: c.muted)),
          ),
        ]);
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: body,
      ),
    );
  }
}

// ── Dialogs ─────────────────────────────────────────────────────────────────

/// Give a plan: find the person, choose the plan, (pair) the partner, months.
class _GrantDialog extends StatefulWidget {
  const _GrantDialog();
  @override
  State<_GrantDialog> createState() => _GrantDialogState();
}

class _GrantDialogState extends State<_GrantDialog> {
  final _api = AdminApi.instance;
  final _q = TextEditingController();
  final _note = TextEditingController();
  List<Map<String, dynamic>> _users = const [];
  Map<String, dynamic>? _user;
  List<Map<String, dynamic>> _bonds = const [];
  Map<String, dynamic>? _bond;
  String _plan = 'together';
  int _months = 1;
  Timer? _deb;

  @override
  void dispose() {
    _deb?.cancel();
    _q.dispose();
    _note.dispose();
    super.dispose();
  }

  void _search(String v) {
    _deb?.cancel();
    _deb = Timer(const Duration(milliseconds: 300), () async {
      try {
        final r = await _api.get(
            '/admin/api/users?q=${Uri.encodeQueryComponent(v.trim())}');
        if (!mounted) return;
        setState(() => _users = ((r['users'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .take(6)
            .toList());
      } catch (_) {}
    });
  }

  Future<void> _pick(Map<String, dynamic> u) async {
    setState(() {
      _user = u;
      _bond = null;
      _bonds = const [];
    });
    try {
      final r = await _api.get('/admin/api/billing/users/${u['id']}/bonds');
      if (!mounted) return;
      setState(() => _bonds = ((r['bonds'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList());
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final c = context.adm;
    final pair = _plan == 'space_plus';
    final ready = _user != null && (!pair || _bond != null);
    return AlertDialog(
      title: const Text('Give a plan'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'together', label: Text('Together')),
                  ButtonSegment(
                      value: 'space_plus', label: Text('Bigger Our Space')),
                ],
                selected: {_plan},
                onSelectionChanged: (s) => setState(() => _plan = s.first),
              ),
              const SizedBox(height: 12),
              if (_user == null) ...[
                TextField(
                  controller: _q,
                  autofocus: true,
                  onChanged: _search,
                  decoration: InputDecoration(
                    labelText: 'Find the person',
                    prefixIcon: const Icon(Icons.search_rounded),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Radii.md)),
                  ),
                ),
                for (final u in _users)
                  ListTile(
                    dense: true,
                    title: Text('${u['username']}'),
                    subtitle: Text('${u['email'] ?? ''}',
                        style: TextStyle(color: c.muted)),
                    onTap: () => _pick(u),
                  ),
              ] else
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.person_rounded),
                  title: Text('${_user!['username']}'),
                  trailing: TextButton(
                      onPressed: () => setState(() => _user = null),
                      child: const Text('Change')),
                ),
              if (_user != null && pair) ...[
                const SizedBox(height: 6),
                Text('Which pair?', style: TextStyle(color: c.muted)),
                if (_bonds.isEmpty)
                  Text('They have no 1:1 Our Space yet.',
                      style: TextStyle(color: c.faint)),
                for (final b in _bonds)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                        identical(_bond, b)
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: identical(_bond, b) ? kAdminRed : c.faint),
                    onTap: () => setState(() => _bond = b),
                    title: Text('with ${b['partner']}'),
                    subtitle: b['space_plus_until'] == null
                        ? null
                        : Text('Has it until ${_day(b['space_plus_until'] as String?)}'),
                  ),
              ],
              const SizedBox(height: 10),
              DropdownButtonFormField<int>(
                initialValue: _months,
                decoration: InputDecoration(
                    labelText: 'How long',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Radii.md))),
                items: [
                  for (final m in const [1, 2, 3, 6, 12])
                    DropdownMenuItem(
                        value: m,
                        child: Text(m == 12 ? '12 months' : '$m month(s)')),
                ],
                onChanged: (v) => setState(() => _months = v ?? 1),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _note,
                decoration: InputDecoration(
                    labelText: 'Note (only you see it)',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Radii.md))),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: !ready
              ? null
              : () => Navigator.pop(context, <String, dynamic>{
                    'plan_code': _plan,
                    'months': _months,
                    'user_id': _user!['id'],
                    if (pair) 'partner_id': _bond!['partner_id'],
                    if (_note.text.trim().isNotEmpty) 'note': _note.text.trim(),
                    'label': pair
                        ? '${_user!['username']} & ${_bond!['partner']}'
                        : '${_user!['username']}',
                  }),
          child: const Text('Next'),
        ),
      ],
    );
  }
}

class _PlanDialog extends StatefulWidget {
  const _PlanDialog({required this.plan});
  final Map<String, dynamic> plan;
  @override
  State<_PlanDialog> createState() => _PlanDialogState();
}

class _PlanDialogState extends State<_PlanDialog> {
  late final _name = TextEditingController(text: '${widget.plan['name']}');
  late final _price =
      TextEditingController(text: '${widget.plan['price_tzs']}');
  late final _year =
      TextEditingController(text: '${widget.plan['year_months']}');
  late final _mb = TextEditingController(text: '${widget.plan['space_mb'] ?? ''}');
  late bool _active = widget.plan['active'] == true;

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    _year.dispose();
    _mb.dispose();
    super.dispose();
  }

  InputDecoration _dec(String l, [String? helper]) => InputDecoration(
      labelText: l,
      helperText: helper,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.md)));

  @override
  Widget build(BuildContext context) {
    final price = int.tryParse(_price.text.replaceAll(',', '')) ?? 0;
    final year = int.tryParse(_year.text) ?? 12;
    final space = widget.plan['code'] == 'space_plus';
    return AlertDialog(
      title: Text('Edit ${widget.plan['name']}'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: _name, decoration: _dec('Name')),
            const SizedBox(height: 10),
            TextField(
              controller: _price,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {}),
              decoration: _dec('Price a month (TZS)'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _year,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {}),
              decoration: _dec('12 months cost … months',
                  '= ${fmtTzs(price * year)} for a year'),
            ),
            if (space) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _mb,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: _dec('Our Space size (MB per pair)'),
              ),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _active,
              onChanged: (v) => setState(() => _active = v),
              title: const Text('On sale in the app'),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, <String, dynamic>{
            'name': _name.text.trim(),
            'price_tzs': price,
            'year_months': year,
            if (space && int.tryParse(_mb.text) != null)
              'space_mb': int.parse(_mb.text),
            'active': _active,
          }),
          child: const Text('Next'),
        ),
      ],
    );
  }
}

class _PayDialog extends StatefulWidget {
  const _PayDialog({required this.settings});
  final Map<String, dynamic> settings;
  @override
  State<_PayDialog> createState() => _PayDialogState();
}

class _PayDialogState extends State<_PayDialog> {
  late final _net =
      TextEditingController(text: '${widget.settings['pay_network'] ?? 'M-Pesa'}');
  late final _num =
      TextEditingController(text: '${widget.settings['pay_number'] ?? ''}');
  late final _name =
      TextEditingController(text: '${widget.settings['pay_name'] ?? ''}');
  late final _how =
      TextEditingController(text: '${widget.settings['instructions'] ?? ''}');

  @override
  void dispose() {
    _net.dispose();
    _num.dispose();
    _name.dispose();
    _how.dispose();
    super.dispose();
  }

  InputDecoration _dec(String l, [String? h]) => InputDecoration(
      labelText: l,
      helperText: h,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.md)));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Where people pay'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: _net, decoration: _dec('Network', 'e.g. M-Pesa')),
            const SizedBox(height: 10),
            TextField(
                controller: _num,
                decoration: _dec('Number', 'A Lipa number or phone number')),
            const SizedBox(height: 10),
            TextField(
                controller: _name,
                decoration: _dec('Name they’ll see when paying')),
            const SizedBox(height: 10),
            TextField(
                controller: _how,
                maxLines: 3,
                decoration: _dec('Extra steps (optional)')),
          ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, <String, dynamic>{
            'pay_network': _net.text.trim(),
            'pay_number': _num.text.trim(),
            'pay_name': _name.text.trim(),
            'instructions': _how.text.trim(),
          }),
          child: const Text('Next'),
        ),
      ],
    );
  }
}
