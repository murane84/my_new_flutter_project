import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_busy.dart';

// ─── Genie menus ────────────────────────────────────────────────────────────
// One menu motion for the whole app: a menu GROWS out of the button that
// opened it (scaling from that corner with a soft overshoot, fading in, its
// rows drifting in one after another) and folds back INTO it on dismiss.
// Submenus never make the menu taller: on wide windows they open as a flyout
// card beside it (hover or click), on phones they slide in inside the same
// card with a "‹ Back" header. Back / Esc step out one level; tap-outside
// closes everything.
//
//  • [showGenieMenu] + [GenieMenuEntry] — build a menu from entries.
//  • [GenieMenuButton] — an icon button that opens one.
//  • [GeniePopupMenuButton] — a drop-in for PopupMenuButton (same itemBuilder
//    / onSelected API) so existing menus get the motion without rewrites.

/// One row of a genie menu: an action, a submenu (with [children]), or a
/// divider ([GenieMenuEntry.divider]).
class GenieMenuEntry {
  const GenieMenuEntry({
    this.icon,
    required this.label,
    this.onTap,
    this.destructive = false,
    this.children,
    this.trailing,
    this.enabled = true,
    this.custom,
  }) : isDivider = false;

  const GenieMenuEntry.divider()
      : icon = null,
        label = '',
        onTap = null,
        destructive = false,
        children = null,
        trailing = null,
        enabled = false,
        custom = null,
        isDivider = true;

  final IconData? icon;
  final String label;
  final VoidCallback? onTap;
  final bool destructive;
  final List<GenieMenuEntry>? children;
  final Widget? trailing;
  final bool enabled;

  /// A ready-made row widget (used when adapting PopupMenuItem children).
  final Widget? custom;
  final bool isDivider;
}

/// Open a genie menu growing out of [anchor] (the opener's global rect).
Future<void> showGenieMenu(
  BuildContext context, {
  required Rect anchor,
  required List<GenieMenuEntry> entries,
  double width = 248,
  Color? color,
}) {
  HapticFeedback.selectionClick();
  return Navigator.of(context).push(_GenieMenuRoute(
    anchor: anchor,
    entries: entries,
    width: width,
    color: color,
  ));
}

Rect _rectOf(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return Rect.zero;
  return box.localToGlobal(Offset.zero) & box.size;
}

class _GenieMenuRoute extends PopupRoute<void> {
  _GenieMenuRoute({
    required this.anchor,
    required this.entries,
    required this.width,
    this.color,
  });

  final Rect anchor;
  final List<GenieMenuEntry> entries;
  final double width;
  final Color? color;

  @override
  Color? get barrierColor => Colors.transparent;
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => 'Close menu';
  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 200);

  // Keep the busy logo spinner off an open menu.
  bool _counted = false;

  @override
  void install() {
    super.install();
    if (!_counted) {
      _counted = true;
      menusOnScreen.value++;
    }
  }

  @override
  void dispose() {
    if (_counted) {
      _counted = false;
      menusOnScreen.value = (menusOnScreen.value - 1).clamp(0, 99);
    }
    super.dispose();
  }

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    return _GenieMenuSurface(
      anchor: anchor,
      entries: entries,
      width: width,
      color: color,
      animation: animation,
    );
  }
}

/// Wide windows (desktop / web / tablets) open submenus as a flyout card
/// beside the menu; narrower screens slide the submenu in, inside the same
/// card. Either way the menu never grows taller when a submenu opens.
const double _kFlyoutMinWidth = 720;

class _GenieMenuSurface extends StatefulWidget {
  const _GenieMenuSurface({
    required this.anchor,
    required this.entries,
    required this.width,
    required this.animation,
    this.color,
  });

  final Rect anchor;
  final List<GenieMenuEntry> entries;
  final double width;
  final Animation<double> animation;
  final Color? color;

  @override
  State<_GenieMenuSurface> createState() => _GenieMenuSurfaceState();
}

class _GenieMenuSurfaceState extends State<_GenieMenuSurface> {
  // The open flyout (wide only): its entry and the row it grew from.
  GenieMenuEntry? _fly;
  Rect? _flyFrom;

  void _openFlyout(GenieMenuEntry e, Rect row) {
    if (identical(_fly, e)) return;
    HapticFeedback.selectionClick();
    setState(() {
      _fly = e;
      _flyFrom = row;
    });
  }

