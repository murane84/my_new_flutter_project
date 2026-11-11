import 'package:flutter/foundation.dart' show ValueListenable, kIsWeb;
import 'package:flutter/material.dart';

import '../services/heart_lock.dart';
import '../services/moment_prefs.dart';
import '../services/quiet_hours.dart';
import '../services/last_seen_privacy.dart';
import '../services/status_privacy.dart';
import '../services/block_list.dart';
import '../services/contact_names.dart';
import '../widgets/person_avatar.dart';
import '../services/notif_service.dart'
    show requestWebNotifications, webNotificationsPermission;
import 'stories/status_audience_sheet.dart';
import '../services/song_insights.dart';
import '../utils/popup_shell.dart';
import '../widgets/welcome_tour.dart';
import '../utils/readable.dart' show accentInk;
import '../utils/radii.dart';
import '../utils/adaptive_sheet.dart';

/// Moments & nudges — every warm, app-initiated touch in one place, each with
/// its own switch. Everything here is on-device.
class MomentsSettingsScreen extends StatefulWidget {
  const MomentsSettingsScreen({super.key});

  @override
  State<MomentsSettingsScreen> createState() => _MomentsSettingsScreenState();
}

class _MomentsSettingsScreenState extends State<MomentsSettingsScreen> {
  bool _receipts = HeartLock.instance.sendReceipts;

  @override
  void initState() {
    super.initState();
    Future.wait([
      MomentPrefs.instance.load(),
      SongInsights.instance.load(),
      HeartLock.instance.init(),
      QuietHours.instance.load(),
      LastSeenPrivacy.instance.load(),
      StatusPrivacy.instance.load(),
    ]).then((_) {
      if (mounted) {
        setState(() => _receipts = HeartLock.instance.sendReceipts);
      }
    });
  }

  Widget _tile({
    required IconData icon,
    required String title,
    required String subtitle,
    required ValueListenable<bool> value,
    required ValueChanged<bool> onChanged,
  }) {
    return ValueListenableBuilder<bool>(
      valueListenable: value,
      builder: (context, on, _) => _row(icon, title, subtitle, on, onChanged),
    );
  }

