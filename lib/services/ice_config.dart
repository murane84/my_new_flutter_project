import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/app_config.dart';
import '../screens/token_helper.dart';

/// Shared STUN/TURN (ICE) configuration for ALL WebRTC in the app — voice calls
/// AND "Listen Together" live sessions.
///
/// Why this exists: the ICE servers used to be hard-coded (copy-pasted) inside
/// both call_service.dart and live_session_service.dart. When the free public
/// TURN they pointed at (openrelay.metered.ca) was decommissioned, every
/// cross-network call/session silently hung — and the only fix would have been
/// rebuilding and reshipping the app.
///
/// Now the server owns the config (`GET /webrtc/ice`), so a TURN provider can be
/// swapped or renewed with a backend env-var change that reaches every client
/// instantly — no rebuild. Both services fetch through this one place, so they
/// can never drift apart again.
///
/// Fail-safe: if the endpoint is ever unreachable we fall back to the last good
/// result, or to STUN-only — so WebRTC is never WORSE than "can't relay", it
/// just can't punch through restrictive NATs until TURN is reachable again.
class IceConfig {
  IceConfig._();
  static final IceConfig instance = IceConfig._();

  // STUN-only last resort. Enough for same-network / friendly-NAT peers; a
  // relay (TURN) is what the server adds on top for cross-network reliability.
  static const Map<String, dynamic> _fallback = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  Map<String, dynamic>? _cached;
  DateTime? _fetchedAt;
  // Re-fetch periodically so renewed/ephemeral TURN credentials stay fresh and
  // a provider swap on the server is picked up without restarting the app.
  static const Duration _ttl = Duration(minutes: 10);

  /// The ICE configuration to hand to `createPeerConnection`. Cached for a few
  /// minutes; refreshed from the server in the background of normal use.
  Future<Map<String, dynamic>> servers() async {
    final cached = _cached;
    final at = _fetchedAt;
    if (cached != null && at != null &&
        DateTime.now().difference(at) < _ttl) {
      return cached;
    }
    try {
      final base = await AppConfig.baseUrl;
      final token = await getToken();
      final res = await http.get(
        Uri.parse('$base/webrtc/ice'),
        headers: {
          if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
        },
      ).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        final list = (body is Map) ? body['iceServers'] : null;
        if (list is List && list.isNotEmpty) {
          final cfg = <String, dynamic>{
            'iceServers': list,
            'sdpSemantics': 'unified-plan',
          };
          _cached = cfg;
          _fetchedAt = DateTime.now();
          return cfg;
        }
      }
    } catch (_) {
      // fall through to cache / STUN-only
    }
    return _cached ?? _fallback;
  }

  /// Force the next `servers()` call to re-fetch (e.g. after a network change).
  void invalidate() {
    _cached = null;
    _fetchedAt = null;
  }
}
