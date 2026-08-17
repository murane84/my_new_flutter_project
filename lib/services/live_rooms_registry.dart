import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../utils/app_config.dart';
import '../screens/token_helper.dart';

/// Tracks the OPEN "Listening Rooms" my friends are hosting right now, so the
/// friend list's "Live Room" slot can offer a one-tap drop-in.
///
/// Fed three ways, all funneling here:
///  • `live_room_available` / `live_room_ended` events on the home socket
///    (a friend opens or closes a room while I'm online), and
///  • `GET /live/rooms` on a fresh friend-list load (rooms already live when I
///    came online).
///
/// Keyed by host id (a host has at most one live room), newest first. A
/// [ChangeNotifier] so the card repaints the moment a room appears/disappears.
class LiveRoomsRegistry extends ChangeNotifier {
  LiveRoomsRegistry._();
  static final LiveRoomsRegistry instance = LiveRoomsRegistry._();

  // host_id -> {session_id, host_id, host_username, track, _seq}
  final Map<int, Map<String, dynamic>> _rooms = {};
  int _seq = 0; // monotonic recency counter (newest = highest)

  List<Map<String, dynamic>> get rooms {
    final list = _rooms.values.toList();
    list.sort((a, b) => (b['_seq'] as int).compareTo(a['_seq'] as int));
    return list;
  }

  bool get hasRooms => _rooms.isNotEmpty;
  int get count => _rooms.length;
  Map<String, dynamic>? get mostRecent => hasRooms ? rooms.first : null;

  void _put(Map data) {
    final hostId = (data['host_id'] as num?)?.toInt();
    final sid = data['session_id'] as String?;
    if (hostId == null || sid == null) return;
    _rooms[hostId] = {
      'session_id': sid,
      'host_id': hostId,
      'host_username': (data['host_username'] ?? '').toString(),
      'track': data['track'],
      '_seq': _seq++,
    };
  }

  /// A friend opened (or updated) a room.
  void applyAvailable(Map data) {
    _put(data);
    notifyListeners();
  }

  /// A friend's room ended. Removes only if the ended session matches the one we
  /// hold (so a same-host restart isn't wiped by a stale 'ended').
  void applyEnded(Map data) {
    final hostId = (data['host_id'] as num?)?.toInt();
    final sid = data['session_id'] as String?;
    var changed = false;
    if (hostId != null && _rooms.containsKey(hostId)) {
      if (sid == null || _rooms[hostId]!['session_id'] == sid) {
        _rooms.remove(hostId);
        changed = true;
      }
    } else if (sid != null) {
      final before = _rooms.length;
      _rooms.removeWhere((_, v) => v['session_id'] == sid);
      changed = _rooms.length != before;
    }
    if (changed) notifyListeners();
  }

  /// Drop a room by its session id (e.g. after we join/leave it).
  void removeSession(String sessionId) {
    final before = _rooms.length;
    _rooms.removeWhere((_, v) => v['session_id'] == sessionId);
    if (_rooms.length != before) notifyListeners();
  }

  /// Seed from the server — live rooms hosted by a friend right now.
  Future<void> loadSnapshot() async {
    try {
      final base = await AppConfig.baseUrl;
      final token = await getToken();
      final res = await http.get(
        Uri.parse('$base/live/rooms'),
        headers: {
          if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
        },
      ).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        final list = (body is Map) ? body['rooms'] : null;
        if (list is List) {
          _rooms.clear();
          for (final r in list) {
            if (r is Map) _put(r);
          }
          notifyListeners();
        }
      }
    } catch (_) {
      // best-effort; events will still populate us live
    }
  }

  void clearAll() {
    if (_rooms.isEmpty) return;
    _rooms.clear();
    notifyListeners();
  }
}
