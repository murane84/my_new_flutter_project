part of '../music_controls.dart';

// Small reusable control widgets pulled out of music_controls.dart
// unchanged: the icon button, the toggle chip, and the playback-speed
// panel. Leaf widgets — values + callbacks in, theme colours out.

// ─── Small reusable widgets ───────────────────────────────────────────────────

class _CtrlBtn extends StatelessWidget {
  final IconData icon;
  final double size;
  final Color color;
  final VoidCallback? onTap;
  final String tooltip;

  const _CtrlBtn({
    required this.icon,
    required this.size,
    required this.color,
    required this.tooltip,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, size: size, color: color),
        ),
      ),
    );
  }
}

class _CtrlChip extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color activeColor;
  final VoidCallback onTap;
  final String tooltip;

  const _CtrlChip({
    required this.icon,
    required this.active,
    required this.activeColor,
    required this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            // A raised, gently top-lit chip — accent-glowing when active, a
            // subtle surface gradient when idle, so the controls feel alive
            // instead of flat grey (especially in light mode).
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: active
                  ? [
                      activeColor.withValues(alpha: 0.30),
                      activeColor.withValues(alpha: 0.15),
                    ]
                  : [
                      // Idle chips carry a faint wash of the app accent so the
                      // control cluster feels themed and alive instead of a
                      // flat grey box — most visible in light mode.
                      Color.alphaBlend(
                        scheme.primary
                            .withValues(alpha: isDark ? 0.10 : 0.07),
                        scheme.surface,
                      ),
                      Color.alphaBlend(
                        scheme.primary
                            .withValues(alpha: isDark ? 0.18 : 0.13),
                        scheme.surfaceContainerHighest,
                      ),
                    ],
            ),
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: active
                  ? activeColor.withValues(alpha: 0.85)
                  : scheme.primary.withValues(alpha: isDark ? 0.32 : 0.24),
              width: active ? 1.6 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: active
                    ? activeColor.withValues(alpha: 0.32)
                    : scheme.primary
                        .withValues(alpha: isDark ? 0.22 : 0.14),
                blurRadius: active ? 12 : 7,
                offset: Offset(0, active ? 4 : 3),
              ),
            ],
          ),
          child: Icon(
            icon,
            size: 20,
            color: active
                ? activeColor
                : Color.alphaBlend(
                    scheme.primary.withValues(alpha: 0.35),
                    scheme.onSurface.withValues(alpha: 0.78),
                  ),
          ),
        ),
      ),
    );
  }
}

// ─── Speed panel ──────────────────────────────────────────────────────────────

class _SpeedPanel extends StatelessWidget {
  final double currentSpeed;
  final void Function(double) onSelect;
  final VoidCallback onClose;

  const _SpeedPanel({
    required this.currentSpeed,
    required this.onSelect,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Just the card now — the caller owns the tap-outside barrier, the
    // position (just above the speed button) and the genie scale, so this
    // widget is a clean leaf that scales/collapses into the button.
    return GestureDetector(
      onTap: () {}, // absorb inner taps so they don't reach the barrier
      child: Container(
        width: 236,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: scheme.primary.withAlpha(110)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(90),
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
              children: [
                Icon(Icons.speed_rounded, size: 16, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Playback speed',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: scheme.onSurface),
                  ),
                ),
                InkWell(
                  onTap: onClose,
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.close_rounded,
                        size: 18, color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // A tidy 3-column grid (two rows of three) so the panel fits its
            // content with no empty gap.
            for (int r = 0; r < _speeds.length; r += 3)
              Padding(
                padding: EdgeInsets.only(
                    bottom: r + 3 < _speeds.length ? 8 : 0),
                child: Row(
                  children: [
                    for (int c = 0; c < 3; c++) ...[
                      if (c > 0) const SizedBox(width: 8),
                      Expanded(
                        child: (r + c) < _speeds.length
                            ? _speedChip(scheme, _speeds[r + c])
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _speedChip(ColorScheme scheme, double s) {
    final active = (s - currentSpeed).abs() < 0.01;
    return GestureDetector(
      onTap: () => onSelect(s),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 11),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active
                ? scheme.primary
                : scheme.outlineVariant.withAlpha(90),
          ),
        ),
        child: Text(
          _speedLabel(s),
          style: TextStyle(
            fontSize: 13,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? scheme.onPrimary : scheme.onSurface,
          ),
        ),
      ),
    );
  }
}
