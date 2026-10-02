import 'package:flutter/material.dart';

import '../services/now_playing_presence.dart';
import 'api_service.dart';
import '../utils/bounce_tap.dart';

/// The music-player toggle for broadcasting "listening now" to friends.
/// Tap flips sharing on/off; long-press opens the audience sheet (who can see).
class PresenceShareButton extends StatelessWidget {
  const PresenceShareButton({super.key, required this.color, this.size = 22});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final presence = NowPlayingPresence.instance;
    return AnimatedBuilder(
      animation: presence,
      builder: (context, _) {
        final on = presence.shareEnabled;
        return Tooltip(
          message: on
              ? "Sharing your listening — tap to go private, hold to pick who sees"
              : "Listening is private — tap to share, hold to pick who sees",
          child: BounceTap(
            onTap: () => presence.setShareEnabled(!on),
            onLongPress: () => showListeningAudienceSheet(context),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(
                on ? Icons.sensors_rounded : Icons.sensors_off_rounded,
                size: size,
                color: on ? color : color.withValues(alpha: 0.45),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Bottom sheet: master share switch + an Everyone / Selected-friends choice,
/// and (when selected) a per-friend checklist of who may see your listening now.
Future<void> showListeningAudienceSheet(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: scheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => const _ListeningAudienceSheet(),
  );
}

class _ListeningAudienceSheet extends StatefulWidget {
  const _ListeningAudienceSheet();
  @override
  State<_ListeningAudienceSheet> createState() =>
      _ListeningAudienceSheetState();
}

class _ListeningAudienceSheetState extends State<_ListeningAudienceSheet> {
  final _presence = NowPlayingPresence.instance;
  List<Map<String, dynamic>> _friends = [];
  bool _loading = true;
  late Set<int> _selected;

  @override
  void initState() {
    super.initState();
    _selected = _presence.allowedFriends;
    _load();
  }

  Future<void> _load() async {
    try {
      final f = await ApiService().getFriends();
      if (mounted) {
        setState(() {
          _friends = f;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: AnimatedBuilder(
        animation: _presence,
        builder: (context, _) {
          final on = _presence.shareEnabled;
          final selectedMode = _presence.shareToSelected;
          return Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 10,
              top: 10,
              bottom: MediaQuery.of(context).viewInsets.bottom + 10,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Icon(Icons.sensors_rounded, color: scheme.primary),
                    const SizedBox(width: 8),
                    Text('Listening now - sharing',
                        style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: scheme.onSurface)),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: on,
                  onChanged: (v) => _presence.setShareEnabled(v),
                  title: const Text("Share what I'm listening to"),
                  subtitle: Text(on
                      ? 'Friends can see your current track'
                      : 'Your listening is private'),
                ),
                if (on) ...[
                  const Divider(height: 10),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text('WHO CAN SEE',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                            color: scheme.onSurfaceVariant)),
                  ),
                  _audienceOption(
                      scheme, 'Everyone in my circle', 'everyone'),
                  _audienceOption(
                      scheme, 'Only selected friends', 'selected'),
                  if (selectedMode)
                    Flexible(
                      child: _loading
                          ? const Padding(
                              padding: EdgeInsets.all(20),
                              child: Center(
                                  child: CircularProgressIndicator()),
                            )
                          : _friends.isEmpty
                              ? Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text('No friends to choose from yet.',
                                      style: TextStyle(
                                          color: scheme.onSurfaceVariant)),
                                )
                              : ListView(
                                  shrinkWrap: true,
                                  children: [
                                    for (final f in _friends)
                                      _friendRow(scheme, f),
                                  ],
                                ),
                    ),
                ],
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('Done'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // A radio-style option without RadioListTile (whose groupValue/onChanged are
  // deprecated in favour of a RadioGroup ancestor) — a plain tappable tile.
  Widget _audienceOption(ColorScheme scheme, String label, String value) {
    final on = _presence.shareMode == value;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
          on ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: on ? scheme.primary : scheme.onSurfaceVariant),
      title: Text(label),
      onTap: () => _presence.setAudience(value, _selected),
    );
  }

  Widget _friendRow(ColorScheme scheme, Map<String, dynamic> f) {
    final id = (f['id'] as num?)?.toInt() ?? -1;
    final name = (f['username'] ?? '').toString();
    final checked = _selected.contains(id);
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      value: checked,
      title: Text(name.isEmpty ? 'Unknown' : name,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      onChanged: (v) {
        setState(() {
          if (v == true) {
            _selected.add(id);
          } else {
            _selected.remove(id);
          }
        });
        _presence.setAudience('selected', _selected);
      },
    );
  }
}
