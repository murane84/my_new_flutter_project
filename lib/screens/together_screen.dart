import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' hide TextDirection;

import 'api_service.dart';
import 'relationship_space_page.dart' show deriveSpaceName;
import '../utils/adaptive_sheet.dart';
import '../utils/session_events.dart';
import '../utils/toast_helper.dart';
import '../utils/popup_shell.dart';
import '../utils/radii.dart';

/// Aluta plans — Together (for me) and Bigger Our Space (for a pair).
///
/// Paying is mobile money: send the amount to the number shown, then type the
/// transaction code from the payment message. The Aluta team checks it and
/// confirms; the plan starts then (and this page updates by itself). Plans
/// deepen closeness — they never gate the basics, and when one runs out
/// nothing is deleted.
class TogetherScreen extends StatefulWidget {
  /// Called after the plan changes so the caller can refresh its cached state.
  final VoidCallback? onChanged;

  /// The status the opener already knows (from its cached plan), used to paint
  /// the correct state on the very first frame.
  final bool? initialTogether;

  /// Me — to name my Spaces ("You & Sam") in the Bigger Our Space list.
  final int? myUserId;

  const TogetherScreen(
      {super.key, this.onChanged, this.initialTogether, this.myUserId});

  @override
  State<TogetherScreen> createState() => _TogetherScreenState();
}

class _TogetherScreenState extends State<TogetherScreen> {
  Map<String, dynamic>? _plan;
  List<Map<String, dynamic>> _spaces = const [];
  final Map<int, Map<String, dynamic>> _spacePlan = {};

  bool get _isTogether => _plan != null
      ? _plan!['is_together'] == true
      : (widget.initialTogether ?? false);

  bool get _known => _plan != null || widget.initialTogether != null;

  static const Color _gold = Color(0xFFF6D77A);
  static const Color _ink = Color(0xFF3A2A00);

  static const List<(IconData, String, String)> _benefits = [
    (
      Icons.favorite_rounded,
      'More Our Spaces',
      'Pin several bonds — a partner, family, your closest friend — not just one.'
    ),
    (
      Icons.all_inclusive_rounded,
      'History kept forever',
      'Your moments, your song, your streak — never expire.'
    ),
    (
      Icons.palette_rounded,
      'Custom Space themes',
      'Give each bond its own colour and your own photo background.'
    ),
  ];

  @override
  void initState() {
    super.initState();
    SessionEvents.instance.planChanged.addListener(_onPlanChanged);
    _load();
  }

  @override
  void dispose() {
    SessionEvents.instance.planChanged.removeListener(_onPlanChanged);
    super.dispose();
  }

  void _onPlanChanged() {
    _load();
    widget.onChanged?.call();
  }

  Future<void> _load() async {
    final p = await ApiService().getPlan();
    final spaces = await ApiService().listSpaces();
    if (!mounted) return;
    setState(() {
      _plan = p;
      _spaces = [
        for (final s in spaces)
          if (((s['members'] as List?) ?? const []).length == 2) s
      ];
    });
    for (final s in _spaces) {
      final id = (s['id'] as num?)?.toInt();
      if (id == null) continue;
      final sp = await ApiService().getSpacePlan(id);
      if (!mounted) return;
      if (sp != null) setState(() => _spacePlan[id] = sp);
    }
  }

  Map<String, dynamic>? _planDef(String code) {
    for (final p in ((_plan?['plans'] as List?) ?? const []).whereType<Map>()) {
      if (p['code'] == code) return p.cast<String, dynamic>();
    }
    return null;
  }

  Map<String, dynamic> get _pay =>
      ((_plan?['pay'] as Map?)?.cast<String, dynamic>()) ?? const {};

  /// My latest payment for this plan (and pair), if it's waiting or was
  /// just turned down.
  Map<String, dynamic>? _latestPayment(String code, {int? partnerId}) {
    for (final p in ((_plan?['payments'] as List?) ?? const []).whereType<Map>()) {
      if (p['plan_code'] != code) continue;
      if (partnerId != null && (p['partner_id'] as num?)?.toInt() != partnerId) {
        continue;
      }
      return p.cast<String, dynamic>();
    }
    return null;
  }

