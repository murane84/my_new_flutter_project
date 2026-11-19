import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../services/media_store.dart';
import 'seal_directory.dart';
import 'seal_keystore.dart';
import 'seal_media.dart';
import 'seal_messenger.dart';
import 'seal_primitives.dart';
import 'seal_scope.dart';
import 'seal_space.dart';
import 'seal_tab.dart';

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

  /// The signed-in person's id — read fresh every time (never cached here):
  /// after a session expires someone else may sign in without the app
  /// restarting, and sealing for the wrong id would break every message.
  static Future<int?> myUid() async {
    try {
      final s = (await SharedPreferences.getInstance()).getString('my_user_id');
      return int.tryParse(s ?? '');
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
    // A timed heart from before its copies travelled with it: covered.
    if (m['message_type'] == 'heart' && m['envelopes'] == null) return;
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
        // A timed heart is opened now (its key can't wait for the moment)
        // but stays covered — for its sender too — until unlock_at.
        m['content'] = _stillTimed(m) ? '' : r.caption;
        m.remove('seal_state');
        _attachMedia(m, r.media);
      case SealOpenStatus.noKey:
        m['content'] = lockedNoKey;
        m['seal_state'] = 'nokey';
      case SealOpenStatus.failed:
        m['content'] = lockedFailed;
        m['seal_state'] = 'failed';
    }
  }

  /// A sealed photo / video / voice note / file: its key goes on the media
  /// address (kept on this device), its real name and type back on the
  /// message — so every viewer, player and download opens it.
  static void _attachMedia(Map<String, dynamic> m, Map<String, dynamic>? media) {
    final url = m['media_url'];
    if (media == null || url is! String || url.isEmpty) return;
    try {
      final key = base64Url.decode(base64Url.normalize('${media['k']}'));
      if (key.length != 32) return;
      m['media_url'] = SealMedia.withKey(url, key);
      final n = '${media['n'] ?? ''}'.trim();
      if (n.isNotEmpty) m['media_name'] = n;
      final t = '${media['mm'] ?? ''}'.trim();
      if (t.isNotEmpty) m['media_mime'] = t;
    } catch (_) {}
  }

  /// [open] every message of a fetched list (in order: oldest first, so a
  /// session moves forward the way it was written).
  static Future<List<Map<String, dynamic>>> openAll(
      List<Map<String, dynamic>> list) async {
    // Deleted for everyone (perhaps while this phone was away): its text
    // goes from this device too.
    final gone = [
      for (final m in list)
        if (m['e2ee'] != null && m['is_deleted'] == true) _int(m['id'])
    ];
    if (gone.isNotEmpty) await forget(gone);
    final sealed = list.where(isSealed).toList()
      ..sort((a, b) => _int(a['id']).compareTo(_int(b['id'])));
    for (final m in sealed) {
      await open(m);
    }
    return list;
  }

  /// A socket event: its message travels under `data` (or `message`).
  static Future<void> openEvent(Map<String, dynamic> event) async {
    final type = event['type'];
    if (type == 'message_deleted' || type == 'delete') {
      final d = event['data'];
      final id = event['message_id'] ?? (d is Map ? d['message_id'] : null);
      if (id != null) await forget([_int(id)]);
      return;
    }
    for (final k in const ['data', 'message']) {
      final d = event[k];
      if (d is Map<String, dynamic> && d['e2ee'] != null) {
        // The server says a timed heart's moment has come: trust that over
        // this phone's clock.
        if (event['type'] == 'heart_unsealed') d['__due'] = true;
        await open(d);
      }
    }
  }

  /// A push for a sealed text: put the unlocked text in `body` when this
  /// phone can read it, without moving any session (the chat opens it for
  /// real). Returns the data to show.
  static bool _stillTimed(Map<String, dynamic> m) {
    if (m['message_type'] != 'heart' || m['__due'] == true) return false;
    final ua = DateTime.tryParse('${m['unlock_at'] ?? ''}');
    return ua != null && DateTime.now().toUtc().isBefore(ua.toUtc());
  }

  static Future<Map<String, dynamic>> openPush(Map<String, dynamic> data) async {
    if (data.values.any(SealScope.isSealed)) {
      // 🔒 Our Space words in a push (the server avoids it, but never show
      // a sealed string as text).
      data = await SealSpace.instance.openJson(Map<String, dynamic>.from(data));
    }
    // Someone reacted to my sealed message: the server only knows
    // "🔒 Message" — this phone has my own words.
    if (data['type'] == 'reaction' &&
        ((data['body'] ?? '').toString() == serverPreview ||
            data['sealed'] == '1')) {
      final out = Map<String, dynamic>.from(data);
      final label = (data['body'] ?? '').toString();
      try {
        final s = await SealMessenger.instance
            .storedOfAny(_int(data['message_id']));
        out['body'] = previewOf(label, s);
      } catch (_) {
        out['body'] = label == serverPreview ? '' : label;
      }
      return out;
    }
    if (data['e2ee'] == null) return data;
    // A heart never shows its note in a banner ("❤️ Secret message").
    if (data['msg_kind'] == 'heart') return data;
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
      if (r.status == SealOpenStatus.ok) {
        out['body'] = previewOf((data['body'] ?? '').toString(), r.text);
        return out;
      }
      // Aluta running in the background may have opened this very message
      // a moment ago (its live connection got it too), moving the session
      // past it: its text is then saved on this phone — read it back.
      for (final wait in const [600, 1500]) {
        await Future<void>.delayed(Duration(milliseconds: wait));
        await (await SharedPreferences.getInstance()).reload();
        SealMessenger.instance.dropCaches();
        final t = await SealMessenger.instance
            .storedOf(_int(data['sender_id']), _int(data['message_id']));
        if (t != null && t.isNotEmpty) {
          out['body'] = previewOf((data['body'] ?? '').toString(), t);
          break;
        }
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
      final label = (r['last_message'] ?? '').toString();
      final sealed = r['last_sealed'];
      // Sealed text ("🔒 Message"), or sealed media ("📷 Photo" — its name
      // and caption are only on the phones).
      if (label != serverPreview && !(sealed is String && sealed.isNotEmpty)) {
        continue;
      }
      final peer = peerOf(r);
      final id = _int(r['last_message_id']);
      if (peer == null || id == 0) continue;
      try {
        var t = await SealMessenger.instance.storedOf(peer, id);
        // Not opened on this device yet: the list brings its sealed copy,
        // so open it now (the chat would anyway) rather than show a lock.
        if ((t == null || t.isEmpty) && sealed is String && sealed.isNotEmpty) {
          final m = jsonDecode(sealed) as Map<String, dynamic>;
          await open(m);
          if (m['seal_state'] == null) {
            t = await SealMessenger.instance.storedOf(peer, id) ??
                (m['content'] ?? '').toString();
          }
        }
        if (t != null && t.isNotEmpty) r['last_message'] = previewOf(label, t);
      } catch (_) {}
    }
  }

  /// A list / banner line for a sealed message, from the server's [label]
  /// and this phone's remembered [stored] form: the words for text; for
  /// sealed media the same shape plain media has ("📷 Photo · caption",
  /// "📎 report.pdf · caption").
  static String previewOf(String label, String? stored) {
    final words = _withoutQuote(SealPayload.textOf(stored));
    final media = SealPayload.mediaOf(stored);
    if (media == null) {
      // A shared location / contact keeps its label, never its JSON.
      if (label != serverPreview && words.startsWith('{')) return label;
      return words.isNotEmpty || label == serverPreview ? words : label;
    }
    var head = label == serverPreview ? '' : label;
    final name = '${media['n'] ?? ''}'.trim();
    if (head.startsWith('📎') && name.isNotEmpty) head = '📎 $name';
    if (head.isEmpty) return words;
    return words.isEmpty ? head : '$head · $words';
  }

  /// Seal [text] for friend [peer]: the extra fields to send ({e2ee,
  /// envelopes}), or null when the friend can't read sealed text yet (send
  /// it plain, as before). Throws when it should be sealed but can't be
  /// right now — the caller treats that like a failed send.
  static Future<Map<String, dynamic>?> sealFor(int peer, String text,
      {Map<String, dynamic>? media}) async {
    final me = await myUid();
    if (me == null || peer <= 0 || peer == me) return null;
    try {
      final env =
          await SealMessenger.instance.seal(peer, me, text, media: media);
      return {'e2ee': SealSpec.version, 'envelopes': jsonEncode(env)};
    } on SealNotSupported {
      return null;
    }
  }

  /// After a sealed send / edit: this phone remembers its own text.
  static Future<void> sent(int peer, Map<String, dynamic> msg, String text,
          {Map<String, dynamic>? media}) =>
      SealMessenger.instance.rememberSent(peer, _int(msg['id']),
          _int(msg['e2ee_rev']), SealPayload.store(text, media));

  /// Whether a file for [peer] can go sealed (every device can open it).
  /// Throws [SealError] when it can't be told right now — the send then
  /// fails (and can be retried) instead of going unlocked.
  static Future<bool> canSealMedia(int peer) async {
    final me = await myUid();
    if (me == null || peer <= 0 || peer == me) return false;
    return SealMessenger.instance.canSealMedia(peer, me);
  }

  /// Give a sent / opened message its sealed media's key and real name.
  static void attachMedia(Map<String, dynamic> m, Map<String, dynamic> media) =>
      _attachMedia(m, media);

  /// My own sealed message's text by id (e.g. peeking at my timed heart).
  static Future<String?> textOfMessage(int id) =>
      SealMessenger.instance.textOfAny(id);

  /// A morning message's text, kept on this phone until it goes out.
  static Future<void> rememberHeld(int peer, int heldId, String text) =>
      SealMessenger.instance.rememberHeld(peer, heldId, text);

  static Future<String> heldText(int peer, Object? heldId) async =>
      await SealMessenger.instance.recallHeld(peer, _int(heldId)) ?? '🔒';

  /// Web: this browser tab is in use again — read back what another tab
  /// changed meanwhile (sessions, keys, texts), then catch up.
  static void watchTabs() => SealTab.start(() async {
        await (await SharedPreferences.getInstance()).reload();
        await SealKeyStore.instance.reload();
        SealMessenger.instance.dropCaches();
        SealSpace.instance.dropCaches();
        await SealDirectory.instance.syncSoon();
      });

  /// A message deleted (for me or for everyone): forget its unlocked text.
  static Future<void> forget(List<int> ids, {int? peer}) async {
    try {
      _dropOpened(await SealMessenger.instance.forget(ids, peer: peer));
    } catch (_) {}
  }

  /// A chat cleared: forget all of its unlocked texts on this device.
  static Future<void> forgetChat(int peer) async {
    try {
      _dropOpened(await SealMessenger.instance.forgetChat(peer));
    } catch (_) {}
  }

  /// Opened copies of deleted sealed media leave this device too.
  static void _dropOpened(List<Map<String, dynamic>> media) {
    for (final m in media) {
      try {
        final key = base64Url.decode(base64Url.normalize('${m['k']}'));
        if (key.length == 32) MediaStore.instance.removeSealed(key);
      } catch (_) {}
    }
  }

  /// Sign-out: off the key directory, every key, session and text forgotten.
  static Future<void> signOut() async {
    // Sessions and Our Space keys first: they're filed under this device's
    // id, which the directory sign-out forgets with the keys.
    await SealMessenger.instance.wipe();
    await SealSpace.instance.wipe();
    await SealDirectory.instance.signOut();
    await MediaStore.instance.wipeSealed(); // opened photos / files too
  }
}
