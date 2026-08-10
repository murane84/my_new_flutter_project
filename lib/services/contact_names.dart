import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';

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
    try {
      if (!_mobile) {
        // Desktop/web can't read the address book — pull the map the phone
        // uploaded to this account (after QR login) instead.
        final m = await ApiService().fetchContactNames();
        _byKey
          ..clear()
          ..addAll(m);
        _loaded = true;
        return;
      }
      bool granted;
      if (allowPrompt) {
        granted = await FlutterContacts.requestPermission(readonly: true);
      } else {
        granted = await Permission.contacts.isGranted;
      }
      if (!granted) {
        // Leave _loaded false when we couldn't read yet (permission may be
        // granted later); a subsequent ensureLoaded can retry.
        _loading = null;
        return;
      }
      final contacts = await FlutterContacts.getContacts(withProperties: true);
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
