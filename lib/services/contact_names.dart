import 'dart:convert';

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
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
  bool _loaded = false;
  Future<void>? _loading;
  DateTime? _at; // when the persisted snapshot was built
  bool _servedPersisted = false; // only hit the saved snapshot once per session
  static const String _prefsKey = 'contact_names_cache_v1';

  bool get isLoaded => _loaded;

  static bool get _mobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

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
          final stale = _at == null ||
              DateTime.now().difference(_at!) > const Duration(hours: 6);
          if (stale) {
            Future.delayed(const Duration(seconds: 3),
                () => _readFromSource(allowPrompt: false));
          }
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
      _loaded = true;
      _persist();
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

  Future<Map<String, String>?> _loadPersisted() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return null;
      final obj = jsonDecode(raw) as Map<String, dynamic>;
      final atMs = (obj['at'] as num?)?.toInt();
      _at = atMs != null ? DateTime.fromMillisecondsSinceEpoch(atMs) : null;
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
