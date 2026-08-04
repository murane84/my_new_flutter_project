import 'package:flutter/material.dart';

// ── Toast types ───────────────────────────────────────────────────────────────
enum ToastType { info, error, success }

// ── Public API ────────────────────────────────────────────────────────────────

/// Shows a floating pill toast just above the footer (44 px bottom bar).
/// A compact card with a type icon, coloured accent and soft shadow.
void showToast(
  BuildContext context,
  String message, {
  ToastType type = ToastType.info,
  Duration duration = const Duration(milliseconds: 2000),
}) {
  if (!context.mounted) return;
  final theme = Theme.of(context);
  final isDark = theme.brightness == Brightness.dark;
  final primary = theme.colorScheme.primary;
  OverlayEntry? entry;
  entry = OverlayEntry(
    builder: (_) => _ToastOverlay(
      message: message,
      type: type,
      duration: duration,
      isDark: isDark,
      primaryColor: primary,
      onDone: () {
        try {
          entry?.remove();
        } catch (_) {}
      },
    ),
  );
  Overlay.of(context).insert(entry);
}

// ── Overlay widget ────────────────────────────────────────────────────────────

class _ToastOverlay extends StatefulWidget {
  final String message;
  final ToastType type;
  final Duration duration;
  final bool isDark;
  final Color primaryColor;
  final VoidCallback onDone;

  const _ToastOverlay({
    required this.message,
    required this.type,
    required this.duration,
    required this.isDark,
    required this.primaryColor,
    required this.onDone,
  });

  @override
  State<_ToastOverlay> createState() => _ToastOverlayState();
}

class _ToastOverlayState extends State<_ToastOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 240),
      vsync: this,
    );
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack);
    _ctrl.forward();

    Future.delayed(widget.duration, () {
      if (!mounted) return;
      _ctrl.reverse().then((_) => widget.onDone());
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // Accent colour per toast type. Info uses the warm app colour (primary);
  // success/error keep their semantic hues (warmed to match the palette).
  Color get _accent {
    switch (widget.type) {
      case ToastType.error:
        return const Color(0xFFE53935); // warm red
      case ToastType.success:
        return const Color(0xFF2E9E6B); // warm green
      case ToastType.info:
        return widget.primaryColor; // brand red
    }
  }

  // Only real errors get an icon (the exclamation). Informational and success
  // notices — "Back online", "Added to playlist", etc. — show the message text
  // alone inside the styled box; no icon, so they don't grab negative attention.
  IconData? get _icon {
    switch (widget.type) {
      case ToastType.error:
        return Icons.error_outline_rounded;
      case ToastType.success:
      case ToastType.info:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Theme-aware surface: charcoal in dark mode, a warm near-white in light.
    final card = widget.isDark
        ? const Color(0xF01E1E24)
        : const Color(0xF9FFF7F5); // ~97% opaque warm white
    final textColor =
        widget.isDark ? Colors.white : const Color(0xFF2A1414);
    final ambientShadow = widget.isDark
        ? Colors.black.withAlpha(90)
        : Colors.black.withAlpha(35);

    return Positioned(
      // 44 px footer + gap
      bottom: 60,
      left: 0,
      right: 0,
      child: FadeTransition(
        opacity: _ctrl,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.35),
            end: Offset.zero,
          ).animate(_anim),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.92, end: 1.0).animate(_anim),
            alignment: Alignment.bottomCenter,
            child: Center(
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                constraints: const BoxConstraints(maxWidth: 360),
                margin: const EdgeInsets.symmetric(horizontal: 24),
                padding: const EdgeInsets.only(
                    left: 6, right: 16, top: 10, bottom: 10),
                decoration: BoxDecoration(
                  color: card,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: _accent.withAlpha(widget.isDark ? 90 : 130),
                      width: 1),
                  boxShadow: [
                    BoxShadow(
                      color: ambientShadow,
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                    BoxShadow(
                      color: _accent.withAlpha(widget.isDark ? 45 : 30),
                      blurRadius: 14,
                      spreadRadius: -2,
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Coloured accent bar
                    Container(
                      width: 4,
                      height: 28,
                      margin: const EdgeInsets.only(right: 12),
                      decoration: BoxDecoration(
                        color: _accent,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    if (_icon != null) ...[
                      Icon(_icon, color: _accent, size: 19),
                      const SizedBox(width: 10),
                    ],
                    Flexible(
                      child: Text(
                        widget.message,
                        style: TextStyle(
                          color: textColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          height: 1.25,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                  ],
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
