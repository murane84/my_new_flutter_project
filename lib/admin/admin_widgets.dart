import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

const Color kAdminRed = Color(0xFFC62828);
const Color kAdminCard = Color(0xFF1B1B24);
const Color kAdminCard2 = Color(0xFF242431);

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

class AdminNotice extends StatelessWidget {
  const AdminNotice(
      {super.key, required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 36, color: kAdminRed),
            const SizedBox(height: 12),
            Text(title,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(body, style: const TextStyle(color: Colors.white70)),
          ],
        ),
      ),
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
    final c = error ? const Color(0xFFEF5350) : const Color(0xFF64B5F6);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(error ? Icons.error_outline : Icons.info_outline,
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
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final c in codes)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: kAdminCard2,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(c,
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 16,
                    letterSpacing: 1.5)),
          ),
      ],
    );
  }
}

/// Titled card section.
class AdminSection extends StatelessWidget {
  const AdminSection(
      {super.key, required this.title, required this.child, this.trailing, this.subtitle});
  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle!,
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class AdminStat extends StatelessWidget {
  const AdminStat(
      {super.key,
      required this.label,
      required this.value,
      this.icon,
      this.hint,
      this.accent});
  final String label;
  final String value;
  final IconData? icon;
  final String? hint;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final a = accent ?? Colors.white;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kAdminCard,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: a.withValues(alpha: 0.8)),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(color: Colors.white60, fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(value,
              style: TextStyle(
                  fontSize: 24, fontWeight: FontWeight.w800, color: a)),
          if (hint != null)
            Text(hint!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
        ],
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
      const gap = 10.0;
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final ch in children) SizedBox(width: w, child: ch)],
      );
    });
  }
}

/// Simple daily column chart: one bar per {date,count}.
class AdminDailyBars extends StatelessWidget {
  const AdminDailyBars(
      {super.key, required this.days, this.color = kAdminRed, this.height = 120});
  final List<Map<String, dynamic>> days;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (days.isEmpty) {
      return const Text('No data yet', style: TextStyle(color: Colors.white54));
    }
    final counts = [for (final d in days) (d['count'] as num?)?.toInt() ?? 0];
    final maxV = counts.fold<int>(0, (a, b) => b > a ? b : a);
    String lbl(int i) {
      final s = (days[i]['date'] ?? '').toString();
      final t = DateTime.tryParse(s);
      return t == null ? s : DateFormat('d MMM').format(t);
    }

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
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: Container(
                        height: maxV == 0
                            ? 2
                            : 2 + (height - 2) * counts[i] / maxV,
                        decoration: BoxDecoration(
                          color: counts[i] == 0
                              ? Colors.white12
                              : color.withValues(alpha: 0.85),
                          borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(3)),
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
            Text(lbl(0),
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
            const Spacer(),
            Text('max ${fmtInt(maxV)} / day',
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
            const Spacer(),
            Text(lbl(counts.length - 1),
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
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
    if (rows.isEmpty) {
      return const Text('No data yet', style: TextStyle(color: Colors.white54));
    }
    final total = rows.fold<num>(0, (a, r) => a + r.$2);
    final maxV = rows.fold<num>(0, (a, r) => r.$2 > a ? r.$2 : a);
    return Column(
      children: [
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                SizedBox(
                  width: 130,
                  child: Text(r.$1,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13)),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: maxV == 0 ? 0 : (r.$2 / maxV).toDouble(),
                      minHeight: 10,
                      backgroundColor: Colors.white10,
                      color: color,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 92,
                  child: Text(
                    total == 0
                        ? r.$3
                        : '${r.$3} · ${(100 * r.$2 / total).round()}%',
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ),
              ],
            ),
          ),
      ],
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
            Text(message, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: ctl,
            obscureText: true,
            autofocus: true,
            onSubmitted: (v) => Navigator.pop(ctx, v),
            decoration: const InputDecoration(
                labelText: 'Your Aluta password', border: OutlineInputBorder()),
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
    backgroundColor: error ? const Color(0xFFB71C1C) : null,
  ));
}
