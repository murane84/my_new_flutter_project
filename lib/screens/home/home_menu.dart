part of '../home_page.dart';

// Split out of home_page.dart (pure code-movement, no behaviour change):
// header overflow menu (grouped submenus). A private extension on HomePageState — a library `part`, so it
// shares the file's imports and reaches every private field/method. None
// of these methods call setState directly, so the extension stays clear of
// @protected members.

extension _HomeMenu on HomePageState {
  // One row of the header overflow menu (icon + label).
  // ── Overflow menu (grouped, MenuAnchor with submenus) ─────────────────────

  /// The header overflow menu, grouped by intent so it scales as features grow:
  /// Aluta Together (monetization, top level for visibility), Groups, then the
  /// Friends / Devices / Tools / Account parent submenus, and Sign out. Actions
  /// live with their kin (both "add a friend" flows under Friends; profile +
  /// appearance + legal under Account) rather than piling into one tall list.
  /// On desktop, Tools' only applicable action is Identify song, so it surfaces
  /// at the top level instead of sitting alone in a one-item submenu.
  Widget _buildOverflowMenu(
      BuildContext context, ThemeProvider themeProvider, ColorScheme scheme) {
    final bool mobile = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    final menuStyle = MenuStyle(
      backgroundColor: WidgetStatePropertyAll(scheme.surface),
      elevation: const WidgetStatePropertyAll(10),
      // Faint red hairline so the menu (and each submenu) lifts off the UI.
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
              color: scheme.primary.withAlpha(70), width: 1),
        ),
      ),
      padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 6, horizontal: 4)),
    );

    return MenuAnchor(
      style: menuStyle,
      builder: (ctx, controller, child) => IconButton(
        icon: Icon(Icons.more_vert_rounded, color: scheme.onSurface),
        tooltip: 'Menu',
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
      menuChildren: [
        // Monetization lives at the TOP LEVEL so the upgrade is one tap from the
        // menu — it used to be buried two levels deep under Tools & settings.
        _menuBtn(
            scheme,
            _isTogether
                ? Icons.workspace_premium_rounded
                : Icons.favorite_border_rounded,
            _isTogether ? 'Together ✓' : 'Aluta Together',
            _openTogether),
        _menuBtn(scheme, Icons.groups_rounded, 'Groups', () async {
          final conv = await showAppPopup<Map<String, dynamic>>(
              context, const GroupsScreen());
          if (conv != null && mounted) openGroupInPanel(conv);
        }),
        // Friends — the two "grow your circle" actions grouped together (they
        // were the same intent split across two flat Tools entries).
        SubmenuButton(
          menuStyle: menuStyle,
          leadingIcon: Icon(Icons.group_add_rounded,
              size: 20, color: scheme.primary),
          menuChildren: [
            _menuBtn(scheme, Icons.contacts_rounded, 'Find friends',
                () => _findFriendsFromContacts()),
            _menuBtn(scheme, Icons.person_add_alt_1_rounded, 'Add friend',
                () => _showAddFriend()),
          ],
          child: const Text('Friends'),
        ),
        // Devices — QR linking + the linked-devices manager.
        SubmenuButton(
          menuStyle: menuStyle,
          leadingIcon: Icon(Icons.devices_rounded,
              size: 20, color: scheme.primary),
          menuChildren: [
            if (mobile)
              _menuBtn(scheme, Icons.laptop_chromebook_rounded,
                  'Link a computer', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const DeviceLinkScanScreen()),
                );
              }),
            _menuBtn(scheme, Icons.devices_other_rounded, 'Linked devices',
                () {
              showAppPopup(context, const LinkedDevicesScreen());
            }),
          ],
          child: const Text('Devices'),
        ),
        // Tools — on mobile a small submenu (Identify song + Call reliability,
        // which is mobile-only). On desktop Call reliability doesn't apply, so
        // Identify song sits directly at the top level rather than alone in a
        // one-item submenu.
        if (mobile)
          SubmenuButton(
            menuStyle: menuStyle,
            leadingIcon:
                Icon(Icons.tune_rounded, size: 20, color: scheme.primary),
            menuChildren: [
              _menuBtn(scheme, Icons.hearing_rounded, 'Identify song',
                  () => showSongIdentifier(context)),
              _menuBtn(scheme, Icons.phonelink_ring_rounded,
                  'Call reliability', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const CallReliabilityScreen()),
                );
              }),
            ],
            child: const Text('Tools'),
          )
        else
          _menuBtn(scheme, Icons.hearing_rounded, 'Identify song',
              () => showSongIdentifier(context)),
        // Account — you + your app: your profile, personalization, and the
        // legal/about info, all under one parent as requested.
        SubmenuButton(
          menuStyle: menuStyle,
          leadingIcon: Icon(Icons.account_circle_outlined,
              size: 20, color: scheme.primary),
          menuChildren: [
            _menuBtn(scheme, Icons.person_rounded, 'Profile', () async {
              await showAppPopup(context, const ProfileScreen());
              if (mounted) _loadUserData();
            }),
            _menuBtn(scheme, Icons.palette_outlined, 'Appearance',
                () => showAppPopup(context, const AppearanceScreen())),
            _menuBtn(scheme, Icons.shield_outlined, 'Legal & About',
                () => showLegalMenu(context)),
          ],
          child: const Text('Account'),
        ),
        const Divider(height: 10),
        _menuBtn(scheme, Icons.logout_rounded, 'Sign out', _logout,
            destructive: true),
      ],
    );
  }

  MenuItemButton _menuBtn(
      ColorScheme scheme, IconData icon, String label, VoidCallback onPressed,
      {bool destructive = false}) {
    final accent = destructive ? scheme.error : scheme.primary;
    return MenuItemButton(
      leadingIcon: Icon(icon, size: 20, color: accent),
      onPressed: onPressed,
      child: Text(
        label,
        style: destructive ? TextStyle(color: scheme.error) : null,
      ),
    );
  }
}
