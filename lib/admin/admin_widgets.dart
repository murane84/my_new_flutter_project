import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Color kAdminRed = Color(0xFFD90429); // Aluta brand red

// ── Theme (dark / light, remembered on this browser) ─────────────────────────

final ValueNotifier<ThemeMode> adminThemeMode =
    ValueNotifier<ThemeMode>(ThemeMode.dark);
const _kThemeKey = 'aluta_admin_theme';

Future<void> loadAdminTheme() async {
  try {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_kThemeKey);
    if (v == 'light') adminThemeMode.value = ThemeMode.light;
    if (v == 'dark') adminThemeMode.value = ThemeMode.dark;
  } catch (_) {}
}

Future<void> toggleAdminTheme() async {
  final next =
      adminThemeMode.value == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
  adminThemeMode.value = next;
  try {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kThemeKey, next == ThemeMode.dark ? 'dark' : 'light');
  } catch (_) {}
}

/// Surface + text colours for the dashboard in either theme.
class AdminPalette {
  const AdminPalette({
    required this.dark,
    required this.bg,
    required this.bar,
    required this.card,
    required this.card2,
    required this.text,
    required this.muted,
    required this.faint,
    required this.border,
  });
  final bool dark;
  final Color bg, bar, card, card2, text, muted, faint, border;

  static const darkP = AdminPalette(
    dark: true,
    bg: Color(0xFF0F0F14),
    bar: Color(0xFF15151C),
    card: Color(0xFF1B1B24),
    card2: Color(0xFF262633),
    text: Colors.white,
    muted: Color(0xB3FFFFFF),
    faint: Color(0x61FFFFFF),
    border: Color(0x1AFFFFFF),
  );

  static const lightP = AdminPalette(
    dark: false,
    bg: Color(0xFFF7F2F3),
    bar: Colors.white,
    card: Colors.white,
    card2: Color(0xFFF3ECEE),
    text: Color(0xFF231417),
    muted: Color(0xFF6E5A5E),
    faint: Color(0xFFA08F93),
    border: Color(0xFFEADFE2),
  );

  static AdminPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? darkP : lightP;
}

extension AdminPaletteX on BuildContext {
  AdminPalette get adm => AdminPalette.of(this);
}

ThemeData adminTheme(Brightness b) {
  final p = b == Brightness.dark ? AdminPalette.darkP : AdminPalette.lightP;
  final scheme = ColorScheme.fromSeed(
    seedColor: kAdminRed,
    brightness: b,
    primary: kAdminRed,
    surface: p.card,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: p.bg,
    dividerColor: p.border,
    cardTheme: CardThemeData(
      color: p.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: p.border),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.bar,
      foregroundColor: p.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: p.bar,
      indicatorColor: kAdminRed.withValues(alpha: p.dark ? 0.25 : 0.12),
      selectedIconTheme: const IconThemeData(color: kAdminRed),
      unselectedIconTheme: IconThemeData(color: p.muted),
      selectedLabelTextStyle: const TextStyle(
          color: kAdminRed, fontWeight: FontWeight.w700, fontSize: 12),
      unselectedLabelTextStyle: TextStyle(color: p.muted, fontSize: 12),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.bar,
      indicatorColor: kAdminRed.withValues(alpha: p.dark ? 0.25 : 0.12),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
          color: s.contains(WidgetState.selected) ? kAdminRed : p.muted)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.card2,
      selectedColor: kAdminRed.withValues(alpha: p.dark ? 0.3 : 0.14),
      side: BorderSide(color: p.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      labelStyle: TextStyle(color: p.text, fontSize: 12.5),
    ),
  );
}

// ── Formatting ───────────────────────────────────────────────────────────────

String fmtBytes(num? b) {
  final v = (b ?? 0).toDouble();
  if (v < 1024) return '${v.toInt()} B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var x = v / 1024;
  var i = 0;
  while (x >= 1024 && i < units.length - 1) {
    x /= 1024;
    i++;
  }
  return '${x.toStringAsFixed(x >= 100 ? 0 : 1)} ${units[i]}';
}

DateTime? parseTime(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  return DateTime.tryParse(iso)?.toLocal();
}

