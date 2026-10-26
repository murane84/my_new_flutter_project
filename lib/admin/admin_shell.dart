import 'dart:async';

import 'package:flutter/material.dart';

import 'admin_api.dart';
import 'admin_devices.dart';
import 'admin_overview.dart';
import 'admin_widgets.dart';

/// Signed-in frame: Overview · Devices · Activity log, plus the always-there
/// "Lock admin" (Not me) and sign-out.
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
        icon: const Icon(Icons.lock_outline, color: kAdminRed),
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

  @override
  Widget build(BuildContext context) {
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
          color: const Color(0xFFF9A825),
          icon: Icons.hourglass_bottom,
          text: 'This device is read-only until '
              '${fmtDateTime(_device['probation_until'] as String?)} '
              '(new-device probation).',
        ),
      if (pending > 0)
        _Banner(
          color: kAdminRed,
          icon: Icons.devices_other,
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
        Expanded(child: IndexedStack(index: _tab, children: pages)),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF15151C),
        titleSpacing: 16,
        title: Row(
          children: [
            const Icon(Icons.shield_outlined, color: kAdminRed),
            const SizedBox(width: 10),
            const Text('Aluta Admin',
                style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(width: 12),
            if (owner != null && wide)
              Text('@${owner['username']}',
                  style: const TextStyle(color: Colors.white54, fontSize: 14)),
          ],
        ),
        actions: [
          Tooltip(
            message: 'Lock admin (not me)',
            child: IconButton(
              onPressed: _lockAdmin,
              icon: const Icon(Icons.lock_outline, color: kAdminRed),
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'out') widget.onSignOut();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                enabled: false,
                child: Text(
                  'This device: ${_device['name'] ?? '—'}',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const PopupMenuItem(value: 'out', child: Text('Sign out')),
            ],
          ),
        ],
      ),
      body: wide
          ? Row(
              children: [
                NavigationRail(
                  backgroundColor: const Color(0xFF15151C),
                  selectedIndex: _tab,
                  onDestinationSelected: (i) => setState(() => _tab = i),
                  labelType: NavigationRailLabelType.all,
                  destinations: const [
                    NavigationRailDestination(
                        icon: Icon(Icons.insights_outlined),
                        selectedIcon: Icon(Icons.insights),
                        label: Text('Overview')),
                    NavigationRailDestination(
                        icon: Icon(Icons.devices_outlined),
                        selectedIcon: Icon(Icons.devices),
                        label: Text('Devices')),
                    NavigationRailDestination(
                        icon: Icon(Icons.receipt_long_outlined),
                        selectedIcon: Icon(Icons.receipt_long),
                        label: Text('Activity log')),
                  ],
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
              destinations: const [
                NavigationDestination(
                    icon: Icon(Icons.insights_outlined), label: 'Overview'),
                NavigationDestination(
                    icon: Icon(Icons.devices_outlined), label: 'Devices'),
                NavigationDestination(
                    icon: Icon(Icons.receipt_long_outlined), label: 'Log'),
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
    return Material(
      color: color.withValues(alpha: 0.16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
            if (action != null)
              TextButton(onPressed: onAction, child: Text(action!)),
          ],
        ),
      ),
    );
  }
}
