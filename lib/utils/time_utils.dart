import 'package:intl/intl.dart';

/// Parses a server timestamp and returns it in the DEVICE's local timezone.
///
/// Server timestamps are UTC. If the string has no timezone marker (e.g.
/// "2026-08-03 06:14:00"), we assume UTC and append 'Z' before parsing — that's
/// the fix for times showing 3h off in East Africa (UTC+3), etc. If a marker is
/// already present (Z or ±hh:mm) we respect it. Either way we convert to local.
DateTime parseServerTime(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return DateTime.now();
  // Normalise "yyyy-MM-dd HH:mm:ss" → ISO "yyyy-MM-ddTHH:mm:ss".
  if (!s.contains('T') && s.contains(' ')) {
    s = s.replaceFirst(' ', 'T');
  }
  final hasTz = s.endsWith('Z') || RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(s);
  if (!hasTz) s = '${s}Z';
  try {
    return DateTime.parse(s).toLocal();
  } catch (_) {
    return DateTime.now();
  }
}

/// Short local time, e.g. "9:14 AM".
String localTimeOnly(String raw) =>
    DateFormat('h:mm a').format(parseServerTime(raw));

/// A receipt's time ("Opened …", "Delivered …", "Read by …"), read beside
/// the message it belongs to: just the time when it happened the same day the
/// message was sent — otherwise with its day, so "Opened 3:31 PM" under a
/// 6:32 PM message can never look like it was opened before it was sent.
///   same day as sent → "3:31 PM"
///   today            → "Today, 3:31 PM"
///   yesterday        → "Yesterday, 3:31 PM"
///   this year        → "13 Nov, 3:31 PM"
///   older            → "13 Nov 2025, 3:31 PM"
/// [sentAt]: the message's own time (when unknown, today is the reference).
String receiptTime(DateTime when, {DateTime? sentAt}) {
  final w = when.toLocal();
  final time = DateFormat('h:mm a').format(w);
  DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);
  final ref = day((sentAt ?? DateTime.now()).toLocal());
  final d = day(w);
  if (d == ref) return time;
  final today = day(DateTime.now());
  if (d == today) return 'Today, $time';
  if (d == today.subtract(const Duration(days: 1))) return 'Yesterday, $time';
  if (w.year == today.year) return '${DateFormat('d MMM').format(w)}, $time';
  return '${DateFormat('d MMM yyyy').format(w)}, $time';
}

/// [receiptTime] for server timestamps ('' when there's none).
String receiptTimeOf(String? raw, {String? sentRaw}) {
  if (raw == null || raw.trim().isEmpty) return '';
  final sent =
      (sentRaw == null || sentRaw.trim().isEmpty) ? null : parseServerTime(sentRaw);
  return receiptTime(parseServerTime(raw), sentAt: sent);
}

/// Human "last seen" label in local time.
String formatLastSeen(String raw) {
  if (raw.trim().isEmpty) return '';
  final dt = parseServerTime(raw);
  final now = DateTime.now();
  // The first hour reads as a moment, not a clock time.
  final ago = now.difference(dt);
  if (ago.inMinutes < 1) return 'just now';
  if (ago.inMinutes < 60) return '${ago.inMinutes} min ago';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(dt.year, dt.month, dt.day);
  final diff = today.difference(day).inDays;
  final t = DateFormat('h:mm a').format(dt);
  if (diff <= 0) return 'today at $t';
  if (diff == 1) return 'yesterday at $t';
  if (diff < 7) return '${DateFormat('EEEE').format(dt)} at $t';
  return DateFormat('MMM d, h:mm a').format(dt);
}
