part of '../music_controls.dart';

// Lyrics sheet: synced (LRC `[mm:ss.xx]`) with line-by-line highlight following
// the shared play clock. Plain lyrics follow the song too, with no typing of
// timestamps: an automatic estimate from the song length ("≈ auto timing"),
// "Tap to sync" (tap Next as each line starts — one listen, exact), and a
// long-press "Starts now" that fixes one line and re-flows the rest. Users can
// paste/edit lyrics (saved via onSave to the in-app store).

final _lyricLabelRe = RegExp(r'^\s*[\[(][^\]\)]{1,40}[\])]\s*$');

/// The singable lines of plain lyrics, with section labels ("[Chorus]") and
/// blank lines kept as breaks (a short pause), not as lines.
List<(String, bool)> lyricPlainLines(String plain) {
  final out = <(String, bool)>[]; // (text, breakBefore)
  var brk = false;
  for (final raw in plain.split('\n')) {
    final l = raw.trim();
    if (l.isEmpty || _lyricLabelRe.hasMatch(l)) {
      brk = out.isNotEmpty;
      continue;
    }
    out.add((l, brk));
    brk = false;
  }
  return out;
}

/// Plain lyrics spread over the song: an intro lead-in, an outro, a short
/// pause at each section break, and more time for longer lines. Shared by the
/// lyrics sheet and the one-line ticker on Now Playing.
///
/// With a [vocal] map (where the singer actually starts / stops, and the
/// instrumental breaks — found by listening to the file) the lines are laid
/// over the SUNG time only: the first line lands when the voice comes in,
/// and nothing runs during a guitar solo.
List<(Duration, String)> estimateLyricTiming(String plain, Duration total,
    {VocalMap? vocal}) {
  final ls = lyricPlainLines(plain);
  if (ls.isEmpty || total < const Duration(seconds: 20)) return const [];
  final totalMs = total.inMilliseconds;
  // Sung stretches of the song, in ms: [from, to).
  final segs = <(double, double)>[];
  if (vocal != null && vocal.end.inMilliseconds <= totalMs + 2000) {
    var from = vocal.start.inMilliseconds.toDouble();
    for (final b in vocal.breaks) {
      final bs = b.$1.inMilliseconds.toDouble();
      if (bs > from) segs.add((from, bs));
      from = b.$2.inMilliseconds.toDouble();
    }
    final end = vocal.end.inMilliseconds.clamp(0, totalMs).toDouble();
    if (end > from) segs.add((from, end));
  }
  if (segs.isEmpty) {
    // No map: many songs start singing within seconds — keep the lead-in
    // short; the strip's nudge / tap-along fixes the rest.
    final lead = (totalMs * 0.035).clamp(2500, 9000).toDouble();
    final outro = (totalMs * 0.06).clamp(4000, 14000).toDouble();
    segs.add((lead, totalMs - outro));
  }
  final sung = segs.fold<double>(0, (a, s) => a + (s.$2 - s.$1));
  const pauseMs = 1600.0;
  final pauses = ls.where((e) => e.$2).length * pauseMs;
  final weights = [for (final e in ls) e.$1.length.clamp(10, 60).toDouble()];
  final wsum = weights.fold<double>(0, (a, b) => a + b);
  var avail = sung - pauses;
  if (avail < ls.length * 1200) avail = ls.length * 1200.0;
  // Sung-time position → real song time (skipping the breaks).
  double real(double t) {
    var left = t;
    for (final s in segs) {
      final len = s.$2 - s.$1;
      if (left <= len) return s.$1 + left;
      left -= len;
    }
    return segs.last.$2 + left;
  }

  var t = 0.0;
  final out = <(Duration, String)>[];
  for (var i = 0; i < ls.length; i++) {
    if (ls[i].$2 && i > 0) t += pauseMs;
    out.add((Duration(milliseconds: real(t).round()), ls[i].$1));
    t += avail * weights[i] / wsum;
  }
  return out;
}

class _LyricsView extends StatefulWidget {
  final String title;
  final String artist;
  final String raw;
  final void Function(String) onSave;
  /// Tap a synced line to jump the song there.
  final void Function(Duration)? onSeek;

