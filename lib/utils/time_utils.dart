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

/// Human "last seen" label in local time.
String formatLastSeen(String raw) {
  if (raw.trim().isEmpty) return '';
  final dt = parseServerTime(raw);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(dt.year, dt.month, dt.day);
  final diff = today.difference(day).inDays;
  final t = DateFormat('h:mm a').format(dt);
  if (diff <= 0) return 'today at $t';
  if (diff == 1) return 'yesterday at $t';
  if (diff < 7) return '${DateFormat('EEEE').format(dt)} at $t';
  return DateFormat('MMM d, h:mm a').format(dt);
}
