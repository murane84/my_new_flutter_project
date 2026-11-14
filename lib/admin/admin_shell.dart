import 'dart:async';

import 'package:flutter/material.dart';

import '../widgets/genie_menu.dart';

import 'admin_api.dart';
import 'admin_billing.dart';
import 'admin_devices.dart';
import 'admin_feedback.dart';
import 'admin_install.dart';
import 'admin_overview.dart';
import 'admin_users.dart';
import 'admin_widgets.dart';
import '../utils/radii.dart';
import '../utils/depth.dart';

// ── Navigation: groups → pages ─────────────────────────────────────────────
// The rail / bottom bar show GROUPS only (a handful, however many tools
// arrive); a group with several pages gets a slim tab strip on top of its
// page, and the ⋮ menu opens each group as a flyout. A new tool = one
// _AdminPage line in the right group (or a new group) — nothing else.

/// One page of the admin.
class _AdminPage {
  const _AdminPage(this.id, this.label, this.icon, this.iconSel,
      {this.badge = _noBadge, this.badgeWord = ''});
  final String id;
  final String label;
  final IconData icon, iconSel;
  final int Function(_AdminShellState s) badge;
  final String badgeWord; // "Devices · 1 waiting", "Feedback · 2 new"
  static int _noBadge(_AdminShellState s) => 0;
}

/// A group of pages (one rail / bottom-bar destination).
class _AdminGroup {
  const _AdminGroup(this.label, this.icon, this.iconSel, this.pages);
  final String label;
  final IconData icon, iconSel;
  final List<_AdminPage> pages;
  int badge(_AdminShellState s) =>
      pages.fold(0, (sum, p) => sum + p.badge(s));
}

int _pendingBadge(_AdminShellState s) => s._pending;
int _feedbackBadge(_AdminShellState s) => s._newFeedback;
int _paymentsBadge(_AdminShellState s) => s._newPayments;

const _groups = <_AdminGroup>[
  _AdminGroup('Insights', Icons.insights_outlined, Icons.insights_rounded, [
    _AdminPage('overview', 'Overview', Icons.space_dashboard_outlined,
        Icons.space_dashboard_rounded),
    _AdminPage('usage', 'Usage', Icons.show_chart_rounded,
        Icons.show_chart_rounded),
  ]),
  _AdminGroup('People', Icons.people_alt_outlined, Icons.people_alt_rounded, [
    _AdminPage('people', 'People', Icons.people_alt_outlined,
        Icons.people_alt_rounded),
    _AdminPage('feedback', 'Feedback', Icons.rate_review_outlined,
        Icons.rate_review_rounded,
        badge: _feedbackBadge,
        badgeWord: 'new'),
  ]),
  _AdminGroup('Money', Icons.payments_outlined, Icons.payments_rounded, [
    _AdminPage('money', 'Overview', Icons.payments_outlined,
        Icons.payments_rounded),
    _AdminPage('payments', 'Payments', Icons.receipt_outlined,
        Icons.receipt_rounded,
        badge: _paymentsBadge,
        badgeWord: 'to check'),
    _AdminPage('subscribers', 'Subscribers',
        Icons.workspace_premium_outlined, Icons.workspace_premium_rounded),
    _AdminPage('prices', 'Prices', Icons.sell_outlined, Icons.sell_rounded),
  ]),
  _AdminGroup('Security', Icons.shield_outlined, Icons.shield_rounded, [
    _AdminPage('devices', 'Devices', Icons.devices_outlined,
        Icons.devices_rounded,
        badge: _pendingBadge,
        badgeWord: 'waiting'),
    _AdminPage('log', 'Activity log', Icons.receipt_long_outlined,
        Icons.receipt_long_rounded),
  ]),
  _AdminGroup('System', Icons.dns_outlined, Icons.dns_rounded, [
    _AdminPage('system', 'Health', Icons.monitor_heart_outlined,
        Icons.monitor_heart_rounded),
    _AdminPage('storage', 'Storage', Icons.storage_outlined,
        Icons.storage_rounded),
    _AdminPage('cleanup', 'Clean-up', Icons.cleaning_services_outlined,
        Icons.cleaning_services_rounded),
  ]),
];

