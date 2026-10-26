import 'dart:async';

import 'package:flutter/material.dart';

import 'admin_api.dart';
import 'admin_devices.dart';
import 'admin_install.dart';
import 'admin_overview.dart';
import 'admin_widgets.dart';

/// Signed-in frame: Overview · Devices · Activity log, plus the always-there
/// "Lock admin" (Not me), the dark/light switch and sign-out.
class AdminShell extends StatefulWidget {
  const AdminShell({super.key, required this.session, required this.onSignOut});
  final Map<String, dynamic> session;
  final Future<void> Function() onSignOut;

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  int _tab = 0;
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
              blurRadius: 8,
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
    final pending = (_me?['pending_requests'] as num?)?.toInt() ?? 0;
    final pages = <Widget>[
      AdminOverview(onOpenDevices: () => setState(() => _tab = 1)),
      AdminDevicesPage(onChanged: _loadMe),
      const AdminAuditPage(),
    ];
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
          onAction: () => setState(() => _tab = 1),
        ),
    ];

    final body = Column(
      children: [
        ...banners,
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: AdminInstallCard(),
        ),
        Expanded(child: IndexedStack(index: _tab, children: pages)),
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
                  borderRadius: BorderRadius.circular(20),
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
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (v) {
              if (v == 'out') widget.onSignOut();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                enabled: false,
                child: Row(
                  children: [
                    const Icon(Icons.computer_rounded, size: 18),
                    const SizedBox(width: 10),
                    Text('This device: ${_device['name'] ?? '—'}',
                        style: const TextStyle(fontSize: 13)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'out',
                child: Row(
                  children: [
                    Icon(Icons.logout_rounded, size: 18),
                    SizedBox(width: 10),
                    Text('Sign out'),
                  ],
                ),
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
                    selectedIndex: _tab,
                    onDestinationSelected: (i) => setState(() => _tab = i),
                    labelType: NavigationRailLabelType.all,
                    minWidth: 88,
                    destinations: [
                      const NavigationRailDestination(
                          icon: Icon(Icons.space_dashboard_outlined),
                          selectedIcon: Icon(Icons.space_dashboard_rounded),
                          label: Text('Overview')),
                      NavigationRailDestination(
                          icon: navIcon(Icons.devices_outlined, badge: pending),
                          selectedIcon:
                              navIcon(Icons.devices_rounded, badge: pending),
                          label: const Text('Devices')),
                      const NavigationRailDestination(
                          icon: Icon(Icons.receipt_long_outlined),
                          selectedIcon: Icon(Icons.receipt_long_rounded),
                          label: Text('Activity log')),
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
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: [
                const NavigationDestination(
                    icon: Icon(Icons.space_dashboard_outlined),
                    selectedIcon: Icon(Icons.space_dashboard_rounded),
                    label: 'Overview'),
                NavigationDestination(
                    icon: navIcon(Icons.devices_outlined, badge: pending),
                    selectedIcon: navIcon(Icons.devices_rounded, badge: pending),
                    label: 'Devices'),
                const NavigationDestination(
                    icon: Icon(Icons.receipt_long_outlined),
                    selectedIcon: Icon(Icons.receipt_long_rounded),
                    label: 'Log'),
              ],
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
        borderRadius: BorderRadius.circular(14),
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
