import 'package:flutter/material.dart';

/// Presents [child] as a popup that emerges FROM THE FOOTER, floating upward —
/// consistent with the music panel and the app's bottom sheets (rather than
/// dropping down from the header, which clashed with those surfaces and their
/// controls). Fades + rises on entry.
Future<T?> showAppPopup<T>(
  BuildContext context,
  Widget child, {
  // When true, the card scales + fades toward the bottom (its footer "home")
  // on entry and — crucially — on exit, so dismissing it reads as MINIMIZING
  // the card back down rather than a hard cut. Used by Our Space so tapping the
  // minimize button feels like tucking the page away for a moment.
  bool minimizeStyle = false,
}) async {
  // Drop any active text focus so opening the popup never carries a keyboard
  // in with it.
  FocusManager.instance.primaryFocus?.unfocus();
  final result = await showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black.withAlpha(90),
    transitionDuration: const Duration(milliseconds: 300),
    pageBuilder: (_, _, _) => child,
    transitionBuilder: (_, anim, _, c) {
      final curved = CurvedAnimation(
        parent: anim,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      if (minimizeStyle) {
        // Shrink toward the bottom-centre and slide down: on reverse (dismiss)
        // this plays backwards, so the card looks absorbed back down to where
        // it lives instead of vanishing in place.
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
                    begin: const Offset(0, 0.12), end: Offset.zero)
                .animate(curved),
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.86, end: 1.0).animate(curved),
              alignment: Alignment.bottomCenter,
              child: c,
            ),
          ),
        );
      }
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
  // The trailing dismiss control. Defaults to a plain close; a page that opened
  // with `minimizeStyle` can pass a minimize glyph + tooltip so the button reads
  // as "tuck this away" rather than "close".
  final IconData closeIcon;
  final String closeTooltip;
  // When true the page takes the WHOLE screen (edge-to-edge, covering the app
  // chrome) instead of floating as a card — for an immersive, focused surface.
  // The minimize control + the minimize-down animation still bring it back.
  final bool fullScreen;

  const AppPopupShell({
    super.key,
    required this.title,
    required this.icon,
    required this.builder,
    this.headerAction,
    this.desktopMaxWidth = 760,
    this.closeIcon = Icons.close_rounded,
    this.closeTooltip = 'Close',
    this.fullScreen = false,
  });

  /// The shared header bar (icon + title + optional action + close/minimize).
  Widget _header(BuildContext context, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withAlpha(120),
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant.withAlpha(70)),
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
            tooltip: closeTooltip,
            icon: Icon(closeIcon),
            onPressed: () {
              FocusScope.of(context).unfocus();
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final isWide = media.size.width >= 720;

    if (fullScreen) {
      // Fill the whole screen. The header sits below the status bar; the body
      // gets the rest. On wide screens the CONTENT is centred to a comfortable
      // width so it never sprawls, while the surface itself stays edge-to-edge.
      final body = builder(context, isWide);
      return SizedBox.expand(
        child: Material(
        color: scheme.surface,
        child: Padding(
          padding: EdgeInsets.only(top: media.padding.top),
          child: Column(
            children: [
              _header(context, scheme),
              Expanded(
                child: isWide
                    ? Center(
                        child: ConstrainedBox(
                          constraints:
                              BoxConstraints(maxWidth: desktopMaxWidth),
                          child: body,
                        ),
                      )
                    : body,
              ),
            ],
          ),
        ),
      ),
      );
    }
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
                  _header(context, scheme),
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
