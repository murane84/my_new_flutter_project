import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

/// One action on a [showMomentCard].
class MomentAction {
  const MomentAction(this.icon, this.label, this.onTap,
      {this.primary = false, this.emoji});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;
  /// Shown instead of [icon] (mood chips: 😍 🥹 💪 😌 💔).
  final String? emoji;
}

OverlayEntry? _current;

/// A warm, frosted card that drops in from the top for a few seconds — the
/// app noticing a moment (e.g. you came back with music still playing).
/// Swipe up or tap ✕ to dismiss; an action dismisses it too. Only one at a
/// time. Text is set by the caller (see AlutaMood.musicWelcome).
void showMomentCard(
  BuildContext context, {
  required String title,
  String? subtitle,
  IconData leading = Icons.music_note_rounded,
  List<MomentAction> actions = const [],
  Duration hold = const Duration(seconds: 9),
  // Closed (timeout / ✕ / swipe) without tapping any action.
  VoidCallback? onIgnored,
  // Tapping the card itself (not a button) — e.g. open the full details.
  VoidCallback? onTap,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _current?.remove();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _MomentCard(
      title: title,
      subtitle: subtitle,
      leading: leading,
      actions: actions,
      hold: hold,
      onIgnored: onIgnored,
      onTap: onTap,
      onGone: () {
        if (identical(_current, entry)) _current = null;
        if (entry.mounted) entry.remove();
      },
    ),
  );
  _current = entry;
  overlay.insert(entry);
}

