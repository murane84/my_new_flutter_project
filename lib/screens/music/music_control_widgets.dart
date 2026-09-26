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
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: active
                ? activeColor.withAlpha(25)
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active
                  ? activeColor.withAlpha(120)
                  : scheme.outlineVariant.withAlpha(60),
            ),
          ),
          child: Icon(
            icon,
            size: 20,
            color: active ? activeColor : scheme.onSurface.withAlpha(130),
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
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width - 32,
      ),
      child: GestureDetector(
        onTap: () {}, // absorb inner taps so they don't reach the barrier
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: scheme.primary.withAlpha(130)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(70),
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
                    Icon(Icons.speed_rounded,
                        size: 16, color: scheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      'Playback Speed',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: scheme.onSurface),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: onClose,
                      child: Icon(Icons.close,
                          size: 18,
                          color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _speeds.map((s) {
                    final active = (s - currentSpeed).abs() < 0.01;
                    return GestureDetector(
                      onTap: () => onSelect(s),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 10),
                        decoration: BoxDecoration(
                          color: active
                              ? scheme.primary
                              : scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: active
                                ? scheme.primary
                                : scheme.outlineVariant.withAlpha(80),
                          ),
                        ),
                        child: Text(
                          _speedLabel(s),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: active
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: active
                                ? scheme.onPrimary
                                : scheme.onSurface.withAlpha(170),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        ),
    );
  }
}
