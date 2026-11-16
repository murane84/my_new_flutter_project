import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'seal_directory.dart';
import 'seal_messenger.dart';
import 'seal_primitives.dart';
import 'seal_scope.dart';
import 'seal_space.dart';

/// The one door for sealed 1:1 text. Every message map from the server
/// (history fetch, socket event, push) passes [open] before the app reads
/// its `content`; [sealFor] seals outgoing text. The rest of the app keeps
/// working with plain `content` as before.
class SealIngress {
  SealIngress._();

  /// What the server shows instead of a sealed text (lists, pushes).
  static const String serverPreview = '🔒 Message';
  static const String lockedNoKey = '🔒 Sent before this device was set up';
  static const String lockedFailed = "🔒 Couldn't unlock this message";

  static int? _me;

  static Future<int?> myUid() async {
    if (_me != null) return _me;
    try {
      final s = (await SharedPreferences.getInstance()).getString('my_user_id');
      return _me = int.tryParse(s ?? '');
    } catch (_) {
      return null;
    }
  }

  static int _int(Object? v) => v is int ? v : int.tryParse('$v') ?? 0;

  static bool isSealed(Map<String, dynamic> m) =>
      m['e2ee'] != null && m['is_deleted'] != true;

  /// Unlock [m] in place: `content` becomes the text (or a 🔒 note).
  static Future<void> open(Map<String, dynamic> m) async {
    if (!isSealed(m)) return;
    final me = await myUid();
    SealOpened r;
    try {
      r = me == null
          ? const SealOpened(SealOpenStatus.failed)
          : await SealMessenger.instance.open(m, me);
    } catch (_) {
      r = const SealOpened(SealOpenStatus.failed);
    }
    switch (r.status) {
      case SealOpenStatus.plain:
        return;
      case SealOpenStatus.ok:
        m['content'] = r.text ?? '';
        m.remove('seal_state');
      case SealOpenStatus.noKey:
        m['content'] = lockedNoKey;
        m['seal_state'] = 'nokey';
      case SealOpenStatus.failed:
        m['content'] = lockedFailed;
        m['seal_state'] = 'failed';
    }
  }

  /// [open] every message of a fetched list (in order: oldest first, so a
  /// session moves forward the way it was written).
  static Future<List<Map<String, dynamic>>> openAll(
      List<Map<String, dynamic>> list) async {
    final sealed = list.where(isSealed).toList()
      ..sort((a, b) => _int(a['id']).compareTo(_int(b['id'])));
    for (final m in sealed) {
      await open(m);
    }
    return list;
  }

  /// A socket event: its message travels under `data` (or `message`).
  static Future<void> openEvent(Map<String, dynamic> event) async {
    for (final k in const ['data', 'message']) {
      final d = event[k];
      if (d is Map<String, dynamic> && d['e2ee'] != null) await open(d);
    }
  }

  /// A push for a sealed text: put the unlocked text in `body` when this
  /// phone can read it, without moving any session (the chat opens it for
  /// real). Returns the data to show.
  static Future<Map<String, dynamic>> openPush(Map<String, dynamic> data) async {
    if (data.values.any(SealScope.isSealed)) {
      // 🔒 Our Space words in a push (the server avoids it, but never show
      // a sealed string as text).
      data = await SealSpace.instance.openJson(Map<String, dynamic>.from(data));
    }
    if (data['e2ee'] == null) return data;
    final out = Map<String, dynamic>.from(data);
    try {
      final me = await myUid();
      final env = jsonDecode((data['env'] ?? '{}').toString())
          as Map<String, dynamic>;
      if (me == null || env.isEmpty) return out;
      final m = <String, dynamic>{
        'id': data['message_id'],
        'sender_id': data['sender_id'],
        'receiver_id': me,
        'e2ee': data['e2ee'],
        'e2ee_rev': data['e2ee_rev'],
        'envelopes':
            jsonEncode({for (final e in env.entries) '$me:${e.key}': e.value}),
      };
      final r = await SealMessenger.instance.peek(m, me);
      if (r.status == SealOpenStatus.ok && (r.text ?? '').isNotEmpty) {
        out['body'] = _withoutQuote(r.text!);
      }
    } catch (_) {/* keep "🔒 Message" */}
    return out;
  }

  static String _withoutQuote(String t) {
    if (!t.startsWith('> ')) return t;
    final lines = t.split('\n');
    var k = 0;
    while (k < lines.length && lines[k].startsWith('> ')) {
      k++;
    }
    final rest = lines.skip(k).join('\n').trim();
    return rest.isEmpty ? t : rest;
  }

  /// Friend / conversation lists: the server only knows "🔒 Message"; show
  /// this device's unlocked text when it has it. [peerOf] gives the friend's
  /// id for a row (null = a group row, left alone).
  static Future<void> previews(List<Map<String, dynamic>> rows,
      int? Function(Map<String, dynamic>) peerOf) async {
    for (final r in rows) {
      if ((r['last_message'] ?? '').toString() != serverPreview) continue;
      final peer = peerOf(r);
      final id = _int(r['last_message_id']);
      if (peer == null || id == 0) continue;
      try {
        final t = await SealMessenger.instance.textOf(peer, id);
        if (t != null && t.isNotEmpty) r['last_message'] = t;
      } catch (_) {}
    }
  }

  /// Seal [text] for friend [peer]: the extra fields to send ({e2ee,
  /// envelopes}), or null when the friend can't read sealed text yet (send
  /// it plain, as before). Throws when it should be sealed but can't be
  /// right now — the caller treats that like a failed send.
  static Future<Map<String, dynamic>?> sealFor(int peer, String text) async {
    final me = await myUid();
    if (me == null || peer <= 0 || peer == me) return null;
    try {
      final env = await SealMessenger.instance.seal(peer, me, text);
      return {'e2ee': SealSpec.version, 'envelopes': jsonEncode(env)};
    } on SealNotSupported {
      return null;
    }
  }

  /// After a sealed send / edit: this phone remembers its own text.
  static Future<void> sent(int peer, Map<String, dynamic> msg, String text) =>
      SealMessenger.instance
          .rememberSent(peer, _int(msg['id']), _int(msg['e2ee_rev']), text);

  /// A morning message's text, kept on this phone until it goes out.
  static Future<void> rememberHeld(int peer, int heldId, String text) =>
      SealMessenger.instance.rememberHeld(peer, heldId, text);

  static Future<String> heldText(int peer, Object? heldId) async =>
      await SealMessenger.instance.recallHeld(peer, _int(heldId)) ?? '🔒';

  /// Sign-out: off the key directory, every key, session and text forgotten.
  static Future<void> signOut() async {
    // Sessions and Our Space keys first: they're filed under this device's
    // id, which the directory sign-out forgets with the keys.
    await SealMessenger.instance.wipe();
    await SealSpace.instance.wipe();
    await SealDirectory.instance.signOut();
    _me = null;
  }
}
