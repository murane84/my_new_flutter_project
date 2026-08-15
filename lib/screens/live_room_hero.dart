import 'package:flutter/material.dart';

import '../utils/toast_helper.dart';

/// Front-end SHELL for the upcoming Listening Rooms (build stage C1).
///
/// It reserves the desktop "Live Room · Your Circle" slot at the top of the
/// conversation column and previews the concept — but there's no backend yet,
/// so the actions surface a "coming soon" toast. When C1 lands, an ACTIVE room
/// (live participants, now-playing, join/wave) replaces this empty-but-inviting
/// state in the same slot. Deliberately honest: no fake participants or mock
/// "now playing", just the promise + a call to action.
///
/// Desktop-only by placement (it's rendered only in the wide two-column
/// layout), so phones keep their single-stack list unchanged.
class LiveRoomHeroShell extends StatelessWidget {
  const LiveRoomHeroShell({super.key});

  void _comingSoon(BuildContext context) => showToast(
        context,
        'Listening Rooms are coming soon — you’ll start and join live '
        'sessions with your circle right here.',
        type: ToastType.info,
        duration: const Duration(seconds: 3),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.fromLTRB(6, 2, 0, 12),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        // Theme-adaptive: a neutral surface warmed with a touch of the accent,
        // so it reads as a "live" card in both light and dark without going
        // fully dark in light mode.
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.surfaceContainerHighest,
            scheme.primary.withAlpha(dark ? 46 : 24),
          ],
        ),
        border: Border.all(color: scheme.primary.withAlpha(90)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration:
                    BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
              ),
              const SizedBox(width: 7),
              Text(
                'LIVE ROOM · YOUR CIRCLE',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                  color: scheme.primary,
                ),
              ),
              const Spacer(),
              // Honest "not wired yet" marker.
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primary.withAlpha(28),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'SOON',
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                    color: scheme.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Listen together, in real time',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Start a room and your circle can drop in — no ads, and the app '
            'goes quiet the moment two people listen together.',
            style: TextStyle(
              fontSize: 12,
              height: 1.35,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.icon(
                onPressed: () => _comingSoon(context),
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('Start a room'),
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => _comingSoon(context),
                style: OutlinedButton.styleFrom(
                  foregroundColor: scheme.onSurface,
                  side: BorderSide(color: scheme.outlineVariant),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
                child: const Text('Wave 👋'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
