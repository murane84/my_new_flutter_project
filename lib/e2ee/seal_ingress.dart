import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../services/media_store.dart';
import '../services/notif_service.dart' show cancelAllAlutaNotifications;
import 'seal_directory.dart';
import 'seal_keystore.dart';
import 'seal_media.dart';
import 'seal_messenger.dart';
import 'seal_polls.dart';
import 'seal_reacts.dart';
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
    final asked = <String>{};
    for (final m in list) {
      if (isGroupSealed(m) || _quotesLock(m)) {
        await openGroup(m, asked: asked);
      }
    }
    return list;
  }

  // ── Group chats: sealed with the members' shared key (SealSpace) ───────

  /// Groups bigger than this stay unsealed (the server's limit).
  static const int groupMaxMembers = 32;
  static const String lockedGroup =
      '🔒 Sent before this device could read the group';

  // A lock's code as an older Aluta copied it into a plain message (it
  // quoted a sealed message it couldn't open): "🔒s1.<scope>.<epoch>.<…>".
  static final RegExp _lockInText =
      RegExp(r'🔒s1\.[A-Za-z0-9:,]+\.[0-9]+\.[A-Za-z0-9_\-]+');

  /// A plain message quoting a sealed one by its code (an older Aluta's
  /// reply): the code opened in place — the quote reads as the words, names
  /// its author and leads to the original — or a quiet "🔒 Message".
  static Future<void> _openQuotedLocks(
      Map<String, dynamic> m, Set<String>? asked) async {
    final c = m['content'];
    if (c is! String || !c.contains(SealScope.prefix)) return;
    final locks = _lockInText.allMatches(c).map((x) => x.group(0)!).toSet();
    if (locks.isEmpty) return;
    var out = c;
    for (final l in locks) {
      String opened;
      try {
        opened = await SealSpace.instance.open(l, asked: asked);
      } catch (_) {
        opened = SealSpace.unlockFailed;
      }
      final ok = opened != SealSpace.waitingForKey &&
          opened != SealSpace.unlockFailed &&
          !SealScope.isSealed(opened);
      // (a quote holds the words; a sealed media's key never shows)
      out = out.replaceAll(
          l, ok ? SealPayload.textOf(opened) : '🔒 Message');
    }
    m['content'] = out;
  }

  /// A plain group message carrying a lock's code (an older Aluta's quote).
  static bool _quotesLock(Map<String, dynamic> m) {
    final c = m['content'];
    return m['conversation_id'] != null &&
        m['e2ee'] == null &&
        c is String &&
        !c.startsWith(SealScope.prefix) &&
        c.contains(SealScope.prefix);
  }

  static bool isGroupSealed(Map<String, dynamic> m) =>
      SealScope.isSealed(m['content']) && m['is_deleted'] != true;

  /// Unlock a sealed group message in place: `content` becomes the words, a
  /// sealed photo / file gets its key and real name back.
  static Future<void> openGroup(Map<String, dynamic> m,
      {Set<String>? asked}) async {
    if (!isGroupSealed(m)) {
      await _openQuotedLocks(m, asked);
      return;
    }
    m['e2ee_group'] = 1;
    String opened;
    try {
      opened =
          await SealSpace.instance.open(m['content'] as String, asked: asked);
    } catch (_) {
      opened = SealSpace.unlockFailed;
    }
    if (opened == SealSpace.waitingForKey || SealScope.isSealed(opened)) {
      m['content'] = lockedGroup;
      m['seal_state'] = 'nokey';
      return;
    }
    if (opened == SealSpace.unlockFailed) {
      m['content'] = lockedFailed;
      m['seal_state'] = 'failed';
      return;
    }
    m.remove('seal_state');
    m['content'] = SealPayload.textOf(opened);
    _attachMedia(m, SealPayload.mediaOf(opened));
    // A sealed poll: its question and options too.
    if (m['poll'] != null) await SealPolls.openIn(m);
    // This group is sealed: this device (a linked computer too) never
    // writes to it in the clear from now on. (A heart sealed for just one
    // member, with the two people's key, says nothing about the group.)
    final cid = _int(m['conversation_id']);
    if (cid > 0 && m['heart_for'] == null) {
      final me = await myUid();
      if (me != null && _knownSealedGroups.add('$me:$cid')) {
        await markGroupSealed(me, cid);
      }
    }
  }

  static final Set<String> _knownSealedGroups = {};

  /// Group rows of the conversation list: the server knows only "🔒 Message"
  /// / "📷 Photo" for a sealed last message; open its sealed copy with the
  /// group's key for the real words.
  static Future<void> groupPreviews(List<Map<String, dynamic>> rows) async {
    final asked = <String>{};
    for (final r in rows) {
      final raw = r['last_sealed'];
      if (r['is_group'] != true || raw is! String || raw.isEmpty) continue;
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        final c = j['content'];
        if (!SealScope.isSealed(c)) continue;
        final opened =
            await SealSpace.instance.open(c as String, asked: asked);
        if (SealScope.isSealed(opened) ||
            opened == SealSpace.waitingForKey ||
            opened == SealSpace.unlockFailed) {
          continue;
        }
        r['last_message'] =
            previewOf((r['last_message'] ?? '').toString(), opened);
      } catch (_) {}
    }
  }

  static String _groupKey(int me, int cid) => 'aluta_group_sealed_${me}_$cid';

  /// A sealed group message as this device's copy of the chat reads it
  /// (same shape as [previewOf]); the server [label] when it isn't there.
  static Future<String> _groupCachedPreview(
      String label, String cid, String mid) async {
    final me = await myUid();
    final fallback = label == serverPreview ? '' : label;
    if (me == null) return fallback;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('chat_cache_${me}_g$cid');
      if (raw == null) return fallback;
      for (final m in jsonDecode(raw) as List) {
        if (m is! Map || '${m['id']}' != mid || m['seal_state'] != null) {
          continue;
        }
        final words = _withoutQuote('${m['content'] ?? ''}'.trim());
        var head = fallback;
        final name = '${m['media_name'] ?? ''}'.trim();
        if (head.startsWith('📎') && name.isNotEmpty) head = '📎 $name';
        if (head.isEmpty) return words;
        return words.isEmpty ? head : '$head · $words';
      }
    } catch (_) {}
    return fallback;
  }

  /// Once a group has been sealed on this device it stays sealed.
  static Future<bool> groupSealedBefore(int me, int cid) async {
    try {
      return (await SharedPreferences.getInstance())
              .getBool(_groupKey(me, cid)) ==
          true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> markGroupSealed(int me, int cid) async {
    try {
      await (await SharedPreferences.getInstance())
          .setBool(_groupKey(me, cid), true);
    } catch (_) {}
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
      if (d is Map<String, dynamic> && (isGroupSealed(d) || _quotesLock(d))) {
        await openGroup(d);
        continue;
      }
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
    // A sealed group name in the push ("group_title"): "Group" when this
    // phone can't open it.
    if (data.values.any(SealScope.isSealed)) {
      data = Map<String, dynamic>.from(data);
      await openGroupMeta(data,
          named: '${data['type'] ?? ''}'.startsWith('group_call'));
    }
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
        final cid = '${data['conversation_id'] ?? ''}';
        out['body'] = s == null && cid.isNotEmpty
            // A sealed group message: this device's own copy of the chat.
            ? await _groupCachedPreview(label, cid, '${data['message_id']}')
            : previewOf(label, s);
      } catch (_) {
        out['body'] = label == serverPreview ? '' : label;
      }
      return out;
    }
    // A sealed group message (opened above with the group's key, when this
    // phone holds it): the banner reads like the list.
    final sb = data['sealed_body'];
    if (sb is String) {
      final out = Map<String, dynamic>.from(data)..remove('sealed_body');
      if (sb.isNotEmpty &&
          !SealScope.isSealed(sb) &&
          sb != SealSpace.waitingForKey &&
          sb != SealSpace.unlockFailed) {
        out['body'] = previewOf((data['body'] ?? '').toString(), sb);
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
    // A secret heart never previews its note (a group's either).
    if (label.startsWith('❤️')) return label;
    final words = _withoutQuote(SealPayload.textOf(stored));
    final media = SealPayload.mediaOf(stored);
    if (media == null) {
      // A sealed poll: "📊 <its question>".
      if (label.startsWith('📊') && words.isNotEmpty) return '📊 $words';
      // A shared location / contact keeps its label, never its JSON.
      if (label != serverPreview && words.startsWith('{')) return label;
      return words.isNotEmpty || label == serverPreview ? words : label;
    }
    var head = label == serverPreview ? '' : label;
    final name = '${media['n'] ?? ''}'.trim();
    if (head.startsWith('📎') && name.isNotEmpty) head = '📎 $name';
    // A song previews by its title, as a plain one does ("🎵 Title").
    if (head.startsWith('🎵')) {
      if (words.isNotEmpty) return '🎵 $words';
      if (name.isNotEmpty) {
        final dot = name.lastIndexOf('.');
        return '🎵 ${dot > 0 ? name.substring(0, dot) : name}';
      }
      return head;
    }
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
  /// [cap]: what their Aluta must be able to open ("m1" photos, videos,
  /// voice notes and files; "m2" songs, big files, polls, reactions —
  /// [SealMedia.capFor]).
  static Future<bool> canSealMedia(int peer, {String cap = 'm1'}) async {
    final me = await myUid();
    if (me == null || peer <= 0 || peer == me) return false;
    return SealMessenger.instance.canSealMedia(peer, me, cap: cap);
  }

  /// Whether something can go sealed for exactly [members] (a group being
  /// made / renamed): every device of every member opens [cap]. Throws
  /// [SealError] when it can't be told right now.
  static Future<bool> canSealForMembers(List<int> members,
      {String cap = 'm2', bool stay = false}) async {
    final me = await myUid();
    if (me == null || members.length > groupMaxMembers) return false;
    return SealMessenger.instance
        .canSealMediaFor(members, me, stay: stay, cap: cap);
  }

  /// 🔒 A group's name and photo address are sealed with the members' key.
  /// Open them in place (a row of the chat list, a group's details, an
  /// event): a name this device can't open reads "Group", a photo it can't
  /// open is left out (initials show).
  static const _groupMetaKeys = {
    'title': true,
    'group_title': true,
    'avatar_url': false,
    'group_avatar': false,
  };

  /// Returns the keys it couldn't open.
  ///
  /// [named]: open plain `title` / `avatar_url` too (a group row, a group
  /// call ring) — off for any other event, where a sealed `title` is Our
  /// Space words (a diary entry's) with their own lock note.
  static Future<Set<String>> openGroupMeta(Map<String, dynamic> row,
      {Set<String>? asked, bool named = true}) async {
    final failed = <String>{};
    for (final e in _groupMetaKeys.entries) {
      if (!named && (e.key == 'title' || e.key == 'avatar_url')) continue;
      final v = row[e.key];
      if (!SealScope.isSealed(v)) continue;
      String out;
      try {
        out = await SealSpace.instance.open(v as String, asked: asked);
      } catch (_) {
        out = SealSpace.unlockFailed;
      }
      final bad = SealScope.isSealed(out) ||
          out == SealSpace.waitingForKey ||
          out == SealSpace.unlockFailed;
      if (bad) failed.add(e.key);
      row[e.key] = bad ? (e.value ? 'Group' : '') : out;
    }
    return failed;
  }

  /// Whether a file for group [cid] can go sealed (every member device can
  /// open it). Throws [SealError] when it can't be told right now.
  /// [members]: the group's members as just fetched (null: unknown).
  static Future<bool> canSealGroupMedia(int cid, List<int>? members,
      {String cap = 'm1'}) async {
    final me = await myUid();
    if (me == null) return false;
    if (members == null) {
      if (await groupSealedBefore(me, cid)) {
        throw SealError('group members unknown right now');
      }
      return false;
    }
    final stay = await groupSealedBefore(me, cid);
    if (members.length > groupMaxMembers) {
      // A group of more than 32: its own named key — every device of every
      // member must open those (m3) and [cap]. Once sealed, a member with
      // no keys right now (signed out) doesn't turn it back to plain — as
      // in a smaller group.
      return SealSpace.instance.namedReady(
          SealScope.group(cid), {'m3', cap},
          skipKeyless: stay);
    }
    return SealMessenger.instance
        .canSealMediaFor(members, me, stay: stay, cap: cap);
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

  /// A deleted message's opened sealed file leaves this device (groups keep
  /// no plain store, so the chat hands over the message's address).
  static void dropOpenedMedia(Object? url) {
    final key = url is String ? SealMedia.keyOf(url) : null;
    if (key != null) MediaStore.instance.removeSealed(key);
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
    // The server-backup recovery key this phone kept for this person.
    final me = await myUid();
    if (me != null) {
      try {
        await SealKeyStore.platformStorage()
            .delete('aluta_cloud_backup_key_$me');
      } catch (_) {}
    }
    // Sessions and Our Space keys first: they're filed under this device's
    // id, which the directory sign-out forgets with the keys.
    await SealMessenger.instance.wipe();
    await SealSpace.instance.wipe();
    await SealDirectory.instance.signOut();
    await MediaStore.instance.wipeSealed(); // opened photos / files too
    SealPolls.forget(); // opened poll words and reactions held in memory
    SealReacts.forget();
    await cancelAllAlutaNotifications(); // banners hold unlocked words
  }
}
