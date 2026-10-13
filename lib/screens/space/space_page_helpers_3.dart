part of '../relationship_space_page.dart';

// Split out of relationship_space_page.dart (pure code movement, no behaviour change):
// helper methods of _RelationshipSpacePageState that don't call setState, moved into a
// private extension. A library `part`, so it shares the page's imports
// and reaches every private field and method.

extension _SpacePageHelpers3 on _RelationshipSpacePageState {
  // ── pending partner (bond not yet mutual) ────────────────────────────────
  Widget _pendingPartnerBanner(ColorScheme scheme) {
    if ((_space['status'] ?? 'active').toString() != 'pending_partner') {
      return const SizedBox.shrink();
    }
    final name =
        _others.isNotEmpty ? (_others.first['username'] ?? 'them').toString() : 'them';
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: scheme.surfaceContainerHighest,
          border: Border.all(color: _accent.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(Icons.hourglass_top_rounded, size: 18, color: _accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Waiting for $name to accept — this becomes a two-way Space once '
                'they join.',
                style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── milestones ───────────────────────────────────────────────────────────
  Widget _milestoneBanner(ColorScheme scheme) {
    final reached = (_space['stats'] as Map?)?['milestone_reached'];
    if (reached is! Map) return const SizedBox.shrink();
    final kind = (reached['kind'] ?? '').toString();
    final label = (reached['label'] ?? '').toString();
    final emoji = kind == 'streak' ? '🔥' : '💫';
    final line = kind == 'streak'
        ? "You're on a roll together"
        : 'A milestone worth marking';
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [_accent.withValues(alpha: 0.85), _accent],
          ),
        ),
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 26)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: Colors.white)),
                  const SizedBox(height: 2),
                  Text(line,
                      style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.9))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _nextMilestoneHint(ColorScheme scheme) {
    final next = (_space['stats'] as Map?)?['next_milestone'];
    if (next is! Map) return const SizedBox.shrink();
    final remaining = (next['remaining'] as num?)?.toInt() ?? 0;
    final label = (next['label'] ?? '').toString();
    final kind = (next['kind'] ?? '').toString();
    if (remaining <= 0 || label.isEmpty) return const SizedBox.shrink();
    final emoji = kind == 'streak' ? '🔥' : '💫';
    // Optional progress bar: parse the target (first number in the label) and
    // show how far along the bond already is toward it.
    final match = RegExp(r'\d+').firstMatch(label);
    final target = match != null ? int.tryParse(match.group(0)!) : null;
    double? progress;
    if (target != null && target > 0 && remaining < target) {
      progress = ((target - remaining) / target).clamp(0.0, 1.0);
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
      decoration: BoxDecoration(
        color: _accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _accent.withValues(alpha: 0.28)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.auto_awesome_rounded, size: 14, color: _accent),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  '$remaining more day${remaining == 1 ? '' : 's'} to $label $emoji',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface),
                ),
              ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 5,
                backgroundColor: _accent.withValues(alpha: 0.15),
                valueColor: AlwaysStoppedAnimation<Color>(_accent),
              ),
            ),
          ],
        ],
      ),
    );
  }


  /// The "your song" + milestones card. Now shown at the top of Our Playlist
  /// (the standalone Song & milestones section was merged in), and opaque so
  /// the wallpaper never washes out the stats.
  Widget _songMilestoneCard(ColorScheme scheme) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final stats = (_space['stats'] as Map?) ?? const {};
    final next = stats['next_milestone'];
    final hasHint =
        next is Map && ((next['remaining'] as num?)?.toInt() ?? 0) > 0;
    final days = (stats['days_in_song'] as num?)?.toInt() ?? 0;
    final streak = (stats['listen_streak'] as num?)?.toInt() ?? 0;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: isDark
            ? scheme.surfaceContainerHigh
            : scheme.surfaceContainerHighest,
        border: Border.all(color: _accent.withValues(alpha: 0.20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _topSongsInner(scheme),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                  child: _detailStat(scheme, '🎧', '$days',
                      days == 1 ? 'day in a song' : 'days in a song')),
              const SizedBox(width: 10),
              Expanded(
                  child: _detailStat(scheme, '🔥', '$streak',
                      streak == 1 ? 'day streak' : 'day streak')),
            ],
          ),
          if (hasHint) ...[
            const SizedBox(height: 10),
            _nextMilestoneHint(scheme),
          ],
        ],
      ),
    );
  }

  // The couple's most-played tracks (top 3 by shared-listen days), ranked.
  Widget _topSongsInner(ColorScheme scheme) {
    final stats = (_space['stats'] as Map?) ?? const {};
    final songs = ((stats['top_songs'] as List?) ?? const [])
        .whereType<Map>()
        .where((m) => (m['title'] ?? '').toString().trim().isNotEmpty)
        .take(3)
        .toList();
    final multi = songs.length > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _accent.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(Icons.music_note_rounded, color: _accent, size: 20),
            ),
            const SizedBox(width: 12),
            Text(multi ? 'YOUR TOP SONGS' : 'YOUR SONG',
                style: TextStyle(
                    fontSize: 9.5,
                    letterSpacing: 0.8,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurfaceVariant)),
          ],
        ),
        const SizedBox(height: 10),
        if (songs.isEmpty)
          Text(
            'The tracks you two play most show here as you listen together.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          )
        else
          for (int i = 0; i < songs.length; i++)
            Padding(
              padding: EdgeInsets.only(bottom: i == songs.length - 1 ? 0 : 8),
              child: _topSongRow(scheme, i, songs[i]),
            ),
      ],
    );
  }

  Widget _topSongRow(ColorScheme scheme, int i, Map song) {
    final title = (song['title'] ?? '').toString();
    final count = (song['count'] as num?)?.toInt() ?? 0;
    final lead = i == 0;
    return Row(
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: lead ? _accent : _accent.withValues(alpha: 0.14),
            shape: BoxShape.circle,
          ),
          child: Text('${i + 1}',
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: lead ? Colors.white : _accent)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontWeight: lead ? FontWeight.w700 : FontWeight.w600,
                  fontSize: lead ? 14 : 13,
                  color: scheme.onSurface)),
        ),
        if (count > 0) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: _accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(count == 1 ? '1 day' : '$count days',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: _accent)),
          ),
        ],
      ],
    );
  }

  // ── tune in together ──────────────────────────────────────────────────────
  /// When the partner is playing something right now (live "now playing"
  /// presence), invite the user to sync up in one tap. Disappears the moment
  /// they stop. This is the "③ tune-in" beat — catch the bond in a listening
  /// mood and turn it into a shared session.
  // ── "Our World" presence hero (§5.9) ──────────────────────────────────────
  // The now-listening presence is the hub's hero: when the partner is playing,
  // the rich live card; otherwise a gentle invite to start listening together,
  // so the hero is ALWAYS present (never a blank gap) and always points back at
  // the one thing only Aluta can do.
  Widget _presenceHero(ColorScheme scheme) {
    final pid = _partnerId;
    if (pid == null) return const SizedBox.shrink();
    final track = NowPlayingPresence.instance.trackFor(pid);
    final active =
        track != null && (track['title'] ?? '').toString().trim().isNotEmpty;
    if (active) return _tuneInCard(scheme);
    // Nobody's playing — a calm invite rather than an empty space.
    final name = _others.isNotEmpty
        ? (_others.first['username'] ?? 'them').toString()
        : 'them';
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: _listenTogether,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                  _accent.withValues(alpha: 0.10), scheme.surface),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _accent.withValues(alpha: 0.26)),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _accent.withValues(alpha: 0.16),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.headphones_rounded,
                      color: _accent, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Listen together',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: scheme.onSurface)),
                      const SizedBox(height: 2),
                      Text('Nobody\'s playing right now — tap to share a song '
                          'with $name in sync',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration:
                      BoxDecoration(color: _accent, shape: BoxShape.circle),
                  child: Icon(Icons.play_arrow_rounded,
                      color: scheme.onPrimary, size: 22),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tuneInCard(ColorScheme scheme) {
    final pid = _partnerId;
    if (pid == null) return const SizedBox.shrink();
    final track = NowPlayingPresence.instance.trackFor(pid);
    if (track == null) return const SizedBox.shrink();
    final t = (track['title'] ?? '').toString().trim();
    final a = (track['artist'] ?? '').toString().trim();
    if (t.isEmpty) return const SizedBox.shrink();
    final line = a.isNotEmpty ? '$t — $a' : t;
    final name = _others.isNotEmpty
        ? (_others.first['username'] ?? 'They').toString()
        : 'They';
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        // Opaque tinted fill so the now-playing tile never washes out over a
        // wallpaper (same treatment as the 'Thinking of you' pill).
        decoration: BoxDecoration(
          color: Color.alphaBlend(
              _accent.withValues(alpha: 0.16), scheme.surface),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _accent.withValues(alpha: 0.35)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _accent.withValues(alpha: 0.9),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.graphic_eq_rounded,
                  color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$name is listening now',
                      style: TextStyle(
                          fontSize: 11.5, color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 2),
                  Text(line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            FilledButton(
              onPressed: _listenTogether,
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
              child: const Text('Tune in'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Love capsule (§5.5) ──────────────────────────────────────────────────
  Widget _capsuleEmpty(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 30, 16, 20),
      child: Column(
        children: [
          Icon(Icons.card_giftcard_rounded,
              size: 40, color: _accent.withValues(alpha: 0.6)),
          const SizedBox(height: 12),
          Text('No capsules yet',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurface)),
          const SizedBox(height: 4),
          Text(
              'Seal a song + a message to unlock at a moment you choose — '
              'a birthday, an anniversary, or just "9 PM tonight, together".',
              textAlign: TextAlign.center,
              style:
                  TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  String _capsuleCountdown(DateTime unlockLocal) {
    final diff = unlockLocal.difference(DateTime.now());
    if (diff.isNegative) return 'Unlocked';
    if (diff.inDays >= 1) {
      return 'Unlocks in ${diff.inDays}d ${diff.inHours % 24}h';
    }
    if (diff.inHours >= 1) {
      return 'Unlocks in ${diff.inHours}h ${diff.inMinutes % 60}m';
    }
    if (diff.inMinutes >= 1) return 'Unlocks in ${diff.inMinutes}m';
    return 'Unlocks any moment now';
  }

  Widget _capsuleCard(ColorScheme scheme, Map<String, dynamic> c) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final id = (c['id'] as num).toInt();
    final locked = c['locked'] == true;
    final mine = c['mine'] == true;
    final opened = c['opened'] == true;
    final mode = (c['mode'] ?? 'message').toString();
    final creator = (c['creator'] as Map?)?.cast<String, dynamic>();
    final who =
        mine ? 'You' : ((creator?['username'] ?? 'Your partner').toString());
    final unlockAt =
        DateTime.tryParse((c['unlock_at'] ?? '').toString())?.toLocal();
    final title = (c['track_title'] ?? '').toString();
    final artist = (c['track_artist'] ?? '').toString();
    final message = (c['message'] ?? '').toString();
    final sync = mode == 'sync_listen';

    return Container(
      margin: const EdgeInsets.only(bottom: 11),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark
            ? scheme.surfaceContainerHigh
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
            color: _accent.withValues(alpha: locked ? 0.30 : 0.45),
            width: locked ? 1 : 1.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                    locked
                        ? Icons.lock_clock_rounded
                        : Icons.card_giftcard_rounded,
                    color: _accent,
                    size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(mine ? 'Sealed by you' : 'A capsule from $who',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 13.5,
                            color: scheme.onSurface)),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(
                            sync
                                ? Icons.headphones_rounded
                                : Icons.mail_rounded,
                            size: 12,
                            color: scheme.onSurfaceVariant),
                        const SizedBox(width: 5),
                        Text(sync ? 'Listen together' : 'A message',
                            style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ],
                ),
              ),
              if (locked && mine)
                IconButton(
                  tooltip: 'Cancel',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.close_rounded,
                      size: 18, color: scheme.onSurfaceVariant),
                  onPressed: () => _cancelCapsule(id),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (locked) ...[
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: _accent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Text(unlockAt != null ? _capsuleCountdown(unlockAt) : 'Sealed',
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          color: _accent)),
                  if (unlockAt != null) ...[
                    const SizedBox(height: 3),
                    Text(
                        DateFormat('EEE, MMM d · h:mm a').format(unlockAt),
                        style: TextStyle(
                            fontSize: 11.5,
                            color: scheme.onSurfaceVariant)),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text('Sealed until then — the song & message stay a surprise 💌',
                style: TextStyle(
                    fontSize: 11.5, color: scheme.onSurfaceVariant)),
          ] else if (!opened) ...[
            Row(
              children: [
                const Text('🎁', style: TextStyle(fontSize: 22)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('It\'s unlocked — ready to open',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _openCapsule(id),
                style: FilledButton.styleFrom(
                    backgroundColor: _accent, foregroundColor: Colors.white),
                icon: const Icon(Icons.lock_open_rounded, size: 18),
                label: const Text('Open the capsule'),
              ),
            ),
          ] else ...[
            if (title.isNotEmpty)
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
                          Text(title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12.5,
                                  color: scheme.onSurface)),
                          if (artist.isNotEmpty)
                            Text(artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            if (message.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(message,
                  style: TextStyle(
                      fontSize: 14, height: 1.4, color: scheme.onSurface)),
            ],
            if (sync) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _pressPlayTogether,
                  style: OutlinedButton.styleFrom(
                      backgroundColor: scheme.surfaceContainerHighest,
                      foregroundColor: _accent,
                      side: BorderSide(
                          color: _accent.withValues(alpha: 0.6))),
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('Press play together'),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Future<void> _openCapsule(int capsuleId) async {
    final res = await ApiService().openCapsule(_id, capsuleId);
    if (!mounted) return;
    if (res != null) {
      await _load();
    } else {
      showToast(context, 'Could not open it — try again',
          type: ToastType.error);
    }
  }

  Future<void> _cancelCapsule(int capsuleId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this capsule?'),
        content: const Text(
            'It will be deleted and never unlock. This can\'t be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep it')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Cancel capsule')),
        ],
      ),
    );
    if (ok != true) return;
    final done = await ApiService().deleteCapsule(_id, capsuleId);
    if (!mounted) return;
    if (done) {
      showToast(context, 'Capsule cancelled', type: ToastType.info);
      await _load();
    } else {
      showToast(context, 'Could not cancel it', type: ToastType.error);
    }
  }

  Widget _dedicationsBody(ColorScheme scheme) {
    final items = ((_space['dedications'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    if (items.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
          border:
              Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
        ),
        child: Column(
          children: [
            Icon(Icons.favorite_border_rounded, color: _accent, size: 28),
            const SizedBox(height: 10),
            Text('No dedications yet',
                style: TextStyle(
                    fontWeight: FontWeight.w700, color: scheme.onSurface)),
            const SizedBox(height: 4),
            Text('Send a song as a feeling — tap Dedicate.',
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ],
        ),
      );
    }
    return Column(
      children: [for (final d in items) _dedicationCard(scheme, d)],
    );
  }

  Widget _dedicationCard(ColorScheme scheme, Map<String, dynamic> d) {
    final mine = d['mine'] == true;
    final unopened = !mine && d['opened'] != true;
    final title = (d['track_title'] ?? '').toString();
    final artist = (d['track_artist'] ?? '').toString();
    final mood = (d['mood'] ?? '').toString();
    final partnerName =
        ((_space['question'] as Map?)?['partner_name'] ?? 'Partner').toString();
    final who = mine ? 'To $partnerName' : 'From ${d['from_username'] ?? partnerName}';
    return GestureDetector(
      onTap: () => _openDedicationDetail(d),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: unopened
              ? Color.alphaBlend(_accent.withValues(alpha: 0.14), scheme.surface)
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
          border: unopened
              ? Border.all(color: _accent.withValues(alpha: 0.5))
              : null,
        ),
        child: Row(
          children: [
            Icon(mine ? Icons.send_rounded : Icons.favorite_rounded,
                size: 20, color: _accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text(who,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: _accent)),
                    if (unopened) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: _accent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text('New',
                            style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: Colors.white)),
                      ),
                    ],
                  ]),
                  const SizedBox(height: 2),
                  Text(artist.isNotEmpty ? '$title — $artist' : title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: scheme.onSurface)),
                  if (mood.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(mood,
                          style: TextStyle(
                              fontSize: 11.5,
                              color: scheme.onSurfaceVariant)),
                    ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: scheme.onSurfaceVariant, size: 20),
          ],
        ),
      ),
    );
  }

  Future<void> _openDedicationDetail(Map<String, dynamic> d) async {
    final id = (d['id'] as num?)?.toInt();
    final mine = d['mine'] == true;
    if (id != null && !mine && d['opened'] != true) {
      await ApiService().openDedication(_id, id);
    }
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    final title = (d['track_title'] ?? '').toString();
    final artist = (d['track_artist'] ?? '').toString();
    final mood = (d['mood'] ?? '').toString();
    final note = (d['note'] ?? '').toString();
    final voiceUrl = (d['voice_note_url'] ?? '').toString();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(mine ? 'Your dedication' : 'A dedication for you 💝'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: TextStyle(
                    fontWeight: FontWeight.w800, color: scheme.onSurface)),
            if (artist.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(artist,
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
            if (mood.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(mood, style: TextStyle(color: _accent)),
            ],
            if (note.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('“$note”',
                  style: TextStyle(
                      fontStyle: FontStyle.italic, color: scheme.onSurface)),
            ],
            if (voiceUrl.isNotEmpty) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: _DedVoicePlayer(url: voiceUrl, accent: _accent),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _accent),
            onPressed: () {
              Navigator.pop(ctx);
              _playCrateTrack({
                'title': title,
                'ref': (d['track_ref'] ?? '').toString(),
              });
            },
            icon: const Icon(Icons.headphones_rounded, size: 18),
            label: const Text('Listen together'),
          ),
        ],
      ),
    );
    if (mounted) _load();
  }

  // Open the full mixtape for a month: fetch the playable recap, then push the
  // player screen.
  Future<void> _openMixtape(String month) async {
    showToast(context, 'Opening your mixtape…', type: ToastType.info);
    final full = await ApiService().getRecap(_id, month);
    if (!mounted) return;
    if (full == null || full['is_empty'] == true) {
      showToast(context, 'Nothing to play for that month yet',
          type: ToastType.info);
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _MixtapeScreen(
        recap: full,
        apiBase: widget.apiBase,
        accent: spaceThemeColor((_space['theme'] as String?) ?? 'coral'),
        onPlaySong: (t) => _playCrateTrack(t),
      ),
    ));
  }

  bool _hasStreakUnlock(String kind) {
    final u = (_streak?['unlocks'] as List?) ?? const [];
    return u.map((e) => e.toString()).contains(kind);
  }

  void _showUnlockToast(List nu) {
    const lines = {
      'theme_in_tune': 'You unlocked a shared theme 💞',
      'disc_anniversary': 'You unlocked the Anniversary Vinyl disc 💿',
    };
    final first = nu.first.toString();
    showToast(context, lines[first] ?? 'You earned a new reward together 🎵',
        type: ToastType.success);
  }

  String _stageForMilestone(int m) {
    if (m >= 30) return 'In tune';
    if (m >= 14) return 'Deeply connected';
    if (m >= 7) return 'Growing';
    return 'Connected';
  }

  // "Our <Month> is ready" — the Monthly Mixtape card. Shown only when a
  // finished month has shared content; taps open the playable recap.
  Widget _recapCard(ColorScheme scheme) {
    final r = _recapReady;
    if (r == null) return const SizedBox.shrink();
    final label = (r['label'] ?? 'Last month').toString();
    final nums = (r['numbers'] as Map?)?.cast<String, dynamic>() ?? const {};
    int n(String k) => (nums[k] as num?)?.toInt() ?? 0;
    final cover = (r['cover_ref'] ?? '').toString().trim();
    final coverUrl =
        cover.isEmpty ? null : (resolveAvatarUrl(cover, widget.apiBase) ?? cover);
    final bits = <String>[];
    if (n('songs') > 0) bits.add('${n('songs')} song${n('songs') == 1 ? '' : 's'}');
    if (n('photos') > 0) {
      bits.add('${n('photos')} photo${n('photos') == 1 ? '' : 's'}');
    }
    if (n('moments') > 0) {
      bits.add('${n('moments')} moment${n('moments') == 1 ? '' : 's'}');
    }
    final summary = bits.isEmpty ? 'A month of the two of you' : bits.join(' · ');
    final month = (r['month'] ?? '').toString();

    return GestureDetector(
      onTap: () => _openMixtape(month),
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.alphaBlend(_accent.withValues(alpha: 0.16), scheme.surface),
              Color.alphaBlend(_accent.withValues(alpha: 0.05), scheme.surface),
            ],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _accent.withValues(alpha: 0.26)),
        ),
        child: Row(
          children: [
            // Mini cover: the month's first photo, or a vinyl tile.
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 54,
                height: 54,
                child: coverUrl != null
                    ? Image.network(coverUrl,
                        fit: BoxFit.cover,
                        headers: mediaAuthHeaders(coverUrl),
                        errorBuilder: (_, _, _) => _recapVinyl(scheme))
                    : _recapVinyl(scheme),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.album_rounded, size: 15, color: _accent),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text('Our $label',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: scheme.onSurface)),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: _accent.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text('is ready',
                            style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: _accent)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: _accent, shape: BoxShape.circle),
              child: Icon(Icons.play_arrow_rounded,
                  color: scheme.onPrimary, size: 24),
            ),
          ],
        ),
      ),
    );
  }

  Widget _recapVinyl(ColorScheme scheme) {
    return Container(
      color: Color.alphaBlend(_accent.withValues(alpha: 0.22), scheme.surface),
      alignment: Alignment.center,
      child: Icon(Icons.music_note_rounded, color: _accent, size: 26),
    );
  }

  Widget _streakCard(ColorScheme scheme) {
    final s = _streak;
    if (s == null || s['bonded'] != true) return const SizedBox.shrink();
    final current = (s['current_days'] as num?)?.toInt() ?? 0;
    final longest = (s['longest_days'] as num?)?.toInt() ?? 0;
    final stage = (s['stage'] ?? 'New').toString();
    final alive = s['alive'] == true;
    final next = (s['next_milestone'] as num?)?.toInt();
    final toNext = (s['days_to_next'] as num?)?.toInt();
    final on = current > 0;

    String sub;
    double progress;
    if (next != null && toNext != null) {
      sub = on
          ? '$toNext day${toNext == 1 ? '' : 's'} to ${_stageForMilestone(next)}'
          : 'Do something together today to begin';
      progress = next > 0 ? (current / next).clamp(0.0, 1.0) : 0.0;
    } else {
      sub = 'In tune — your deepest run yet';
      progress = 1.0;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Color.alphaBlend(_accent.withValues(alpha: 0.08), scheme.surface),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _accent.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.local_fire_department_rounded,
                  size: 20,
                  color: on ? _accent : scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  on
                      ? '$current day${current == 1 ? '' : 's'} in tune'
                      : 'Start your streak',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(stage,
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: _accent)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: scheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation<Color>(_accent),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(sub,
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
              ),
              if (on && !alive)
                Text('Act today to keep it 🔥',
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: _accent))
              else if (longest > current && longest > 0)
                Text('Best: $longest',
                    style: TextStyle(
                        fontSize: 11.5, color: scheme.onSurfaceVariant)),
            ],
          ),
        ],
      ),
    );
  }
}