  void _closeFlyout() {
    if (_fly == null) return;
    setState(() {
      _fly = null;
      _flyFrom = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final pad = media.padding;
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final anchor = widget.anchor;
    final wide = size.width >= _kFlyoutMinWidth;

    // Place the card beside the opener: right-aligned to it when the button
    // is on the right half, left-aligned otherwise; below it when there's
    // room, else above. The card grows from the corner nearest the button.
    final w = math.min(widget.width, size.width - 16);
    final onRight = anchor.center.dx > size.width / 2;
    final left = (onRight ? anchor.right - w : anchor.left)
        .clamp(8.0, size.width - w - 8);
    // The card's tail (part of its outline) bridges the gap to the button,
    // so the card body starts a little lower than before.
    const gap = 1.0;
    final below = anchor.bottom + gap;
    final roomBelow = size.height - pad.bottom - 8 - below;
    final roomAbove = anchor.top - gap - pad.top - 8;
    final openDown = roomBelow >= 220 || roomBelow >= roomAbove;
    final maxH = openDown ? roomBelow : roomAbove;
    // The tail points at the button's centre, kept clear of the corners.
    final tailX = _TailedCardBorder.clampTip(anchor.center.dx - left, w);
    // The genie grows out of the tail's tip.
    final origin = Alignment(
      (tailX / w) * 2 - 1,
      openDown ? -1 : 1,
    );
    final fill = widget.color ??
        (isDark
            ? Color.alphaBlend(
                Colors.white.withValues(alpha: 0.05), scheme.surface)
            : scheme.surface);
    final edge = BorderSide(
        color: scheme.primary.withValues(alpha: isDark ? 0.30 : 0.22));
    final shadow = [
      BoxShadow(
        color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.16),
        blurRadius: 24,
        offset: const Offset(0, 10),
      ),
    ];

    // Flyout placement: toward the roomier side of the menu (left when the
    // menu hugs the right edge), its first row level with the parent row.
    Widget? flyout;
    final fly = _fly;
    final from = _flyFrom;
    if (wide && fly != null && from != null) {
      const fw = 236.0;
      const fgap = 6.0;
      final toLeft = onRight || left + w + fgap + fw > size.width - 8;
      final fx = toLeft ? left - fgap - fw : left + w + fgap;
      final kids = fly.children ?? const <GenieMenuEntry>[];
      // Rough height so the card can be lifted to stay on-screen.
      final estH = 12.0 +
          kids.fold<double>(0, (s, c) => s + (c.isDivider ? 10 : 44));
      final top = (from.top - 6)
          .clamp(pad.top + 8, math.max(pad.top + 8, size.height - pad.bottom - 8 - estH))
          .toDouble();
      flyout = Positioned(
        key: ValueKey(fly),
        left: fx.clamp(8.0, size.width - fw - 8),
        top: top,
        width: fw,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          builder: (_, v, child) => Opacity(
            opacity: v,
            child: Transform(
              alignment:
                  toLeft ? Alignment.topRight : Alignment.topLeft,
              transform: Matrix4.diagonal3Values(
                  0.85 + 0.15 * v, 0.9 + 0.1 * v, 1),
              child: child,
            ),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: size.height - pad.vertical - 16),
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                decoration: ShapeDecoration(
                  color: fill,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16), side: edge),
                  shadows: shadow,
                ),
                clipBehavior: Clip.antiAlias,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final c in kids)
                        c.isDivider
                            ? Divider(
                                height: 10,
                                indent: 14,
                                endIndent: 14,
                                color: scheme.outlineVariant
                                    .withValues(alpha: 0.5))
                            : _genieRow(context, c,
                                onTap: () => _genieRunAndClose(context, c)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return PopScope(
      // Back / Esc closes an open flyout first, then the menu.
      canPop: _fly == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeFlyout();
      },
      child: Stack(
        children: [
          // Tap anywhere outside closes the whole menu (flyout included).
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).pop(),
            ),
          ),
          Positioned(
            left: left,
            width: w,
            top: openDown ? below : null,
            bottom: openDown ? null : size.height - anchor.top + gap,
            child: AnimatedBuilder(
              animation: widget.animation,
              builder: (context, child) {
                final v = widget.animation.value;
                final reverse =
                    widget.animation.status == AnimationStatus.reverse;
                // Genie: width leads with a little overshoot, height follows,
                // the whole card fades in. Folding back is quicker and flatter.
                final sx = reverse
                    ? Curves.easeIn.transform(v)
                    : Curves.easeOutBack.transform(v);
                final sy = reverse
                    ? Curves.easeIn.transform(v)
                    : Curves.easeOutCubic
                        .transform(((v - 0.05) / 0.95).clamp(0.0, 1.0));
                final fade =
                    Curves.easeOut.transform((v * 1.6).clamp(0.0, 1.0));
                return Opacity(
                  opacity: fade,
                  child: Transform(
                    alignment: origin,
                    transform: Matrix4.diagonal3Values(
                        (0.35 + 0.65 * sx).clamp(0.0, 1.06),
                        (0.15 + 0.85 * sy).clamp(0.0, 1.06),
                        1),
                    child: child,
                  ),
                );
              },
              child: ConstrainedBox(
                constraints:
                    BoxConstraints(maxHeight: maxH.clamp(120.0, 640.0)),
                child: Material(
                  type: MaterialType.transparency,
                  child: Container(
                    // One continuous outline: rounded card + a soft tail
                    // pointing at the opener. Fill, border and shadow all
                    // follow it, so the tail is part of the card, not a
                    // triangle stuck on its edge.
                    decoration: ShapeDecoration(
                      color: fill,
                      shape: _TailedCardBorder(
                          tipX: tailX, up: openDown, side: edge),
                      shadows: shadow,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: _GenieMenuList(
                      entries: widget.entries,
                      animation: widget.animation,
                      flyout: wide,
                      activeFlyout: _fly,
                      onFlyout: _openFlyout,
                      onCloseFlyout: _closeFlyout,
                    ),
                  ),
                ),
              ),
            ),
          ),
          ?flyout,
        ],
      ),
    );
  }
}

