part of '../home_page.dart';

// Self-contained visual leaf widgets pulled out of home_page.dart.
// Each reads its colours from the theme and takes only plain values +
// callbacks — no access to HomePageState. Behaviour is unchanged.

// ─── Small toggle button ───────────────────────────────────────────────────

class _PanelToggleBtn extends StatelessWidget {
  final bool isFullScreen;
  final VoidCallback onTap;
  final IconData? customIcon;
  final String? tooltip;

  const _PanelToggleBtn({
    required this.isFullScreen,
    required this.onTap,
    this.customIcon,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = tooltip ??
        (customIcon == Icons.keyboard_arrow_down_rounded
            ? 'Minimize'
            : (isFullScreen ? 'Exit full screen' : 'Full screen'));
    return Tooltip(
      message: label,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: isFullScreen
                ? scheme.primary
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(
            customIcon ??
                (isFullScreen
                    ? Icons.close_fullscreen_rounded
                    : Icons.open_in_full_rounded),
            size: 17,
            color:
                isFullScreen ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// A single-line label that gently auto-scrolls (marquee) ONLY when the text is
/// too wide to fit; short titles render as a plain static label. Used by the
/// now-playing bar so long song filenames stay fully readable without stealing
/// vertical space.
class _ScrollingText extends StatelessWidget {
  const _ScrollingText({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tp = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: 1,
          textDirection: TextDirection.ltr,
        )..layout();
        final overflows = tp.width > constraints.maxWidth;
        if (!overflows) {
          return Text(text,
              style: style, maxLines: 1, overflow: TextOverflow.clip);
        }
        return Marquee(
          text: text,
          style: style,
          blankSpace: 46,
          velocity: 26,
          pauseAfterRound: const Duration(seconds: 2),
          fadingEdgeStartFraction: 0.06,
          fadingEdgeEndFraction: 0.12,
          showFadingOnlyWhenScrolling: true,
        );
      },
    );
  }
}

/// A refined, thin-stroke logout mark — a rounded door frame with an arrow
/// gliding out through the opening. Lighter and more elegant than the stock
/// filled Material "exit" glyph. Kept for reuse (the header now uses a plain
/// menu item, so it's not referenced right now).
// ignore: unused_element
class _LogoutGlyph extends StatelessWidget {
  const _LogoutGlyph({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: const Size.square(22),
        painter: _LogoutPainter(color),
      );
}

class _LogoutPainter extends CustomPainter {
  _LogoutPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.15 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Door frame: a rounded "[" open on the right.
    final frame = Path()
      ..moveTo(14 * s, 4 * s)
      ..lineTo(8 * s, 4 * s)
      ..cubicTo(6.9 * s, 4 * s, 6 * s, 4.9 * s, 6 * s, 6 * s)
      ..lineTo(6 * s, 18 * s)
      ..cubicTo(6 * s, 19.1 * s, 6.9 * s, 20 * s, 8 * s, 20 * s)
      ..lineTo(14 * s, 20 * s);
    canvas.drawPath(frame, stroke);

    // Arrow gliding out through the opening.
    canvas.drawLine(Offset(11 * s, 12 * s), Offset(20 * s, 12 * s), stroke);
    final head = Path()
      ..moveTo(16.5 * s, 8.5 * s)
      ..lineTo(20 * s, 12 * s)
      ..lineTo(16.5 * s, 15.5 * s);
    canvas.drawPath(head, stroke);
  }

  @override
  bool shouldRepaint(covariant _LogoutPainter old) => old.color != color;
}

/// Polished "Listen together?" invitation — a centered brand card with a
/// headphones badge, the host's avatar + name, the track on a pill, and clear
/// Decline / Join actions. Pops `true` on Join, `false`/null otherwise.
class _LiveInviteDialog extends StatelessWidget {
  const _LiveInviteDialog({required this.hostName, required this.trackTitle});

  final String hostName;
  final String trackTitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial =
        hostName.trim().isNotEmpty ? hostName.trim()[0].toUpperCase() : '?';
    // Tidy a messy filename-title a little for display.
    var title = trackTitle.trim();
    if (title.startsWith('- ')) title = title.substring(2).trim();
    if (title.isEmpty) title = 'a song';

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Material(
          type: MaterialType.transparency,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Container(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 16),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(26),
                border: Border.all(color: scheme.primary.withAlpha(130)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(80),
                    blurRadius: 34,
                    offset: const Offset(0, 14),
                  ),
                  BoxShadow(
                    color: scheme.primary.withAlpha(40),
                    blurRadius: 26,
                    spreadRadius: -6,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Headphones badge with a soft brand halo.
                  Center(
                    child: Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(colors: [
                          scheme.primary.withAlpha(60),
                          scheme.primary.withAlpha(18),
                        ]),
                        border:
                            Border.all(color: scheme.primary.withAlpha(90)),
                      ),
                      child: Icon(Icons.headphones_rounded,
                          size: 30, color: scheme.primary),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Text(
                      'Listen together?',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Host row.
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: scheme.primaryContainer,
                        child: Text(
                          initial,
                          style: TextStyle(
                            color: scheme.onPrimaryContainer,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: RichText(
                          text: TextSpan(
                            style: TextStyle(
                                fontSize: 13.5,
                                color: scheme.onSurface.withAlpha(220),
                                height: 1.3),
                            children: [
                              TextSpan(
                                text: hostName,
                                style:
                                    const TextStyle(fontWeight: FontWeight.w700),
                              ),
                              const TextSpan(
                                  text: ' wants to listen with you, live.'),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Track pill.
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withAlpha(140),
                      borderRadius: BorderRadius.circular(14),
                      border:
                          Border.all(color: scheme.outlineVariant.withAlpha(70)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.music_note_rounded,
                            size: 18, color: scheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  // Actions.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        style: TextButton.styleFrom(
                          foregroundColor: scheme.onSurfaceVariant,
                        ),
                        child: const Text('Decline'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: () => Navigator.of(context).pop(true),
                        icon: const Icon(Icons.headphones_rounded, size: 18),
                        label: const Text('Join'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Overflow-menu row (hover-aware) ────────────────────────────────────────
// A single item inside the top-right dropdown menu. Highlights on hover and
// wraps its icon in a rounded accent chip so the active/hovered choice reads
// clearly against whatever UI sits behind the menu.

class _HoverMenuItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color accent;
  final Color textColor;
  final Color iconBg;

  const _HoverMenuItem({
    required this.icon,
    required this.label,
    required this.accent,
    required this.textColor,
    required this.iconBg,
  });

  @override
  State<_HoverMenuItem> createState() => _HoverMenuItemState();
}

class _HoverMenuItemState extends State<_HoverMenuItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: _hover ? widget.accent.withAlpha(30) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _hover ? widget.accent.withAlpha(48) : widget.iconBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(widget.icon, size: 19, color: widget.accent),
            ),
            const SizedBox(width: 12),
            Text(
              widget.label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: _hover ? FontWeight.w700 : FontWeight.w500,
                color: widget.textColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