  static String _tzs(num? n) =>
      'TZS ${NumberFormat.decimalPattern().format(n ?? 0)}';

  static String _date(String? iso) {
    final d = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
    return d == null ? '' : DateFormat('d MMM yyyy').format(d);
  }

  Future<void> _buy(String code, {int? spaceId, String? forWhom}) async {
    final def = _planDef(code);
    if (def == null) {
      showToast(context, 'This plan isn’t available right now',
          type: ToastType.info);
      return;
    }
    if ((_pay['pay_number'] ?? '').toString().isEmpty &&
        _pay['sandbox'] != true) {
      showToast(context, 'Payments open very soon — check back shortly',
          type: ToastType.info);
      return;
    }
    final sent = await showAdaptiveSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PaySheet(
          plan: def, pay: _pay, spaceId: spaceId, forWhom: forWhom),
    );
    if (sent == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppPopupShell(
      title: 'Aluta plans',
      icon: Icons.workspace_premium_rounded,
      edgeToEdge: true,
      builder: (context, isWide) => RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            _hero(scheme),
            const SizedBox(height: 18),
            for (final b in _benefits) _benefitRow(scheme, b),
            const SizedBox(height: 14),
            _levels(scheme),
            const SizedBox(height: 14),
            _status(scheme, 'together'),
            _status(scheme, 'together_plus'),
            _cta(scheme),
            const SizedBox(height: 28),
            _spaceSection(scheme),
            const SizedBox(height: 18),
            Center(
              child: Text(
                'Pay with ${_pay['pay_network'] ?? 'M-Pesa'} · confirmed by '
                'the Aluta team · nothing is ever deleted when a plan ends',
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hero(ColorScheme scheme) {
    final until = (_plan?['together_until'] ?? '').toString();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.xl),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3A2A00), Color(0xFF6E5410)],
        ),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: _gold,
              borderRadius: BorderRadius.circular(Radii.xl),
            ),
            child: const Text('TOGETHER',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                    color: _ink)),
          ),
          const SizedBox(height: 12),
          const Text(
            'Keep every bond — forever.',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            !_known
                ? 'Checking your plan…'
                : _isTogether
                    ? (_plan?['together_forever'] == true
                        ? 'You’re on Together. Thank you 💛'
                        : 'You’re on Together until ${_date(until)}. Thank you 💛')
                    : 'Upgrading deepens closeness — it never gates the basics.',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9), fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  Widget _benefitRow(ColorScheme scheme, (IconData, String, String) b) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Icon(b.$1, color: const Color(0xFFB88A12)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(b.$2,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                        color: scheme.onSurface)),
                const SizedBox(height: 2),
                Text(b.$3,
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.3,
                        color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// "Waiting for confirmation · QK7…" / "Couldn't confirm …" line.
  Widget _status(ColorScheme scheme, String code, {int? partnerId}) {
    final p = _latestPayment(code, partnerId: partnerId);
    if (p == null) return const SizedBox.shrink();
    final st = (p['status'] ?? '').toString();
    if (st == 'confirmed') return const SizedBox.shrink();
    final waiting = st == 'pending';
    final color = waiting ? const Color(0xFFB88A12) : scheme.error;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(children: [
        Icon(waiting ? Icons.hourglass_top_rounded : Icons.info_outline_rounded,
            size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            waiting
                ? 'Waiting for confirmation · ${_tzs(p['amount_tzs'] as num?)} · '
                    'code ${p['txn_code']}'
                : (p['note'] ?? 'We couldn’t confirm code ${p['txn_code']}')
                    .toString(),
            style: TextStyle(fontSize: 12.5, color: scheme.onSurface),
          ),
        ),
      ]),
    );
  }

  String get _level => (_plan?['level'] ?? (_isTogether ? 'together' : 'free'))
      .toString();

  static const _levelNames = {
    'free': 'Free',
    'together': 'Together',
    'together_plus': 'Plus',
  };

  String _amount(num? v, String unit) {
    final n = (v ?? 0).toInt();
    if (unit == 'on/off') return n == 0 ? '—' : '✓';
    if (n < 0) return '∞';
    return unit == 'MB' ? '$n MB' : unit == 'min' ? '$n min' : '$n';
  }

  /// Every section is open to everyone — this shows how much each level
  /// gives, with my column lit.
  Widget _levels(ColorScheme scheme) {
    final meters = ((_plan?['meters'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    final table =
        (_plan?['limits_table'] as Map?)?.cast<String, dynamic>() ?? const {};
    if (meters.isEmpty || table.isEmpty) return const SizedBox.shrink();
    const levels = ['free', 'together', 'together_plus'];
    final mine = _level;
    Widget cell(String text, {bool head = false, bool lit = false}) => Expanded(
          flex: 3,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 7),
            color: lit ? _gold.withValues(alpha: 0.16) : null,
            child: Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: head ? 12 : 12.5,
                    fontWeight:
                        head || lit ? FontWeight.w800 : FontWeight.w500,
                    color: head ? scheme.onSurfaceVariant : scheme.onSurface)),
          ),
        );
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Row(children: [
          Expanded(
            flex: 5,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 7, 4, 7),
              child: Text('Everyone can use it all',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurfaceVariant)),
            ),
          ),
          for (final l in levels)
            cell(_levelNames[l]!, head: true, lit: l == mine),
        ]),
        for (final m in meters)
          Row(children: [
            Expanded(
              flex: 5,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 7, 4, 7),
                child: Text('${m['label']}',
                    style: TextStyle(fontSize: 12, color: scheme.onSurface)),
              ),
            ),
            for (final l in levels)
              cell(
                  _amount((table[l] as Map?)?[m['key']] as num?,
                      '${m['unit']}'),
                  lit: l == mine),
          ]),
      ]),
    );
  }

  Widget _cta(ColorScheme scheme) {
    if (!_known) {
      return const Center(
          child: Padding(
              padding: EdgeInsets.all(12),
              child: CircularProgressIndicator(strokeWidth: 2)));
    }
    final t = _planDef('together');
    final p = _planDef('together_plus');
    final lvl = _level;
    String price(Map<String, dynamic>? d) =>
        d == null ? '' : ' · ${_tzs(d['price_tzs'] as num?)}/mo';
    final plusUntil = (_plan?['plus_until'] ?? '').toString();
    return Column(children: [
      if (lvl != 'together_plus' && t != null)
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor:
                  lvl == 'together' ? scheme.surfaceContainerHighest : _gold,
              foregroundColor: lvl == 'together' ? scheme.onSurface : _ink,
              padding: const EdgeInsets.symmetric(vertical: 15),
            ),
            onPressed: () => _buy('together'),
            icon: Icon(lvl == 'together'
                ? Icons.add_circle_outline_rounded
                : Icons.workspace_premium_rounded),
            label: Text(
                lvl == 'together'
                    ? 'Add more Together time${price(t)}'
                    : 'Start Together${price(t)}',
                style:
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          ),
        ),
      if (p != null) ...[
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFB88A12),
              side: const BorderSide(color: Color(0xFFB88A12)),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: () => _buy('together_plus'),
            icon: const Icon(Icons.all_inclusive_rounded),
            label: Text(
                lvl == 'together_plus'
                    ? 'Add more Plus time${price(p)}'
                    : 'Go Together Plus${price(p)}',
                style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
        ),
        if (lvl == 'together_plus' && plusUntil.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Plus until ${_date(plusUntil)}',
                style: TextStyle(
                    fontSize: 12, color: scheme.onSurfaceVariant)),
          ),
      ],
    ]);
  }

  Widget _spaceSection(ColorScheme scheme) {
    final def = _planDef('space_plus');
    if (def == null) return const SizedBox.shrink();
    final mb = (def['space_mb'] as num?)?.toInt() ?? 1024;
    final size = mb >= 1024 ? '${(mb / 1024).toStringAsFixed(mb % 1024 == 0 ? 0 : 1)} GB' : '$mb MB';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Icon(Icons.favorite_rounded, color: Color(0xFFE8173F)),
          const SizedBox(width: 8),
          Expanded(
            child: Text('${def['name']}',
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface)),
          ),
          Text('${_tzs(def['price_tzs'] as num?)} / month',
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: 4),
        Text(
            '$size of keepsakes for the two of you — photos, videos, voice '
            'notes. One of you pays; you both get it. A gift they’ll feel.',
            style: TextStyle(
                fontSize: 12.5, height: 1.3, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 10),
        if (_spaces.isEmpty)
          Text('Pin someone in Our Space first.',
              style: TextStyle(color: scheme.onSurfaceVariant)),
        for (final s in _spaces) _spaceRow(scheme, s),
      ],
    );
  }

  Widget _spaceRow(ColorScheme scheme, Map<String, dynamic> s) {
    final id = (s['id'] as num?)?.toInt();
    final name = deriveSpaceName(s, widget.myUserId);
    final sp = id == null ? null : _spacePlan[id];
    final active = sp?['active'] == true;
    int? partnerId;
    for (final m in ((s['members'] as List?) ?? const []).whereType<Map>()) {
      final mid = (m['id'] as num?)?.toInt() ?? (m['user_id'] as num?)?.toInt();
      if (mid != null && mid != widget.myUserId) partnerId = mid;
    }
    final free = ((sp?['free_cap_bytes'] as num?) ?? 0) / (1024 * 1024);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(children: [
        _status(scheme, 'space_plus', partnerId: partnerId),
        Material(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(Radii.lg),
          child: ListTile(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Radii.lg)),
            leading: Icon(
                active ? Icons.verified_rounded : Icons.favorite_border_rounded,
                color: const Color(0xFFE8173F)),
            title: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontWeight: FontWeight.w700, color: scheme.onSurface)),
            subtitle: Text(
                sp == null
                    ? ' '
                    : active
                        ? (sp['until'] == null
                            ? 'Bigger Our Space is on'
                            : 'Bigger until ${_date(sp['until'] as String?)}')
                        : 'Free · ${free.round()} MB',
                style: TextStyle(color: scheme.onSurfaceVariant)),
            trailing: FilledButton.tonal(
              onPressed: id == null
                  ? null
                  : () => _buy('space_plus', spaceId: id, forWhom: name),
              child: Text(active ? 'Add time' : 'Get it'),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Pay with mobile money: choose 1 or 12 months → send the amount to the
/// number shown → type the transaction code from the payment message.
class _PaySheet extends StatefulWidget {
  const _PaySheet(
      {required this.plan, required this.pay, this.spaceId, this.forWhom});
  final Map<String, dynamic> plan;
  final Map<String, dynamic> pay;
  final int? spaceId;
  final String? forWhom;

  @override
  State<_PaySheet> createState() => _PaySheetState();
}

class _PaySheetState extends State<_PaySheet> {
  int _months = 1;
  final _code = TextEditingController();
  final _phone = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    _phone.dispose();
    super.dispose();
  }

  int get _amount => _months == 12
      ? ((widget.plan['year_price_tzs'] as num?) ?? 0).toInt()
      : ((widget.plan['price_tzs'] as num?) ?? 0).toInt();

  bool get _codeOk =>
      RegExp(r'^[A-Za-z0-9]{6,20}$').hasMatch(_code.text.replaceAll(RegExp(r'[^A-Za-z0-9]'), ''));

  Future<void> _send() async {
    setState(() => _busy = true);
    final (ok, msg) = await ApiService().reportPayment(
      planCode: '${widget.plan['code']}',
      months: _months,
      txnCode: _code.text,
      payerPhone: _phone.text.trim(),
      spaceId: widget.spaceId,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    showToast(context, msg, type: ok ? ToastType.success : ToastType.error);
    if (ok) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tzs = NumberFormat.decimalPattern();
    final net = (widget.pay['pay_network'] ?? 'M-Pesa').toString();
    final number = (widget.pay['pay_number'] ?? '').toString();
    final name = (widget.pay['pay_name'] ?? '').toString();
    final extra = (widget.pay['instructions'] ?? '').toString();
    final yearMonths = (widget.plan['year_months'] as num?)?.toInt() ?? 12;
    Widget choice(int m, String label, String sub) {
      final on = _months == m;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _months = m),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
            decoration: BoxDecoration(
              color: on
                  ? scheme.primary.withValues(alpha: 0.12)
                  : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(Radii.md),
              border: Border.all(
                  color: on ? scheme.primary : scheme.outlineVariant,
                  width: on ? 1.6 : 1),
            ),
            child: Column(children: [
              Text(label,
                  style: TextStyle(
                      fontWeight: FontWeight.w800, color: scheme.onSurface)),
              Text(sub,
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
            ]),
          ),
        ),
      );
    }

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${widget.plan['name']}',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface)),
              if (widget.forWhom != null)
                Text('For ${widget.forWhom}',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              if (widget.pay['sandbox'] == true) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF42A5F5).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(Radii.md),
                  ),
                  child: Text(
                      'Test mode — no real money moves. Type any code '
                      '(e.g. TEST123456) to try it; the Aluta team confirms '
                      'it like a real one.',
                      style: TextStyle(fontSize: 12.5, color: scheme.onSurface)),
                ),
              ],
              const SizedBox(height: 14),
              Row(children: [
                choice(1, '1 month', 'TZS ${tzs.format(widget.plan['price_tzs'] ?? 0)}'),
                const SizedBox(width: 10),
                choice(
                    12,
                    '12 months',
                    'TZS ${tzs.format(widget.plan['year_price_tzs'] ?? 0)}'
                        '${yearMonths < 12 ? '\n${12 - yearMonths} months free' : ''}'),
              ]),
              const SizedBox(height: 16),
              _step(scheme, '1',
                  'Send TZS ${tzs.format(_amount)} with $net to', [
                Row(children: [
                  Expanded(
                    child: SelectableText(number.isEmpty ? '—' : number,
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            color: scheme.onSurface)),
                  ),
                  IconButton(
                    tooltip: 'Copy number',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: number));
                      showToast(context, 'Number copied');
                    },
                    icon: const Icon(Icons.copy_rounded, size: 20),
                  ),
                ]),
                if (name.isNotEmpty)
                  Text('Name shown: $name',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                if (extra.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(extra,
                      style: TextStyle(
                          fontSize: 12.5, color: scheme.onSurfaceVariant)),
                ],
              ]),
              const SizedBox(height: 14),
              _step(scheme, '2', 'Type the code from your payment message', [
                TextField(
                  controller: _code,
                  textCapitalization: TextCapitalization.characters,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'e.g. QK71AB2CDE',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Radii.md)),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    hintText: 'The phone you paid from (optional)',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Radii.md)),
                    isDense: true,
                  ),
                ),
              ]),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy || !_codeOk ? null : _send,
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14)),
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Send for confirmation',
                        style: TextStyle(fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 8),
              Text(
                'The Aluta team checks the payment and switches it on — '
                'you’ll get a notification. Paying early adds on to the time '
                'you already have.',
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _step(ColorScheme scheme, String n, String title,
      List<Widget> children) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      CircleAvatar(
        radius: 12,
        backgroundColor: scheme.primary,
        child: Text(n,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: scheme.onPrimary)),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                      fontWeight: FontWeight.w700, color: scheme.onSurface)),
              const SizedBox(height: 6),
              ...children,
            ]),
      ),
    ]);
  }
}