/// Close the menu, then run the row's action (after the fold-back starts, so
/// the menu doesn't linger over the next screen).
void _genieRunAndClose(BuildContext context, GenieMenuEntry e) {
  if (!e.enabled) return;
  Navigator.of(context).pop();
  Future.microtask(() => e.onTap?.call());
}

/// One menu row — shared by the main list, the slide-in page and the flyout.
Widget _genieRow(
  BuildContext context,
  GenieMenuEntry e, {
  required VoidCallback onTap,
  bool active = false,
  bool nested = false,
  ValueChanged<bool>? onHover,
}) {
  final scheme = Theme.of(context).colorScheme;
  final accent = e.destructive ? scheme.error : scheme.primary;
  final textColor = !e.enabled
      ? scheme.onSurface.withValues(alpha: 0.38)
      : (e.destructive ? scheme.error : scheme.onSurface);
  return Material(
    color: active ? scheme.primary.withValues(alpha: 0.08) : Colors.transparent,
    child: InkWell(
      onTap: e.enabled ? onTap : null,
      onHover: onHover,
      child: Padding(
        padding: EdgeInsets.symmetric(
            horizontal: nested ? 12 : 14, vertical: e.custom != null ? 4 : 11),
        child: e.custom ??
            Row(
              children: [
                if (e.icon != null) ...[
                  Icon(e.icon, size: nested ? 18 : 20, color: accent),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Text(e.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: nested ? 13.5 : 14.5,
                          fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                          color: textColor)),
                ),
                if (e.trailing != null) e.trailing!,
                if (e.children != null)
                  Icon(Icons.chevron_right_rounded,
                      size: 20,
                      color: active ? accent : scheme.onSurfaceVariant),
              ],
            ),
      ),
    ),
  );
}

class _GenieMenuList extends StatefulWidget {
  const _GenieMenuList({
    required this.entries,
    required this.animation,
    required this.flyout,
    required this.onFlyout,
    required this.onCloseFlyout,
    this.activeFlyout,
  });
  final List<GenieMenuEntry> entries;
  final Animation<double> animation;

  /// true: submenus open as a flyout card (wide); false: slide-in page.
  final bool flyout;
  final GenieMenuEntry? activeFlyout;
  final void Function(GenieMenuEntry e, Rect row) onFlyout;
  final VoidCallback onCloseFlyout;

