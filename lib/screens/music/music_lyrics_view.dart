part of '../music_controls.dart';

// Lyrics sheet: synced (LRC `[mm:ss.xx]`) with line-by-line highlight following
// the shared play clock, or plain text. Users can paste/edit lyrics (saved via
// onSave to the in-app store).

class _LyricsView extends StatefulWidget {
  final String title;
  final String artist;
  final String raw;
  final void Function(String) onSave;

  const _LyricsView({
    required this.title,
    required this.artist,
    required this.raw,
    required this.onSave,
  });

  @override
  State<_LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<_LyricsView> {
  static final _tagRe = RegExp(r'\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]');

  late String _raw;
  bool _editing = false;
  late final TextEditingController _editCtrl;
  final ScrollController _scrollCtrl = ScrollController();
  int _lastLine = -1;

  // Parsed synced lines (empty => plain mode).
  List<(Duration, String)> _lines = [];
  String _plain = '';

  @override
  void initState() {
    super.initState();
    _raw = widget.raw;
    _editCtrl = TextEditingController(text: _raw);
    _editing = _raw.trim().isEmpty; // jump straight to the editor when empty
    _parse();
  }

  @override
  void dispose() {
    _editCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _parse() {
    final lines = <(Duration, String)>[];
    for (final line in _raw.split('\n')) {
      final matches = _tagRe.allMatches(line).toList();
      if (matches.isEmpty) continue;
      final text = line.replaceAll(_tagRe, '').trim();
      for (final m in matches) {
        final mm = int.parse(m.group(1)!);
        final ss = int.parse(m.group(2)!);
        final fr = m.group(3);
        final ms =
            fr != null ? int.parse(fr.padRight(3, '0').substring(0, 3)) : 0;
        lines.add(
            (Duration(minutes: mm, seconds: ss, milliseconds: ms), text));
      }
    }
    lines.sort((a, b) => a.$1.compareTo(b.$1));
    _lines = lines;
    _plain = _raw.replaceAll(_tagRe, '').trim();
  }

  int _currentLine(Duration pos) {
    var idx = -1;
    for (var i = 0; i < _lines.length; i++) {
      if (_lines[i].$1 <= pos) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  void _autoScroll(int idx) {
    if (idx < 0 || !_scrollCtrl.hasClients || idx == _lastLine) return;
    _lastLine = idx;
    final target =
        (idx * 34.0 - 120).clamp(0.0, _scrollCtrl.position.maxScrollExtent);
    _scrollCtrl.animateTo(target,
        duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, sheetScroll) => Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 4),
              width: 42,
              height: 5,
              decoration: BoxDecoration(
                color: scheme.onSurfaceVariant.withAlpha(90),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 6),
              child: Row(
                children: [
                  Icon(Icons.lyrics_rounded, color: scheme.primary, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15)),
                        if (widget.artist.isNotEmpty)
                          Text(widget.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                        _editing ? Icons.check_rounded : Icons.edit_rounded,
                        color: scheme.primary),
                    tooltip: _editing ? 'Save' : 'Edit lyrics',
                    onPressed: () {
                      if (_editing) {
                        widget.onSave(_editCtrl.text);
                        setState(() {
                          _raw = _editCtrl.text;
                          _editing = false;
                          _lastLine = -1;
                          _parse();
                        });
                      } else {
                        setState(() => _editing = true);
                      }
                    },
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: scheme.outlineVariant.withAlpha(70)),
            Expanded(
              child: _editing
                  ? _editor(scheme, sheetScroll)
                  : _lines.isNotEmpty
                      ? _synced(scheme)
                      : _plainView(scheme, sheetScroll),
            ),
          ],
        ),
      ),
    );
  }

  Widget _editor(ColorScheme scheme, ScrollController sc) => ListView(
        controller: sc,
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
        children: [
          Text(
            'Paste plain lyrics, or LRC with [mm:ss.xx] timestamps for synced '
            'line-by-line highlighting.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _editCtrl,
            maxLines: null,
            minLines: 8,
            keyboardType: TextInputType.multiline,
            decoration: InputDecoration(
              hintText: '[00:12.50] First line…\n[00:16.20] Second line…',
              filled: true,
              fillColor: scheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      );

  Widget _plainView(ColorScheme scheme, ScrollController sc) {
    if (_plain.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lyrics_outlined,
                size: 40, color: scheme.onSurfaceVariant),
            const SizedBox(height: 10),
            Text('No lyrics yet',
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => setState(() => _editing = true),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add lyrics'),
            ),
          ],
        ),
      );
    }
    return ListView(
      controller: sc,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
      children: [
        Text(_plain, style: const TextStyle(fontSize: 15, height: 1.6)),
      ],
    );
  }

  Widget _synced(ColorScheme scheme) {
    return ValueListenableBuilder<PlayClock>(
      valueListenable: playClockNotifier,
      builder: (_, clock, _) {
        final active = _currentLine(clock.position);
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _autoScroll(active));
        return ListView.builder(
          controller: _scrollCtrl,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 60),
          itemCount: _lines.length,
          itemBuilder: (_, i) {
            final on = i == active;
            return Padding(
              padding:
                  const EdgeInsets.symmetric(vertical: 5, horizontal: 8),
              child: Text(
                _lines[i].$2.isEmpty ? '♪' : _lines[i].$2,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: on ? 17 : 14.5,
                  height: 1.3,
                  fontWeight: on ? FontWeight.bold : FontWeight.w500,
                  color:
                      on ? scheme.primary : scheme.onSurface.withAlpha(140),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
