import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../services/heart_lock.dart';
import '../services/moment_prefs.dart';
import '../services/song_insights.dart';
import '../utils/popup_shell.dart';
import '../widgets/welcome_tour.dart';

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
        borderRadius: BorderRadius.circular(16),
        child: SwitchListTile.adaptive(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          secondary: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, size: 19, color: scheme.primary),
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
            'Everything Aluta learns for these moments stays on this phone.',
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
