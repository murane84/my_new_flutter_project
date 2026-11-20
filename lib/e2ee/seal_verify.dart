import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'seal_directory.dart';
import 'seal_messenger.dart';

/// 🔒 Checking a chat's encryption together: a safety code both phones work
/// out on their own from the two people's keys.
///
/// Each person's half comes from every device key they have (sorted), so
/// the code changes when either of you reinstalls Aluta or links / removes
/// a device — exactly when an unexpected device could be listening. The
/// halves are ordered by user id, so both phones show the same 60 digits.
/// Nothing here is sent anywhere: comparing the code (by eye, or by
/// scanning the other phone's QR) happens between the two people.
class SealVerify {
  SealVerify._();

  static const int version = 1;
  static const String qrPrefix = 'aluta-verify:';

  /// One person's 30 digits from their user id and device identity keys.
  static Future<String> personCode(int uid, Iterable<String> ikSigs) async {
    final keys = ikSigs.toList()..sort();
    final h = await Sha256().hash(utf8.encode(
        'AlutaSafety$version\n$uid\n${keys.join('\n')}'));
    final b = h.bytes;
    final out = StringBuffer();
    // Six groups of five digits, each from five bytes of the hash.
    for (var g = 0; g < 6; g++) {
      var n = 0;
      for (var i = 0; i < 5; i++) {
        n = (n * 256 + b[g * 5 + i]) % 100000;
      }
      out.write(n.toString().padLeft(5, '0'));
    }
    return out.toString();
  }

  /// The pair's 60 digits (the lower user id's half first).
  static Future<String> pairCode(
      int a, Iterable<String> aKeys, int b, Iterable<String> bKeys) async {
    final ca = await personCode(a, aKeys);
    final cb = await personCode(b, bKeys);
    return a < b ? '$ca$cb' : '$cb$ca';
  }

  /// "12345 67890 …" in groups of five.
  static List<String> groups(String code) => [
        for (var i = 0; i + 5 <= code.length; i += 5) code.substring(i, i + 5)
      ];

  /// What the QR holds: the pair and the code (no keys, no names).
  static String qrFor(int me, int peer, String code) {
    final lo = me < peer ? me : peer;
    final hi = me < peer ? peer : me;
    return '$qrPrefix$version:$lo:$hi:$code';
  }

  /// Reading the other phone's QR: true = same code, false = a different
  /// code for this pair, null = not this pair's code at all.
  static bool? checkQr(String raw, int me, int peer, String code) {
    if (!raw.startsWith(qrPrefix)) return null;
    final p = raw.substring(qrPrefix.length).split(':');
    if (p.length != 4 || p[0] != '$version') return null;
    final lo = int.tryParse(p[1]), hi = int.tryParse(p[2]);
    final want = {me, peer};
    if (lo == null || hi == null || !want.contains(lo) || !want.contains(hi) ||
        lo == hi) {
      return null;
    }
    return p[3] == code;
  }
}

/// A moment the code changed, and whose keys changed (mine: I reinstalled or
/// linked a device; theirs: they did).
class SealCodeChange {
  const SealCodeChange(this.at, {required this.mine});
  final DateTime at;
  final bool mine;

  Map<String, dynamic> toJson() =>
      {'at': at.toUtc().toIso8601String(), 'mine': mine};

  static SealCodeChange? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = DateTime.tryParse('${j['at']}');
    return at == null ? null : SealCodeChange(at, mine: j['mine'] == true);
  }
}

/// Where this chat's check stands.
class SealVerifyState {
  const SealVerifyState({
    required this.code,
    this.verifiedAt,
    this.changes = const [],
    this.checkedBefore = false,
  });

  /// I had checked an earlier code with them (it has changed since).
  final bool checkedBefore;

  /// The current 60 digits (null: keys not available right now).
  final String? code;

  /// When I last confirmed this exact code (null: not checked, or the code
  /// changed since).
  final DateTime? verifiedAt;

  /// When the code was seen to change (newest last).
  final List<SealCodeChange> changes;

  bool get verified => verifiedAt != null;
}

/// The check's memory on this device (per signed-in person and friend).
class SealVerifyStore {
  SealVerifyStore._();
  static final SealVerifyStore instance = SealVerifyStore._();

  /// Device lists used to work the code out: the messenger's own, so the
  /// code covers exactly the keys messages are sealed for (a fake in tests).
  SealKeyDirectory directory = _SealingDevices();

