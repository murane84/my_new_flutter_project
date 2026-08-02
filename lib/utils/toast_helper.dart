import 'package:flutter/material.dart';

// ── Toast types ───────────────────────────────────────────────────────────────
enum ToastType { info, error, success }

// ── Public API ────────────────────────────────────────────────────────────────

/// Shows a floating pill toast just above the footer (44 px bottom bar).
/// No opaque container — just a semi-transparent pill with shadowed text.
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
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 220),
      vsync: this,
    );
    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
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

  Color get _pill {
    switch (widget.type) {
      case ToastType.error:
        return Colors.red.shade800.withAlpha(210);
      case ToastType.success:
        return Colors.green.shade700.withAlpha(210);
      case ToastType.info:
        return Colors.black.withAlpha(170);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      // 44 px footer + 14 px gap
      bottom: 58,
      left: 0,
      right: 0,
      child: FadeTransition(
        opacity: _opacity,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.3),
            end: Offset.zero,
          ).animate(_opacity),
          child: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 340),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: _pill,
                borderRadius: BorderRadius.circular(30),
              ),
              child: Text(
                widget.message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  shadows: [
                    Shadow(color: Colors.black54, blurRadius: 6),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