  /// The song file — for its VocalMap (where the singing starts).
  final String? path;

  const _LyricsView({
    this.path,
    required this.title,
    required this.artist,
    required this.raw,
    required this.onSave,
    this.onSeek,
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

  // Auto-estimated timing for plain lyrics (cached per song length).
  List<(Duration, String)> _auto = [];
  Duration _autoFor = Duration.zero;
  VocalMap? _autoVocal;

  // Tap-to-sync session.
  bool _syncing = false;
  List<String> _syncText = [];
  final List<Duration> _syncAt = [];


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
      builder: (context, sheetScroll) => Material(
        color: scheme.surface,
        clipBehavior: Clip.antiAlias,
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(22)),
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
                            style: TextStyle(
                                color: scheme.onSurface,
                                fontWeight: FontWeight.bold,
                                fontSize: 15)),
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
                  if (!_editing && !_syncing && _plain.isNotEmpty)
                    PopupMenuButton<String>(
                      tooltip: 'Timing',
                      icon: Icon(Icons.timer_outlined, color: scheme.primary),
                      onSelected: (v) {
                        if (v == 'sync') _startSync();
                        if (v == 'earlier') _shiftAll(-500);
                        if (v == 'later') _shiftAll(500);
                        if (v == 'auto') _clearTiming();
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'sync',
                          child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.touch_app_rounded),
                            title: Text('Tap to sync'),
                            subtitle: Text('Tap Next as each line starts'),
                          ),
                        ),
                        if (_lines.isNotEmpty) ...[
                          const PopupMenuItem(
                            value: 'earlier',
                            child: ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.fast_rewind_rounded),
                              title: Text('Lyrics 0.5 s earlier'),
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'later',
                            child: ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.fast_forward_rounded),
                              title: Text('Lyrics 0.5 s later'),
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'auto',
                            child: ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.auto_mode_rounded),
                              title: Text('Back to auto timing'),
                            ),
                          ),
                        ],
                      ],
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
                  // Explicit close (the drag handle alone is awkward on desktop).
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    color: scheme.onSurfaceVariant,
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: scheme.outlineVariant.withAlpha(70)),
            Expanded(
              child: _editing
                  ? _editor(scheme, sheetScroll)
                  : _syncing
                      ? _syncPanel(scheme)
                      : _lines.isNotEmpty
                          ? _synced(scheme, _lines, auto: false)
                          : _autoOrPlain(scheme, sheetScroll),
            ),
          ],
        ),
      ),
    );
  }

  void _saveEdits() {
    widget.onSave(_editCtrl.text);
    setState(() {
      _raw = _editCtrl.text;
      _editing = false;
      _lastLine = -1;
      _parse();
    });
  }

  Widget _editor(ColorScheme scheme, ScrollController sc) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 14, 16, MediaQuery.of(context).viewInsets.bottom + 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline_rounded,
                  size: 15, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Paste plain lyrics, or LRC with [mm:ss.xx] timestamps for '
                  'synced line-by-line highlighting.',
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Fill the whole sheet — no awkward empty space below a small box.
          Expanded(
            child: TextField(
              controller: _editCtrl,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              style: TextStyle(
                  fontSize: 14, height: 1.5, color: scheme.onSurface),
              decoration: InputDecoration(
                hintText: '[00:12.50] First line…\n[00:16.20] Second line…',
                hintStyle: TextStyle(
                    color: scheme.onSurfaceVariant.withAlpha(130),
                    height: 1.5),
                filled: true,
                fillColor: scheme.surfaceContainerHighest
                    .withValues(alpha: 0.6),
                contentPadding: const EdgeInsets.all(14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (_raw.trim().isNotEmpty)
                TextButton(
                  onPressed: () => setState(() {
                    _editCtrl.text = _raw;
                    _editing = false;
                  }),
                  child: const Text('Cancel'),
                ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _saveEdits,
                icon: const Icon(Icons.check_rounded, size: 18),
                label: const Text('Save lyrics'),
              ),
            ],
          ),
        ],
      ),
    );
  }

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

  Widget _synced(ColorScheme scheme, List<(Duration, String)> lines,
      {required bool auto}) {
    return ValueListenableBuilder<PlayClock>(
      valueListenable: playClockNotifier,
      builder: (_, clock, _) {
        final active = _currentIn(lines, clock.position);
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _autoScroll(active));
        // Soft top/bottom fade so lines drift in and out of view.
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (r) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.white,
              Colors.white,
              Colors.transparent
            ],
            stops: [0.0, 0.08, 0.88, 1.0],
          ).createShader(r),
          child: Stack(children: [
          ListView.builder(
          controller: _scrollCtrl,
          padding: EdgeInsets.fromLTRB(16, auto ? 44 : 24, 16, 80),
          itemCount: lines.length,
          itemBuilder: (_, i) {
            final on = i == active;
            // Lines further from the current one fade gently; sung lines
            // sit a little quieter than the ones still to come.
            final d = active < 0 ? 3 : (i - active).abs();
            final alpha = on
                ? 255
                : (i < active ? 95 : (200 - d * 22).clamp(90, 200));
            return InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: widget.onSeek == null
                  ? null
                  : () => widget.onSeek!(lines[i].$1),
              // Fix one line: it starts NOW; the lines after it re-flow.
              onLongPress: () => _startsNow(lines, i, clock.position),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                child: AnimatedScale(
                  scale: on ? 1.0 : 0.94,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 17,
                      height: 1.35,
                      fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                      color: on
                          ? scheme.primary
                          : scheme.onSurface.withAlpha(alpha.toInt()),
                      shadows: on
                          ? [
                              Shadow(
                                  color: scheme.primary.withAlpha(70),
                                  blurRadius: 12)
                            ]
                          : null,
                    ),
                    child: Text(
                      lines[i].$2.isEmpty ? '♪' : lines[i].$2,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
          if (auto)
            Positioned(
              top: 8,
              left: 0,
              right: 0,
              child: Center(
                child: Material(
                  color: scheme.surfaceContainerHighest,
                  shape: const StadiumBorder(),
                  child: InkWell(
                    customBorder: const StadiumBorder(),
                    onTap: _startSync,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      child: Text(
                        '≈ auto timing · tap to sync exactly',
                        style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ]),
        );
      },
    );
  }

  // ── Auto timing ────────────────────────────────────────────────────────────

  int _currentIn(List<(Duration, String)> lines, Duration pos) {
    var idx = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].$1 <= pos) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  List<(Duration, String)> _estimate(Duration total) =>
      estimateLyricTiming(_plain, total,
          vocal: widget.path == null
              ? null
              : VocalMaps.instance.cached(widget.path!));

  Widget _autoOrPlain(ColorScheme scheme, ScrollController sc) {
    if (_plain.isEmpty) return _plainView(scheme, sc);
    return ValueListenableBuilder<PlayClock>(
      valueListenable: playClockNotifier,
      builder: (_, clock, _) {
        final d = clock.duration;
        if (d < const Duration(seconds: 20)) return _plainView(scheme, sc);
        final vm = widget.path == null
            ? null
            : VocalMaps.instance.cached(widget.path!);
        if (d != _autoFor || !identical(vm, _autoVocal)) {
          _autoFor = d;
          _autoVocal = vm;
          _auto = _estimate(d);
        }
        if (_auto.isEmpty) return _plainView(scheme, sc);
        return _synced(scheme, _auto, auto: true);
      },
    );
  }

  // ── Saving timing ──────────────────────────────────────────────────────────

  static String _tag(Duration d) {
    final ms = d.inMilliseconds < 0 ? 0 : d.inMilliseconds;
    final m = ms ~/ 60000, s = (ms % 60000) ~/ 1000, cs = (ms % 1000) ~/ 10;
    return '[${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.'
        '${cs.toString().padLeft(2, '0')}]';
  }

  void _saveTimed(List<(Duration, String)> lines) {
    final text = lines.map((e) => '${_tag(e.$1)}${e.$2}').join('\n');
    widget.onSave(text);
    setState(() {
      _raw = text;
      _editCtrl.text = text;
      _lastLine = -1;
      _parse();
    });
  }

  void _shiftAll(int ms) {
    if (_lines.isEmpty) return;
    _saveTimed([
      for (final l in _lines) (l.$1 + Duration(milliseconds: ms), l.$2),
    ]);
    showToast(context, ms < 0 ? 'Lyrics moved 0.5 s earlier' : 'Lyrics moved 0.5 s later');
  }

  void _clearTiming() {
    final text = _plain;
    widget.onSave(text);
    setState(() {
      _raw = text;
      _editCtrl.text = text;
      _lastLine = -1;
      _autoFor = Duration.zero;
      _parse();
    });
  }

  /// Long-press: this line starts NOW — it and every line after it move by
  /// the same amount (what came before stays as it was).
  void _startsNow(List<(Duration, String)> lines, int i, Duration now) {
    HapticFeedback.mediumImpact();
    final delta = now - lines[i].$1;
    _saveTimed([
      for (var j = 0; j < lines.length; j++)
        (j >= i ? lines[j].$1 + delta : lines[j].$1, lines[j].$2),
    ]);
    showToast(context, 'Line set to start here — the rest follow');
  }

  // ── Tap to sync ────────────────────────────────────────────────────────────

  void _startSync() {
    final ls = lyricPlainLines(_plain).map((e) => e.$1).toList();
    if (ls.isEmpty) return;
    setState(() {
      _syncing = true;
      _syncText = ls;
      _syncAt.clear();
    });
    widget.onSeek?.call(Duration.zero);
    playbackBus.onPlay?.call();
  }

  void _syncTap() {
    if (_syncAt.length >= _syncText.length) return;
    HapticFeedback.selectionClick();
    setState(() => _syncAt.add(playClockNotifier.value.position));
    if (_syncAt.length == _syncText.length) _finishSync();
  }

  void _finishSync() {
    if (_syncAt.isEmpty) {
      setState(() => _syncing = false);
      return;
    }
    // Lines not reached yet keep an estimate after the last tap.
    final timed = <(Duration, String)>[];
    for (var i = 0; i < _syncText.length; i++) {
      final at = i < _syncAt.length
          ? _syncAt[i]
          : _syncAt.last + Duration(seconds: 3 * (i - _syncAt.length + 1));
      timed.add((at, _syncText[i]));
    }
    setState(() => _syncing = false);
    _saveTimed(timed);
    showToast(context, 'Lyrics synced 🎤', type: ToastType.success);
  }

  Widget _syncPanel(ColorScheme scheme) {
    final i = _syncAt.length;
    String at(int k) => k >= 0 && k < _syncText.length ? _syncText[k] : '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(children: [
        Text('Tap Next the moment each line starts',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        Text('${i.clamp(0, _syncText.length)} of ${_syncText.length}',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: scheme.primary)),
        const Spacer(),
        Text(at(i - 1),
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 14, color: scheme.onSurface.withAlpha(110))),
        const SizedBox(height: 14),
        Text(i < _syncText.length ? at(i) : 'All lines timed',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: scheme.primary)),
        const SizedBox(height: 14),
        Text(at(i + 1),
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 14, color: scheme.onSurface.withAlpha(150))),
        const Spacer(),
        SizedBox(
          width: double.infinity,
          height: 64,
          child: FilledButton.icon(
            onPressed: i < _syncText.length ? _syncTap : null,
            icon: const Icon(Icons.touch_app_rounded),
            label: const Text('Next line',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20))),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          TextButton.icon(
            onPressed: i == 0
                ? null
                : () {
                    // Missed one: undo the last tap and replay a bit before.
                    final back = _syncAt.removeLast();
                    setState(() {});
                    final to = back - const Duration(seconds: 3);
                    widget.onSeek
                        ?.call(to < Duration.zero ? Duration.zero : to);
                  },
            icon: const Icon(Icons.undo_rounded, size: 18),
            label: const Text('Back'),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => setState(() {
              _syncing = false;
              _syncAt.clear();
            }),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 4),
          FilledButton.tonal(
            onPressed: i == 0 ? null : _finishSync,
            child: const Text('Done'),
          ),
        ]),
      ]),
    );
  }
}
