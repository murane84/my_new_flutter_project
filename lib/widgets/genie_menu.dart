import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_busy.dart';

// ─── Genie menus ────────────────────────────────────────────────────────────
// One menu motion for the whole app: a menu GROWS out of the button that
// opened it (scaling from that corner with a soft overshoot, fading in, its
// rows drifting in one after another) and folds back INTO it on dismiss.
// Submenus open inline (accordion) with the same easing instead of popping a
// second floating card. Back / tap-outside / Esc all close it.
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

class _GenieMenuSurface extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final pad = media.padding;
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;

    // Place the card beside the opener: right-aligned to it when the button
    // is on the right half, left-aligned otherwise; below it when there's
    // room, else above. The card grows from the corner nearest the button.
    final w = math.min(width, size.width - 16);
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
    final fill = color ??
        (isDark
            ? Color.alphaBlend(
                Colors.white.withValues(alpha: 0.05), scheme.surface)
            : scheme.surface);

    return Stack(
      children: [
        Positioned(
          left: left,
          width: w,
          top: openDown ? below : null,
          bottom: openDown ? null : size.height - anchor.top + gap,
          child: AnimatedBuilder(
            animation: animation,
            builder: (context, child) {
              final v = animation.value;
              final reverse = animation.status == AnimationStatus.reverse;
              // Genie: width leads with a little overshoot, height follows,
              // the whole card fades in. Folding back is quicker and flatter.
              final sx = reverse
                  ? Curves.easeIn.transform(v)
                  : Curves.easeOutBack.transform(v);
              final sy = reverse
                  ? Curves.easeIn.transform(v)
                  : Curves.easeOutCubic
                      .transform(((v - 0.05) / 0.95).clamp(0.0, 1.0));
              final fade = Curves.easeOut.transform((v * 1.6).clamp(0.0, 1.0));
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
              constraints: BoxConstraints(maxHeight: maxH.clamp(120.0, 640.0)),
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
                      tipX: tailX,
                      up: openDown,
                      side: BorderSide(
                          color: scheme.primary
                              .withValues(alpha: isDark ? 0.30 : 0.22)),
                    ),
                    shadows: [
                      BoxShadow(
                        color: Colors.black
                            .withValues(alpha: isDark ? 0.5 : 0.16),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _GenieMenuList(
                    entries: entries,
                    animation: animation,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GenieMenuList extends StatefulWidget {
  const _GenieMenuList({required this.entries, required this.animation});
  final List<GenieMenuEntry> entries;
  final Animation<double> animation;

  @override
  State<_GenieMenuList> createState() => _GenieMenuListState();
}

class _GenieMenuListState extends State<_GenieMenuList> {
  int? _open; // index of the expanded submenu

  void _run(GenieMenuEntry e) {
    if (!e.enabled) return;
    if (e.children != null) {
      HapticFeedback.selectionClick();
      setState(() => _open = _open == widget.entries.indexOf(e)
          ? null
          : widget.entries.indexOf(e));
      return;
    }
    Navigator.of(context).pop();
    // Run after the fold-back starts so the menu doesn't linger over the
    // next screen.
    Future.microtask(() => e.onTap?.call());
  }

  @override
  Widget build(BuildContext context) {
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
      Widget row;
      if (e.isDivider) {
        row = Divider(
            height: 10,
            indent: 14,
            endIndent: 14,
            color: scheme.outlineVariant.withValues(alpha: 0.5));
      } else {
        final open = _open == i;
        row = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _row(context, e, open: open),
            if (e.children != null)
              AnimatedSize(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: open
                    ? Container(
                        margin: const EdgeInsets.fromLTRB(10, 0, 10, 4),
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final c in e.children!)
                              c.isDivider
                                  ? const Divider(height: 8)
                                  : _row(context, c, nested: true),
                          ],
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
          ],
        );
      }
      rows.add(FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, -0.25), end: Offset.zero)
              .animate(anim),
          child: row,
        ),
      ));
    }
    return Shortcuts(
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
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: rows,
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, GenieMenuEntry e,
      {bool open = false, bool nested = false}) {
    final scheme = Theme.of(context).colorScheme;
    final accent = e.destructive ? scheme.error : scheme.primary;
    final textColor = !e.enabled
        ? scheme.onSurface.withValues(alpha: 0.38)
        : (e.destructive ? scheme.error : scheme.onSurface);
    return InkWell(
      onTap: e.enabled ? () => _run(e) : null,
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
                          fontWeight: FontWeight.w500,
                          color: textColor)),
                ),
                if (e.trailing != null) e.trailing!,
                if (e.children != null)
                  AnimatedRotation(
                    turns: open ? 0.25 : 0,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    child: Icon(Icons.chevron_right_rounded,
                        size: 20, color: scheme.onSurfaceVariant),
                  ),
              ],
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

  /// Keep the tail's base off the rounded corners.
  static double clampTip(double x, double width) {
    const m = 18 + halfBase + 4;
    if (width <= m * 2) return width / 2;
    return x.clamp(m, width - m);
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
    final hb = math.min(halfBase, rect.width / 2 - rad);
    final p = Path()
      ..moveTo(l + rad, t)
      ..lineTo(tx - hb, t)
      // Flat where it leaves the edge, rounded at the tip.
      ..cubicTo(tx - hb * 0.5, t, tx - hb * 0.32, tip, tx, tip)
      ..cubicTo(tx + hb * 0.32, tip, tx + hb * 0.5, t, tx + hb, t)
      ..lineTo(r - rad, t)
      ..arcToPoint(Offset(r, t + rad), radius: Radius.circular(rad))
      ..lineTo(r, b - rad)
      ..arcToPoint(Offset(r - rad, b), radius: Radius.circular(rad))
      ..lineTo(l + rad, b)
      ..arcToPoint(Offset(l, b - rad), radius: Radius.circular(rad))
      ..lineTo(l, t + rad)
      ..arcToPoint(Offset(l + rad, t), radius: Radius.circular(rad))
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
