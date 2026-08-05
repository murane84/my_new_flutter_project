import 'package:flutter/material.dart';

/// Presents [child] as a top-anchored popup that sits just BELOW the Aluta app
/// header — so the brand title and the theme / policy / sign-out controls stay
/// visible and are never covered. Fades + slides down on entry.
Future<T?> showAppPopup<T>(BuildContext context, Widget child) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black.withAlpha(90),
    transitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (_, __, ___) => child,
    transitionBuilder: (_, anim, __, c) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
                  begin: const Offset(0, -0.04), end: Offset.zero)
              .animate(curved),
          child: c,
        ),
      );
    },
  );
}

/// The shared popup card: anchored under the app header, wide-but-capped on
/// desktop and near-full-width on phones, with a thin red-accent border, a
/// header row (icon + title + optional action + close) and a flexible body.
///
/// [isWide] is exposed to callers via the [builder] so a page can lay its
/// fields out in columns on desktop (no scrolling) and stack them on phones.
class AppPopupShell extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget? headerAction;
  final double desktopMaxWidth;
  final Widget Function(BuildContext context, bool isWide) builder;

  const AppPopupShell({
    super.key,
    required this.title,
    required this.icon,
    required this.builder,
    this.headerAction,
    this.desktopMaxWidth = 760,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final isWide = media.size.width >= 720;
    // Clear the Aluta app header (toolbar + status bar) with a small gap.
    final topInset = media.padding.top + 64;
    final maxW = isWide ? desktopMaxWidth : media.size.width - 24;
    final maxH = media.size.height - topInset - 20;

    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding:
            EdgeInsets.only(top: topInset, left: 12, right: 12, bottom: 12),
        child: Material(
          type: MaterialType.transparency,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
            child: Container(
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: scheme.primary.withAlpha(130)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(70),
                    blurRadius: 30,
                    offset: const Offset(0, 12),
                  ),
                  BoxShadow(
                    color: scheme.primary.withAlpha(26),
                    blurRadius: 22,
                    spreadRadius: -6,
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withAlpha(120),
                      border: Border(
                        bottom: BorderSide(
                            color: scheme.outlineVariant.withAlpha(70)),
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: scheme.primary.withAlpha(28),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(icon, size: 19, color: scheme.primary),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                                fontSize: 16.5, fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (headerAction != null) headerAction!,
                        IconButton(
                          tooltip: 'Close',
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                  Flexible(child: builder(context, isWide)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