  @override
  State<_GenieMenuList> createState() => _GenieMenuListState();
}

class _GenieMenuListState extends State<_GenieMenuList> {
  // Narrow screens: the submenu currently slid in (null = main list).
  GenieMenuEntry? _page;

  void _tap(BuildContext rowCtx, GenieMenuEntry e) {
    if (!e.enabled) return;
    if (e.children != null) {
      if (widget.flyout) {
        identical(widget.activeFlyout, e)
            ? widget.onCloseFlyout()
            : widget.onFlyout(e, _rectOf(rowCtx));
      } else {
        HapticFeedback.selectionClick();
        setState(() => _page = e);
      }
      return;
    }
    _genieRunAndClose(context, e);
  }

  // Desktop hover: resting on a submenu row opens its flyout; moving onto a
  // plain row closes it.
  void _hover(BuildContext rowCtx, GenieMenuEntry e, bool inside) {
    if (!widget.flyout || !inside || !e.enabled) return;
    if (e.children != null) {
      widget.onFlyout(e, _rectOf(rowCtx));
    } else if (!e.isDivider) {
      widget.onCloseFlyout();
    }
  }

  Widget _mainList(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = <Widget>[];
    final n = widget.entries.length;
    for (var i = 0; i < n; i++) {
      final e = widget.entries[i];
      // Rows drift in one after another (a short stagger, ~25ms apart).
      final start = (0.15 + i * 0.05).clamp(0.0, 0.7);
      final anim = CurvedAnimation(
        parent: widget.animation,
        curve: Interval(start, (start + 0.4).clamp(0.0, 1.0),
            curve: Curves.easeOutCubic),
        reverseCurve: Curves.easeIn,
      );
      final Widget row = e.isDivider
          ? Divider(
              height: 10,
              indent: 14,
              endIndent: 14,
              color: scheme.outlineVariant.withValues(alpha: 0.5))
          : Builder(
              builder: (rowCtx) => _genieRow(
                rowCtx,
                e,
                active: widget.flyout && identical(widget.activeFlyout, e),
                onTap: () => _tap(rowCtx, e),
                onHover: (h) => _hover(rowCtx, e, h),
              ),
            );
      rows.add(FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, -0.25), end: Offset.zero)
              .animate(anim),
          child: row,
        ),
      ));
    }
    return SingleChildScrollView(
      key: const ValueKey('genie-main'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
  }

  // The slid-in submenu: "‹ Account" header, then its rows.
  Widget _subPage(BuildContext context, GenieMenuEntry p) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      key: ValueKey(p),
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _page = null),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 14, 10),
              child: Row(
                children: [
                  Icon(Icons.chevron_left_rounded,
                      size: 24, color: scheme.primary),
                  const SizedBox(width: 4),
                  if (p.icon != null) ...[
                    Icon(p.icon, size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(p.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                            color: scheme.onSurface)),
                  ),
                ],
              ),
            ),
          ),
          Divider(
              height: 1,
              indent: 14,
              endIndent: 14,
              color: scheme.outlineVariant.withValues(alpha: 0.5)),
          const SizedBox(height: 4),
          for (final c in p.children ?? const <GenieMenuEntry>[])
            c.isDivider
                ? Divider(
                    height: 10,
                    indent: 14,
                    endIndent: 14,
                    color: scheme.outlineVariant.withValues(alpha: 0.5))
                : _genieRow(context, c,
                    onTap: () => _genieRunAndClose(context, c)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    return PopScope(
      // Back / Esc on a slid-in submenu returns to the main list first.
      canPop: page == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _page != null) setState(() => _page = null);
      },
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
        },
        child: Actions(
          actions: {
            DismissIntent: CallbackAction<DismissIntent>(
                onInvoke: (_) => Navigator.of(context).maybePop()),
          },
          child: Focus(
            autofocus: true,
            // The card resizes IN STEP with the slide: only the incoming page
            // sets the size (the outgoing one is laid over it and clipped as
            // it slides away), so there's never a moment of blank card
            // waiting to shrink/grow after the switch.
            child: AnimatedSize(
              duration: const Duration(milliseconds: 210),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 210),
                reverseDuration: const Duration(milliseconds: 160),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                layoutBuilder: (cur, prev) => Stack(
                  alignment: Alignment.topCenter,
                  clipBehavior: Clip.hardEdge,
                  children: [
                    for (final p in prev)
                      Positioned(top: 0, left: 0, right: 0, child: p),
                    ?cur,
                  ],
                ),
                // The submenu slides in from the right; the main list comes
                // back from the left.
                transitionBuilder: (child, anim) {
                  final isSub = child.key != const ValueKey('genie-main');
                  return FadeTransition(
                    opacity: anim,
                    child: SlideTransition(
                      position: Tween(
                              begin: Offset(isSub ? 0.35 : -0.35, 0),
                              end: Offset.zero)
                          .animate(anim),
                      child: child,
                    ),
                  );
                },
                child: page == null ? _mainList(context) : _subPage(context, page),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An icon button that opens a genie menu of [entries] (built lazily, so the
/// rows can reflect current state).
class GenieMenuButton extends StatelessWidget {
  const GenieMenuButton({
    super.key,
    required this.entries,
    this.icon = const Icon(Icons.more_vert_rounded),
    this.tooltip = 'Menu',
    this.width = 248,
  });

  final List<GenieMenuEntry> Function() entries;
  final Widget icon;
  final String? tooltip;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (ctx) => IconButton(
        icon: icon,
        tooltip: tooltip,
        onPressed: () => showGenieMenu(ctx,
            anchor: _rectOf(ctx), entries: entries(), width: width),
      ),
    );
  }
}

/// Drop-in replacement for [PopupMenuButton]: same [itemBuilder] /
/// [onSelected] contract, opened with the genie motion. Styling arguments
/// that only made sense for the old popup are accepted and ignored.
class GeniePopupMenuButton<T> extends StatelessWidget {
  const GeniePopupMenuButton({
    super.key,
    required this.itemBuilder,
    this.onSelected,
    this.onCanceled,
    this.icon,
    this.child,
    this.tooltip,
    this.iconSize,
    this.padding = const EdgeInsets.all(8),
    this.enabled = true,
    this.color,
    // accepted for compatibility (unused by the genie surface)
    this.shape,
    this.elevation,
    this.position,
    this.menuPadding,
    this.shadowColor,
    this.offset = Offset.zero,
    this.initialValue,
    this.splashRadius,
    this.constraints,
    this.surfaceTintColor,
    this.iconColor,
  });

  final PopupMenuItemBuilder<T> itemBuilder;
  final PopupMenuItemSelected<T>? onSelected;
  final VoidCallback? onCanceled;
  final Widget? icon;
  final Widget? child;
  final String? tooltip;
  final double? iconSize;
  final EdgeInsetsGeometry padding;
  final bool enabled;
  final Color? color;
  final ShapeBorder? shape;
  final double? elevation;
  final PopupMenuPosition? position;
  final EdgeInsetsGeometry? menuPadding;
  final Color? shadowColor;
  final Offset offset;
  final T? initialValue;
  final double? splashRadius;
  final BoxConstraints? constraints;
  final Color? surfaceTintColor;
  final Color? iconColor;

  void _open(BuildContext ctx) {
    final items = itemBuilder(ctx);
    final entries = <GenieMenuEntry>[];
    for (final it in items) {
      if (it is PopupMenuDivider) {
        entries.add(const GenieMenuEntry.divider());
      } else if (it is PopupMenuItem<T>) {
        final value = it.value;
        final tap = it.onTap;
        entries.add(GenieMenuEntry(
          label: '',
          enabled: it.enabled,
          custom: DefaultTextStyle.merge(
            style: TextStyle(
                fontSize: 14.5, color: Theme.of(ctx).colorScheme.onSurface),
            child: IconTheme.merge(
              data: IconThemeData(color: Theme.of(ctx).colorScheme.primary),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: it.child ?? const SizedBox.shrink(),
                ),
              ),
            ),
          ),
          onTap: () {
            tap?.call();
            if (value != null) onSelected?.call(value as T);
          },
        ));
      }
    }
    if (entries.isEmpty) return;
    showGenieMenu(ctx, anchor: _rectOf(ctx), entries: entries, color: color)
        .then((_) {});
  }

  @override
  Widget build(BuildContext context) {
    return Builder(builder: (ctx) {
      if (child != null) {
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? () => _open(ctx) : null,
          child: tooltip == null || tooltip!.isEmpty
              ? child!
              : Tooltip(message: tooltip!, child: child!),
        );
      }
      return IconButton(
        icon: icon ?? Icon(Icons.more_vert_rounded, color: iconColor),
        iconSize: iconSize,
        padding: padding,
        tooltip: tooltip,
        constraints: constraints,
        splashRadius: splashRadius,
        onPressed: enabled ? () => _open(ctx) : null,
      );
    });
  }
}

