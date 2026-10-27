import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/now_playing_presence.dart';
import 'api_service.dart';
import '../utils/bounce_tap.dart';
import '../services/contact_names.dart';
import '../widgets/person_avatar.dart';

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
/// A floating Aluta card (centred, capped width on wide screens).
Future<void> showListeningAudienceSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    // No theme outline — the sheet draws its own card.
    shape: const RoundedRectangleBorder(),
    elevation: 0,
    barrierColor: Colors.black.withValues(alpha: 0.25),
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
  String _query = '';

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

  String _nameOf(Map<String, dynamic> f) => ContactNames.instance
      .displayName(of: f, registered: (f['username'] ?? '').toString());

  void _setSelected(Set<int> next) {
    setState(() => _selected = next);
    _presence.setAudience('selected', _selected);
  }

  LinearGradient _grad(ColorScheme scheme) => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.lerp(scheme.primary, Colors.white, 0.15)!,
          Color.lerp(scheme.primary, Colors.black, 0.15)!,
        ],
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final media = MediaQuery.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            12, 0, 12, media.viewInsets.bottom + 12),
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 460,
              maxHeight: media.size.height * 0.85,
            ),
            child: Container(
              decoration: BoxDecoration(
                color: isDark
                    ? Color.alphaBlend(
                        Colors.white.withValues(alpha: 0.05), scheme.surface)
                    : scheme.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                    color: scheme.primary
                        .withValues(alpha: isDark ? 0.30 : 0.18)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.14),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: AnimatedBuilder(
                animation: _presence,
                builder: (context, _) => _body(context, scheme, isDark),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, ColorScheme scheme, bool isDark) {
    final on = _presence.shareEnabled;
    final selectedMode = _presence.shareToSelected;
    final shown = _friends
        .where((f) =>
            _query.isEmpty || _nameOf(f).toLowerCase().contains(_query))
        .toList();
    final String summary = !on
        ? 'Your listening is private'
        : selectedMode
            ? (_selected.isEmpty
                ? 'Nobody picked yet — choose friends below'
                : '${_selected.length} friend${_selected.length == 1 ? '' : 's'} can see your track')
            : 'Everyone in your circle sees your track';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header: gradient chip · title + live summary · close.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 10, 12),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: on ? _grad(scheme) : null,
                  color: on ? null : scheme.surfaceContainerHighest,
                  boxShadow: on
                      ? [
                          BoxShadow(
                              color: scheme.primary.withValues(alpha: 0.35),
                              blurRadius: 10,
                              offset: const Offset(0, 3)),
                        ]
                      : null,
                ),
                child: Icon(
                    on ? Icons.sensors_rounded : Icons.sensors_off_rounded,
                    size: 20,
                    color: on ? Colors.white : scheme.onSurfaceVariant),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Listening now',
                        style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: scheme.onSurface)),
                    const SizedBox(height: 2),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: Text(summary,
                          key: ValueKey(summary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant)),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: Icon(Icons.close_rounded,
                    size: 20, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        // Master switch as a soft tile.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Material(
            color: on
                ? scheme.primary.withValues(alpha: isDark ? 0.16 : 0.08)
                : scheme.surfaceContainerHighest
                    .withValues(alpha: isDark ? 0.5 : 0.7),
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () {
                HapticFeedback.selectionClick();
                _presence.setShareEnabled(!on);
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                child: Row(
                  children: [
                    Icon(Icons.graphic_eq_rounded,
                        size: 20,
                        color: on ? scheme.primary : scheme.onSurfaceVariant),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("Share what I'm listening to",
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: scheme.onSurface)),
                          Text(
                              on
                                  ? 'Friends see the song on your avatar'
                                  : 'Turn on to let friends tune in',
                              style: TextStyle(
                                  fontSize: 11.5,
                                  color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    Switch(
                      value: on,
                      onChanged: (v) {
                        HapticFeedback.selectionClick();
                        _presence.setShareEnabled(v);
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // Who can see — two choice cards, then (selected) the friend picker.
        AnimatedSize(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: !on
              ? const SizedBox(height: 4)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 16, 16, 8),
                      child: Text('WHO CAN SEE',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1,
                              color: scheme.onSurfaceVariant)),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: _audienceCard(scheme, isDark,
                                icon: Icons.groups_rounded,
                                label: 'Everyone',
                                sub: 'My whole circle',
                                value: 'everyone'),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _audienceCard(scheme, isDark,
                                icon: Icons.person_pin_rounded,
                                label: 'Only some',
                                sub: 'Friends I pick',
                                value: 'selected'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
        if (on && selectedMode) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 38,
                    child: TextField(
                      onChanged: (v) =>
                          setState(() => _query = v.trim().toLowerCase()),
                      style: const TextStyle(fontSize: 13.5),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'Search friends',
                        prefixIcon:
                            const Icon(Icons.search_rounded, size: 18),
                        filled: true,
                        fillColor: scheme.surfaceContainerHighest
                            .withValues(alpha: isDark ? 0.5 : 0.7),
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 8),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                ),
                if (_friends.isNotEmpty)
                  TextButton(
                    onPressed: () => _setSelected(
                        _selected.length == _friends.length
                            ? <int>{}
                            : {
                                for (final f in _friends)
                                  (f['id'] as num?)?.toInt() ?? -1
                              }..remove(-1)),
                    child: Text(_selected.length == _friends.length
                        ? 'Clear'
                        : 'All'),
                  ),
              ],
            ),
          ),
          Flexible(
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : shown.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                            _friends.isEmpty
                                ? 'No friends to choose from yet.'
                                : 'No friend matches “$_query”.',
                            textAlign: TextAlign.center,
                            style:
                                TextStyle(color: scheme.onSurfaceVariant)),
                      )
                    : ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                        children: [
                          for (final f in shown) _friendRow(scheme, f),
                        ],
                      ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Done',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }

  Widget _audienceCard(ColorScheme scheme, bool isDark,
      {required IconData icon,
      required String label,
      required String sub,
      required String value}) {
    final active = _presence.shareMode == value;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          HapticFeedback.selectionClick();
          _presence.setAudience(value, _selected);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: active ? _grad(scheme) : null,
            color: active
                ? null
                : (isDark
                    ? scheme.surfaceContainerHighest
                    : Color.alphaBlend(scheme.primary.withValues(alpha: 0.04),
                        scheme.surfaceContainerHighest)),
            border: Border.all(
                color: active
                    ? scheme.primary
                    : scheme.primary.withValues(alpha: isDark ? 0.25 : 0.16)),
            boxShadow: active
                ? [
                    BoxShadow(
                        color: scheme.primary.withValues(alpha: 0.35),
                        blurRadius: 10,
                        offset: const Offset(0, 3)),
                  ]
                : null,
          ),
          child: Row(
            children: [
              Icon(icon,
                  size: 22,
                  color: active ? scheme.onPrimary : scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                            color: active
                                ? scheme.onPrimary
                                : scheme.onSurface)),
                    Text(sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11,
                            color: active
                                ? scheme.onPrimary.withValues(alpha: 0.85)
                                : scheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _friendRow(ColorScheme scheme, Map<String, dynamic> f) {
    final id = (f['id'] as num?)?.toInt() ?? -1;
    final name = _nameOf(f);
    final checked = _selected.contains(id);
    return Material(
      color: checked
          ? scheme.primary.withValues(alpha: 0.07)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          HapticFeedback.selectionClick();
          final next = Set<int>.from(_selected);
          checked ? next.remove(id) : next.add(id);
          _setSelected(next);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              PersonAvatar(
                name: name,
                avatar: f['avatar_url'] as String?,
                radius: 18,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(name.isEmpty ? 'Unknown' : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight:
                            checked ? FontWeight.w700 : FontWeight.w500,
                        color: scheme.onSurface)),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: checked ? _grad(scheme) : null,
                  border: checked
                      ? null
                      : Border.all(
                          color: scheme.onSurfaceVariant
                              .withValues(alpha: 0.5),
                          width: 1.5),
                ),
                child: checked
                    ? const Icon(Icons.check_rounded,
                        size: 16, color: Colors.white)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
