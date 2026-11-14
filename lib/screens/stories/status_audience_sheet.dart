import 'package:flutter/material.dart';

import '../../services/contact_names.dart';
import '../../services/status_privacy.dart';
import '../../utils/readable.dart' show accentInk;
import '../api_service.dart';
import '../../widgets/pill_search.dart';
import '../../services/haptics.dart';
import '../../utils/radii.dart';
import '../../widgets/skeleton.dart';
import '../../utils/adaptive_sheet.dart';
import '../../utils/keyboard.dart';

/// "Who can see my status": My circle / Bonds only, plus friends to hide it
/// from either way. Saved to the account; the server applies it.
Future<void> showStatusAudienceSheet(BuildContext context) async {
  await StatusPrivacy.instance.load();
  if (!context.mounted) return;
  await showAdaptiveSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl))),
    builder: (_) => const _StatusAudienceSheet(),
  );
}

class _StatusAudienceSheet extends StatefulWidget {
  const _StatusAudienceSheet();

  @override
  State<_StatusAudienceSheet> createState() => _StatusAudienceSheetState();
}

class _StatusAudienceSheetState extends State<_StatusAudienceSheet> {
  final _sp = StatusPrivacy.instance;
  late String _mode = _sp.mode.value;
  late final Set<int> _hidden = Set<int>.of(_sp.hidden.value);
  List<Map<String, dynamic>> _friends = [];
  bool _loading = true;
  String _q = '';

  @override
  void initState() {
    super.initState();
    ApiService().getFriends().then((f) {
      if (mounted) {
        setState(() {
          _friends = f;
          _loading = false;
        });
      }
    }).catchError((_) {
      if (mounted) setState(() => _loading = false);
    });
  }

  String _name(Map<String, dynamic> f) => ContactNames.instance.displayName(
      of: f, registered: (f['username'] ?? 'Friend').toString());

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = _friends
        .where((f) => _q.isEmpty || _name(f).toLowerCase().contains(_q))
        .toList();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: scheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                child: Text('Who can see my status',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurface)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: LayoutBuilder(builder: (context, box) {
                  final narrow = box.maxWidth < 300;
                  return SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                          value: 'circle',
                          icon: const Icon(Icons.groups_rounded, size: 18),
                          label: Text(narrow ? 'Circle' : 'My circle')),
                      const ButtonSegment(
                          value: 'bonds',
                          icon: Icon(Icons.favorite_rounded, size: 18),
                          label: Text('Bonds only')),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (s) {
                      Haptics.selectionClick();
                      setState(() => _mode = s.first);
                      _sp.setMode(_mode);
                    },
                  );
                }),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
                child: Text(
                  _mode == 'bonds'
                      ? 'Only your Our Space partners see it (once they’ve accepted).'
                      : 'All your friends see it.',
                  style:
                      TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                ),
              ),
              const Divider(height: 18),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                child: Row(children: [
                  Icon(Icons.visibility_off_rounded,
                      size: 18, color: accentInk(scheme)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        _hidden.isEmpty
                            ? 'Hide from…'
                            : 'Hidden from ${_hidden.length}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: TextField(
                  onTapOutside: unfocusOnTapOutside,
                  onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
                  decoration: InputDecoration(
                    // Pill, like every search box (theme borders are 12 px boxes).
                    border: pillSearchBorder(scheme),
                    enabledBorder: pillSearchBorder(scheme),
                    focusedBorder: pillSearchBorder(scheme, focused: true),
                    // One compact height for every search pill (38 px, like Circle's).
                    isDense: true,
                    constraints: const BoxConstraints(minHeight: 38, maxHeight: 38),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 38, maxHeight: 38),
                    suffixIconConstraints: const BoxConstraints(minWidth: 38, minHeight: 38, maxHeight: 38),
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    hintText: 'Search friends',
                  ),
                ),
              ),
              Flexible(
                child: _loading
                    ? const SkeletonList(rows: 5, avatar: 38)
                    : shown.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                                _friends.isEmpty
                                    ? 'No friends yet.'
                                    : 'No one matches “$_q”.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: scheme.onSurfaceVariant)),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            itemCount: shown.length,
                            itemBuilder: (_, i) {
                              final f = shown[i];
                              final id = (f['id'] as num?)?.toInt() ?? -1;
                              final on = _hidden.contains(id);
                              return CheckboxListTile(
                                dense: true,
                                value: on,
                                title: Text(_name(f),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                subtitle: on
                                    ? const Text('Won’t see your status')
                                    : null,
                                onChanged: (v) {
                                  setState(() {
                                    v == true
                                        ? _hidden.add(id)
                                        : _hidden.remove(id);
                                  });
                                  _sp.setHidden(_hidden);
                                },
                              );
                            },
                          ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
