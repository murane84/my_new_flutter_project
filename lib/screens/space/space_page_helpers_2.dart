part of '../relationship_space_page.dart';

// Split out of relationship_space_page.dart (pure code movement, no behaviour change):
// helper methods of _RelationshipSpacePageState that don't call setState, moved into a
// private extension. A library `part`, so it shares the page's imports
// and reaches every private field and method.

extension _SpacePageHelpers2 on _RelationshipSpacePageState {
  // One consistent footer shell for every section: centered and capped to a
  // comfortable width so the action never stretches edge-to-edge on desktop.
  Widget _footerBar(Widget child) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: child,
          ),
        ),
      );

  // The primary footer action — the same cute raised, gradient pill everywhere.
  Widget _footerPrimary(String label, IconData icon, VoidCallback onTap) {
    return _PressableRaised(
      onTap: onTap,
      radius: 16,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.lerp(_accent, Colors.white, 0.14)!,
          _accent,
          Color.lerp(_accent, Colors.black, 0.20)!,
        ],
      ),
      border: Border.all(color: Colors.white.withValues(alpha: 0.20)),
      shadows: [
        BoxShadow(
          color: _accent.withValues(alpha: 0.42),
          blurRadius: 16,
          offset: const Offset(0, 8),
        ),
        BoxShadow(
          color: Colors.white.withValues(alpha: 0.22),
          blurRadius: 1,
          spreadRadius: -1,
          offset: const Offset(0, -1),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: Colors.white),
            const SizedBox(width: 8),
            Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 14.5)),
          ],
        ),
      ),
    );
  }

  // The secondary footer action (same height/shape, tonal) — e.g. "Add song".
  Widget _footerSecondary(
      ColorScheme scheme, String label, IconData icon, VoidCallback onTap) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fill = dark
        ? Color.alphaBlend(Colors.white.withValues(alpha: 0.06), scheme.surface)
        : scheme.surface;
    return _PressableRaised(
      onTap: onTap,
      radius: 16,
      gradient: LinearGradient(colors: [fill, fill]),
      border: Border.all(color: _accent.withValues(alpha: 0.5), width: 1.4),
      shadows: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.06),
          blurRadius: 10,
          offset: const Offset(0, 4),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: _accent),
            const SizedBox(width: 8),
            Text(label,
                style: TextStyle(
                    color: _accent,
                    fontWeight: FontWeight.w800,
                    fontSize: 14.5)),
          ],
        ),
      ),
    );
  }

  /// The header's control cluster, folded into ONE connected pill
  /// (Space settings · menu · minimize) — the same segmented treatment as the
  /// section nav pill — so the top-right reads as a single unit, not three
  /// scattered chips.
  Widget _headerCluster(ColorScheme scheme) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Widget seg(IconData icon, String tip, VoidCallback onTap) => Tooltip(
          message: tip,
          child: InkResponse(
            onTap: onTap,
            radius: 24,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              child: Icon(icon, size: 20, color: _accent),
            ),
          ),
        );
    Widget divider() => Container(
        width: 1, height: 22, color: _accent.withValues(alpha: 0.22));
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [scheme.surfaceContainerHigh, scheme.surfaceContainer]
              : [Colors.white, scheme.surfaceContainerHighest],
        ),
        border: Border.all(color: _accent.withValues(alpha: 0.45)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.36 : 0.12),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            seg(Icons.tune_rounded, 'Space settings', _editSpace),
            if (widget.mainMenuBuilder != null) ...[
              divider(),
              // The platform ⋮ menu, tinted to the accent so it belongs to the
              // cluster rather than floating as a separate control.
              IconTheme.merge(
                data: IconThemeData(color: _accent, size: 20),
                child: widget.mainMenuBuilder!(context),
              ),
            ],
            divider(),
            seg(Icons.close_fullscreen_rounded, 'Minimize', () {
              FocusScope.of(context).unfocus();
              Navigator.of(context).pop();
            }),
          ],
        ),
      ),
    );
  }

  /// One memory rendered as a page of ruled paper, in its AUTHOR's font. Shows
  /// only the author's photo (no name); readers can react + comment; only the
  /// author gets the edit/delete menu.
  Widget _memoryBookPage(
      ColorScheme scheme, Map<String, dynamic> e, int index, int total) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final title = (e['title'] ?? '').toString().trim();
    final body = (e['body'] ?? '').toString().trim();
    final mine = e['mine'] == true;
    final author = (e['author'] as Map?)?.cast<String, dynamic>();
    final created = DateTime.tryParse((e['created_at'] ?? '').toString());
    final font = diaryFontFamily((e['font'] ?? '').toString());
    final paper = isDark ? const Color(0xFF211B17) : const Color(0xFFFFFDF5);
    final ink = isDark ? const Color(0xFFEDE6DD) : const Color(0xFF352A20);
    final rule = (isDark ? Colors.white : _accent)
        .withValues(alpha: isDark ? 0.06 : 0.10);
    final commentCount = (e['comment_count'] as num?)?.toInt() ?? 0;
    // Who signs the entry — real username, or the reader's own name for a memory
    // they wrote before the author record hydrates.
    final signName = ((author?['username'] ?? '').toString().trim().isNotEmpty)
        ? (author!['username']).toString().trim()
        : (mine ? (widget.myName ?? '').trim() : '');
    // If this memory grew from a kept Pinned Moment, show it at the top of the
    // page, tappable to glide back to the moment on the wall.
    final srcThumb = (e['source_thumb'] ?? '').toString().trim();
    final srcMomentId = (e['source_moment_id'] as num?)?.toInt();
    final srcUrl = srcThumb.isEmpty ? null : _full(srcThumb);
    void turn(int dir) {
      final target = index + dir;
      if (target < 0 || target >= total) return;
      _diaryPageCtrl.animateToPage(target,
          duration: const Duration(milliseconds: 340),
          curve: Curves.easeOutCubic);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              color: paper,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _accent.withValues(alpha: 0.20)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.42 : 0.16),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: CustomPaint(
          painter: _RuledPaperPainter(
            line: rule,
            margin: _accent.withValues(alpha: 0.28),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Author photo only (no name), the time, and the author's menu.
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 8, 6),
                child: Row(
                  children: [
                    diaryAuthorBadge(
                      name: (author?['username'] ?? '?').toString(),
                      imageUrl: _full(author?['avatar_url']),
                      radius: 15,
                    ),
                    const Spacer(),
                    if (created != null)
                      Text(_diaryAgo(created),
                          style: TextStyle(
                              fontSize: 11.5,
                              color: ink.withValues(alpha: 0.6))),
                    if (mine) _memoryMenuButton(e, ink),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(52, 2, 20, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Compact clip of the kept moment — the diary is for the
                      // STORY; the full media is one tap away on the wall. Show
                      // the whole image (contain), kept small so text leads.
                      if (srcUrl != null && srcMomentId != null) ...[
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: GestureDetector(
                            onTap: () => _jumpToMoment(srcMomentId),
                            behavior: HitTestBehavior.opaque,
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: _accent.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(13),
                                border: Border.all(
                                    color: _accent.withValues(alpha: 0.28)),
                              ),
                              child: Row(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(9),
                                    child: SizedBox(
                                      width: 54,
                                      height: 54,
                                      child: ColoredBox(
                                        color: (isDark
                                                ? Colors.white
                                                : Colors.black)
                                            .withValues(alpha: 0.06),
                                        child: authNetworkImage(
                                          url: srcUrl,
                                          headers: mediaAuthHeaders(srcUrl),
                                          fit: BoxFit.contain,
                                          cacheWidth: 200,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Row(
                                          children: [
                                            Icon(Icons.push_pin_rounded,
                                                size: 12, color: _accent),
                                            const SizedBox(width: 5),
                                            Flexible(
                                              child: Text(
                                                'From a pinned moment',
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    fontSize: 12,
                                                    fontWeight:
                                                        FontWeight.w700,
                                                    color: _accent),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'Tap to revisit it on the wall',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              fontSize: 11,
                                              color: ink.withValues(
                                                  alpha: 0.55)),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Icon(Icons.chevron_right_rounded,
                                      size: 18,
                                      color: ink.withValues(alpha: 0.5)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (title.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(title,
                              style: TextStyle(
                                  fontFamily: font,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 19,
                                  height: 1.6,
                                  color: ink)),
                        ),
                      Text(body,
                          style: TextStyle(
                              fontFamily: font,
                              fontSize: 15.5,
                              height: 1.9,
                              color: ink.withValues(alpha: 0.92))),
                    ],
                  ),
                ),
              ),
              // Sign off like a love letter — the author's name in a hand plus
              // the full date, sitting low on the page, so a short memory's
              // blank ruled space reads as a CLOSED entry, not an unfinished one.
              if (signName.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 22, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('❦',
                          style: TextStyle(
                              fontSize: 14,
                              color: _accent.withValues(alpha: 0.55))),
                      Text('— $signName',
                          style: TextStyle(
                              // Signed in the author's chosen hand; Classic
                              // still flourishes in handwriting.
                              fontFamily: font ?? diaryFontFamily('handwriting'),
                              fontSize: 20,
                              height: 1.15,
                              color: ink.withValues(alpha: 0.9))),
                      if (created != null)
                        Text(
                            DateFormat('d MMMM yyyy')
                                .format(created.toLocal()),
                            style: TextStyle(
                                fontSize: 10.5,
                                color: ink.withValues(alpha: 0.5))),
                    ],
                  ),
                ),
              // Footer: reactions + comment on one clean strip. Reserve room
              // on whichever side carries a dog-ear page-turn corner, so the
              // reaction/comment pills never collide with the fold.
              Container(
                padding: EdgeInsets.fromLTRB(
                    16 + (index > 0 ? 42 : 0),
                    12,
                    16 + (index < total - 1 ? 42 : 0),
                    14),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      (isDark ? Colors.white : _accent)
                          .withValues(alpha: isDark ? 0.05 : 0.03),
                      (isDark ? Colors.black : _accent)
                          .withValues(alpha: isDark ? 0.20 : 0.07),
                    ],
                  ),
                  border: Border(
                      top: BorderSide(color: _accent.withValues(alpha: 0.14))),
                ),
                child: LayoutBuilder(
                  builder: (ctx, c) {
                    final reactions = diaryReactionRow(
                      scheme: scheme,
                      accent: _accent,
                      entry: e,
                      onToggle: (em) => _reactDiary(e, em),
                      onAdd: () async {
                        final em = await pickDiaryReaction(context, _accent);
                        if (em != null) _reactDiary(e, em);
                      },
                    );
                    // One strip always: reactions take the room they need, the
                    // comment button trails — compact (icon + count) on a phone
                    // so the two never have to stack onto two rows.
                    final compact = c.maxWidth < 440;
                    final commentPill = _diaryCommentPill(scheme, commentCount,
                        () => _openMemoryDetail(e),
                        compact: compact);
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(child: reactions),
                        const SizedBox(width: 8),
                        commentPill,
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
          ),
          // Dog-ear page-turn corners ON the page: bottom-right turns to the
          // next memory, bottom-left to the previous — tap the fold, or keep
          // swiping/dragging the page. Shown only when a page exists that way,
          // tucked exactly into the paper's corner.
          if (index < total - 1)
            Positioned(
              right: 6,
              bottom: 4,
              child: _DiaryDogEar(
                isNext: true,
                paper: paper,
                accent: _accent,
                isDark: isDark,
                onTap: () => turn(1),
              ),
            ),
          if (index > 0)
            Positioned(
              left: 6,
              bottom: 4,
              child: _DiaryDogEar(
                isNext: false,
                paper: paper,
                accent: _accent,
                isDark: isDark,
                onTap: () => turn(-1),
              ),
            ),
        ],
      ),
    );
  }

  /// Edit/Delete menu — only ever shown on the author's own memory.
  /// The raised 3D "Write in our diary" button (gradient body, down-shadow +
  /// top highlight, press-sink) — the app's depth language on the primary CTA.
  /// The raised 3D comment pill in a memory's footer.
  Widget _diaryCommentPill(
      ColorScheme scheme, int count, VoidCallback onTap,
      {bool compact = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return _PressableRaised(
      onTap: onTap,
      radius: 22,
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          isDark ? scheme.surfaceContainerHigh : Colors.white,
          isDark ? scheme.surfaceContainer : scheme.surfaceContainerHighest,
        ],
      ),
      border: Border.all(color: _accent.withValues(alpha: 0.45)),
      shadows: [
        BoxShadow(
          color: Colors.black.withValues(alpha: isDark ? 0.40 : 0.12),
          blurRadius: 8,
          offset: const Offset(0, 3),
        ),
        BoxShadow(
          color: Colors.white.withValues(alpha: isDark ? 0.05 : 0.9),
          blurRadius: 1,
          spreadRadius: -1,
          offset: const Offset(0, -1),
        ),
      ],
      child: Padding(
        padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 14, vertical: 9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mode_comment_outlined, size: 16, color: _accent),
            const SizedBox(width: 6),
            // Compact (phone footer): just the count, so it never forces a
            // second row. Full: the worded label + a chevron affordance.
            Text(
                compact
                    ? (count == 0 ? '0' : '$count')
                    : (count == 0
                        ? 'Comment'
                        : '$count ${count == 1 ? 'comment' : 'comments'}'),
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: _accent)),
            if (!compact)
              Icon(Icons.chevron_right_rounded, size: 16, color: _accent),
          ],
        ),
      ),
    );
  }

  Widget _memoryMenuButton(Map<String, dynamic> e, Color ink) {
    final scheme = Theme.of(context).colorScheme;
    Widget row(IconData icon, String label, Color color) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 12),
            Text(label,
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600, color: color)),
          ],
        );
    return GeniePopupMenuButton<String>(
      tooltip: 'Options',
      // Drop UNDER the trigger, styled like the app's other menus: rounded with
      // a soft accent hairline, iconized rows, and a clearly destructive Delete.
      icon: Icon(Icons.more_horiz_rounded,
          size: 18, color: ink.withValues(alpha: 0.6)),
      color: scheme.surface,
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: 0.28),
      position: PopupMenuPosition.under,
      menuPadding: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: _accent.withValues(alpha: 0.35), width: 1),
      ),
      onSelected: (v) {
        if (v == 'edit') {
          _editDiaryEntry(e);
        } else if (v == 'delete') {
          _deleteDiaryEntry(e);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'edit',
          height: 42,
          child: row(Icons.edit_outlined, 'Edit', scheme.onSurface),
        ),
        PopupMenuItem(
          enabled: false,
          height: 8,
          padding: EdgeInsets.zero,
          child: Divider(
              height: 1,
              thickness: 1,
              indent: 12,
              endIndent: 12,
              color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        PopupMenuItem(
          value: 'delete',
          height: 42,
          child: row(Icons.delete_outline_rounded, 'Delete', scheme.error),
        ),
      ],
    );
  }

  /// A small chip that opens the couple's upcoming plans (kept out of the book
  /// so the pages stay about memories). Hidden when there are no plans.
  // A prominent "Plans ahead" chip, now sitting in the diary header so it's
  // always visible (it used to hide in the bottom-left corner). Opaque and
  // accent-tinted; compact (icon + count) on a narrow phone so the header
  // never crowds, full label on wider screens.
  Widget _diaryPlansStrip(ColorScheme scheme, {bool compact = false}) {
    final plans = _plans;
    if (plans.isEmpty) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? scheme.surfaceContainerHigh : scheme.surface;
    final fill = Color.alphaBlend(_accent.withValues(alpha: 0.16), base);
    return Tooltip(
      message: 'Plans ahead',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _showPlansSheet(scheme),
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: EdgeInsets.symmetric(
                horizontal: compact ? 10 : 12, vertical: 7),
            decoration: BoxDecoration(
              color: fill, // opaque — the wallpaper can't show through
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: _accent.withValues(alpha: 0.55)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.event_note_rounded, size: 15, color: _accent),
                const SizedBox(width: 6),
                Text(
                  compact ? '${plans.length}' : 'Plans ahead (${plans.length})',
                  style: TextStyle(
                      color: _accent,
                      fontWeight: FontWeight.w800,
                      fontSize: 12.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showPlansSheet(ColorScheme scheme) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _diarySectionLabel(scheme, 'Plans ahead', '🗓️'),
              const SizedBox(height: 10),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: [for (final e in _plans) _planRow(scheme, e)],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A boxed stat used inside the Song & milestones card.
  Widget _detailStat(
      ColorScheme scheme, String emoji, String value, String label) {
    // Compact inline stat so the milestone card stays short and leaves room
    // for the track list below.
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 11),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 15)),
          const SizedBox(width: 8),
          Text(value,
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  color: scheme.onSurface)),
          const SizedBox(width: 5),
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }

  Widget _ringed({required Widget child}) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          // A subtly bevelled white ring (bright top-left → cooler bottom-right)
          // reads as a rounded, lit rim rather than a flat white circle.
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.white, Color(0xFFEDEDF2)],
          ),
          boxShadow: [
            // Cast shadow lifts the avatar off the banner…
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 12,
              spreadRadius: -1,
              offset: const Offset(0, 6),
            ),
            // …and a faint white halo softens the rim into the light.
            BoxShadow(
              color: Colors.white.withValues(alpha: 0.35),
              blurRadius: 3,
              spreadRadius: -2,
              offset: const Offset(0, -1),
            ),
          ],
        ),
        child: child,
      );
}
