import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../services/aluta_mood.dart' show AlutaMoment;
import '../services/song_insights.dart';

const _momentLabel = {
  AlutaMoment.dawn: ('🌄', 'Dawn'),
  AlutaMoment.morning: ('🌅', 'Morning'),
  AlutaMoment.afternoon: ('☀️', 'Afternoon'),
  AlutaMoment.evening: ('🌇', 'Evening'),
  AlutaMoment.night: ('🌙', 'Late night'),
};

const _feelColor = {
  SongFeel.love: Color(0xFFFF3B6B),
  SongFeel.missing: Color(0xFF8E5CFF),
  SongFeel.hyped: Color(0xFFFF9F1C),
  SongFeel.calm: Color(0xFF2EC4B6),
  SongFeel.hurting: Color(0xFF6C7A89),
};

/// "Your week in music" — every song from the last 7 days, most-played
/// first: podium for the top three, ▲ ▼ NEW 🔥 against last week, 💞 for Our
/// Playlist songs, a tappable mood mix (filters the list), the songs that
/// own each part of the day, and — with a partner who shares — the songs in
/// BOTH your tops, ready to play together. Totals up top; send to partner.
Future<void> showWeekInMusic(
  BuildContext context, {
  String? partnerName,
  void Function(String text)? onSend,
  Future<List<String>?> Function()? partnerTop,
  VoidCallback? onListenTogether,
}) {
  final w = SongInsights.instance.weekInMusic();
  final scheme = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final all = w.songs;
  final maxPlays = all.isEmpty ? 1 : all.first.plays;
  final top10Ours = all.take(10).where((s) => s.ours).length;
  final theirsFuture = partnerTop?.call();
  SongFeel? filter;
  final headline = [
    if (w.feel != null)
      'Mostly ${w.feel!.emoji} ${w.feel!.label.toLowerCase()}',
    if (w.newCount > 0)
      '${w.newCount} new ${w.newCount == 1 ? 'song' : 'songs'} this week',
  ].join(' · ');

  String shareText() {
    final top = all.take(5).toList();
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

  // ▲ ▼ NEW 🔥 — this week against the one before.
  Widget? trend(int plays, int last) {
    String t;
    Color c;
    if (last == 0) {
      t = 'NEW';
      c = const Color(0xFF2EC4B6);
    } else if (plays >= last * 2 && plays >= 4) {
      t = '🔥';
      c = const Color(0xFFFF6B35);
    } else if (plays > last) {
      t = '▲';
      c = const Color(0xFF2BB673);
    } else if (plays < last) {
      t = '▼';
      c = scheme.onSurfaceVariant;
    } else {
      return null;
    }
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(t,
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w900, color: c)),
    );
  }

  final scroll = ScrollController();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // Desktop / tablet: a centred sheet instead of an edge-to-edge one.
    constraints: const BoxConstraints(maxWidth: 680),
    backgroundColor: scheme.surface,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      final songs = filter == null
          ? all
          : all.where((s) => s.feel == filter).toList();
      final mixTotal = w.feelMix.values.fold<int>(0, (a, b) => a + b);
      final dayTops = [
        for (final mo in AlutaMoment.values)
          if (w.momentTops[mo] != null) (mo, w.momentTops[mo]!),
      ];
      return SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.9),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // Sticky header: title, close and the active mood filter stay put
            // while the songs scroll; a hairline shows once content is under it.
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 8, 8),
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
                      Text(headline.isEmpty
                              ? 'The last 7 days, most played first'
                              : headline,
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
            ),
            if (filter != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
                child: Row(children: [
                  Text('Only ${filter!.emoji} ${filter!.label.toLowerCase()}',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface)),
                  const Spacer(),
                  TextButton(
                      onPressed: () => setS(() => filter = null),
                      child: const Text('Show all')),
                ]),
              ),
            ListenableBuilder(
              listenable: scroll,
              builder: (_, _) => Divider(
                height: 1,
                thickness: 1,
                color: scroll.hasClients && scroll.offset > 2
                    ? scheme.outlineVariant.withValues(alpha: 0.6)
                    : Colors.transparent,
              ),
            ),
            Flexible(
              child: CustomScrollView(
                controller: scroll,
                shrinkWrap: true,
                slivers: [
            SliverToBoxAdapter(
              child: Column(children: [
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                  child: Row(children: [
                    stat('${all.length}', all.length == 1 ? 'song' : 'songs'),
                    const SizedBox(width: 8),
                    stat('${w.total}', w.total == 1 ? 'play' : 'plays'),
                    const SizedBox(width: 8),
                    stat(w.together > 0 ? '${w.together}×' : '—', 'together'),
                  ]),
                ),
                // Mood mix — tap a slice to see only those songs.
                if (mixTotal > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            height: 12,
                            child: Row(children: [
                              for (final e in w.feelMix.entries)
                                Expanded(
                                  flex: e.value,
                                  child: GestureDetector(
                                    onTap: () => setS(() => filter =
                                        filter == e.key ? null : e.key),
                                    child: AnimatedOpacity(
                                      duration:
                                          const Duration(milliseconds: 150),
                                      opacity: filter == null ||
                                              filter == e.key
                                          ? 1
                                          : 0.3,
                                      child: Container(
                                          color: _feelColor[e.key]),
                                    ),
                                  ),
                                ),
                            ]),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(spacing: 6, runSpacing: 4, children: [
                          for (final e in w.feelMix.entries)
                            GestureDetector(
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setS(() =>
                                    filter = filter == e.key ? null : e.key);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: (_feelColor[e.key] ?? scheme.primary)
                                      .withValues(
                                          alpha: filter == e.key ? 0.28 : 0.12),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                    '${e.key.emoji} ${(e.value * 100 / mixTotal).round()}% ${e.key.label.toLowerCase()}',
                                    style: TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w700,
                                        color: scheme.onSurface)),
                              ),
                            ),
                        ]),
                      ],
                    ),
                  ),
                // Who owns each part of the day.
                if (dayTops.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: [
                        for (final (mo, t) in dayTops)
                          Container(
                            margin: const EdgeInsets.only(right: 8),
                            constraints: const BoxConstraints(maxWidth: 180),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 7),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest
                                  .withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                    '${_momentLabel[mo]!.$1} ${_momentLabel[mo]!.$2}',
                                    style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: scheme.onSurfaceVariant)),
                                Text(t,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w700,
                                        color: scheme.onSurface)),
                              ],
                            ),
                          ),
                      ]),
                    ),
                  ),
                if (top10Ours > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
                    child: Row(children: [
                      const Text('💞', style: TextStyle(fontSize: 14)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                            '$top10Ours of your top 10 ${top10Ours == 1 ? 'is' : 'are'} in Our Playlist${partnerName == null ? '' : ' with $partnerName'}',
                            style: TextStyle(
                                fontSize: 12.5,
                                color: scheme.onSurfaceVariant)),
                      ),
                    ]),
                  ),
                // Songs in BOTH your tops (partner shares their listening).
                if (theirsFuture != null)
                  FutureBuilder<List<String>?>(
                    future: theirsFuture,
                    builder: (_, snap) {
                      final theirs = snap.data;
                      if (theirs == null || theirs.isEmpty) {
                        return const SizedBox.shrink();
                      }
                      final keys = {
                        for (final t in theirs) SongInsights.keyOf(t)
                      };
                      final both = [
                        for (final s in all.take(15))
                          if (keys.contains(SongInsights.keyOf(s.title)))
                            s.title,
                      ];
                      if (both.isEmpty) return const SizedBox.shrink();
                      return Container(
                        margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          gradient: LinearGradient(colors: [
                            scheme.primary.withValues(alpha: 0.18),
                            scheme.primary.withValues(alpha: 0.05),
                          ]),
                          border: Border.all(
                              color: scheme.primary.withValues(alpha: 0.35)),
                        ),
                        child: Row(children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                    'In both your tops${partnerName == null ? '' : ' — you & $partnerName'} 💞',
                                    style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 13.5,
                                        color: scheme.onSurface)),
                                const SizedBox(height: 2),
                                Text(both.take(4).join(' · '),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 12.5,
                                        color: scheme.onSurfaceVariant)),
                              ],
                            ),
                          ),
                          if (onListenTogether != null)
                            TextButton.icon(
                              onPressed: () {
                                Navigator.pop(ctx);
                                onListenTogether();
                              },
                              icon: const Icon(Icons.headphones_rounded,
                                  size: 18),
                              label: const Text('Together'),
                            ),
                        ]),
                      );
                    },
                  ),
                const SizedBox(height: 6),
              ]),
            ),
            if (songs.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: Text(
                        all.isEmpty
                            ? 'Nothing played in the last 7 days yet'
                            : 'No songs with that feeling this week',
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(10, 0, 14, 8),
                sliver: SliverList.builder(
                  itemCount: songs.length,
                  itemBuilder: (_, j) {
                    final s = songs[j];
                    final i = all.indexOf(s); // rank in the whole week
                    final top3 = i < 3;
                    final mark = trend(s.plays, s.lastWeek);
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
                              Row(children: [
                                Flexible(
                                  child: Text(s.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 14.5,
                                          fontWeight: top3
                                              ? FontWeight.w800
                                              : FontWeight.w600,
                                          color: scheme.onSurface)),
                                ),
                                if (s.ours)
                                  const Padding(
                                    padding: EdgeInsets.only(left: 4),
                                    child: Text('💞',
                                        style: TextStyle(fontSize: 12)),
                                  ),
                                ?mark,
                              ]),
                              if (s.artist.isNotEmpty || s.streak >= 3)
                                Text(
                                    [
                                      if (s.artist.isNotEmpty) s.artist,
                                      if (s.streak >= 3)
                                        '🔁 ${s.streak} days in a row',
                                    ].join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: scheme.onSurfaceVariant)),
                              const SizedBox(height: 6),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(3),
                                child: LinearProgressIndicator(
                                  value: s.plays / maxPlays,
                                  minHeight: 4,
                                  color: (s.feel == null
                                          ? scheme.primary
                                          : _feelColor[s.feel]!)
                                      .withValues(alpha: top3 ? 1 : 0.65),
                                  backgroundColor:
                                      scheme.primary.withValues(alpha: 0.10),
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
                ],
              ),
            ),
            // Sticky footer: the send button is always one tap away.
            if (onSend != null && all.isNotEmpty)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surface,
                  border: Border(
                      top: BorderSide(
                          color: scheme.outlineVariant.withValues(alpha: 0.6))),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
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
              ),
          ]),
        ),
      );
    }),
  // Dispose after the close animation, once the list has let go of it.
  ).whenComplete(() =>
      Future.delayed(const Duration(seconds: 1), scroll.dispose));
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "✨ First heard 29 Oct · together with Wifey 💞" / "… · on your own".
String _firstHeard(DateTime at, String? withName) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(at.year, at.month, at.day);
  final gap = today.difference(day).inDays;
  final when = gap == 0
      ? 'today'
      : gap == 1
          ? 'yesterday'
          : '${at.day} ${_months[at.month - 1]}'
              '${at.year == now.year ? '' : ' ${at.year}'}';
  final who = (withName ?? '').trim().split(RegExp(r'\s+')).first;
  return who.isEmpty
      ? '✨ First heard $when · on your own'
      : '✨ First heard $when · together with $who 💞';
}

