import 'package:flutter/foundation.dart';

/// Holds images shared INTO Aluta from other apps (via the Android share sheet).
///
/// The recipient is chosen on the normal Home friend list, not a separate page:
/// while [hasPending] is true, Home shows a "tap a contact to send" banner and
/// tapping a friend sends the image(s) there. This is a [ChangeNotifier] so Home
/// reacts when a share arrives while it's already open.
class ShareInbox extends ChangeNotifier {
  ShareInbox._();
  static final ShareInbox instance = ShareInbox._();

  final List<String> _pending = [];

  List<String> get pending => List.unmodifiable(_pending);
  bool get hasPending => _pending.isNotEmpty;

  void add(Iterable<String> paths) {
    final incoming = paths.where((p) => p.trim().isNotEmpty).toList();
    if (incoming.isEmpty) return;
    _pending.addAll(incoming);
    notifyListeners();
  }

  void clear() {
    if (_pending.isEmpty) return;
    _pending.clear();
    notifyListeners();
  }
}