String fmtDateTime(String? iso) {
  final t = parseTime(iso);
  if (t == null) return '—';
  return DateFormat('d MMM yyyy, HH:mm').format(t);
}

String fmtAgo(String? iso) {
  final t = parseTime(iso);
  if (t == null) return 'never';
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  if (d.inDays < 30) return '${d.inDays} d ago';
  return DateFormat('d MMM yyyy').format(t);
}

String fmtInt(num? n) => NumberFormat.decimalPattern().format(n ?? 0);

// ── Building blocks ──────────────────────────────────────────────────────────

/// Aluta-style gradient icon chip (the attach sheet's look).
class AdminIconChip extends StatelessWidget {
  const AdminIconChip(
      {super.key, required this.icon, required this.color, this.size = 34});
  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.32),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(color, Colors.white, 0.18)!,
            Color.lerp(color, Colors.black, 0.18)!,
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.35),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Icon(icon, size: size * 0.55, color: Colors.white),
    );
  }
}

/// A small tinted message line (info or error).
class AdminInline extends StatelessWidget {
  const AdminInline({super.key, required this.text, this.error = false});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final c = error ? const Color(0xFFEF5350) : const Color(0xFF42A5F5);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(error ? Icons.error_outline_rounded : Icons.info_outline_rounded,
              size: 18, color: c),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}

class AdminCodesGrid extends StatelessWidget {
  const AdminCodesGrid({super.key, required this.codes});
  final List<String> codes;

  @override
  Widget build(BuildContext context) {
    final p = context.adm;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final c in codes)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: p.card2,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: p.border),
            ),
            child: SelectableText(c,
                style: TextStyle(
                    color: p.text,
                    fontFamily: 'monospace',
                    fontSize: 16,
                    letterSpacing: 1.5)),
          ),
      ],
    );
  }
}

/// Page title with a gradient icon chip.
class AdminPageTitle extends StatelessWidget {
  const AdminPageTitle({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = context.adm;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          AdminIconChip(icon: icon, color: kAdminRed, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: p.text,
                        fontSize: 22,
                        fontWeight: FontWeight.w800)),
                if (subtitle != null)
                  Text(subtitle!,
                      style: TextStyle(color: p.muted, fontSize: 13)),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Titled card section with an icon chip.
class AdminSection extends StatelessWidget {
  const AdminSection({
    super.key,
    required this.title,
    required this.child,
    this.icon,
    this.color = kAdminRed,
    this.trailing,
    this.subtitle,
  });
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color color;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = context.adm;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  AdminIconChip(icon: icon!, color: color, size: 32),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: TextStyle(
                              color: p.text,
                              fontSize: 16,
                              fontWeight: FontWeight.w700)),
                      if (subtitle != null)
                        Text(subtitle!,
                            style: TextStyle(color: p.muted, fontSize: 12)),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

class AdminStat extends StatelessWidget {
  const AdminStat({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.hint,
    this.accent = kAdminRed,
    this.onTap,
  });
  final String label;
  final String value;
  final IconData icon;
  final String? hint;
  final Color accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.adm;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          children: [
            // Soft accent glow in the corner.
            Positioned(
              right: -30,
              top: -30,
              child: Container(
                width: 90,
                height: 90,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withValues(alpha: p.dark ? 0.10 : 0.07),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      AdminIconChip(icon: icon, color: accent, size: 30),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: p.muted,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(value,
                      style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: p.text)),
                  Text(hint ?? ' ',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.faint, fontSize: 11.5)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Responsive grid of stat tiles (2 columns on phones, more on wide screens).
class AdminStatGrid extends StatelessWidget {
  const AdminStatGrid({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth > 900 ? 4 : c.maxWidth > 560 ? 3 : 2;
      const gap = 12.0;
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final ch in children) SizedBox(width: w, child: ch)],
      );
    });
  }
}

/// Daily column chart: one rounded gradient bar per {date,count}.
class AdminDailyBars extends StatelessWidget {
  const AdminDailyBars(
      {super.key, required this.days, this.color = kAdminRed, this.height = 120});
  final List<Map<String, dynamic>> days;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final p = context.adm;
    if (days.isEmpty) {
      return Text('No data yet', style: TextStyle(color: p.muted));
    }
    final counts = [for (final d in days) (d['count'] as num?)?.toInt() ?? 0];
    final maxV = counts.fold<int>(0, (a, b) => b > a ? b : a);
    String lbl(int i) {
      final s = (days[i]['date'] ?? '').toString();
      final t = DateTime.tryParse(s);
      return t == null ? s : DateFormat('d MMM').format(t);
    }

