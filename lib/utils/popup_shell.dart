import 'package:flutter/material.dart';

/// Presents [child] as a popup that emerges FROM THE FOOTER, floating upward —
/// consistent with the music panel and the app's bottom sheets (rather than
/// dropping down from the header, which clashed with those surfaces and their
/// controls). Fades + rises on entry.
Future<T?> showAppPopup<T>(BuildContext context, Widget child) async {
  // Drop any active text focus so opening the popup never carries a keyboard
  // in with it.
  FocusManager.instance.primaryFocus?.unfocus();
  final result = await showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black.withAlpha(90),
    transitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (_, _, _) => child,
    transitionBuilder: (_, anim, _, c) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          // Begin slightly BELOW its resting spot and rise up (emerge from the
          // footer), instead of dropping down from the header.
          position: Tween<Offset>(
                  begin: const Offset(0, 0.06), end: Offset.zero)
              .animate(curved),
          child: c,
        ),
      );
    },
  );
  // However it was dismissed (X, barrier tap or back), make sure focus
  // restoration doesn't pop a keyboard up on the page underneath.
  FocusManager.instance.primaryFocus?.unfocus();
  return result;
}

/// The shared popup card: anchored ABOVE THE FOOTER (bottom-centre) and rising
/// upward, wide-but-capped on desktop and near-full-width on phones, with a thin
/// red-accent border, a header row (icon + title + optional action + close) and
/// a flexible body.
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
    // Clear the Aluta app header (toolbar + status bar) with a small gap when the
    // card is tall — but the card is bottom-anchored, so short pages hug the
    // footer and rise from there.
    final topInset = media.padding.top + 64;
    final maxW = isWide ? desktopMaxWidth : media.size.width - 24;
    // Reserve the system navigation-bar inset (padding.bottom) plus the app
    // footer (~52) so the popup floats just ABOVE the footer, never under it or
    // the Android 3-button nav bar.
    final bottomInset = media.padding.bottom + 56;
    final maxH = media.size.height - topInset - 12 - bottomInset;

    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.only(
            top: topInset, left: 12, right: 12, bottom: bottomInset),
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
                        ?headerAction,
                        IconButton(
                          tooltip: 'Close',
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () {
                            FocusScope.of(context).unfocus();
                            Navigator.of(context).pop();
                          },
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
