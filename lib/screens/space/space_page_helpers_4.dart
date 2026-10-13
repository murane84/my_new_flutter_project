part of '../relationship_space_page.dart';

// Split out of relationship_space_page.dart (pure code movement, no behaviour change):
// helper methods of _RelationshipSpacePageState that don't call setState, moved into a
// private extension. A library `part`, so it shares the page's imports
// and reaches every private field and method.

extension _SpacePageHelpers4 on _RelationshipSpacePageState {
  Widget _answerBubble(ColorScheme scheme, String who,
      Map<String, dynamic>? ans, String kind) {
    final text = (ans?['answer_text'] ?? '').toString().trim();
    final tt = (ans?['track_title'] ?? '').toString().trim();
    final ta = (ans?['track_artist'] ?? '').toString().trim();
    final mood = (ans?['mood'] ?? '').toString().trim();
    final display = kind == 'music'
        ? (tt.isEmpty ? '—' : (ta.isEmpty ? tt : '$tt — $ta'))
        : kind == 'mood'
            ? (mood.isEmpty ? '—' : mood)
            : (text.isEmpty ? '—' : text);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(who,
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700, color: _accent)),
          const SizedBox(height: 3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (kind == 'music') ...[
                Icon(Icons.music_note_rounded,
                    size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(display,
                    style: TextStyle(
                        fontSize: kind == 'mood' ? 15 : 13,
                        fontWeight:
                            kind == 'mood' ? FontWeight.w600 : FontWeight.w400,
                        height: 1.3,
                        color: scheme.onSurface)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _moodChip(ColorScheme scheme, String emoji, String label) {
    return GestureDetector(
      onTap: _qSubmitting ? null : () => _sendAnswer(mood: '$emoji $label'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _accent.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 16)),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface)),
          ],
        ),
      ),
    );
  }

  // Shown on a mood reveal when the two of you picked different feelings — a
  // gentle, one-tap way to close the gap (never an observation left hanging).
  Widget _moodRemedyRow(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.favorite_rounded, size: 14, color: _accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                    'Feeling a little differently today — close the gap?',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _qSubmitting ? null : _listenTogether,
                  icon: const Icon(Icons.headphones_rounded, size: 16),
                  label: const Text('Listen together'),
                  style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: _accent,
                      side: BorderSide(color: _accent.withValues(alpha: 0.5))),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _qSubmitting ? null : _composeDedication,
                  icon: const Icon(Icons.favorite_rounded, size: 16),
                  label: const Text('Dedicate'),
                  style: FilledButton.styleFrom(
                      backgroundColor: _accent,
                      visualDensity: VisualDensity.compact),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _archiveItem(ColorScheme scheme, Map<String, dynamic> it) {
    final prompt = (it['prompt'] as Map?)?.cast<String, dynamic>() ?? const {};
    final body = (prompt['body'] ?? '').toString();
    final kind = (prompt['kind'] ?? 'text').toString();
    final day = (it['day'] ?? '').toString();
    final mine = (it['my_answer'] as Map?)?.cast<String, dynamic>();
    final theirs = (it['partner_answer'] as Map?)?.cast<String, dynamic>();
    final partnerName =
        ((_space['question'] as Map?)?['partner_name'] ?? 'Partner').toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(day,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text(body,
              style: TextStyle(
                  fontWeight: FontWeight.w700, color: scheme.onSurface)),
          const SizedBox(height: 8),
          _answerBubble(scheme, 'You', mine, kind),
          const SizedBox(height: 6),
          _answerBubble(scheme, partnerName, theirs, kind),
        ],
      ),
    );
  }


  Widget _playlistEmpty(ColorScheme scheme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          Icon(Icons.queue_music_rounded, color: _accent, size: 26),
          const SizedBox(height: 8),
          Text('Start your crate',
              style: TextStyle(
                  fontWeight: FontWeight.w700, color: scheme.onSurface)),
          const SizedBox(height: 4),
          Text(
            'Add the songs that are you two. Whoever adds, you both see it here.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _trackRow(ColorScheme scheme, Map<String, dynamic> t) {
    final id = (t['id'] as num?)?.toInt();
    final title = (t['title'] ?? '').toString();
    final artist = (t['artist'] ?? '').toString();
    final memo = (t['memo'] ?? '').toString().trim();
    final source = (t['source'] ?? 'manual').toString();
    final mine = t['mine'] == true;
    final adder = mine ? 'You' : (t['added_by_username'] ?? '').toString();
    final (srcIcon, srcText) = _sourceBadge(source);
    final subParts = <String>[];
    if (artist.isNotEmpty) subParts.add(artist);
    subParts.add('added by $adder');
    if (srcText.isNotEmpty) subParts.add('from $srcText');
    final subtitle = subParts.join(' · ');
    return GestureDetector(
      onLongPress: id == null ? null : () => _editTrackMemo(t),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: _accent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child:
                      Icon(Icons.music_note_rounded, color: _accent, size: 18),
                ),
                if (srcIcon != null)
                  Positioned(
                    right: -4,
                    bottom: -4,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(srcIcon, size: 12, color: _accent),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: scheme.onSurface)),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                  if (memo.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      '\u201c$memo\u201d',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.25,
                        fontStyle: FontStyle.italic,
                        color: scheme.onSurface.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: memo.isEmpty ? 'Add a memory' : 'Edit memory',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                memo.isEmpty
                    ? Icons.note_add_outlined
                    : Icons.sticky_note_2_rounded,
                size: 18,
                color: memo.isEmpty ? scheme.onSurfaceVariant : _accent,
              ),
              onPressed: id == null ? null : () => _editTrackMemo(t),
            ),
            IconButton(
              tooltip: 'Listen together',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.play_circle_fill_rounded, color: _accent),
              onPressed: () => _playCrateTrack(t),
            ),
            if (id != null)
              IconButton(
                tooltip: 'Remove',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.close_rounded,
                    size: 18, color: scheme.onSurfaceVariant),
                onPressed: () => _removeTrackFromCrate(id),
              ),
          ],
        ),
      ),
    );
  }

  /// Add or edit the one-line memory on a soundtrack track (long-press, or the
  /// note button). Saving an empty note clears it.
  Future<void> _editTrackMemo(Map<String, dynamic> t) async {
    final id = (t['id'] as num?)?.toInt();
    if (id == null) return;
    final ctrl = TextEditingController(text: (t['memo'] ?? '').toString());
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add a memory'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 1,
          maxLines: 3,
          maxLength: 140,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'playing the night we\u2026'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (result == null || !mounted) return;
    final updated = await ApiService().annotateTrack(_id, id, result);
    if (!mounted) return;
    if (updated != null) {
      _load();
    } else {
      showToast(context, 'Could not save the memory', type: ToastType.error);
    }
  }

  // ── moments ───────────────────────────────────────────────────────────────
  Widget _momentsEmpty(ColorScheme scheme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          Icon(Icons.auto_awesome_rounded, color: _accent, size: 28),
          const SizedBox(height: 10),
          Text('No moments yet',
              style: TextStyle(
                  fontWeight: FontWeight.w700, color: scheme.onSurface)),
          const SizedBox(height: 4),
          Text(
            'Pin a dedication, a first song, or a note you never want to lose.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  // A tender moment card — who sent it, the song (if any), the note, and a
  // heart the other can tap.
  Widget _momentCard(ColorScheme scheme, Map<String, dynamic> m) {
    final id = (m['id'] as num).toInt();
    final hot = _highlightMomentId == id;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final kind = (m['kind'] ?? 'note').toString();
    final caption = (m['caption'] ?? '').toString();
    final mine = m['mine'] == true;
    final author = (m['author'] as Map?)?.cast<String, dynamic>();
    final authorName = mine ? 'You' : (author?['username'] ?? '').toString();
    final created = DateTime.tryParse((m['created_at'] ?? '').toString());
    final song = _songFromRef(m['ref']);
    final commentCount = (m['comment_count'] as num?)?.toInt() ??
        ((m['comments'] as List?)?.length ?? 0);
    final displayName = authorName.isEmpty ? _momentLabel(kind) : authorName;

    return GestureDetector(
      key: _momentKeys.putIfAbsent(id, () => GlobalKey()),
      onLongPress: mine ? () => _confirmDeleteMoment(id) : null,
      // Right-click on desktop opens the same delete, matching comments.
      onSecondaryTap: mine ? () => _confirmDeleteMoment(id) : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        margin: const EdgeInsets.only(bottom: 11),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          // SOLID & opaque — the wallpaper must never bleed through and wash out
          // the content or the action buttons. Romance lives in the caption
          // over the media, not in a translucent tint around it.
          color: isDark
              ? scheme.surfaceContainerHigh
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: hot
                  ? _accent.withValues(alpha: 0.85)
                  : scheme.outlineVariant.withValues(alpha: 0.5),
              width: hot ? 2 : 1),
          boxShadow: [
            BoxShadow(
              color: hot
                  ? _accent.withValues(alpha: 0.26)
                  : Colors.black.withValues(alpha: isDark ? 0.30 : 0.07),
              blurRadius: hot ? 20 : 12,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: avatar · name over a kind·time subtitle · pin marker.
            Row(
              children: [
                diaryAuthorBadge(
                  name: displayName,
                  imageUrl: _full(author?['avatar_url']),
                  radius: 16,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5,
                              color: scheme.onSurface)),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(_momentIcon(kind), size: 12, color: _accent),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              created != null
                                  ? '${_momentLabel(kind)} · ${_timeAgo(created)}'
                                  : _momentLabel(kind),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.push_pin_rounded,
                    size: 15, color: _accent.withValues(alpha: 0.55)),
                // Visible options menu so the owner can delete on desktop
                // (mouse) too — long-press still works on touch.
                if (mine) ...[
                  const SizedBox(width: 2),
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: PopupMenuButton<String>(
                      tooltip: 'Moment options',
                      padding: EdgeInsets.zero,
                      icon: Icon(Icons.more_horiz_rounded,
                          size: 19, color: scheme.onSurfaceVariant),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      onSelected: (v) {
                        if (v == 'delete') _confirmDeleteMoment(id);
                      },
                      itemBuilder: (ctx) => [
                        PopupMenuItem<String>(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(Icons.delete_outline_rounded,
                                  size: 18, color: scheme.error),
                              const SizedBox(width: 10),
                              Text('Delete moment',
                                  style: TextStyle(color: scheme.error)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
            if (song != null) ...[
              const SizedBox(height: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.music_note_rounded, size: 16, color: _accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (song['title'] ?? 'A song').toString(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 12.5,
                                color: scheme.onSurface),
                          ),
                          if ((song['artist'] ?? '').toString().isNotEmpty)
                            Text(
                              (song['artist']).toString(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
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
            if ((kind == 'photo' || kind == 'gif') &&
                _full(m['ref']) != null) ...[
              const SizedBox(height: 10),
              _mediaWithCaption(
                  scheme, _momentPhoto(scheme, _full(m['ref'])!), caption),
            ],
            if (kind == 'voice' && _full(m['ref']) != null) ...[
              const SizedBox(height: 10),
              _DedVoicePlayer(url: _full(m['ref'])!, accent: _accent),
            ],
            if (kind == 'video' && _full(m['ref']) != null) ...[
              const SizedBox(height: 10),
              // Centered in the card; the caption rides on the video itself
              // (fades out while playing) instead of a separate overlay.
              Center(
                child: GlimpseVideo(
                  url: _full(m['ref'])!,
                  headers: mediaAuthHeaders(_full(m['ref'])!),
                  accent: _accent,
                  aspectRatioFallback: 16 / 9,
                  caption: caption,
                  posterUrl: '${_full(m['ref'])!}/thumb',
                  onFullscreen: () => _openMomentVideo(_full(m['ref'])!),
                ),
              ),
            ],
            if (kind == 'listen') ...[
              const SizedBox(height: 10),
              _listenMomentCard(scheme, m),
            ],
            // Non-media captions (note / song / voice) read beneath the content.
            if (caption.isNotEmpty &&
                kind != 'photo' &&
                kind != 'gif' &&
                kind != 'video' &&
                kind != 'listen') ...[
              const SizedBox(height: 10),
              Text(caption,
                  style: TextStyle(
                      fontSize: 14.5, height: 1.4, color: scheme.onSurface)),
            ],
            const SizedBox(height: 10),
            // Gateway: expand this moment into a fuller Our Diary entry.
            _momentDiaryGateway(scheme, m),
            const SizedBox(height: 12),
            // Reactions (multi-emoji) + comments — the same capability as Our
            // Diary: react with any emoji, and open a comment thread.
            LayoutBuilder(
              builder: (ctx, c) {
                final compact = c.maxWidth < 440;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: diaryReactionRow(
                        scheme: scheme,
                        accent: _accent,
                        entry: m,
                        onToggle: (em) => _reactMoment(id, em),
                        onAdd: () async {
                          final em = await pickDiaryReaction(context, _accent);
                          if (em != null) _reactMoment(id, em);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    _diaryCommentPill(
                        scheme, commentCount, () => _openMomentComments(m),
                        compact: compact),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Parse a song moment's `ref` (JSON {title, artist}); null if it isn't a song.
  Map<String, dynamic>? _songFromRef(dynamic ref) {
    if (ref is! String || ref.trim().isEmpty) return null;
    try {
      final j = jsonDecode(ref);
      if (j is Map && (j['title'] ?? '').toString().trim().isNotEmpty) {
        return j.cast<String, dynamic>();
      }
    } catch (_) {}
    return null;
  }

  /// A kept photo thumbnail inside a moment card; tap opens a zoomable viewer.
  /// Wrap a piece of media so its caption floats, bold and centred, over the
  /// bottom of the image on a soft dark-to-clear scrim — with a tiny heart for
  /// a little romance. Non-media kinds keep their caption beneath the content.
  Widget _mediaWithCaption(ColorScheme scheme, Widget media, String caption) {
    if (caption.trim().isEmpty) return media;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Stack(
        children: [
          media,
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 26, 14, 12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.66),
                      Colors.black.withValues(alpha: 0.0),
                    ],
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.favorite_rounded,
                        size: 13,
                        color: Colors.white.withValues(alpha: 0.92)),
                    const SizedBox(height: 4),
                    Text(
                      caption,
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w800,
                        height: 1.25,
                        shadows: [
                          Shadow(
                              color: Colors.black54,
                              blurRadius: 6,
                              offset: Offset(0, 1)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// A gentle invitation to carry a pinned moment into Our Diary, where a
  /// partner can write the fuller story behind it.
  Widget _momentDiaryGateway(ColorScheme scheme, Map<String, dynamic> m) {
    // Centered below the content on every screen size.
    return Align(
      alignment: Alignment.center,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _addDiaryEntry(fromMoment: m),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: _accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: _accent.withValues(alpha: 0.55), width: 1.2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.menu_book_rounded, size: 14, color: _accent),
              const SizedBox(width: 6),
              Text('Write about this in Our Diary',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _accent)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _momentPhoto(ColorScheme scheme, String url) {
    return GestureDetector(
      onTap: () => _openMomentPhoto(url),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: ColoredBox(
          color: scheme.surfaceContainerHighest,
          child: ConstrainedBox(
            // Show the WHOLE item (contain, not crop); letterboxed on a solid,
            // opaque surface. Taller cap so portrait media still reads.
            constraints: const BoxConstraints(
                maxHeight: 300, minWidth: double.infinity),
            child: authNetworkImage(
              url: url,
              headers: mediaAuthHeaders(url),
              fit: BoxFit.contain,
              cacheWidth: 1200,
            ),
          ),
        ),
      ),
    );
  }

  void _openMomentPhoto(String url) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      builder: (dctx) => GestureDetector(
        onTap: () => Navigator.pop(dctx),
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 4,
                child: authNetworkImage(
                  url: url,
                  headers: mediaAuthHeaders(url),
                  fit: BoxFit.contain,
                ),
              ),
            ),
            Positioned(
              top: 40,
              right: 16,
              child: IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                onPressed: () => Navigator.pop(dctx),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A kept video shows a dark poster with a play button; tap opens a
  /// fullscreen player.
  void _openMomentVideo(String url) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      builder: (dctx) => _MomentVideoPlayer(url: url),
    );
  }

  String _timeAgo(DateTime dt) {
    final d = DateTime.now().difference(dt.toLocal());
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    if (d.inDays < 7) return '${d.inDays}d';
    return DateFormat('MMM d').format(dt.toLocal());
  }

  Future<void> _reactMoment(int momentId, String emoji) async {
    final res = await ApiService().reactMoment(_id, momentId, emoji);
    if (!mounted) return;
    if (res != null) {
      _load(); // refresh the shared timeline with the new reaction state
    }
  }

  void _openMomentComments(Map<String, dynamic> m) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => _MomentCommentsSheet(
        spaceId: _id,
        moment: m,
        accent: _accent,
        apiBase: widget.apiBase,
        onChanged: _load,
      ),
    );
  }

  Future<void> _confirmDeleteMoment(int momentId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this moment?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final done = await ApiService().deleteMoment(_id, momentId);
    if (!mounted) return;
    if (done) {
      _load();
    } else {
      showToast(context, 'Could not remove', type: ToastType.error);
    }
  }

  IconData _momentIcon(String kind) {
    switch (kind) {
      case 'dedication':
        return Icons.favorite_rounded;
      case 'song':
        return Icons.music_note_rounded;
      case 'voice':
        return Icons.mic_rounded;
      case 'photo':
        return Icons.photo_rounded;
      case 'video':
        return Icons.movie_rounded;
      case 'gif':
        return Icons.gif_box_rounded;
      default:
        return Icons.sticky_note_2_rounded;
    }
  }

  // A saved listen-together session: a headphones header, the set's song list,
  // the session length, and the live-reaction tally captured during playback.
  Widget _listenMomentCard(ColorScheme scheme, Map<String, dynamic> m) {
    List<String> songs = const [];
    int reactions = 0;
    int minutes = 0;
    final ref = m['ref'];
    if (ref is String && ref.trim().isNotEmpty) {
      try {
        final j = jsonDecode(ref);
        if (j is Map) {
          songs = ((j['songs'] as List?) ?? const [])
              .map((e) => e.toString())
              .where((e) => e.trim().isNotEmpty)
              .toList();
          reactions = (j['reactions'] as num?)?.toInt() ?? 0;
          minutes = (j['minutes'] as num?)?.toInt() ?? 0;
        }
      } catch (_) {}
    }
    final shown = songs.take(6).toList();
    final extra = songs.length - shown.length;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _accent.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.headphones_rounded, size: 18, color: _accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Listened together',
                    style: TextStyle(
                        fontWeight: FontWeight.w800, color: scheme.onSurface)),
              ),
              if (minutes > 0)
                Text('${minutes}m',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ),
          if (shown.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final t in shown)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Icon(Icons.music_note_rounded,
                        size: 14, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(t,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13, color: scheme.onSurface)),
                    ),
                  ],
                ),
              ),
            if (extra > 0)
              Padding(
                padding: const EdgeInsets.only(left: 22, top: 2),
                child: Text('+$extra more',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
              ),
          ],
          if (reactions > 0) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.favorite_rounded, size: 13, color: _accent),
                const SizedBox(width: 6),
                Text('$reactions reaction${reactions == 1 ? '' : 's'} shared',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _momentLabel(String kind) {
    switch (kind) {
      case 'dedication':
        return 'A dedication';
      case 'song':
        return 'A song';
      case 'voice':
        return 'A voice note';
      case 'photo':
        return 'A photo';
      case 'video':
        return 'A video';
      case 'gif':
        return 'A GIF';
      case 'listen':
        return 'A listen';
      default:
        return 'A note';
    }
  }

  // ── Our Diary (shared notebook: memories + plans) ─────────────────────────
  /// A compact strip at the top of the main surface for the soonest pinned plan
  /// — a gentle in-app reminder that also complements the device notification.
  /// Tapping opens the diary. Hidden when nothing is pinned ahead.
  Widget _upcomingPlanBanner(ColorScheme scheme) {
    if (_partnerId == null) return const SizedBox.shrink();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    Map<String, dynamic>? soonest;
    DateTime? soonestDay;
    for (final e in _plans) {
      if (e['pinned'] != true) continue;
      final d = DateTime.tryParse((e['plan_date'] ?? '').toString());
      if (d == null) continue;
      final day = DateTime(d.year, d.month, d.day);
      if (day.isBefore(today)) continue;
      if (soonestDay == null || day.isBefore(soonestDay)) {
        soonest = e;
        soonestDay = day;
      }
    }
    if (soonest == null || soonestDay == null) return const SizedBox.shrink();
    final title = (soonest['title'] ?? '').toString().trim().isNotEmpty
        ? (soonest['title']).toString().trim()
        : (soonest['body'] ?? '').toString().trim();
    final rel = _relDay(soonestDay);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        // Opaque (tint blended onto the surface) so the wallpaper never bleeds
        // through this card, matching the other Our Space cards.
        color: Color.alphaBlend(
            _accent.withValues(alpha: 0.10), scheme.surface),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: _openDiary,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _accent.withValues(alpha: 0.30)),
            ),
            child: Row(
              children: [
                const Text('🗓️', style: TextStyle(fontSize: 18)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Plan ahead · $rel',
                          style: TextStyle(
                              fontSize: 11.5, color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 2),
                      Text(title.isEmpty ? 'A plan you pinned' : title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded,
                    color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _diaryEmpty(ColorScheme scheme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          Icon(Icons.menu_book_rounded, color: _accent, size: 28),
          const SizedBox(height: 10),
          Text('Your story, in your words',
              style: TextStyle(
                  fontWeight: FontWeight.w700, color: scheme.onSurface)),
          const SizedBox(height: 4),
          Text(
            'Write the moments you shared, and the plans you’re dreaming up '
            'together. Pin a plan and you’ll both get a reminder.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _diarySectionLabel(ColorScheme scheme, String label, String emoji) {
    return Row(
      children: [
        Text(emoji, style: const TextStyle(fontSize: 14)),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 13,
                color: scheme.onSurface)),
      ],
    );
  }

  Widget _planRow(ColorScheme scheme, Map<String, dynamic> e) {
    final id = (e['id'] as num?)?.toInt();
    final title = (e['title'] ?? '').toString().trim();
    final body = (e['body'] ?? '').toString().trim();
    final mine = e['mine'] == true;
    final pinned = e['pinned'] == true;
    final author = (e['author'] as Map?)?.cast<String, dynamic>();
    final authorName = mine ? 'You' : (author?['username'] ?? '').toString();
    final d = DateTime.tryParse((e['plan_date'] ?? '').toString());
    final when = d != null
        ? '${DateFormat('EEE, MMM d').format(d)} · ${_relDay(DateTime(d.year, d.month, d.day))}'
        : 'No date yet';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: pinned
            ? Border.all(color: _accent.withValues(alpha: 0.5))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.event_rounded, size: 15, color: _accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(when,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface)),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: pinned ? 'Unpin reminder' : 'Pin for a reminder',
                icon: Icon(
                  pinned
                      ? Icons.notifications_active_rounded
                      : Icons.notifications_none_rounded,
                  size: 20,
                  color: pinned ? _accent : scheme.onSurfaceVariant,
                ),
                onPressed: id == null ? null : () => _togglePin(e),
              ),
              _diaryMenu(scheme, e),
            ],
          ),
          if (title.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(title,
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: scheme.onSurface)),
          ],
          if (body.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(body,
                maxLines: body.length > _kMemoryPreviewChars ? 5 : null,
                overflow: body.length > _kMemoryPreviewChars
                    ? TextOverflow.ellipsis
                    : TextOverflow.clip,
                style: TextStyle(
                    fontSize: 13, height: 1.3, color: scheme.onSurface)),
            if (body.length > _kMemoryPreviewChars)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => _openMemoryDetail(e),
                  style: TextButton.styleFrom(
                    foregroundColor: _accent,
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    minimumSize: const Size(0, 0),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Read more'),
                ),
              ),
          ],
          const SizedBox(height: 6),
          Text(mine ? 'You' : (authorName.isEmpty ? 'Partner' : authorName),
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          _diaryEngagement(scheme, e),
        ],
      ),
    );
  }

  Widget _diaryEngagement(ColorScheme scheme, Map<String, dynamic> e) {
    final count = (e['comment_count'] as num?)?.toInt() ??
        ((e['comments'] as List?)?.length ?? 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        diaryReactionRow(
          scheme: scheme,
          accent: _accent,
          entry: e,
          onToggle: (em) => _reactDiary(e, em),
          onAdd: () async {
            final em = await pickDiaryReaction(context, _accent);
            if (em != null && mounted) _reactDiary(e, em);
          },
        ),
        const SizedBox(height: 6),
        InkWell(
          onTap: () => _openMemoryDetail(e),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.mode_comment_outlined,
                    size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                  count == 0
                      ? 'Comment'
                      : (count == 1 ? '1 comment' : '$count comments'),
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant),
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right_rounded,
                    size: 16, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _diaryMenu(ColorScheme scheme, Map<String, dynamic> e) {
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: Icon(Icons.more_horiz_rounded,
          size: 20, color: scheme.onSurfaceVariant),
      onSelected: (v) {
        if (v == 'edit') _editDiaryEntry(e);
        if (v == 'delete') _deleteDiaryEntry(e);
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'edit', child: Text('Edit')),
        PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
  }

  /// 'today' / 'tomorrow' / 'in N days' / 'N days ago' for a plan's day.
  String _relDay(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = day.difference(today).inDays;
    if (diff == 0) return 'today';
    if (diff == 1) return 'tomorrow';
    if (diff > 1) return 'in $diff days';
    if (diff == -1) return 'yesterday';
    return '${-diff} days ago';
  }

  /// The current version of a diary entry by id (so an open detail card and the
  /// list stay in sync after a reload).
  Map<String, dynamic>? _diaryById(int id) {
    for (final e in _diary) {
      if ((e['id'] as num?)?.toInt() == id) return e;
    }
    return null;
  }

  /// Toggle my [emoji] reaction on a diary entry from the list, then reload so
  /// the counts update in place.
  Future<void> _reactDiary(Map<String, dynamic> e, String emoji) async {
    final id = (e['id'] as num?)?.toInt();
    if (id == null) return;
    final updated = await ApiService().reactDiaryEntry(_id, id, emoji);
    if (!mounted) return;
    if (updated == null) {
      showToast(context, 'Could not react — try again', type: ToastType.error);
      return;
    }
    await _load();
  }

  /// Open the full-read card for one memory/plan: complete text, reactions and
  /// the comment thread. Grows from / is absorbed back into its row.
  void _openMemoryDetail(Map<String, dynamic> e, [Offset? origin]) {
    final id = (e['id'] as num?)?.toInt();
    if (id == null) return;
    _absorbDialog<void>(
      origin: origin,
      builder: (dctx) => _MemoryDetailSheet(
        spaceId: _id,
        entry: _diaryById(id) ?? e,
        accent: _accent,
        apiBase: widget.apiBase,
        onChanged: () {
          if (mounted) _load();
        },
      ),
    );
  }

  /// A centered dialog whose open/close scales + fades toward [origin] (a tile
  /// or row), so a card looks absorbed back into where it came from. Shared by
  /// the feature cards and the memory-detail card.
  Future<T?> _absorbDialog<T>({
    required Offset? origin,
    required WidgetBuilder builder,
  }) {
    final media = MediaQuery.of(context).size;
    final align = origin == null
        ? Alignment.center
        : Alignment(
            ((origin.dx / media.width) * 2 - 1).clamp(-1.0, 1.0),
            ((origin.dy / media.height) * 2 - 1).clamp(-1.0, 1.0),
          );
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Minimize',
      barrierColor: Colors.black.withValues(alpha: 0.45),
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (dctx, _, _) => builder(dctx),
      transitionBuilder: (dctx, anim, _, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.55, end: 1.0).animate(curved),
            alignment: align,
            child: child,
          ),
        );
      },
    );
  }

  Future<void> _editDiaryEntry(Map<String, dynamic> e) async {
    final id = (e['id'] as num?)?.toInt();
    if (id == null) return;
    final res = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _DiaryComposer(accent: _accent, existing: e, myName: widget.myName),
    );
    if (res == null) return;
    final saved = await ApiService().editDiaryEntry(
      _id,
      id,
      kind: res['kind'] as String?,
      body: res['body'] as String?,
      title: (res['title'] ?? '') as String?,
      planDate: (res['plan_date'] ?? '') as String?,
      pinned: res['pinned'] as bool?,
      font: res['font'] as String?,
    );
    if (!mounted) return;
    if (saved != null) {
      // A plan turned into a memory (or its pin/date changed) may no longer
      // warrant a reminder — clear this one; _load() reschedules what remains.
      if ((saved['kind'] ?? '').toString() != 'plan' ||
          saved['pinned'] != true) {
        await cancelDiaryReminder(id);
      }
      await _load();
    } else {
      showToast(context, 'Could not update that entry', type: ToastType.error);
    }
  }

  Future<void> _togglePin(Map<String, dynamic> e) async {
    final id = (e['id'] as num?)?.toInt();
    if (id == null) return;
    final newPinned = !(e['pinned'] == true);
    final saved =
        await ApiService().editDiaryEntry(_id, id, pinned: newPinned);
    if (!mounted) return;
    if (saved == null) {
      showToast(context, 'Could not update the reminder', type: ToastType.error);
      return;
    }
    if (!newPinned) await cancelDiaryReminder(id);
    await _load();
  }

  Future<void> _deleteDiaryEntry(Map<String, dynamic> e) async {
    final id = (e['id'] as num?)?.toInt();
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this entry?'),
        content: const Text('It’s removed from your shared diary for both of you.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final done = await ApiService().deleteDiaryEntry(_id, id);
    if (!mounted) return;
    if (done) {
      await cancelDiaryReminder(id);
      await _load();
    } else {
      showToast(context, 'Could not remove', type: ToastType.error);
    }
  }
}