/// Signed-in frame: the page groups (Insights · People · Money · Security ·
/// System), plus the always-there "Lock admin" (Not me), the dark/light
/// switch and sign-out.
class AdminShell extends StatefulWidget {
  const AdminShell({super.key, required this.session, required this.onSignOut});
  final Map<String, dynamic> session;
  final Future<void> Function() onSignOut;

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  int _group = 0;
  // The page last open in each group (coming back to a group lands there).
  final Map<int, int> _pageIn = <int, int>{};
  int get _pending => (_me?['pending_requests'] as num?)?.toInt() ?? 0;
  int get _newFeedback => (_me?['new_feedback'] as num?)?.toInt() ?? 0;
  int get _newPayments => (_me?['pending_payments'] as num?)?.toInt() ?? 0;

  int _pageOf(int g) =>
      (_pageIn[g] ?? 0).clamp(0, _groups[g].pages.length - 1);

  /// Open a page by id (from banners, cards, the ⋮ menu).
  void _go(String id) {
    for (var g = 0; g < _groups.length; g++) {
      final i = _groups[g].pages.indexWhere((p) => p.id == id);
      if (i >= 0) {
        setState(() {
          _group = g;
          _pageIn[g] = i;
        });
        return;
      }
    }
  }

  Widget _pageWidget(String id) => switch (id) {
        'overview' =>
          AdminOverview(onOpenDevices: () => _go('devices')),
        'usage' => AdminOverview(
            view: AdminMetricsView.usage,
            onOpenDevices: () => _go('devices')),
        'system' => AdminOverview(
            view: AdminMetricsView.system,
            onOpenDevices: () => _go('devices')),
        'storage' => AdminOverview(
            view: AdminMetricsView.storage,
            onOpenDevices: () => _go('devices')),
        'cleanup' => AdminOverview(
            view: AdminMetricsView.cleanup,
            onOpenDevices: () => _go('devices')),
        'devices' => AdminDevicesPage(onChanged: _loadMe),
        'feedback' => AdminFeedbackPage(onChanged: _loadMe),
        'people' => const AdminUsersPage(),
        'money' => AdminBillingPage(onChanged: _loadMe),
        'payments' => AdminBillingPage(
            view: AdminBillingView.payments, onChanged: _loadMe),
        'subscribers' => AdminBillingPage(
            view: AdminBillingView.subscribers, onChanged: _loadMe),
        'prices' => AdminBillingPage(
            view: AdminBillingView.prices, onChanged: _loadMe),
        'log' => const AdminAuditPage(),
        _ => const SizedBox.shrink(),
      };
  Map<String, dynamic>? _me;
  Timer? _meTimer;

