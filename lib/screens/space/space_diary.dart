part of '../relationship_space_page.dart';

// Split out of relationship_space_page.dart (pure code movement, no behaviour
// change): diary composer, paper/dog-ear painters, pressable button. A library `part`, so it shares the page's imports and
// private members.

// ── diary composer sheet ──────────────────────────────────────────────────
/// Write (or edit) a shared diary entry: a memory (something you shared) or a
/// plan ahead (with an optional date + a pin for a reminder). Returns a map
/// {kind, title, body, plan_date, pinned} on save, or null on cancel.
/// A reusable raised, 3D tappable surface: gradient body, hairline border and
/// layered shadows (down-shadow + top highlight), sinking flatter while held.
/// Used for the diary's primary CTA and its comment pill.
class _PressableRaised extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double radius;
  final Gradient gradient;
  final BoxBorder? border;
  final List<BoxShadow> shadows;
  const _PressableRaised({
    required this.child,
    required this.onTap,
    required this.gradient,
    this.shadows = const [],
    this.border,
    this.radius = 14,
  });

  @override
  State<_PressableRaised> createState() => _PressableRaisedState();
}

class _PressableRaisedState extends State<_PressableRaised> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(widget.radius);
    return AnimatedScale(
      scale: _down ? 0.97 : 1.0,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOut,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: r,
          gradient: widget.gradient,
          border: widget.border,
          // Sink: drop the lift while pressed so it reads as pushed in.
          boxShadow: _down ? const [] : widget.shadows,
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: r,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            borderRadius: r,
            onTap: widget.onTap,
            onHighlightChanged: (v) {
              if (mounted) setState(() => _down = v);
            },
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// A folded page-corner ("dog-ear") you tap to turn the diary. Bottom-right
/// turns forward, bottom-left turns back — the little curl reads as a real
/// book and, unlike the old floating arrow, never sits over the writing.
class _DiaryDogEar extends StatelessWidget {
  final bool isNext;
  final Color paper;
  final Color accent;
  final bool isDark;
  final VoidCallback onTap;
  const _DiaryDogEar({
    required this.isNext,
    required this.paper,
    required this.accent,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const s = 46.0;
    return Semantics(
      button: true,
      label: isNext ? 'Next page' : 'Previous page',
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: CustomPaint(
          size: const Size(s, s),
          painter: _DogEarPainter(
              isNext: isNext, paper: paper, accent: accent, isDark: isDark),
        ),
      ),
    );
  }
}

class _DogEarPainter extends CustomPainter {
  final bool isNext;
  final Color paper;
  final Color accent;
  final bool isDark;
  _DogEarPainter({
    required this.isNext,
    required this.paper,
    required this.accent,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.save();
    // Paint a bottom-RIGHT fold, then mirror horizontally for the prev corner.
    if (!isNext) {
      canvas.translate(w, 0);
      canvas.scale(-1, 1);
    }
    final creaseA = Offset(0, h); // bottom-left of the little square
    final creaseB = Offset(w, 0); // top-right
    final corner = Offset(w, h); // the folded page corner

    // Soft shadow along the crease, cast up-left onto the page, so the corner
    // reads as physically lifted.
    canvas.drawLine(
      creaseA,
      creaseB,
      Paint()
        ..color = Colors.black.withValues(alpha: isDark ? 0.30 : 0.15)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );

    // The flap (page underside): a triangle from the crease to the corner, with
    // a gentle gradient + a whisper of the Space colour so it feels warm.
    final flap = Path()
      ..moveTo(creaseA.dx, creaseA.dy)
      ..lineTo(corner.dx, corner.dy)
      ..lineTo(creaseB.dx, creaseB.dy)
      ..close();
    final under =
        Color.lerp(paper, isDark ? Colors.black : accent, isDark ? 0.35 : 0.20)!;
    canvas.drawPath(
      flap,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomRight,
          end: Alignment.topLeft,
          colors: [under, paper],
        ).createShader(Rect.fromLTWH(0, 0, w, h)),
    );

    // Crease highlight — the sharp top edge of the fold catching light.
    canvas.drawLine(
      creaseA,
      creaseB,
      Paint()
        ..color = Colors.white.withValues(alpha: isDark ? 0.06 : 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    // A faint chevron on the flap so the fold clearly reads as "turn the page".
    final cx = w * 0.70, cy = h * 0.70, cs = 5.0;
    canvas.drawPath(
      Path()
        ..moveTo(cx - cs, cy - cs)
        ..lineTo(cx + cs * 0.4, cy)
        ..lineTo(cx - cs, cy + cs),
      Paint()
        ..color = accent.withValues(alpha: 0.80)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _DogEarPainter old) =>
      old.isNext != isNext ||
      old.paper != paper ||
      old.accent != accent ||
      old.isDark != isDark;
}



/// Faint horizontal rules + a soft left margin line, so a memory reads like a
/// page from a lined notebook. Kept very low-contrast on purpose.
class _RuledPaperPainter extends CustomPainter {
  final Color line;
  final Color margin;
  _RuledPaperPainter({required this.line, required this.margin});

  @override
  void paint(Canvas canvas, Size size) {
    final rule = Paint()
      ..color = line
      ..strokeWidth = 1;
    const gap = 30.0;
    for (double y = 62; y < size.height - 8; y += gap) {
      canvas.drawLine(Offset(16, y), Offset(size.width - 16, y), rule);
    }
    final m = Paint()
      ..color = margin
      ..strokeWidth = 1.2;
    canvas.drawLine(const Offset(40, 14), Offset(40, size.height - 12), m);
  }

  @override
  bool shouldRepaint(covariant _RuledPaperPainter old) =>
      old.line != line || old.margin != margin;
}

class _DiaryComposer extends StatefulWidget {
  final Color accent;
  final Map<String, dynamic>? existing; // non-null when editing
  final String? myName; // for the live signature preview
  final String? seedTitle; // prefill (e.g. a kept moment's caption)
  final String? fromMomentThumb; // small preview of the moment being expanded
  final String? fromMomentLabel; // banner label when seeded from a moment
  const _DiaryComposer({
    required this.accent,
    this.existing,
    this.myName,
    this.seedTitle,
    this.fromMomentThumb,
    this.fromMomentLabel,
  });

  @override
  State<_DiaryComposer> createState() => _DiaryComposerState();
}

class _DiaryComposerState extends State<_DiaryComposer> {
  late final TextEditingController _title;
  late final TextEditingController _body;
  bool _planMode = false;
  DateTime? _date;
  bool _pinned = false;
  String _font = ''; // the author's chosen typeface for this memory

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _title = TextEditingController(
        text: (e?['title'] ?? widget.seedTitle ?? '').toString());
    _body = TextEditingController(text: (e?['body'] ?? '').toString());
    _planMode = (e?['kind'] ?? 'memory').toString() == 'plan';
    _date = DateTime.tryParse((e?['plan_date'] ?? '').toString());
    _pinned = e?['pinned'] == true;
    _font = (e?['font'] ?? '').toString();
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? now.add(const Duration(days: 1)),
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (picked != null && mounted) setState(() => _date = picked);
  }

  void _save() {
    final body = _body.text.trim();
    if (body.isEmpty) {
      showToast(context, 'Write a little something first.',
          type: ToastType.info);
      return;
    }
    final title = _title.text.trim();
    // plan_date is only meaningful for a plan; send '' (cleared) otherwise so an
    // edit that turns a plan into a memory drops the old date server-side.
    final planDate = _planMode && _date != null
        ? DateFormat('yyyy-MM-dd').format(_date!)
        : '';
    Navigator.pop(context, {
      'kind': _planMode ? 'plan' : 'memory',
      'title': title.isEmpty ? '' : title,
      'body': body,
      'plan_date': planDate,
      'pinned': _planMode && _pinned,
      // Font is the author's per-memory touch; plans (joint) don't carry one.
      'font': _planMode ? '' : _font,
    });
  }

  Widget _sectionLabel(ColorScheme scheme, String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t.toUpperCase(),
            style: TextStyle(
                fontSize: 10.5,
                letterSpacing: 0.8,
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant)),
      );

  Widget _modeSeg(ColorScheme scheme, String label, IconData icon,
      bool selected, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            color: selected ? widget.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            boxShadow: selected
                ? [
                    BoxShadow(
                        color: widget.accent.withValues(alpha: 0.35),
                        blurRadius: 10,
                        offset: const Offset(0, 3))
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 17,
                  color: selected ? Colors.white : scheme.onSurfaceVariant),
              const SizedBox(width: 7),
              Text(label,
                  style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color:
                          selected ? Colors.white : scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fontPill(ColorScheme scheme, (String, String) f) {
    final selected = _font == f.$1;
    return GestureDetector(
      onTap: () => setState(() => _font = f.$1),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? widget.accent.withValues(alpha: 0.14)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: selected
                ? widget.accent
                : scheme.outlineVariant.withValues(alpha: 0.5),
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              Icon(Icons.check_rounded, size: 15, color: widget.accent),
              const SizedBox(width: 6),
            ],
            Text(f.$2,
                style: TextStyle(
                    fontFamily: diaryFontFamily(f.$1),
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? widget.accent : scheme.onSurface)),
          ],
        ),
      ),
    );
  }

  InputDecoration _fieldDecoration(ColorScheme scheme, String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle:
          TextStyle(color: scheme.onSurfaceVariant.withValues(alpha: 0.7)),
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      counterStyle: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide:
            BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: widget.accent, width: 1.6),
      ),
    );
  }

  Widget _signaturePreview(ColorScheme scheme) {
    final name =
        (widget.myName ?? '').trim().isEmpty ? 'You' : widget.myName!.trim();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 18, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            widget.accent.withValues(alpha: 0.08),
            scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          ],
        ),
        border: Border.all(color: widget.accent.withValues(alpha: 0.20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.draw_rounded, size: 13, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text('YOUR SIGNATURE',
                  style: TextStyle(
                      fontSize: 9.5,
                      letterSpacing: 0.8,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Flexible(
                child: Text('— $name',
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: diaryFontFamily(_font) ??
                            diaryFontFamily('handwriting'),
                        fontSize: 22,
                        height: 1.15,
                        color: scheme.onSurface.withValues(alpha: 0.92))),
              ),
              const SizedBox(width: 8),
              Text('❦',
                  style: TextStyle(
                      fontSize: 15,
                      color: widget.accent.withValues(alpha: 0.75))),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final editing = widget.existing != null;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 10, 20, 18 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: widget.accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(Icons.menu_book_rounded,
                      size: 20, color: widget.accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(editing ? 'Edit diary entry' : 'Write in our diary',
                          style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 17,
                              color: scheme.onSurface)),
                      Text(
                          _planMode
                              ? 'A plan to look forward to'
                              : 'A moment worth keeping',
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
            if (widget.fromMomentLabel != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: widget.accent.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: widget.accent.withValues(alpha: 0.24)),
                ),
                child: Row(
                  children: [
                    if (widget.fromMomentThumb != null) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(9),
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: authNetworkImage(
                            url: widget.fromMomentThumb!,
                            headers: mediaAuthHeaders(widget.fromMomentThumb!),
                            fit: BoxFit.cover,
                            cacheWidth: 140,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.push_pin_rounded,
                                  size: 12, color: widget.accent),
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  widget.fromMomentLabel!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: widget.accent),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Tell the fuller story behind this moment 💞',
                            style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  _modeSeg(scheme, 'Memory', Icons.auto_stories_rounded,
                      !_planMode, () => setState(() => _planMode = false)),
                  const SizedBox(width: 4),
                  _modeSeg(scheme, 'Plan ahead', Icons.event_rounded, _planMode,
                      () => setState(() => _planMode = true)),
                ],
              ),
            ),
            if (!_planMode) ...[
              const SizedBox(height: 18),
              _sectionLabel(scheme, 'Your handwriting & signature'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [for (final f in kDiaryFonts) _fontPill(scheme, f)],
              ),
              const SizedBox(height: 12),
              _signaturePreview(scheme),
            ],
            const SizedBox(height: 18),
            _sectionLabel(scheme, _planMode ? 'Title' : 'Title (optional)'),
            TextField(
              controller: _title,
              maxLength: 80,
              style: TextStyle(
                  fontFamily: _planMode ? null : diaryFontFamily(_font),
                  fontWeight: FontWeight.w700),
              decoration: _fieldDecoration(
                  scheme,
                  _planMode
                      ? 'What are you planning?'
                      : 'Give this memory a title'),
            ),
            const SizedBox(height: 6),
            _sectionLabel(scheme, _planMode ? 'Details' : 'The story'),
            TextField(
              controller: _body,
              maxLines: 5,
              maxLength: 1000,
              style: TextStyle(
                  fontFamily: _planMode ? null : diaryFontFamily(_font),
                  height: 1.5),
              decoration: _fieldDecoration(
                  scheme,
                  _planMode
                      ? 'Where, when, why it will be special…'
                      : 'Tell the story of this moment…'),
            ),
            if (_planMode) ...[
              const SizedBox(height: 10),
              InkWell(
                onTap: _pickDate,
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                  decoration: BoxDecoration(
                    color:
                        scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: scheme.outlineVariant.withValues(alpha: 0.35)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.event_rounded, color: widget.accent, size: 19),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _date == null
                              ? 'Pick a date (optional)'
                              : DateFormat('EEE, MMM d, yyyy').format(_date!),
                          style: TextStyle(
                            color: _date == null
                                ? scheme.onSurfaceVariant
                                : scheme.onSurface,
                            fontWeight: _date == null
                                ? FontWeight.w400
                                : FontWeight.w700,
                          ),
                        ),
                      ),
                      if (_date != null)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: Icon(Icons.close_rounded,
                              size: 18, color: scheme.onSurfaceVariant),
                          onPressed: () => setState(() => _date = null),
                        ),
                    ],
                  ),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Remind us',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(
                  _date == null
                      ? 'Pick a date to enable a reminder'
                      : 'We will both get a nudge the morning of',
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
                value: _pinned && _date != null,
                onChanged:
                    _date == null ? null : (v) => setState(() => _pinned = v),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: widget.accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: _save,
                icon: Icon(
                    editing ? Icons.check_rounded : Icons.auto_stories_rounded,
                    size: 20),
                label: Text(editing ? 'Save changes' : 'Save to diary',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