/// A floating, dismissible card with everything Aluta learned about one song
/// — opened by tapping a song nudge banner ("on repeat", "makes you miss…",
/// "feels like yours"): a 7-day play chart, this week's plays and rank,
/// how many days you played it, all-time plays, its feel (tap to change) and
/// whether it's in Our Playlist. "See my week" opens the full week.
Future<void> showSongInsight(BuildContext context, String title,
    {String? partnerName,
    void Function(String text)? onSendWeek,
    Future<({String name, VoidCallback thank})?> Function()? sharedBy,
    VoidCallback? onOpenWeek}) {
  final scheme = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final sharerFuture = sharedBy?.call();
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
                  chip('🎵 ${st.week}× this week'),
                  if (st.rank != null) chip('🏆 #${st.rank} this week'),
                  if (st.lastWeek == 0 && st.week > 0)
                    chip('✨ New this week')
                  else if (st.week > st.lastWeek)
                    chip('▲ up from ${st.lastWeek}× last week')
                  else if (st.week < st.lastWeek)
                    chip('▼ ${st.lastWeek}× last week'),
                  chip('📅 ${st.daysThisWeek} of 7 days'),
                  if (st.streak >= 2) chip('🔁 ${st.streak} days in a row'),
                  if (st.total > st.week) chip('🎧 ${st.total}× lately'),
                  if (st.ours) chip('💞 In Our Playlist'),
                ]),
                // The day it all started — and who was there.
                if (st.firstAt != null) ...[
                  const SizedBox(height: 10),
                  Text(_firstHeard(st.firstAt!, st.firstWith),
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurfaceVariant)),
                ],
                // When you listen — the part-of-day split.
                if (st.moments.values.any((v) => v > 0)) ...[
                  const SizedBox(height: 14),
                  Text('When you listen',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 6),
                  Builder(builder: (_) {
                    final tot =
                        st.moments.values.fold<int>(0, (a, b) => a + b);
                    final parts = st.moments.entries
                        .where((e) => e.value > 0)
                        .toList();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(7),
                          child: SizedBox(
                            height: 10,
                            child: Row(children: [
                              for (var i = 0; i < parts.length; i++)
                                Expanded(
                                  flex: parts[i].value,
                                  child: Container(
                                    color: scheme.primary.withValues(
                                        alpha: 0.35 +
                                            0.65 * (i + 1) / parts.length),
                                  ),
                                ),
                            ]),
                          ),
                        ),
                        const SizedBox(height: 5),
                        Wrap(spacing: 10, children: [
                          for (final e in parts)
                            Text(
                                '${_momentLabel[e.key]!.$1} ${_momentLabel[e.key]!.$2} ${(e.value * 100 / tot).round()}%',
                                style: TextStyle(
                                    fontSize: 11.5,
                                    color: scheme.onSurfaceVariant)),
                        ]),
                      ],
                    );
                  }),
                ],
                // Who brought it to you (from your chats).
                if (sharerFuture != null)
                  FutureBuilder<({String name, VoidCallback thank})?>(
                    future: sharerFuture,
                    builder: (_, snap) {
                      final who = snap.data;
                      if (who == null) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Row(children: [
                          const Text('🎁', style: TextStyle(fontSize: 15)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text('${who.name} shared this with you',
                                style: TextStyle(
                                    fontSize: 13, color: scheme.onSurface)),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.pop(ctx);
                              who.thank();
                            },
                            child: const Text('Thank them'),
                          ),
                        ]),
                      );
                    },
                  ),
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
                    if (onOpenWeek != null) {
                      onOpenWeek();
                    } else {
                      showWeekInMusic(context,
                          partnerName: partnerName, onSend: onSendWeek);
                    }
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
