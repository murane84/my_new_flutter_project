import 'package:flutter/material.dart';

import '../../services/account_prefs.dart';
import '../../services/status_privacy.dart';
import '../../utils/prefs_now.dart';
import 'create_story_sheet.dart' show kStatusBgs, StatusPaletteButton;
import 'status_audience_sheet.dart';
import '../../widgets/edge_scroll_row.dart';
import '../../utils/motion.dart';
import '../../utils/radii.dart';
import '../../utils/adaptive_sheet.dart';

/// What a one-tap share will look like, and in which colours.
enum QuickStatusKind { text, music, sticker }

/// The quick "Share as status" step used by the music player list, a chat
/// bubble and Glow: a live preview of the status on the chosen background,
/// the same colour strip as the composer (+ the custom palette), and Post.
/// Remembers the last colour, so it opens on your own taste next time.
///
/// What to post: the background ("#hexA,#hexB" or "#hex") and the words —
/// the (edited) text of a text status, or a caption for a song / GIF.
class QuickStatusChoice {
  const QuickStatusChoice(this.background, this.text);
  final String background;
  final String text;
}

/// Null when cancelled.
Future<QuickStatusChoice?> pickStatusColours(
  BuildContext context, {
  required QuickStatusKind kind,
  String text = '',
  String title = '',
  String artist = '',
  String? stickerUrl,
  String? note, // e.g. "It came from someone else — make sure…"
}) {
  return showAdaptiveSheet<QuickStatusChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (_) => _QuickStatusSheet(
        kind: kind,
        text: text,
        title: title,
        artist: artist,
        stickerUrl: stickerUrl,
        note: note),
  );
}

const _kLastBg = 'quick_status_bg_v1';

class _QuickStatusSheet extends StatefulWidget {
  const _QuickStatusSheet({
    required this.kind,
    required this.text,
    required this.title,
    required this.artist,
    this.stickerUrl,
    this.note,
  });
  final QuickStatusKind kind;
  final String text, title, artist;
  final String? stickerUrl;
  final String? note;

  @override
  State<_QuickStatusSheet> createState() => _QuickStatusSheetState();
}

class _QuickStatusSheetState extends State<_QuickStatusSheet> {
  late List<Color> _cur;
  // Text status: the words themselves (editable). Song / GIF: a caption.
  late final TextEditingController _words =
      TextEditingController(text: widget.text);

  @override
  void dispose() {
    _words.dispose();
    super.dispose();
  }

  static String _hex(Color c) =>
      '#${c.toARGB32().toRadixString(16).padLeft(8, '0')}';

