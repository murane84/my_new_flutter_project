// Shared helpers for chat-list last-message previews.
//
// A "listen together" (live) or call log stores its outcome as a bare token in
// the message content (e.g. 'noanswer', 'declined', 'busy'). When that token
// reaches a chat list as a raw last_message — for instance a server-provided
// preview that carries no message type — the row would otherwise read awkwardly
// ("noanswer"). [mapOutcomeToken] turns such a token into a friendly label; it
// returns null for ordinary text so callers fall back to the original string.

const Map<String, String> _kOutcomeTokens = <String, String>{
  'listened': '🎧 Listened together',
  'noanswer': 'No answer',
  'declined': 'Declined',
  'busy': '📞 Line busy',
  'unreachable': '📞 Unreachable',
  'failed': '📞 Call failed',
  'cancelled': '📞 Call cancelled',
  'missed': '📞 Missed call',
  'answered': '📞 Call',
};

/// Friendly label for a bare call / listen-together outcome token, or null when
/// [raw] is ordinary message text that should be shown as-is.
String? mapOutcomeToken(String raw) =>
    _kOutcomeTokens[raw.trim().toLowerCase()];
