import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

/// Fast, searchable phone-book picker for sharing a contact.
///
/// Speed matters on rich phone books: loading every contact WITH its phone
/// numbers up-front (`withProperties: true`) blocks the UI for seconds. Instead
/// this opens INSTANTLY (with a spinner), loads names only (`withProperties:
/// false` — dramatically faster), and the caller fetches the chosen contact's
/// number lazily on tap. A session cache (passed back via [onLoaded]) makes any
/// later open instant.
///
/// Returns the selected [Contact] (name + id; phones are fetched by the caller)
/// via `Navigator.pop`, or null if dismissed.
class ContactPickerSheet extends StatefulWidget {
  const ContactPickerSheet({super.key, this.initial, this.onLoaded});

  /// Previously-loaded list (session cache) — shown immediately if present.
  final List<Contact>? initial;

  /// Called once the list has loaded, so the host can cache it for next time.
  final void Function(List<Contact> contacts)? onLoaded;

  @override
  State<ContactPickerSheet> createState() => _ContactPickerSheetState();
}

class _ContactPickerSheetState extends State<ContactPickerSheet> {
  List<Contact>? _all; // null = still loading
  bool _error = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    final cached = widget.initial;
    if (cached != null) {
      _all = cached;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      // Names only — no per-contact phone/email lookup, so this returns fast
      // even on a large phone book. The number is fetched when a row is tapped.
      final list = await FlutterContacts.getContacts();
      list.retainWhere((c) => c.displayName.trim().isNotEmpty);
      list.sort((a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
      if (!mounted) return;
      setState(() => _all = list);
      widget.onLoaded?.call(list);
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, controller) => Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.onSurfaceVariant.withAlpha(80),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.person_rounded, color: scheme.primary),
                  const SizedBox(width: 8),
                  const Text('Share a contact',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: 'Search contacts',
                  prefixIcon: const Icon(Icons.search_rounded),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Expanded(child: _body(scheme, controller)),
          ],
        ),
      ),
    );
  }

  Widget _body(ColorScheme scheme, ScrollController controller) {
    if (_error) {
      return Center(
        child: Text('Couldn’t load contacts',
            style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    if (_all == null) {
      // Sheet is already open — just show a spinner so it never feels frozen.
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.6),
          ),
          const SizedBox(height: 12),
          Text('Loading contacts…',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
        ],
      );
    }
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? _all!
        : _all!
            .where((c) => c.displayName.toLowerCase().contains(q))
            .toList();
    if (filtered.isEmpty) {
      return Center(
        child: Text('No contacts found',
            style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    return ListView.builder(
      controller: controller,
      itemCount: filtered.length,
      itemBuilder: (context, i) {
        final c = filtered[i];
        final initial =
            c.displayName.isNotEmpty ? c.displayName[0].toUpperCase() : '?';
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: scheme.primary.withAlpha(35),
            child: Text(initial,
                style: TextStyle(
                    color: scheme.primary, fontWeight: FontWeight.bold)),
          ),
          title:
              Text(c.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => Navigator.pop(context, c),
        );
      },
    );
  }
}