  @override
  void initState() {
    super.initState();
    _loadMe();
    _meTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      if (!AdminApi.instance.userIdle) _loadMe();
    });
  }

  @override
  void dispose() {
    _meTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadMe() async {
    try {
      final me = await AdminApi.instance.get('/admin/api/me');
      if (mounted) setState(() => _me = me);
    } catch (_) {}
  }

  Map<String, dynamic> get _device =>
      ((_me?['device'] ?? widget.session['device']) as Map?)
          ?.cast<String, dynamic>() ??
      const {};

  Future<void> _lockAdmin() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const AdminIconChip(
            icon: Icons.lock_rounded, color: kAdminRed, size: 44),
        title: const Text('Lock admin now?'),
        content: const Text(
          'Use this if anything looks wrong. It ends every admin session '
          '(including this one), cancels pending requests and removes devices '
          'still on probation. To unlock: change your Aluta password in the '
          'app, then sign in here from a trusted device.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kAdminRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Lock admin'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await AdminApi.instance.post('/admin/api/lock-now');
    } catch (_) {}
    AdminApi.instance.forget();
    await widget.onSignOut();
  }

  Widget _brandMark() => Container(
        width: 36,
        height: 36,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: Depth.sm,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Image.asset(
          'assets/images/logo.png',
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) =>
              const Icon(Icons.shield_rounded, color: kAdminRed, size: 20),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final p = context.adm;
    final owner = (widget.session['owner'] as Map?)?.cast<String, dynamic>();
    final probation = _device['on_probation'] == true;
    final pending = _pending;
    // Every page stays alive (as before): one flat stack, in group order.
    final flat = [for (final g in _groups) ...g.pages];
    final pages = [for (final pg in flat) _pageWidget(pg.id)];
    final group = _groups[_group];
    final page = group.pages[_pageOf(_group)];
    final stackIndex = flat.indexOf(page);
    final wide = MediaQuery.sizeOf(context).width >= 840;

    final banners = <Widget>[
      if (probation)
        _Banner(
          color: const Color(0xFFFFA000),
          icon: Icons.hourglass_bottom_rounded,
          text: 'This device is read-only until '
              '${fmtDateTime(_device['probation_until'] as String?)} '
              '(new-device probation).',
        ),
      if (pending > 0)
        _Banner(
          color: kAdminRed,
          icon: Icons.devices_other_rounded,
          text: pending == 1
              ? 'A device is asking for admin access.'
              : '$pending devices are asking for admin access.',
          action: 'Review',
          onAction: () => _go('devices'),
        ),
    ];

    final body = Column(
      children: [
        ...banners,
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: AdminInstallCard(),
        ),
        if (group.pages.length > 1)
          _SubTabs(
            pages: group.pages,
            selected: _pageOf(_group),
            badgeOf: (pg) => pg.badge(this),
            onSelect: (i) => setState(() => _pageIn[_group] = i),
          ),
        Expanded(child: IndexedStack(index: stackIndex, children: pages)),
      ],
    );

    Widget navIcon(IconData i, {int badge = 0}) => Badge(
          isLabelVisible: badge > 0,
          label: Text('$badge'),
          backgroundColor: kAdminRed,
          child: Icon(i),
        );

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        shape: Border(bottom: BorderSide(color: p.border)),
        title: Row(
          children: [
            _brandMark(),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Aluta',
                    style: TextStyle(
                        color: p.text,
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                        letterSpacing: 1.5)),
                const Text('ADMIN',
                    style: TextStyle(
                        color: kAdminRed,
                        fontWeight: FontWeight.w700,
                        fontSize: 10,
                        letterSpacing: 3)),
              ],
            ),
            if (owner != null && wide) ...[
              const SizedBox(width: 16),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: p.card2,
                  borderRadius: BorderRadius.circular(Radii.xl),
                  border: Border.all(color: p.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.verified_user_rounded,
                        size: 14, color: p.muted),
                    const SizedBox(width: 6),
                    Text('@${owner['username']}',
                        style: TextStyle(color: p.muted, fontSize: 13)),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          IconButton(
            tooltip: p.dark ? 'Light mode' : 'Dark mode',
            onPressed: toggleAdminTheme,
            icon: Icon(p.dark
                ? Icons.light_mode_rounded
                : Icons.dark_mode_rounded),
          ),
          IconButton(
            tooltip: 'Lock admin (not me)',
            onPressed: _lockAdmin,
            icon: const Icon(Icons.lock_rounded, color: kAdminRed),
          ),
          // Same genie menu as the Aluta app: grows out of ⋮, folds back in.
          GenieMenuButton(
            icon: Icon(Icons.more_vert_rounded, color: p.text),
            tooltip: 'Menu',
            width: 260,
            entries: () => [
              GenieMenuEntry(
                icon: Icons.computer_rounded,
                label: 'This device · ${_device['name'] ?? '—'}',
                enabled: false,
              ),
              const GenieMenuEntry.divider(),
              // One row per group; its pages open as a flyout (a submenu
              // on phones) — the menu never grows past the groups.
              for (var g = 0; g < _groups.length; g++)
                if (_groups[g].pages.length == 1)
                  GenieMenuEntry(
                    icon: _groups[g].iconSel,
                    label: _groups[g].label,
                    onTap: () => _go(_groups[g].pages.first.id),
                  )
                else
                  GenieMenuEntry(
                    icon: _groups[g].iconSel,
                    label: _groups[g].badge(this) > 0
                        ? '${_groups[g].label} · ${_groups[g].badge(this)}'
                        : _groups[g].label,
                    children: [
                      for (final pg in _groups[g].pages)
                        GenieMenuEntry(
                          icon: pg.iconSel,
                          label: pg.badge(this) > 0
                              ? '${pg.label} · ${pg.badge(this)} ${pg.badgeWord}'
                                  .trim()
                              : pg.label,
                          onTap: () => _go(pg.id),
                        ),
                    ],
                  ),
              const GenieMenuEntry.divider(),
              GenieMenuEntry(
                icon: p.dark
                    ? Icons.light_mode_rounded
                    : Icons.dark_mode_rounded,
                label: p.dark ? 'Light mode' : 'Dark mode',
                onTap: toggleAdminTheme,
              ),
              GenieMenuEntry(
                icon: Icons.lock_rounded,
                label: 'Lock admin (not me)',
                destructive: true,
                onTap: _lockAdmin,
              ),
              GenieMenuEntry(
                icon: Icons.logout_rounded,
                label: 'Sign out',
                onTap: () => widget.onSignOut(),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: wide
          ? Row(
              children: [
                Container(
                  decoration: BoxDecoration(
                    border: Border(right: BorderSide(color: p.border)),
                  ),
                  child: NavigationRail(
                    selectedIndex: _group,
                    onDestinationSelected: (g) => setState(() => _group = g),
                    labelType: NavigationRailLabelType.all,
                    minWidth: 88,
                    destinations: [
                      for (final g in _groups)
                        NavigationRailDestination(
                            icon: navIcon(g.icon, badge: g.badge(this)),
                            selectedIcon:
                                navIcon(g.iconSel, badge: g.badge(this)),
                            label: Text(g.label)),
                    ],
                  ),
                ),
                Expanded(child: body),
              ],
            )
          : body,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _group,
              onDestinationSelected: (g) => setState(() => _group = g),
              destinations: [
                for (final g in _groups)
                  NavigationDestination(
                      icon: navIcon(g.icon, badge: g.badge(this)),
                      selectedIcon: navIcon(g.iconSel, badge: g.badge(this)),
                      label: g.label),
              ],
            ),
    );
  }
}

