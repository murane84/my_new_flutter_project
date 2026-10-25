import 'package:flutter/material.dart';

import '../services/song_insights.dart';

/// "Your week in music" — the full list behind the Sunday recap card: every
/// song from the last 7 days, most-played first, with a podium for the top
/// three, play bars, each song's feel, and the week's totals. [onSend] (when
/// there's a partner) shares the top songs with them.
Future<void> showWeekInMusic(
  BuildContext context, {
  String? partnerName,
  void Function(String text)? onSend,
}) {
  final w = SongInsights.instance.weekInMusic();
  final scheme = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final songs = w.songs;
  final maxPlays = songs.isEmpty ? 1 : songs.first.plays;

  String shareText() {
    final top = songs.take(5).toList();
    return [
      '🎶 My week in music',
      for (var i = 0; i < top.length; i++)
        '${i + 1}. ${top[i].title}${top[i].artist.isEmpty ? '' : ' — ${top[i].artist}'} (${top[i].plays}×)',
      if (w.feel != null) 'Mostly ${w.feel!.emoji} ${w.feel!.label.toLowerCase()}',
      if (w.together > 0) 'We listened together ${w.together}× 💞',
    ].join('\n');
  }

  Widget stat(String big, String small) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: isDark ? 0.16 : 0.08),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(children: [
            Text(big,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: scheme.primary)),
            const SizedBox(height: 2),
            Text(small,
                maxLines: 1,
                style: TextStyle(
                    fontSize: 11.5, color: scheme.onSurfaceVariant)),
          ]),
        ),
      );

  Widget rankBadge(int i) {
    const medals = ['🥇', '🥈', '🥉'];
    if (i < 3) {
      return SizedBox(
          width: 34,
          child: Text(medals[i],
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24)));
    }
    return SizedBox(
      width: 34,
      child: Text('${i + 1}',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: scheme.onSurfaceVariant)),
    );
  }

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: scheme.surface,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.86),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: [
                    scheme.primary,
                    Color.lerp(scheme.primary, Colors.white, 0.3)!,
                  ]),
                ),
                child: const Icon(Icons.insights_rounded,
                    color: Colors.white, size: 23),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Your week in music',
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            color: scheme.onSurface)),
                    Text(
                        w.feel == null
                            ? 'The last 7 days, most played first'
                            : 'Mostly ${w.feel!.emoji} ${w.feel!.label.toLowerCase()} this week',
                        style: TextStyle(
                            fontSize: 12.5, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Row(children: [
              stat('${songs.length}', songs.length == 1 ? 'song' : 'songs'),
              const SizedBox(width: 8),
              stat('${w.total}', w.total == 1 ? 'play' : 'plays'),
              const SizedBox(width: 8),
              stat(w.together > 0 ? '${w.together}×' : '—', 'together'),
            ]),
          ),
          Flexible(
            child: songs.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text('Nothing played in the last 7 days yet',
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(10, 6, 14, 8),
                    itemCount: songs.length,
                    itemBuilder: (_, i) {
                      final s = songs[i];
                      final top3 = i < 3;
                      return Container(
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        padding: const EdgeInsets.fromLTRB(4, 9, 10, 9),
                        decoration: BoxDecoration(
                          color: top3
                              ? scheme.primary
                                  .withValues(alpha: isDark ? 0.14 : 0.06)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(children: [
                          rankBadge(i),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(s.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 14.5,
                                        fontWeight: top3
                                            ? FontWeight.w800
                                            : FontWeight.w600,
                                        color: scheme.onSurface)),
                                if (s.artist.isNotEmpty)
                                  Text(s.artist,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: scheme.onSurfaceVariant)),
                                const SizedBox(height: 6),
                                // How it compares to this week's #1.
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(3),
                                  child: LinearProgressIndicator(
                                    value: s.plays / maxPlays,
                                    minHeight: 4,
                                    color: scheme.primary.withValues(
                                        alpha: top3 ? 1 : 0.6),
                                    backgroundColor: scheme.primary
                                        .withValues(alpha: 0.10),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text('${s.plays}×',
                                  style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w800,
                                      color: scheme.onSurface)),
                              if (s.feel != null)
                                Tooltip(
                                  message: s.feel!.label,
                                  child: Text(s.feel!.emoji,
                                      style: const TextStyle(fontSize: 15)),
                                ),
                            ],
                          ),
                        ]),
                      );
                    },
                  ),
          ),
          if (onSend != null && songs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
              child: FilledButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  onSend(shareText());
                },
                icon: const Icon(Icons.send_rounded, size: 18),
                label: Text(partnerName == null
                    ? 'Share my top songs'
                    : 'Send my top songs to $partnerName'),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16))),
              ),
            ),
        ]),
      ),
    ),
  );
}
