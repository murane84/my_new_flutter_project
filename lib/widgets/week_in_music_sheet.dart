import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

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


/// A floating, dismissible card with everything Aluta learned about one song
/// — opened by tapping a song nudge banner ("on repeat", "makes you miss…",
/// "feels like yours"): a 7-day play chart, this week's plays and rank,
/// how many days you played it, all-time plays, its feel (tap to change) and
/// whether it's in Our Playlist. "See my week" opens the full week.
Future<void> showSongInsight(BuildContext context, String title,
    {String? partnerName,
    void Function(String text)? onSendWeek}) {
  final scheme = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
      final st = SongInsights.instance.songStats(title);
      if (st == null) {
        return const SizedBox.shrink();
      }
      final peak = st.last7.fold<int>(1, (a, b) => b > a ? b : a);
      const days = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
      final today = DateTime.now();
      Widget chip(String t) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: isDark ? 0.16 : 0.08),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(t,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface)),
          );
      return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 40),
        backgroundColor: scheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(colors: [
                        Colors.white.withValues(alpha: 0.9),
                        scheme.primary,
                        Color.lerp(scheme.primary, Colors.black, 0.4)!,
                      ], stops: const [0.1, 0.2, 1]),
                    ),
                    child: const Icon(Icons.music_note_rounded,
                        color: Colors.white, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(st.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w900,
                                color: scheme.onSurface)),
                        if (st.artist.isNotEmpty)
                          Text(st.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12.5,
                                  color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ]),
                const SizedBox(height: 14),
                // Plays per day, this week.
                SizedBox(
                  height: 96,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 0; i < 7; i++)
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (st.last7[i] > 0)
                                Text('${st.last7[i]}',
                                    style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700,
                                        color: scheme.onSurfaceVariant)),
                              const SizedBox(height: 2),
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 300),
                                height: 4 + 58 * st.last7[i] / peak,
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 6),
                                decoration: BoxDecoration(
                                  color: st.last7[i] > 0
                                      ? scheme.primary.withValues(
                                          alpha: i == 6 ? 1 : 0.65)
                                      : scheme.outlineVariant
                                          .withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                  i == 6
                                      ? 'Today'
                                      : days[today
                                              .subtract(Duration(days: 6 - i))
                                              .weekday -
                                          1],
                                  style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: i == 6
                                          ? FontWeight.w800
                                          : FontWeight.w500,
                                      color: scheme.onSurfaceVariant)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  chip('🔁 ${st.week}× this week'),
                  if (st.rank != null) chip('🏆 #${st.rank} this week'),
                  chip('📅 ${st.daysThisWeek} of 7 days'),
                  if (st.total > st.week) chip('🎧 ${st.total}× lately'),
                  if (st.ours) chip('💞 In Our Playlist'),
                ]),
                const SizedBox(height: 14),
                Text('How does it feel?',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurfaceVariant)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final f in SongFeel.values)
                    ChoiceChip(
                      selected: st.feel == f,
                      label: Text('${f.emoji} ${f.label}'),
                      onSelected: (_) {
                        HapticFeedback.selectionClick();
                        SongInsights.instance.setFeel(st.title, f);
                        setD(() {});
                      },
                    ),
                ]),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    showWeekInMusic(context,
                        partnerName: partnerName, onSend: onSendWeek);
                  },
                  icon: const Icon(Icons.format_list_numbered_rounded,
                      size: 18),
                  label: const Text('See my week in music'),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14))),
                ),
              ],
            ),
          ),
        ),
      );
    }),
  );
}
