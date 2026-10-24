/// Messages the home socket received while their chat was CLOSED, held in
/// memory so opening that chat paints them instantly (with the "N new
/// messages" divider) instead of waiting for the history fetch. The badge and
/// the peek on the chat list come from the same event, so now the thread
/// agrees with them from the first frame.
class LiveInbox {
  LiveInbox._();
  static final LiveInbox instance = LiveInbox._();

  static const _keep = Duration(minutes: 30);
  static const _perThread = 60;

  // thread key ('d<friendId>' | 'g<conversationId>') → newest-first messages
  final Map<String, List<({DateTime at, Map<String, dynamic> msg})>> _byThread =
      {};

  static String? _keyOf(Map<String, dynamic> m, String? myId) {
    final rid = m['receiver_id']?.toString();
    final sid = (m['sender_id'] ?? (m['sender'] as Map?)?['id'])?.toString();
    if (rid != null && rid.isNotEmpty && rid != 'null') {
      final other = sid == myId ? rid : sid;
      return other == null ? null : 'd$other';
    }
    final cid = m['conversation_id']?.toString();
    return (cid == null || cid.isEmpty) ? null : 'g$cid';
  }

  void add(Map<String, dynamic> msg, String? myId) {
    if (msg['id'] == null) return;
    final key = _keyOf(msg, myId);
    if (key == null) return;
    final list = _byThread.putIfAbsent(key, () => []);
    final id = msg['id'].toString();
    list.removeWhere((e) => e.msg['id'].toString() == id);
    list.insert(0, (at: DateTime.now(), msg: Map<String, dynamic>.from(msg)));
    if (list.length > _perThread) list.removeRange(_perThread, list.length);
  }

  /// The fresh messages for a DM ([friendId]) or group ([conversationId]),
  /// newest first. They stay until [clear] (the chat's own fetch has them).
  List<Map<String, dynamic>> peek({int? friendId, int? conversationId}) {
    final key = conversationId != null ? 'g$conversationId' : 'd$friendId';
    final list = _byThread[key];
    if (list == null) return const [];
    final cutoff = DateTime.now().subtract(_keep);
    list.removeWhere((e) => e.at.isBefore(cutoff));
    return [for (final e in list) Map<String, dynamic>.from(e.msg)];
  }

  void clear({int? friendId, int? conversationId}) =>
      _byThread.remove(conversationId != null ? 'g$conversationId' : 'd$friendId');
}
