import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/on_accent.dart';

/// A tactile header action for the music lists (playlist, Up next queue,
/// Listen Together): a soft rounded chip that reads as a button at rest,
/// presses in (scale + deeper tint) under the finger, ripples, and glows in
/// its accent while [active] (e.g. Favourites filter on).
class AlutaTapChip extends StatefulWidget {
  const AlutaTapChip({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.activeColor,
    this.size = 36,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;
  final Color? activeColor;
  final double size;

  @override
  State<AlutaTapChip> createState() => _AlutaTapChipState();
}

class _AlutaTapChipState extends State<AlutaTapChip> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final enabled = widget.onTap != null;
    final accent = widget.activeColor ?? scheme.primary;
    final on = widget.active;
    // Active = a solid accent chip with a contrasting icon (readable on any
    // theme colour); idle = the soft surface chip.
    final bg = on
        ? (_down ? Color.lerp(accent, Colors.black, 0.12)! : accent)
        : (_down
            ? scheme.primary.withValues(alpha: isDark ? 0.24 : 0.14)
            : (isDark
                ? scheme.surfaceContainerHigh
                : Colors.white.withValues(alpha: 0.92)));
    final border = on
        ? Color.lerp(accent, Colors.black, 0.15)!
        : scheme.primary.withValues(alpha: isDark ? 0.35 : 0.22);
    final fg = !enabled
        ? scheme.onSurfaceVariant.withValues(alpha: 0.4)
        : (on ? onAccent(accent) : scheme.primary);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Tooltip(
        message: widget.tooltip,
        child: AnimatedScale(
          scale: _down ? 0.9 : 1.0,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(widget.size * 0.33),
              border: Border.all(color: border, width: on ? 1.4 : 1),
              boxShadow: _down || !enabled
                  ? null
                  : [
                      BoxShadow(
                        color: (on ? accent : scheme.primary)
                            .withValues(alpha: isDark ? 0.18 : 0.14),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(widget.size * 0.33),
                splashColor: accent.withValues(alpha: 0.22),
                onTap: !enabled
                    ? null
                    : () {
                        HapticFeedback.selectionClick();
                        widget.onTap!();
                      },
                onTapDown: enabled ? (_) => _set(true) : null,
                onTapUp: enabled ? (_) => _set(false) : null,
                onTapCancel: enabled ? () => _set(false) : null,
                child: Icon(widget.icon, size: widget.size * 0.52, color: fg),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
