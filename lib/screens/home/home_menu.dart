part of '../home_page.dart';

// Split out of home_page.dart (pure code-movement, no behaviour change):
// header overflow menu (grouped submenus). A private extension on HomePageState — a library `part`, so it
// shares the file's imports and reaches every private field/method. None
// of these methods call setState directly, so the extension stays clear of
// @protected members.

extension _HomeMenu on HomePageState {
  // One row of the header overflow menu (icon + label).
  // ── Overflow menu (grouped genie menu with inline submenus) ──────────────

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
    // Genie menu (widgets/genie_menu.dart): grows out of the ⋮ button and
    // folds back into it; submenus open inline with the same motion.
    return GenieMenuButton(
      icon: Icon(Icons.more_vert_rounded, color: scheme.onSurface),
      tooltip: 'Menu',
      width: 252,
      entries: () => [
        // Monetization lives at the TOP LEVEL so the upgrade is one tap away.
        GenieMenuEntry(
          icon: _isTogether
              ? Icons.workspace_premium_rounded
              : Icons.favorite_border_rounded,
          label: _isTogether ? 'Together ✓' : 'Aluta Together',
          onTap: _openTogether,
        ),
        GenieMenuEntry(
          icon: Icons.groups_rounded,
          label: 'Groups',
          onTap: () async {
            final conv = await showAppPopup<Map<String, dynamic>>(
                context, const GroupsScreen());
            if (conv != null && mounted) openGroupInPanel(conv);
          },
        ),
        // Friends — the two "grow your circle" actions together.
        GenieMenuEntry(
          icon: Icons.group_add_rounded,
          label: 'Friends',
          children: [
            GenieMenuEntry(
                icon: Icons.contacts_rounded,
                label: 'Find friends',
                onTap: () => _findFriendsFromContacts()),
            GenieMenuEntry(
                icon: Icons.person_add_alt_1_rounded,
                label: 'Add friend',
                onTap: () => _showAddFriend()),
          ],
        ),
        // Devices — QR linking + the linked-devices manager.
        GenieMenuEntry(
          icon: Icons.devices_rounded,
          label: 'Devices',
          children: [
            if (mobile)
              GenieMenuEntry(
                icon: Icons.laptop_chromebook_rounded,
                label: 'Link a computer',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const DeviceLinkScanScreen()),
                ),
              ),
            GenieMenuEntry(
              icon: Icons.devices_other_rounded,
              label: 'Linked devices',
              onTap: () => showAppPopup(context, const LinkedDevicesScreen()),
            ),
          ],
        ),
        // Tools — a small submenu on mobile; on desktop Identify song sits at
        // the top level (Call reliability is mobile-only).
        if (mobile)
          GenieMenuEntry(
            icon: Icons.tune_rounded,
            label: 'Tools',
            children: [
              GenieMenuEntry(
                  icon: Icons.hearing_rounded,
                  label: 'Identify song',
                  onTap: () => showSongIdentifier(context)),
              GenieMenuEntry(
                icon: Icons.phonelink_ring_rounded,
                label: 'Call reliability',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const CallReliabilityScreen()),
                ),
              ),
            ],
          )
        else
          GenieMenuEntry(
              icon: Icons.hearing_rounded,
              label: 'Identify song',
              onTap: () => showSongIdentifier(context)),
        // Account — profile, personalization, backup and legal together.
        GenieMenuEntry(
          icon: Icons.account_circle_outlined,
          label: 'Account',
          children: [
            GenieMenuEntry(
              icon: Icons.person_rounded,
              label: 'Profile',
              onTap: () async {
                await showAppPopup(context, const ProfileScreen());
                if (mounted) _loadUserData();
              },
            ),
            GenieMenuEntry(
                icon: Icons.palette_outlined,
                label: 'Appearance',
                onTap: () =>
                    showAppPopup(context, const AppearanceScreen())),
            GenieMenuEntry(
                icon: Icons.auto_awesome_rounded,
                label: 'Moments & nudges',
                onTap: () =>
                    showAppPopup(context, const MomentsSettingsScreen())),
            GenieMenuEntry(
                icon: Icons.lock_outline_rounded,
                label: 'Backup & restore',
                onTap: () => showAppPopup(context, const BackupScreen())),
            GenieMenuEntry(
                icon: Icons.shield_outlined,
                label: 'Legal & About',
                onTap: () => showLegalMenu(context)),
          ],
        ),
        const GenieMenuEntry.divider(),
        GenieMenuEntry(
            icon: Icons.logout_rounded,
            label: 'Sign out',
            onTap: _logout,
            destructive: true),
      ],
    );
  }
}
