import 'dart:convert';

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform, ValueNotifier;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

import '../screens/api_service.dart';

/// Resolves a phone number to the name it's saved under in the user's own phone
/// book. Used to give group messages a personal touch: if a sender's number is
/// in your contacts we show YOUR saved name for them, otherwise their app
/// username (with a ~) and number.
///
/// The map is built once per session from the device address book and cached.
/// Numbers are keyed both by their full digits and by their last 9 digits, so a
/// contact saved locally (e.g. 0629080911) still matches the same person's
/// E.164 number (+255629080911).
class ContactNames {
  ContactNames._();
  static final ContactNames instance = ContactNames._();

  final Map<String, String> _byKey = {};
  // Bumped whenever the name map changes, so the UI can repaint when a
  // background read finishes (a newly saved contact shows up without a manual
  // refresh).
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  bool _loaded = false;
  Future<void>? _loading;
  DateTime? _at; // when the persisted snapshot was built
  // Signature (count + id/name hash) of the address book at the last full read.
  // A cheap re-check against this lets a launch detect add/remove/rename and
  // skip the heavy property read when nothing has changed.
  String _sig = '';
  bool _servedPersisted = false; // only hit the saved snapshot once per session
  static const String _prefsKey = 'contact_names_cache_v1';

  bool get isLoaded => _loaded;

  static bool get _mobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Whether this platform can read the address book / add contacts
  /// (mobile only). Exposed so UI can gate contact-save affordances.
  static bool get isSupported => _mobile;

  static String _digits(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

  /// Build the number → saved-name map. By default this is SILENT: it only runs
  /// if contacts permission is ALREADY granted (so opening a chat never triggers
  /// a surprise permission dialog). Pass allowPrompt: true to request it.
  Future<void> ensureLoaded({bool allowPrompt = false}) {
    if (_loaded) return Future.value();
    return _loading ??= _load(allowPrompt: allowPrompt);
  }

  Future<void> _load({required bool allowPrompt}) async {
    // Instant: serve a saved snapshot from a previous run so startup never waits
    // on the address-book read; refresh from the source in the background. The
    // snapshot survives app updates (SharedPreferences), so a new version keeps
    // the saved names and only re-reads to pick up changes.
    if (!_servedPersisted) {
      _servedPersisted = true;
      try {
        final cached = await _loadPersisted();
        if (cached != null && cached.isNotEmpty) {
          _byKey
            ..clear()
            ..addAll(cached);
          _loaded = true;
          _loading = null;
          revision.value++;
          // Detect-changes-only: a cheap signature check in the background;
          // the heavy property read runs ONLY when contacts actually changed
          // (new/removed/renamed) — so an update never re-reads the whole book
          // for nothing, but a newly saved contact still shows within seconds.
          Future.delayed(
              const Duration(seconds: 3), () => _refreshIfChanged());
          return;
        }
      } catch (_) {}
    }
    await _readFromSource(allowPrompt: allowPrompt);
  }

  Future<void> _readFromSource({required bool allowPrompt}) async {
    try {
      if (!_mobile) {
        // Desktop/web can't read the address book — pull the map the phone
        // uploaded to this account (after QR login) instead.
        final m = await ApiService().fetchContactNames();
        _byKey
          ..clear()
          ..addAll(m);
        _loaded = true;
        _persist();
        revision.value++;
        return;
      }
      if (allowPrompt) {
        final granted =
            await FlutterContacts.requestPermission(readonly: true);
        if (!granted) {
          // Leave _loaded false — a later ensureLoaded can retry.
          _loading = null;
          return;
        }
      }
      // Read the address book. getContacts needs only READ_CONTACTS; if that
      // isn't granted the plugin throws and we leave the map empty for a later
      // retry. We deliberately do NOT gate on the contacts permission GROUP
      // status — a declared WRITE_CONTACTS can report the group as "denied"
      // even when READ is granted, which would silently blank every name.
      final List<Contact> contacts;
      try {
        contacts = await FlutterContacts.getContacts(withProperties: true);
      } catch (_) {
        _loading = null; // not granted yet — retry later
        return;
      }
      for (final c in contacts) {
        final name = c.displayName.trim();
        if (name.isEmpty) continue;
        for (final p in c.phones) {
          final d = _digits(p.number);
          if (d.length < 6) continue;
          _byKey[d] = name;
          if (d.length >= 9) {
            _byKey[d.substring(d.length - 9)] = name;
          }
        }
      }
      _sig = _signatureOf(contacts);
      _loaded = true;
      _persist();
      revision.value++;
      // Best-effort: push the map to the server so the DESKTOP app can show
      // these saved names too (the whole point of the QR-linked account).
      if (_byKey.isNotEmpty) {
        ApiService().uploadContactNames(Map<String, String>.from(_byKey));
      }
    } catch (_) {
      // Best-effort — fall back to app usernames if anything goes wrong.
      _loaded = true;
    } finally {
      _loading = null;
    }
  }

  // A cheap fingerprint of the address book (count + a rolling hash of each
  // contact's id and display name). Changes when a contact is added, removed
  // or renamed — the common cases we must detect.
  String _signatureOf(List<Contact> contacts) {
    int h = 17;
    for (final c in contacts) {
      h = 0x1fffffff & (h * 31 + c.id.hashCode);
      h = 0x1fffffff & (h * 31 + c.displayName.hashCode);
    }
    return '${contacts.length}:$h';
  }

  // Background: only do the heavy (with-properties) read when the address book
  // actually changed since the last full read. A light id+name read is enough
  // to tell. A weekly backstop still refreshes to catch rare number-only edits
  // (same name, changed number) that the name/count signature can't see.
  Future<void> _refreshIfChanged() async {
    if (!_mobile) return;
    try {
      final veryStale = _at == null ||
          DateTime.now().difference(_at!) > const Duration(days: 7);
      if (!veryStale && _sig.isNotEmpty) {
        final light = await FlutterContacts.getContacts(); // ids + names only
        if (_signatureOf(light) == _sig) return; // nothing changed — keep cache
      }
    } catch (_) {
      // Couldn't check — fall through to a full read.
    }
    await _readFromSource(allowPrompt: false);
  }

  Future<Map<String, String>?> _loadPersisted() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return null;
      final obj = jsonDecode(raw) as Map<String, dynamic>;
      final atMs = (obj['at'] as num?)?.toInt();
      _at = atMs != null ? DateTime.fromMillisecondsSinceEpoch(atMs) : null;
      _sig = (obj['sig'] as String?) ?? '';
      final src = (obj['map'] as Map?) ?? const {};
      return src.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      return null;
    }
  }

  Future<void> _persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      final obj = <String, dynamic>{
        'at': DateTime.now().millisecondsSinceEpoch,
        'sig': _sig,
        'map': _byKey,
      };
      await p.setString(_prefsKey, jsonEncode(obj));
      _at = DateTime.now();
    } catch (_) {}
  }

  /// Force a reload (e.g. right after a QR login on desktop pulls a fresh token).
  Future<void> refresh() {
    _loaded = false;
    _loading = null;
    _sig = '';
    _byKey.clear();
    return ensureLoaded();
  }

  /// The name this number is saved under in the user's phone book, or null if
  /// it isn't saved (or contacts aren't available).
  String? nameFor(String phone) {
    if (_byKey.isEmpty) return null;
    final d = _digits(phone);
    if (d.length < 6) return null;
    final hit = _byKey[d];
    if (hit != null) return hit;
    if (d.length >= 9) return _byKey[d.substring(d.length - 9)];
    return null;
  }
}
