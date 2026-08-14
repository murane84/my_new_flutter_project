import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

import '../screens/api_service.dart';

/// Android "Connected apps" integration: shows Aluta actions ("Voice call on
/// Aluta", "Message on Aluta") under a phone-book contact who has a registered
/// Aluta account — the same mechanism WhatsApp / Telegram use.
///
/// The heavy lifting (a stub sync account + ContactsContract rows) lives in the
/// native ConnectedContacts object; this Dart side reads the address book,
/// matches numbers against registered users via the backend, hands the matches
/// to native, and routes a tapped action back into the app. Android-only and
/// entirely best-effort — every path fails silently so it can never block the
/// app or throw on unsupported platforms.
class ConnectedContactsService {
  ConnectedContactsService._();
  static final ConnectedContactsService instance = ConnectedContactsService._();

  static const MethodChannel _ch = MethodChannel('aluta/connected_contacts');

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Invoked when the user taps an Aluta "Voice call" / "Message" row under a
  /// contact in the system Contacts app. Set by HomePage to route into the app.
  void Function(String action, int userId, String number)? onAction;

  bool _inited = false;

  /// Wire the native → Dart action channel and drain any action that
  /// cold-launched the app (before this handler existed).
  Future<void> init() async {
    if (!_supported || _inited) return;
    _inited = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'onAction' && call.arguments is Map) {
        _dispatch(Map<String, dynamic>.from(call.arguments as Map));
      }
      return null;
    });
    try {
      final p = await _ch.invokeMethod('consumePendingAction');
      if (p is Map) _dispatch(Map<String, dynamic>.from(p));
    } catch (_) {/* no channel yet / not Android */}
  }

  void _dispatch(Map<String, dynamic> p) {
    final action = (p['action'] ?? '').toString();
    if (action.isEmpty) return;
    final userId = int.tryParse((p['userId'] ?? '').toString()) ?? 0;
    final number = (p['number'] ?? '').toString();
    onAction?.call(action, userId, number);
  }

  bool _refreshed = false;

  /// Read the address book, match numbers against registered Aluta users, and
  /// write / prune the "Connected apps" rows. Requests contacts permission
  /// (read + write) — if declined, quietly does nothing. Runs at most ONCE per
  /// app session (the scan + contact writes are heavy; no need to repeat them on
  /// every home remount).
  Future<void> refresh() async {
    if (!_supported || _refreshed) return;
    _refreshed = true;
    try {
      // Needs read (to list numbers) AND write (to add the rows).
      final granted = await FlutterContacts.requestPermission(readonly: false);
      if (!granted) return;
      final contacts = await FlutterContacts.getContacts(withProperties: true);
      final phones = <String>{};
      for (final c in contacts) {
        for (final p in c.phones) {
          final n = p.number.trim();
          if (n.length >= 6) phones.add(n);
        }
      }
      if (phones.isEmpty) return;

      final res = await ApiService().syncContacts(phones.toList());
      final matched = (res['matched'] as List?) ?? const [];
      final list = <Map<String, dynamic>>[];
      for (final m in matched) {
        if (m is! Map) continue;
        final id = m['id'];
        final phone = (m['phone'] ?? '').toString().trim();
        if (id == null || phone.isEmpty) continue;
        final name = (m['username'] ?? '').toString();
        list.add({
          'userId': id.toString(),
          'number': phone,
          'name': name.isEmpty ? 'Aluta user' : name,
        });
      }
      await _ch.invokeMethod('ensureAccount');
      await _ch.invokeMethod('sync', {'matches': list});
    } catch (_) {/* best-effort */}
  }

  /// Remove all Aluta contact rows (e.g. on sign-out).
  Future<void> clear() async {
    if (!_supported) return;
    try {
      await _ch.invokeMethod('clear');
    } catch (_) {/* best-effort */}
  }
}