  Widget _row(IconData icon, String title, String subtitle, bool on,
      ValueChanged<bool> onChanged) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.lg),
        child: SwitchListTile.adaptive(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.lg)),
          secondary: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Icon(icon, size: 19, color: accentInk(scheme)),
          ),
          title: Text(title,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
          subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
          value: on,
          onChanged: onChanged,
        ),
      ),
    );
  }

  String _hm(int m) => TimeOfDay(hour: m ~/ 60, minute: m % 60).format(context);

  Future<void> _pickTime(int current, Future<void> Function(int) save) async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
    );
    if (t != null) await save(t.hour * 60 + t.minute);
  }

  /// Quiet hours: the switch, then From / Until when it's on.
  Widget _quietHours() {
    final q = QuietHours.instance;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([q.on, q.from, q.to]),
      builder: (context, _) => Column(
        children: [
          _row(
            Icons.bedtime_rounded,
            'Quiet hours',
            q.on.value
                ? 'Music & Our Space alerts arrive silently '
                    '${_hm(q.from.value)}–${_hm(q.to.value)} · calls, '
                    'messages and mentions still ring'
                : 'Hush music & Our Space alerts at night',
            q.on.value,
            q.setOn,
          ),
          if (q.on.value)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                for (final (label, value, save) in [
                  ('From', q.from.value, q.setFrom),
                  ('Until', q.to.value, q.setTo),
                ])
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: OutlinedButton(
                        onPressed: () => _pickTime(value, save),
                        style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(44),
                            shape: const StadiumBorder()),
                        // Narrow phones: the time scales down, never wraps.
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('$label  ${_hm(value)}',
                              maxLines: 1,
                              softWrap: false,
                              style: TextStyle(color: accentInk(scheme))),
                        ),
                      ),
                    ),
                  ),
              ]),
            ),
        ],
      ),
    );
  }

  /// Who can see my last seen — and, the same way back, whose I can see.
  Widget _lastSeenPrivacy() {
    final lp = LastSeenPrivacy.instance;
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<String>(
      valueListenable: lp.mode,
      builder: (context, m, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Material(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(Radii.lg),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.visibility_rounded,
                      size: 20, color: accentInk(scheme)),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('Who can see my last seen',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ]),
                const SizedBox(height: 10),
                // Narrow phones: shorter labels so the three choices fit
                // on one line without wrapping or clipping.
                LayoutBuilder(builder: (context, box) {
                  final narrow = box.maxWidth < 300;
                  Widget label(String t) => FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(t, maxLines: 1, softWrap: false));
                  return SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<String>(
                      showSelectedIcon: false,
                      style: narrow
                          ? const ButtonStyle(
                              visualDensity: VisualDensity.compact,
                              padding: WidgetStatePropertyAll(
                                  EdgeInsets.symmetric(horizontal: 6)),
                            )
                          : null,
                      segments: [
                        ButtonSegment(
                            value: 'circle',
                            label: label(narrow ? 'Circle' : 'My circle')),
                        ButtonSegment(value: 'bonds', label: label('Bonds')),
                        ButtonSegment(value: 'nobody', label: label('Nobody')),
                      ],
                      selected: {m},
                      onSelectionChanged: (s) => lp.set(s.first),
                    ),
                  );
                }),
                const SizedBox(height: 8),
                Text(
                  switch (m) {
                    'bonds' =>
                      'Only your Our Space partners — and you see only theirs.',
                    'nobody' =>
                      "Nobody sees yours — and you won't see anyone's.",
                    _ => 'All your friends — and you see theirs.',
                  },
                  style: TextStyle(
                      fontSize: 12.5, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The people I've blocked, each with Unblock.
  void _openBlocked() {
    BlockList.instance.refresh();
    showAdaptiveSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
          child: ListenableBuilder(
            listenable: BlockList.instance,
            builder: (ctx, _) {
              final people = BlockList.instance.people;
              final scheme = Theme.of(ctx).colorScheme;
              return Column(mainAxisSize: MainAxisSize.min, children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: Text('Blocked',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                      "They aren't told. No messages, calls, status or "
                      'listening either way while blocked.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
                ),
                if (people.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('Nobody blocked',
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: people.length,
                      itemBuilder: (_, i) {
                        final p = people[i];
                        final id = (p['id'] as num).toInt();
                        final name = ContactNames.instance.displayName(
                            of: p,
                            registered: (p['username'] ?? 'User').toString());
                        return ListTile(
                          leading: PersonAvatar(
                              name: name,
                              avatar: p['avatar_url']?.toString()),
                          title: Text(name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: TextButton(
                            onPressed: () =>
                                BlockList.instance.toggle(ctx, id, name),
                            child: const Text('Unblock'),
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 8),
              ]);
            },
          ),
        ),
      ),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
        child: Text(t.toUpperCase(),
            style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.3,
                fontWeight: FontWeight.w800,
                color: Theme.of(context).colorScheme.primary)),
      );

  @override
  Widget build(BuildContext context) {
    final mp = MomentPrefs.instance;
    final si = SongInsights.instance;
    return AppPopupShell(
      title: 'Moments & nudges',
      icon: Icons.auto_awesome_rounded,
      // Same page shape as Profile: a full-width panel card between
      // the header and the footer / now-playing bar.
      edgeToEdge: true,
      builder: (ctx, isWide) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
        children: [
          _section('When you come back'),
          _tile(
            icon: Icons.waving_hand_rounded,
            title: 'Welcome-back cards',
            subtitle: 'Music still playing, or what you missed while away',
            value: mp.welcomeCards,
            onChanged: mp.setWelcome,
          ),
          _tile(
            icon: Icons.auto_awesome_rounded,
            title: 'Today’s glow',
            subtitle: 'One Glow card a day',
            value: mp.glowDaily,
            onChanged: mp.setGlowDaily,
          ),
          _section('Notifications'),
          // Web: the browser asks once; then Aluta can notify while its tab
          // is in the background (messages, calls, invites, Our Space…).
          if (kIsWeb)
            Builder(builder: (context) {
              final perm = webNotificationsPermission;
              final on = perm == 'granted';
              return _row(
                Icons.notifications_active_rounded,
                'Browser notifications',
                switch (perm) {
                  'granted' =>
                    'On — Aluta notifies you while its tab is in the background',
                  'denied' =>
                    'Blocked in your browser — allow notifications for this site in its settings',
                  'unsupported' => 'This browser can’t show notifications',
                  _ => 'Get messages, calls and invites when Aluta isn’t on screen',
                },
                on,
                (v) async {
                  if (!v || on) return;
                  await requestWebNotifications();
                  if (mounted) setState(() {});
                },
              );
            }),
          _quietHours(),
          _section('Privacy'),
          _lastSeenPrivacy(),
          // Who can see my status — My circle / Bonds only, + hide from…
          ValueListenableBuilder<String>(
            valueListenable: StatusPrivacy.instance.mode,
            builder: (context, _, _) => ValueListenableBuilder<Set<int>>(
              valueListenable: StatusPrivacy.instance.hidden,
              builder: (context, _, _) {
                final scheme = Theme.of(context).colorScheme;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Material(
                    color:
                        scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(Radii.lg),
                    child: ListTile(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(Radii.lg)),
                      leading: Icon(Icons.amp_stories_rounded,
                          color: accentInk(scheme)),
                      title: const Text('Who can see my status',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(StatusPrivacy.instance.summary),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => showStatusAudienceSheet(context),
                    ),
                  ),
                );
              },
            ),
          ),
          // People I've blocked — see and unblock them here.
          ListenableBuilder(
            listenable: BlockList.instance,
            builder: (context, _) {
              final scheme = Theme.of(context).colorScheme;
              final n = BlockList.instance.count;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Material(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(Radii.lg),
                  child: ListTile(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Radii.lg)),
                    leading: Icon(Icons.block_rounded, color: accentInk(scheme)),
                    title: const Text('Blocked',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(n == 0
                        ? 'Nobody — block from a chat or a profile'
                        : n == 1
                            ? '1 person'
                            : '$n people'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: _openBlocked,
                  ),
                ),
              );
            },
          ),
          _section('Music'),
          _tile(
            icon: Icons.graphic_eq_rounded,
            title: 'Music nudges',
            subtitle:
                'Songs on repeat, the feel strip and your Sunday recap · max one nudge a day',
            value: si.enabled,
            onChanged: si.setEnabled,
          ),
          _section('In your chats'),
          _tile(
            icon: Icons.nightlight_round,
            title: 'Little rituals',
            subtitle: 'Good night, anniversary, on-this-day and streak chips',
            value: mp.rituals,
            onChanged: mp.setRituals,
          ),
          _row(
            Icons.mark_email_read_rounded,
            'Heart opened receipts',
            _receipts
                ? 'They see “Opened” when you open their heart'
                : 'Your opening stays private',
            _receipts,
            (v) {
              setState(() => _receipts = v);
              HeartLock.instance.setSendReceipts(v);
            },
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: () => WelcomeTour.show(context),
            icon: const Icon(Icons.replay_rounded, size: 18),
            label: const Text('Replay the Aluta tour'),
            style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
                shape: const StadiumBorder()),
          ),
          const SizedBox(height: 10),
          Text(
            'What Aluta learns for these moments is kept with your account, so it '
            'follows you to a new phone. Your partner sees your week in music '
            'only if you share what you\u2019re listening to.',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 11.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