    final barW = counts.length > 40 ? 0.5 : 1.5;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < counts.length; i++)
                Expanded(
                  child: Tooltip(
                    message: '${lbl(i)}: ${counts[i]}',
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: barW),
                      child: Container(
                        height: maxV == 0
                            ? 3
                            : 3 + (height - 3) * counts[i] / maxV,
                        decoration: BoxDecoration(
                          borderRadius:
                              const BorderRadius.vertical(top: Radius.circular(5)),
                          color: counts[i] == 0 ? p.border : null,
                          gradient: counts[i] == 0
                              ? null
                              : LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    color,
                                    color.withValues(alpha: 0.45),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(lbl(0), style: TextStyle(color: p.faint, fontSize: 11)),
            const Spacer(),
            Text('peak ${fmtInt(maxV)} / day',
                style: TextStyle(color: p.faint, fontSize: 11)),
            const Spacer(),
            Text(lbl(counts.length - 1),
                style: TextStyle(color: p.faint, fontSize: 11)),
          ],
        ),
      ],
    );
  }
}

/// Horizontal share bars: label · bar · value.
class AdminShareBars extends StatelessWidget {
  const AdminShareBars({super.key, required this.rows, this.color = kAdminRed});

  /// (label, value, display text)
  final List<(String, num, String)> rows;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final p = context.adm;
    if (rows.isEmpty) {
      return Text('No data yet', style: TextStyle(color: p.muted));
    }
    final total = rows.fold<num>(0, (a, r) => a + r.$2);
    final maxV = rows.fold<num>(0, (a, r) => r.$2 > a ? r.$2 : a);
    return Column(
      children: [
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 136,
                  child: Text(r.$1,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: p.text)),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: maxV == 0 ? 0 : (r.$2 / maxV).toDouble(),
                      minHeight: 10,
                      backgroundColor: p.border,
                      color: color,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 96,
                  child: Text(
                    total == 0
                        ? r.$3
                        : '${r.$3} · ${(100 * r.$2 / total).round()}%',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 12, color: p.muted),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Password box with the show/hide eye.
class AdminPasswordField extends StatefulWidget {
  const AdminPasswordField({
    super.key,
    required this.controller,
    this.label = 'Your Aluta password',
    this.autofocus = false,
    this.onSubmitted,
  });
  final TextEditingController controller;
  final String label;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  @override
  State<AdminPasswordField> createState() => _AdminPasswordFieldState();
}

class _AdminPasswordFieldState extends State<AdminPasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      obscureText: _obscure,
      autofocus: widget.autofocus,
      onSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        labelText: widget.label,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        prefixIcon: const Icon(Icons.lock_outline_rounded, size: 20),
        suffixIcon: IconButton(
          tooltip: _obscure ? 'Show password' : 'Hide password',
          icon: Icon(_obscure
              ? Icons.visibility_off_rounded
              : Icons.visibility_rounded),
          onPressed: () => setState(() => _obscure = !_obscure),
        ),
      ),
    );
  }
}

/// Ask for the owner password (step-up) — returns null when cancelled.
Future<String?> askPassword(BuildContext context,
    {required String title, String? message, String action = 'Confirm'}) {
  final ctl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message != null) ...[
            Text(message, style: TextStyle(color: ctx.adm.muted)),
            const SizedBox(height: 12),
          ],
          AdminPasswordField(
            controller: ctl,
            autofocus: true,
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text),
            child: Text(action)),
      ],
    ),
  );
}

void adminToast(BuildContext context, String text, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(text),
    behavior: SnackBarBehavior.floating,
    backgroundColor: error ? const Color(0xFFB71C1C) : null,
  ));
}