class _MomentCard extends StatefulWidget {
  const _MomentCard({
    required this.title,
    required this.subtitle,
    required this.leading,
    required this.actions,
    required this.hold,
    required this.onGone,
    this.onIgnored,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final IconData leading;
  final List<MomentAction> actions;
  final Duration hold;
  final VoidCallback onGone;
  final VoidCallback? onIgnored;
  final VoidCallback? onTap;

  @override
  State<_MomentCard> createState() => _MomentCardState();
}

class _MomentCardState extends State<_MomentCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 420));
  Timer? _timer;
  double _drag = 0;
  bool _leaving = false;
  bool _acted = false;
  // Tap a card whose words don't fit → it opens up in place to the full
  // text and stays until dismissed (no auto-hide while you read).
  bool _expanded = false;
  bool _canExpand = false; // set each build: is any text cut off?

  void _toggleExpand() {
    HapticFeedback.selectionClick();
    setState(() => _expanded = !_expanded);
    _timer?.cancel();
    if (!_expanded) _timer = Timer(widget.hold, _leave);
  }

  @override
  void initState() {
    super.initState();
    _in.forward();
    HapticFeedback.lightImpact();
    _timer = Timer(widget.hold, _leave);
  }

  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    _timer?.cancel();
    if (!_acted) widget.onIgnored?.call();
    if (mounted) await _in.reverse();
    widget.onGone();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final top = MediaQuery.paddingOf(context).top + 10;
    final ink = isDark ? Colors.white : const Color(0xFF2B2829);
    return Positioned(
      top: top,
      left: 12,
      right: 12,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: AnimatedBuilder(
            animation: _in,
            builder: (_, child) {
              final t = Curves.easeOutBack.transform(_in.value.clamp(0, 1));
              return Opacity(
                opacity: _in.value.clamp(0.0, 1.0),
                child: Transform.translate(
                  offset: Offset(0, -40 * (1 - t) + _drag),
                  child: child,
                ),
              );
            },
            child: GestureDetector(
              // A card with its own details view opens that; any other card
              // expands in place when its text was cut off.
              onTap: widget.onTap != null
                  ? () {
                      _acted = true;
                      _leave();
                      widget.onTap!();
                    }
                  : () {
                      if (_canExpand || _expanded) _toggleExpand();
                    },
              onVerticalDragUpdate: (d) {
                setState(() => _drag = (_drag + d.delta.dy).clamp(-120, 12));
              },
              onVerticalDragEnd: (d) {
                if (_drag < -30 || (d.primaryVelocity ?? 0) < -300) {
                  _leave();
                } else {
                  setState(() => _drag = 0);
                }
              },
              child: Material(
                type: MaterialType.transparency,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(12, 12, 6, 10),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.black.withValues(alpha: 0.55)
                            : Colors.white.withValues(alpha: 0.82),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                            color: scheme.primary.withValues(alpha: 0.35)),
                        boxShadow: [
                          BoxShadow(
                            color: scheme.primary.withValues(alpha: 0.18),
                            blurRadius: 24,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _Pulse(color: scheme.primary, icon: widget.leading),
                              const SizedBox(width: 10),
                              Expanded(
                                child: LayoutBuilder(builder: (ctx, c) {
                                  final titleStyle = TextStyle(
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.w800,
                                      height: 1.25,
                                      color: ink);
                                  final subStyle = TextStyle(
                                      fontSize: 12,
                                      height: 1.35,
                                      color: ink.withValues(alpha: 0.6));
                                  bool cut(String t, TextStyle st, int lines) {
                                    final tp = TextPainter(
                                      text: TextSpan(text: t, style: st),
                                      maxLines: lines,
                                      textDirection: Directionality.of(ctx),
                                    )..layout(maxWidth: c.maxWidth);
                                    return tp.didExceedMaxLines;
                                  }

                                  // Does anything not fit? Then the card can
                                  // open up (or has its own details view).
                                  final more = widget.onTap != null ||
                                      cut(widget.title, titleStyle, 3) ||
                                      (widget.subtitle != null &&
                                          cut(widget.subtitle!, subStyle, 1));
                                  _canExpand = more && widget.onTap == null;
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(widget.title,
                                          maxLines: _expanded ? null : 3,
                                          overflow: _expanded
                                              ? TextOverflow.visible
                                              : TextOverflow.ellipsis,
                                          style: titleStyle),
                                      if (widget.subtitle != null) ...[
                                        const SizedBox(height: 2),
                                        AnimatedSize(
                                          duration: const Duration(
                                              milliseconds: 220),
                                          curve: Curves.easeOutCubic,
                                          alignment: Alignment.topLeft,
                                          child: Text(widget.subtitle!,
                                              maxLines: _expanded ? null : 1,
                                              overflow: _expanded
                                                  ? TextOverflow.visible
                                                  : TextOverflow.ellipsis,
                                              style: subStyle),
                                        ),
                                      ],
                                      if (more) ...[
                                        const SizedBox(height: 3),
                                        Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                  widget.onTap != null
                                                      ? 'Tap to see all'
                                                      : (_expanded
                                                          ? 'Tap to fold'
                                                          : 'Tap to read all'),
                                                  style: TextStyle(
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      color: scheme.primary)),
                                              Icon(
                                                  widget.onTap != null
                                                      ? Icons
                                                          .chevron_right_rounded
                                                      : (_expanded
                                                          ? Icons
                                                              .expand_less_rounded
                                                          : Icons
                                                              .expand_more_rounded),
                                                  size: 15,
                                                  color: scheme.primary),
                                            ]),
                                      ],
                                    ],
                                  );
                                }),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                tooltip: 'Dismiss',
                                icon: Icon(Icons.close_rounded,
                                    size: 18,
                                    color: ink.withValues(alpha: 0.5)),
                                onPressed: _leave,
                              ),
                            ],
                          ),
                          if (widget.actions.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                for (final a in widget.actions)
                                  a.primary
                                      ? FilledButton.icon(
                                          onPressed: () {
                                            _acted = true;
                                            _leave();
                                            a.onTap();
                                          },
                                          icon: a.emoji != null
                                              ? Text(a.emoji!,
                                                  style: const TextStyle(
                                                      fontSize: 15))
                                              : Icon(a.icon, size: 16),
                                          label: Text(a.label),
                                          style: FilledButton.styleFrom(
                                              visualDensity:
                                                  VisualDensity.compact,
                                              shape: const StadiumBorder()),
                                        )
                                      : OutlinedButton.icon(
                                          onPressed: () {
                                            _acted = true;
                                            _leave();
                                            a.onTap();
                                          },
                                          icon: a.emoji != null
                                              ? Text(a.emoji!,
                                                  style: const TextStyle(
                                                      fontSize: 15))
                                              : Icon(a.icon, size: 16),
                                          label: Text(a.label),
                                          style: OutlinedButton.styleFrom(
                                              visualDensity:
                                                  VisualDensity.compact,
                                              shape: const StadiumBorder()),
                                        ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The leading disc: the icon over a soft, slow double pulse.
class _Pulse extends StatefulWidget {
  const _Pulse({required this.color, required this.icon});
  final Color color;
  final IconData icon;
  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1600))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) {
          final t = _c.value;
          return Stack(alignment: Alignment.center, children: [
            Container(
              width: 30 + 10 * t,
              height: 30 + 10 * t,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color.withValues(alpha: 0.22 * (1 - t)),
              ),
            ),
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [
                  Color.lerp(widget.color, Colors.white, 0.2)!,
                  widget.color,
                ]),
              ),
              child: Icon(widget.icon, size: 17, color: Colors.white),
            ),
          ]);
        },
      ),
    );
  }
}
