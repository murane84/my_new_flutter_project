import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../services/song_insights.dart';

/// Under the now-playing card: how this song feels to you, and — from that
/// feeling — who it's for. Pick 😍 and it offers "Send to Belyner 💞" and
/// "Together"; 🥹 offers a heart; 💪 sharing; 😌 keeps it with your calm
/// songs; 💔 only ever offers a hand ("Talk to …"), never a push to share.
/// The same SongInsights memory the chat nudges use — music and chat in
/// one harmony. Hidden when Music nudges are off.
class SongFeelStrip extends StatefulWidget {
  const SongFeelStrip(
      {super.key, required this.title, this.artist = '', required this.accent});
  final String title;
  final String artist;
  final Color accent;

  @override
  State<SongFeelStrip> createState() => _SongFeelStripState();
}

class _SongFeelStripState extends State<SongFeelStrip> {
  bool _choosing = false;

  @override
  void initState() {
    super.initState();
    SongInsights.instance.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(SongFeelStrip old) {
    super.didUpdateWidget(old);
    if (old.title != widget.title) _choosing = false;
  }

  void _pick(SongFeel f) {
    HapticFeedback.selectionClick();
    SongInsights.instance.setFeel(widget.title, f);
    setState(() => _choosing = false);
  }

  Widget _pill(String text,
      {VoidCallback? onTap, bool strong = false, IconData? icon}) {
    final a = widget.accent;
    final on = Theme.of(context).colorScheme.onSurface;
    return Material(
      color: strong ? a.withValues(alpha: 0.16) : on.withValues(alpha: 0.05),
      shape: StadiumBorder(
          side: BorderSide(
              color: strong
                  ? a.withValues(alpha: 0.45)
                  : on.withValues(alpha: 0.12))),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: strong ? a : on.withValues(alpha: 0.7)),
              const SizedBox(width: 4),
            ],
            Text(text,
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: strong ? a : on.withValues(alpha: 0.75))),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final si = SongInsights.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([si.enabled, si.feelsRev]),
      builder: (context, _) {
        final on = si.enabled.value;
        if (!on || widget.title.trim().isEmpty) return const SizedBox.shrink();
        final feel = si.feelOf(widget.title);
        final b = SongBridge.instance;
        final partner = b.partnerName?.call();
        final hasP = partner != null && partner.isNotEmpty;
        final on2 = Theme.of(context).colorScheme.onSurface;
        Widget child;
        if (feel == null || _choosing) {
          child = Row(
            key: const ValueKey('choose'),
            children: [
              Text('How does this feel?',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: on2.withValues(alpha: 0.6))),
              const Spacer(),
              for (final f in SongFeel.values)
                Tooltip(
                  message: f.label,
                  child: InkResponse(
                    onTap: () => _pick(f),
                    radius: 18,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: AnimatedScale(
                        scale: feel == f ? 1.2 : 1,
                        duration: const Duration(milliseconds: 160),
                        child: Text(f.emoji,
                            style: const TextStyle(fontSize: 19)),
                      ),
                    ),
                  ),
                ),
            ],
          );
        } else {
          final actions = <Widget>[];
          final t = widget.title;
          switch (feel) {
            case SongFeel.love:
              actions.add(hasP
                  ? _pill('Send to $partner 💞',
                      strong: true,
                      onTap: () => b.messagePartner
                          ?.call(text: '“$t” reminds me of you 💞'))
                  : _pill('Share 🎶',
                      strong: true, onTap: () => b.shareCurrent?.call()));
              if (hasP) {
                actions.add(_pill('Together',
                    icon: Icons.headphones_rounded,
                    onTap: () => b.listenTogether?.call()));
              }
              break;
            case SongFeel.missing:
              if (hasP) {
                actions.add(_pill('Send $partner a heart 💌',
                    strong: true,
                    onTap: () => b.messagePartner?.call(
                        text: '“$t” made me miss you 🥹', heart: true, mood: 'miss')));
                actions.add(_pill('Together',
                    icon: Icons.headphones_rounded,
                    onTap: () => b.listenTogether?.call()));
              }
              break;
            case SongFeel.hyped:
              actions.add(_pill('Share the energy 🎶',
                  strong: true, onTap: () => b.shareCurrent?.call()));
              break;
            case SongFeel.calm:
              actions.add(_pill('In your calm songs 🌙'));
              break;
            case SongFeel.hurting:
              if (hasP) {
                actions.add(_pill('Talk to $partner',
                    icon: Icons.chat_bubble_rounded,
                    onTap: () => b.messagePartner?.call()));
              }
              break;
          }
          child = Row(
            key: ValueKey('feel_${feel.key}'),
            children: [
              _pill('${feel.emoji} ${feel.label}',
                  onTap: () => setState(() => _choosing = true)),
              const SizedBox(width: 6),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Row(children: [
                    for (final a in actions) ...[
                      a,
                      const SizedBox(width: 6),
                    ],
                  ]),
                ),
              ),
            ],
          );
        }
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: child,
        );
      },
    );
  }
}
