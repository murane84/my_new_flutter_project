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
  OverlayEntry? entry;
  entry = OverlayEntry(
    builder: (_) => _ToastOverlay(
      message: message,
      type: type,
      duration: duration,
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
  final VoidCallback onDone;

  const _ToastOverlay({
    required this.message,
    required this.type,
    required this.duration,
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

  // Accent colour per toast type — used for the icon and left bar.
  Color get _accent {
    switch (widget.type) {
      case ToastType.error:
        return const Color(0xFFFF5A5A);
      case ToastType.success:
        return const Color(0xFF3DD68C);
      case ToastType.info:
        return const Color(0xFF6FB3FF);
    }
  }

  IconData get _icon {
    switch (widget.type) {
      case ToastType.error:
        return Icons.error_outline_rounded;
      case ToastType.success:
        return Icons.check_circle_outline_rounded;
      case ToastType.info:
        return Icons.info_outline_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    // A dark glass card reads cleanly over both light and dark backgrounds.
    const card = Color(0xF01E1E24); // ~94% opaque charcoal

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
                  border: Border.all(color: _accent.withAlpha(90), width: 1),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(90),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                    BoxShadow(
                      color: _accent.withAlpha(45),
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
                    Icon(_icon, color: _accent, size: 19),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        widget.message,
                        style: const TextStyle(
                          color: Colors.white,
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