  static List<Color>? _parse(String? v) {
    if (v == null || v.isEmpty) return null;
    try {
      final cs = v
          .split(',')
          .map((h) => Color(int.parse(h.replaceFirst('#', ''), radix: 16)))
          .toList();
      return cs.isEmpty ? null : cs;
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _cur = _parse(prefsNow?.getString(_kLastBg)) ?? kStatusBgs.first;
    _words.addListener(() => setState(() {}));
  }

  String get _value =>
      _cur.length >= 2 ? '${_hex(_cur[0])},${_hex(_cur[1])}' : _hex(_cur[0]);

  static Color _ink(List<Color> cs) {
    final l = cs.map((c) => c.computeLuminance()).reduce((a, b) => a + b) /
        cs.length;
    return l > 0.55 ? const Color(0xFF15171C) : Colors.white;
  }

  bool _same(List<Color> a, List<Color> b) =>
      a.length == b.length &&
      List.generate(a.length, (i) => a[i].toARGB32() == b[i].toARGB32())
          .every((x) => x);

  Widget _preview() {
    // The words' ink glides to the new colour with the background, instead
    // of snapping white ↔ dark mid-change.
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: _ink(_cur)),
      duration: Motion.standard,
      curve: Curves.easeOut,
      builder: (context, c, _) => _previewWith(c ?? _ink(_cur)),
    );
  }

  Widget _previewWith(Color ink) {
    // Always a gradient (a plain colour = the same colour twice): animating
    // between a plain colour and a gradient fades through transparent, which
    // flashed the dark backdrop whenever you left purple.
    final deco = BoxDecoration(
      borderRadius: BorderRadius.circular(Radii.xl),
      gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _cur.length >= 2 ? _cur : [_cur.first, _cur.first]),
    );
    Widget body;
    switch (widget.kind) {
      case QuickStatusKind.text:
        final n = _words.text.trim().length;
        body = Text(_words.text,
            textAlign: TextAlign.center,
            maxLines: 9,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: ink,
                fontWeight: FontWeight.w700,
                height: 1.3,
                fontSize: n <= 40 ? 24 : (n <= 140 ? 18 : 14.5)));
      case QuickStatusKind.music:
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.music_note_rounded, size: 44, color: ink),
          const SizedBox(height: 10),
          Text(widget.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: ink, fontSize: 20, fontWeight: FontWeight.w800)),
          if (widget.artist.isNotEmpty)
            Text(widget.artist,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: ink.withValues(alpha: 0.8), fontSize: 14)),
          if (_words.text.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(_words.text.trim(),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: ink, fontSize: 13.5, fontStyle: FontStyle.italic)),
          ],
        ]);
      case QuickStatusKind.sticker:
        final u = widget.stickerUrl ?? '';
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          u.startsWith('http')
              ? Image.network(u, height: 150, fit: BoxFit.contain)
              : Icon(Icons.gif_box_rounded, size: 60, color: ink),
          if (_words.text.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(_words.text.trim(),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: ink, fontSize: 14, fontWeight: FontWeight.w600)),
          ],
        ]);
    }
    return AnimatedContainer(
      duration: Motion.standard,
      curve: Curves.easeOut,
      height: 260,
      width: double.infinity,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(22),
      decoration: deco,
      child: body,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ink = scheme.onSurface;
    return SafeArea(
      child: SingleChildScrollView(
        // Typing a caption lifts the sheet above the keyboard.
        padding: EdgeInsets.fromLTRB(
            16, 0, 16, 12 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Share as your status',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('Pick its colours — your circle sees it for 24 hours',
              style:
                  TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
          if (widget.note != null) ...[
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.info_outline_rounded,
                  size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(widget.note!,
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
              ),
            ]),
          ],
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: _preview(),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 46,
            child: EdgeScrollRow(builder: (_, edgeCtrl) => ListView.separated(controller: edgeCtrl, 
              scrollDirection: Axis.horizontal,
              itemCount: kStatusBgs.length + 1,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                if (i == 0) {
                  final custom = !kStatusBgs.any((b) => _same(b, _cur));
                  return Center(
                    child: StatusPaletteButton(
                      ink: ink,
                      current: custom ? _cur.first : null,
                      size: custom ? 38 : 30,
                      onPicked: (c) => setState(() => _cur = [
                            c,
                            Color.lerp(c, Colors.black, 0.35)!,
                          ]),
                    ),
                  );
                }
                final pair = kStatusBgs[i - 1];
                final on = _same(pair, _cur);
                return GestureDetector(
                  onTap: () => setState(() => _cur = pair),
                  child: Center(
                    child: AnimatedContainer(
                      duration: Motion.quick,
                      width: on ? 38 : 30,
                      height: on ? 38 : 30,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: pair.length >= 2
                            ? LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: pair)
                            : null,
                        color: pair.length >= 2 ? null : pair.first,
                        border: Border.all(
                            color: on ? ink : ink.withValues(alpha: 0.3),
                            width: on ? 3 : 1.5),
                      ),
                      child: on
                          ? Icon(Icons.check_rounded,
                              size: 16, color: _ink(pair))
                          : null,
                    ),
                  ),
                );
              },
            )),
          ),
          const SizedBox(height: 10),
          // The words: edit a text status, or add a line to a song / GIF.
          TextField(
            controller: _words,
            maxLength: widget.kind == QuickStatusKind.text ? 700 : 140,
            minLines: 1,
            maxLines: widget.kind == QuickStatusKind.text ? 4 : 2,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              isDense: true,
              counterText: '',
              hintText: widget.kind == QuickStatusKind.text
                  ? 'Your status'
                  : 'Add a few words (optional)',
              prefixIcon: const Icon(Icons.edit_note_rounded, size: 20),
              filled: true,
              fillColor: scheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Radii.lg),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 6),
          // Who will see it — the same "Who can see my status" choice, one
          // tap away (it applies to every status, not just this one).
          ValueListenableBuilder<String>(
            valueListenable: StatusPrivacy.instance.mode,
            builder: (context, _, _) => ValueListenableBuilder<Set<int>>(
              valueListenable: StatusPrivacy.instance.hidden,
              builder: (context, _, _) => Align(
                alignment: Alignment.centerLeft,
                child: ActionChip(
                  visualDensity: VisualDensity.compact,
                  avatar: Icon(Icons.visibility_rounded,
                      size: 16, color: scheme.primary),
                  label: Text('Seen by: ${StatusPrivacy.instance.summary}',
                      style: const TextStyle(fontSize: 12)),
                  onPressed: () => showStatusAudienceSheet(context),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                // A text status needs words.
                onPressed: (widget.kind == QuickStatusKind.text &&
                        _words.text.trim().isEmpty)
                    ? null
                    : () {
                        prefsNow
                            ?.setString(_kLastBg, _value)
                            .then((_) => AccountPrefs.touch());
                        Navigator.pop(context,
                            QuickStatusChoice(_value, _words.text.trim()));
                      },
                icon: const Icon(Icons.amp_stories_rounded, size: 18),
                label: const Text('Post'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}