/// A rounded card whose outline grows a soft tail toward its opener. The
/// tail is a smooth bell (flat where it leaves the edge, rounded at the tip)
/// so it reads as part of the card. [up] puts it on the top edge (menu opens
/// downward); otherwise it sits on the bottom edge. [tipX] is the tip's x in
/// the card's local space.
class _TailedCardBorder extends ShapeBorder {
  const _TailedCardBorder({
    required this.tipX,
    required this.up,
    this.side = BorderSide.none,
    this.radius = 18,
  });

  final double tipX;
  final bool up;
  final BorderSide side;
  final double radius;

  static const double tailH = 9;
  static const double halfBase = 14;

  /// The tip sits right under the opener's centre. Near an edge the
  /// corner on that side tightens (see [_path]) so the tail can still reach
  /// the button instead of being pushed inward.
  static const double minEdge = 16;
  static double clampTip(double x, double width) {
    if (width <= minEdge * 2) return width / 2;
    return x.clamp(minEdge, width - minEdge);
  }

  @override
  EdgeInsetsGeometry get dimensions =>
      up ? const EdgeInsets.only(top: tailH) : const EdgeInsets.only(bottom: tailH);

  Path _path(Rect rect) {
    // Built with the tail on top, mirrored for a bottom tail.
    final l = rect.left, r = rect.right;
    final t = rect.top + tailH, b = rect.bottom;
    final tip = rect.top;
    final rad = math.min(radius, math.min(rect.width, b - t) / 2);
    final tx = l + clampTip(tipX, rect.width);
    final dl = tx - l, dr = r - tx;
    final hb = math.max(8.0, math.min(halfBase, math.min(dl, dr) - 4));
    // Tail-side corners give way when the tail sits close to them, so the
    // tail flows out of the corner rather than being shoved off the button.
    final rl = (dl - hb - 2).clamp(2.0, rad);
    final rr = (dr - hb - 2).clamp(2.0, rad);
    final p = Path()
      ..moveTo(l + rl, t)
      ..lineTo(tx - hb, t)
      // Flat where it leaves the edge, rounded at the tip.
      ..cubicTo(tx - hb * 0.5, t, tx - hb * 0.32, tip, tx, tip)
      ..cubicTo(tx + hb * 0.32, tip, tx + hb * 0.5, t, tx + hb, t)
      ..lineTo(r - rr, t)
      ..arcToPoint(Offset(r, t + rr), radius: Radius.circular(rr))
      ..lineTo(r, b - rad)
      ..arcToPoint(Offset(r - rad, b), radius: Radius.circular(rad))
      ..lineTo(l + rad, b)
      ..arcToPoint(Offset(l, b - rad), radius: Radius.circular(rad))
      ..lineTo(l, t + rl)
      ..arcToPoint(Offset(l + rl, t), radius: Radius.circular(rl))
      ..close();
    if (up) return p;
    final m = Matrix4.identity()
      ..translateByDouble(0.0, rect.top + rect.bottom, 0.0, 1.0)
      ..scaleByDouble(1.0, -1.0, 1.0, 1.0);
    return p.transform(m.storage);
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => _path(rect);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      _path(rect.deflate(side.width));

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none || side.width == 0) return;
    final paint = side.toPaint()..isAntiAlias = true;
    canvas.drawPath(_path(rect.deflate(side.width / 2)), paint);
  }

  @override
  ShapeBorder scale(double t) => _TailedCardBorder(
      tipX: tipX, up: up, side: side.scale(t), radius: radius * t);

  @override
  bool operator ==(Object other) =>
      other is _TailedCardBorder &&
      other.tipX == tipX &&
      other.up == up &&
      other.side == side &&
      other.radius == radius;

  @override
  int get hashCode => Object.hash(tipX, up, side, radius);
}
