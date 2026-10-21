import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../services/song_insights.dart';

/// How this song feels to you — and, from that feeling, who it's for.
/// 😍 → "Send to Belyner 💞" · Together; 🥹 → a heart; 💪 → share the energy;
/// 😌 → kept with your calm songs; 💔 → only ever a hand ("Talk to …").
/// One SongInsights memory shared with the chat nudges, so music and chat
/// move in harmony. Hidden when Music nudges are off.
///
/// [centered] lays it out for the full NOW PLAYING screen; [onLeave] runs
/// before an action that opens a chat / Space (e.g. pop the full player).
class SongFeelStrip extends StatefulWidget {
  const SongFeelStrip({
    super.key,
    required this.title,
    this.artist = '',
    required this.accent,
    this.centered = false,
    this.onLeave,
  });
  final String title;
  final String artist;
  final Color accent;
  final bool centered;
  final VoidCallback? onLeave;

  @override
  State<SongFeelStrip> createState() => _SongFeelStripState();
}

class _SongFeelStripState extends State<SongFeelStrip> {
  bool _choosing = false;
  SongFeel? _justPicked;

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
    if (old.title != widget.title) {
      _choosing = false;
      _justPicked = null;
    }
  }

  void _pick(SongFeel f) {
    HapticFeedback.selectionClick();
    SongInsights.instance.setFeel(widget.title, f);
    setState(() {
      _choosing = false;
      _justPicked = f;
    });
  }

  void _go(VoidCallback? fn) {
    if (fn == null) return;
    widget.onLeave?.call();
    fn();
  }

  // ── pieces ───────────────────────────────────────────────────────────────
  Widget _emoji(SongFeel f, bool selected) {
    final a = widget.accent;
    final size = widget.centered ? 44.0 : 36.0;
    return Tooltip(
      message: f.label,
      child: GestureDetector(
        onTap: () => _pick(f),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: size,
          height: size,
          margin: EdgeInsets.symmetric(horizontal: widget.centered ? 5 : 2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected
                ? a.withValues(alpha: 0.22)
                : Colors.white.withValues(alpha: 0.0),
            border: Border.all(
                color: selected
                    ? a.withValues(alpha: 0.6)
                    : a.withValues(alpha: 0.14)),
          ),
          alignment: Alignment.center,
          child: Text(f.emoji,
              style: TextStyle(fontSize: widget.centered ? 22 : 18)),
        ),
      ),
    );
  }

  Widget _pill(String text,
      {VoidCallback? onTap, bool strong = false, IconData? icon}) {
    final a = widget.accent;
    final on = Theme.of(context).colorScheme.onSurface;
    final fg = strong ? Colors.white : on.withValues(alpha: 0.8);
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: strong
              ? LinearGradient(colors: [
                  Color.lerp(a, Colors.white, 0.18)!,
                  a,
                ])
              : null,
          color: strong ? null : on.withValues(alpha: 0.05),
          border: strong
              ? null
              : Border.all(color: on.withValues(alpha: 0.12)),
          boxShadow: strong
              ? [
                  BoxShadow(
                      color: a.withValues(alpha: 0.3),
                      blurRadius: 10,
                      offset: const Offset(0, 3))
                ]
              : null,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(
                horizontal: 12, vertical: widget.centered ? 8 : 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: fg),
                const SizedBox(width: 5),
              ],
              Text(text,
                  style: TextStyle(
                      fontSize: widget.centered ? 13 : 12,
                      fontWeight: FontWeight.w700,
                      color: fg)),
            ]),
          ),
        ),
      ),
    );
  }

  List<Widget> _actions(SongFeel feel) {
    final b = SongBridge.instance;
    final partner = b.partnerName?.call();
    final hasP = partner != null && partner.isNotEmpty;
    final canShare = b.canShare?.call() ?? false;
    final t = widget.title;
    final out = <Widget>[];
    switch (feel) {
      case SongFeel.love:
        if (hasP) {
          out.add(_pill('Send to $partner',
              icon: Icons.favorite_rounded,
              strong: true,
              onTap: () => _go(() => b.messagePartner
                  ?.call(text: '“$t” reminds me of you 💞'))));
          out.add(_pill('Together',
              icon: Icons.headphones_rounded,
              onTap: () => _go(b.listenTogether)));
        } else if (canShare) {
          out.add(_pill('Share',
              icon: Icons.send_rounded,
              strong: true,
              onTap: () => _go(b.shareCurrent)));
        }
        break;
      case SongFeel.missing:
        if (hasP) {
          out.add(_pill('Send $partner a heart',
              icon: Icons.mark_email_unread_rounded,
              strong: true,
              onTap: () => _go(() => b.messagePartner?.call(
                  text: '“$t” made me miss you 🥹',
                  heart: true,
                  mood: 'miss'))));
          out.add(_pill('Together',
              icon: Icons.headphones_rounded,
              onTap: () => _go(b.listenTogether)));
        }
        break;
      case SongFeel.hyped:
        if (canShare) {
          out.add(_pill('Share the energy',
              icon: Icons.bolt_rounded,
              strong: true,
              onTap: () => _go(b.shareCurrent)));
        } else if (hasP) {
          out.add(_pill('Tell $partner',
              icon: Icons.bolt_rounded,
              strong: true,
              onTap: () => _go(() => b.messagePartner
                  ?.call(text: '“$t” has me hyped 💪🎶'))));
        }
        break;
      case SongFeel.calm:
        out.add(_pill('Kept with your calm songs', icon: Icons.spa_rounded));
        break;
      case SongFeel.hurting:
        if (hasP) {
          out.add(_pill('Talk to $partner',
              icon: Icons.chat_bubble_rounded,
              strong: true,
              onTap: () => _go(() => b.messagePartner?.call())));
        } else {
          out.add(_pill('Be gentle with yourself 💗'));
        }
        break;
    }
    return out;
  }

  Widget _frame(Widget child) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: EdgeInsets.symmetric(
              horizontal: 12, vertical: widget.centered ? 10 : 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            color: isDark
                ? Colors.white.withValues(alpha: 0.05)
                : Colors.white.withValues(alpha: 0.55),
            border:
                Border.all(color: widget.accent.withValues(alpha: 0.18)),
          ),
          child: child,
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
        if (!si.enabled.value || widget.title.trim().isEmpty) {
          return const SizedBox.shrink();
        }
        final feel = si.feelOf(widget.title);
        final on = Theme.of(context).colorScheme.onSurface;
        Widget body;
        if (feel == null || _choosing) {
          final label = Text(
            feel == null ? 'How does this song feel?' : 'Change the feeling',
            style: TextStyle(
                fontSize: widget.centered ? 13 : 12,
                fontWeight: FontWeight.w700,
                color: on.withValues(alpha: 0.65)),
          );
          final row = Row(
            mainAxisSize: MainAxisSize.min,
            children: [for (final f in SongFeel.values) _emoji(f, feel == f)],
          );
          body = widget.centered
              ? Column(
                  key: const ValueKey('choose'),
                  mainAxisSize: MainAxisSize.min,
                  children: [label, const SizedBox(height: 8), row],
                )
              : Row(
                  key: const ValueKey('choose'),
                  children: [
                    Expanded(child: label),
                    FittedBox(child: row),
                  ],
                );
        } else {
          final chosen = GestureDetector(
            onTap: () => setState(() => _choosing = true),
            child: TweenAnimationBuilder<double>(
              key: ValueKey('pop_${feel.key}_${_justPicked?.key}'),
              tween: Tween(begin: _justPicked == feel ? 0.6 : 1, end: 1),
              duration: const Duration(milliseconds: 420),
              curve: Curves.elasticOut,
              builder: (_, s, child) =>
                  Transform.scale(scale: s, child: child),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(feel.emoji,
                    style: TextStyle(fontSize: widget.centered ? 22 : 18)),
                const SizedBox(width: 6),
                Text(feel.label,
                    style: TextStyle(
                        fontSize: widget.centered ? 13.5 : 12.5,
                        fontWeight: FontWeight.w800,
                        color: on.withValues(alpha: 0.85))),
                const SizedBox(width: 4),
                Icon(Icons.edit_rounded,
                    size: 12, color: on.withValues(alpha: 0.4)),
              ]),
            ),
          );
          final acts = _actions(feel);
          body = widget.centered
              ? Column(
                  key: ValueKey('feel_${feel.key}'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    chosen,
                    if (acts.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: acts,
                      ),
                    ],
                  ],
                )
              : Row(
                  key: ValueKey('feel_${feel.key}'),
                  children: [
                    chosen,
                    const SizedBox(width: 10),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        reverse: true,
                        child: Row(children: [
                          for (final a in acts) ...[
                            a,
                            const SizedBox(width: 6),
                          ],
                        ]),
                      ),
                    ),
                  ],
                );
        }
        return _frame(AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: body,
          ),
        ));
      },
    );
  }
}