  String _k(String what, int me, int peer) => 'aluta_verify_${what}_${me}_$peer';

  /// Work out the code now (null when a key list can't be fetched, or the
  /// friend has no keys — encryption isn't on in that chat).
  Future<String?> codeFor(int me, int peer) async {
    final mine = await directory.devicesOf(me);
    final theirs = await directory.devicesOf(peer);
    if (mine == null || theirs == null || mine.isEmpty || theirs.isEmpty) {
      return null;
    }
    return SealVerify.pairCode(me, mine.map((d) => d.ikSig), peer,
        theirs.map((d) => d.ikSig));
  }

  /// The chat's state, noting a change of code since last time (a friend
  /// reinstalled or linked a device). A change clears "verified".
  Future<SealVerifyState> refresh(int me, int peer) {
    // One look at a time per chat (the chat and the check screen may both
    // ask): a change is noted once.
    final k = '$me:$peer';
    return _inFlight[k] ??=
        _refresh(me, peer).whenComplete(() => _inFlight.remove(k));
  }

  final Map<String, Future<SealVerifyState>> _inFlight = {};

  Future<SealVerifyState> _refresh(int me, int peer) async {
    final p = await SharedPreferences.getInstance();
    final code = await codeFor(me, peer);
    final changes = _changes(p, me, peer);
    if (code == null) {
      return SealVerifyState(code: null, changes: changes);
    }
    final seen = p.getString(_k('seen', me, peer));
    if (seen != null && seen != code && seen.length == code.length) {
      // Whose half moved: mine (I reinstalled / linked a device) or theirs.
      final mineFirst = me < peer;
      String myHalf(String c) =>
          mineFirst ? c.substring(0, 30) : c.substring(30);
      changes.add(SealCodeChange(DateTime.now().toUtc(),
          mine: myHalf(seen) != myHalf(code)));
      while (changes.length > 20) {
        changes.removeAt(0);
      }
      await p.setString(_k('changes', me, peer),
          jsonEncode([for (final c in changes) c.toJson()]));
    }
    if (seen != code) await p.setString(_k('seen', me, peer), code);
    final at = _verifiedAt(p, me, peer, code);
    return SealVerifyState(
        code: code,
        verifiedAt: at,
        changes: changes,
        checkedBefore: at == null && p.getString(_k('ok', me, peer)) != null);
  }

  /// What's known without the network (for a quick first paint).
  Future<SealVerifyState> cached(int me, int peer) async {
    final p = await SharedPreferences.getInstance();
    final seen = p.getString(_k('seen', me, peer));
    final at = seen == null ? null : _verifiedAt(p, me, peer, seen);
    return SealVerifyState(
        code: seen,
        verifiedAt: at,
        changes: _changes(p, me, peer),
        checkedBefore: at == null && p.getString(_k('ok', me, peer)) != null);
  }

  /// I compared [code] with my friend and they match.
  Future<void> markVerified(int me, int peer, String code) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _k('ok', me, peer),
        jsonEncode(
            {'code': code, 'at': DateTime.now().toUtc().toIso8601String()}));
  }

  Future<void> clearVerified(int me, int peer) async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_k('ok', me, peer));
  }

  DateTime? _verifiedAt(SharedPreferences p, int me, int peer, String code) {
    final raw = p.getString(_k('ok', me, peer));
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['code'] != code) return null; // the code changed since
      return DateTime.tryParse('${j['at']}');
    } catch (_) {
      return null;
    }
  }

  List<SealCodeChange> _changes(SharedPreferences p, int me, int peer) {
    try {
      final raw = p.getString(_k('changes', me, peer));
      if (raw == null) return [];
      return [
        for (final j in jsonDecode(raw) as List)
          if (SealCodeChange.fromJson(j) != null) SealCodeChange.fromJson(j)!
      ];
    } catch (_) {
      return [];
    }
  }
}

/// The messenger's view of a person's devices (fresh), as a directory.
class _SealingDevices implements SealKeyDirectory {
  @override
  Future<List<SealPeerDevice>?> devicesOf(int userId) =>
      SealMessenger.instance.devicesFor(userId);

  @override
  Future<List<SealDeviceBundle>?> bundlesFor(int userId,
          {String? deviceId}) async =>
      const [];
}
