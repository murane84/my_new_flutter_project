import 'package:flutter/material.dart';

import 'net.dart' show NetStatus;

// ── Toast types ───────────────────────────────────────────────────────────────
enum ToastType { info, error, success }

/// A button on a toast ("Show", "Share one", "Tell me when…"). Tapping it
/// runs [onPressed] and closes the toast.
class ToastAction {
  const ToastAction(this.label, this.onPressed);
  final String label;
  final VoidCallback onPressed;
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Shows a floating pill toast just above the footer (44 px bottom bar).
/// A compact card with a type icon, coloured accent and soft shadow.
void showToast(
  BuildContext context,
  String message, {
  ToastType type = ToastType.info,
  Duration duration = const Duration(milliseconds: 2000),
  String? detail,
  List<ToastAction> actions = const [],
  VoidCallback? onTap,
  // Show on this overlay instead of the nearest one (e.g. the app's root
  // overlay, kept from a screen that may be gone by the time this fires).
  OverlayState? overlay,
}) {
  if (!context.mounted) return;
  // Something to tap → give people time to read and reach it.
  if ((actions.isNotEmpty || onTap != null) &&
      duration < const Duration(milliseconds: 5000)) {
    duration = const Duration(milliseconds: 5000);
  }
  // An error toast says WHY when a request just failed (offline, timed out,
  // server busy, session expired…) — unless the message already says it.
  String? why = detail;
  if (type == ToastType.error && why == null) {
    final r = NetStatus.recentReason();
    if (r != null && !_alreadyExplains(message, r)) {
      why = r[0].toUpperCase() + r.substring(1);
      message = _dropTryAgain(message);
      if (duration < const Duration(milliseconds: 3600)) {
        duration = const Duration(milliseconds: 3600);
      }
    }
  }
  final theme = Theme.of(context);
  final isDark = theme.brightness == Brightness.dark;
  final primary = theme.colorScheme.primary;
  // One toast at a time: a new one replaces the one on screen, so two never
  // sit on top of each other (e.g. "Checking…" then the result).
  final prev = _current;
  _current = null;
  if (prev != null) {
    try {
      prev.remove();
    } catch (_) {}
  }
  OverlayEntry? entry;
  entry = OverlayEntry(
    builder: (_) => _ToastOverlay(
      message: message,
      detail: why,
      type: type,
      duration: duration,
      isDark: isDark,
      primaryColor: primary,
      actions: actions,
      onTap: onTap,
      onDone: () {
        if (identical(_current, entry)) _current = null;
        try {
          entry?.remove();
        } catch (_) {}
      },
    ),
  );
  _current = entry;
  (overlay ?? Overlay.of(context)).insert(entry);
}

OverlayEntry? _current;

bool _alreadyExplains(String message, String reason) {
  final m = message.toLowerCase();
  if (m.contains(reason.toLowerCase())) return true;
  const hints = [
    'internet', 'offline', 'connection', 'timed out', 'sign in', 'session',
    'busy', 'too large', 'too big', 'wait a moment', 'no longer', 'not found',
    "isn't on the server", 'access',
  ];
  return hints.any(m.contains);
}

// "Could not send — try again" + a reason line reads better as just
// "Could not send"; the reason says whether trying again will help.
String _dropTryAgain(String message) {
  final s = message.replaceFirst(
      RegExp(r'\s*[—–\-,.]\s*(please\s+)?try again\.?\s*$',
          caseSensitive: false),
      '');
  return s.isEmpty ? message : s;
}

// ── Overlay widget ────────────────────────────────────────────────────────────

class _ToastOverlay extends StatefulWidget {
  final String message;
  final String? detail;
  final ToastType type;
  final Duration duration;
  final bool isDark;
  final Color primaryColor;
  final VoidCallback onDone;
  final List<ToastAction> actions;
  final VoidCallback? onTap;

  const _ToastOverlay({
    this.actions = const [],
    this.onTap,
    required this.message,
    this.detail,
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

    Future.delayed(widget.duration, _close);
  }

  bool _closing = false;
  void _close() {
    if (!mounted || _closing) return;
    _closing = true;
    _ctrl.reverse().then((_) => widget.onDone());
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
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.onTap == null
                            ? null
                            : () {
                                widget.onTap!();
                                _close();
                              },
                        child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.message,
                            style: TextStyle(
                              color: textColor,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              height: 1.25,
                              decoration: TextDecoration.none,
                            ),
                          ),
                          if (widget.detail != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                widget.detail!,
                                style: TextStyle(
                                  color: textColor.withValues(alpha: 0.72),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w400,
                                  height: 1.25,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ),
                          if (widget.actions.isNotEmpty)
                            Align(
                              alignment: Alignment.centerRight,
                              child: _actionsRow(),
                            ),
                        ],
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

  Widget _actionsRow() => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(
          alignment: WrapAlignment.end,
          spacing: 4,
          children: [
            for (final a in widget.actions)
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: _accent,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700),
                ),
                onPressed: () {
                  a.onPressed();
                  _close();
                },
                child: Text(a.label),
              ),
          ],
        ),
      );
}