/// The pages of the open group — a slim strip of pills above the page.
class _SubTabs extends StatelessWidget {
  const _SubTabs({
    required this.pages,
    required this.selected,
    required this.badgeOf,
    required this.onSelect,
  });
  final List<_AdminPage> pages;
  final int selected;
  final int Function(_AdminPage) badgeOf;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final p = context.adm;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (var i = 0; i < pages.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _pill(p, pages[i], i == selected, badgeOf(pages[i]),
                    () => onSelect(i)),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _pill(AdminPalette p, _AdminPage pg, bool on, int badge,
      VoidCallback tap) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.xl),
        onTap: on ? null : tap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: on ? kAdminRed.withValues(alpha: p.dark ? 0.18 : 0.10) : p.card2,
            borderRadius: BorderRadius.circular(Radii.xl),
            border: Border.all(
                color: on ? kAdminRed.withValues(alpha: 0.55) : p.border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(on ? pg.iconSel : pg.icon,
                size: 16, color: on ? kAdminRed : p.muted),
            const SizedBox(width: 6),
            Text(pg.label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                    color: on ? p.text : p.muted)),
            if (badge > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: kAdminRed,
                  borderRadius: BorderRadius.circular(Radii.xl),
                ),
                child: Text('$badge',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800)),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.color,
    required this.icon,
    required this.text,
    this.action,
    this.onAction,
  });
  final Color color;
  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final p = context.adm;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: p.dark ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          AdminIconChip(icon: icon, color: color, size: 28),
          const SizedBox(width: 10),
          Expanded(
              child: Text(text,
                  style: TextStyle(fontSize: 13, color: p.text))),
          if (action != null)
            TextButton(onPressed: onAction, child: Text(action!)),
        ],
      ),
    );
  }
}
