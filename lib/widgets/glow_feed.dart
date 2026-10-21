import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, HapticFeedback;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/glow_cards.dart';
import '../services/aluta_mood.dart';
import '../services/song_insights.dart';

/// GLOW — the third friend-page layer: a calm feed of love writing, research
/// -inspired insights, small things to try together, and healthy-love care.
/// A "Today's glow" card leads (picked by the date, the time of day and the
/// feeling you last gave a song), then the rest of the pack, shuffled fresh
/// each day. Save ♡ what speaks to you; send any card to your partner.
/// Bundled and on-device — no server. Encouragement, not therapy.
class GlowFeed extends StatefulWidget {
  const GlowFeed({super.key});

  @override
  State<GlowFeed> createState() => _GlowFeedState();
}

enum _Filter { all, quotes, insights, together, healthy, saved }

class _GlowFeedState extends State<GlowFeed> {
  static const _savedKey = 'glow_saved_v1';
  Set<String> _saved = {};
  _Filter _filter = _Filter.all;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() => _saved = (p.getStringList(_savedKey) ?? const []).toSet());
    }).catchError((_) {});
    SongInsights.instance.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _toggleSave(GlowCard c) async {
    HapticFeedback.selectionClick();
    setState(() {
      if (!_saved.remove(c.id)) _saved.add(c.id);
    });
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_savedKey, _saved.toList());
    } catch (_) {}
  }

  String _shareText(GlowCard c) {
    switch (c.kind) {
      case GlowKind.quote:
        return '✨ “${c.text.replaceAll('\n', ' ')}”\n— ${c.source}';
      case GlowKind.together:
        return '💞 ${c.text}';
      case GlowKind.insight:
      case GlowKind.healthy:
        return '✨ ${c.title}\n${c.text}';
    }
  }

  void _send(GlowCard c) {
    final b = SongBridge.instance;
    final partner = b.partnerName?.call();
    if (partner != null && partner.isNotEmpty && b.messagePartner != null) {
      b.messagePartner!(text: _shareText(c));
      return;
    }
    Clipboard.setData(ClipboardData(text: _shareText(c)));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('Copied — paste it to someone you love 💞')));
  }

  // ── Daily selection ──────────────────────────────────────────────────────
  int get _daySeed {
    final d = DateTime.now();
    return d.year * 1000 + d.difference(DateTime(d.year)).inDays;
  }

  List<String> get _wantTags {
    final f = SongInsights.instance.lastFeel;
    final byFeel = switch (f) {
      SongFeel.missing => ['missing', 'steady'],
      SongFeel.love => ['admire', 'close'],
      SongFeel.hyped => ['new', 'team'],
      SongFeel.calm => ['calm'],
      SongFeel.hurting => ['repair', 'calm'],
      null => <String>[],
    };
    final byMoment = switch (AlutaMood.moment) {
      AlutaMoment.dawn || AlutaMoment.morning => ['gratitude', 'new'],
      AlutaMoment.afternoon => ['team', 'close'],
      AlutaMoment.evening => ['close', 'repair'],
      AlutaMoment.night => ['calm', 'steady'],
    };
    return [...byFeel, ...byMoment];
  }

  GlowCard get _today {
    final want = _wantTags;
    final pool = glowCards
        .where((c) =>
            c.kind != GlowKind.healthy && c.tags.any(want.contains))
        .toList();
    final list = pool.isEmpty ? glowCards : pool;
    return list[_daySeed % list.length];
  }

  List<GlowCard> get _feed {
    final today = _today;
    // A gentle, stable-per-day shuffle (no flicker on rebuild).
    final seed = _daySeed;
    final list = [...glowCards]..sort((a, b) =>
        ((a.id.hashCode ^ seed) & 0x7fffffff)
            .compareTo((b.id.hashCode ^ seed) & 0x7fffffff));
    list.remove(today);
    bool keep(GlowCard c) => switch (_filter) {
          _Filter.all => true,
          _Filter.quotes => c.kind == GlowKind.quote,
          _Filter.insights => c.kind == GlowKind.insight,
          _Filter.together => c.kind == GlowKind.together,
          _Filter.healthy => c.kind == GlowKind.healthy,
          _Filter.saved => _saved.contains(c.id),
        };
    return list.where(keep).toList();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final feed = _feed;
    final showToday = _filter == _Filter.all;
    return ListView(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 20),
      children: [
        _filters(scheme),
        const SizedBox(height: 10),
        if (showToday) ...[
          _todayCard(scheme, isDark, _today),
          const SizedBox(height: 14),
        ],
        if (feed.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Text(
                _filter == _Filter.saved
                    ? 'Tap ♡ on a card to keep it here'
                    : 'Nothing here yet',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        for (final c in feed) ...[
          _card(scheme, isDark, c),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 8),
        _footer(scheme),
      ],
    );
  }

  Widget _filters(ColorScheme scheme) {
    const labels = {
      _Filter.all: 'For you',
      _Filter.quotes: 'Quotes',
      _Filter.insights: 'Insights',
      _Filter.together: 'Together',
      _Filter.healthy: 'Healthy love',
      _Filter.saved: 'Saved',
    };
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final f in _Filter.values)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(labels[f]!),
                avatar: f == _Filter.saved
                    ? Icon(Icons.favorite_rounded,
                        size: 14, color: scheme.primary)
                    : null,
                selected: _filter == f,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                onSelected: (_) => setState(() => _filter = f),
              ),
            ),
        ],
      ),
    );
  }

  ({IconData icon, String label}) _kindOf(GlowKind k) => switch (k) {
        GlowKind.quote => (icon: Icons.format_quote_rounded, label: 'Quote'),
        GlowKind.insight => (icon: Icons.lightbulb_rounded, label: 'Insight'),
        GlowKind.together =>
          (icon: Icons.favorite_rounded, label: 'Try together'),
        GlowKind.healthy => (icon: Icons.shield_rounded, label: 'Healthy love'),
      };

  Widget _todayCard(ColorScheme scheme, bool isDark, GlowCard c) {
    final a = scheme.primary;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 12, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(a, Colors.white, isDark ? 0.0 : 0.15)!
                .withValues(alpha: isDark ? 0.55 : 0.9),
            Color.lerp(a, Colors.black, 0.25)!,
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: a.withValues(alpha: 0.35),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.auto_awesome_rounded,
                size: 16, color: Colors.white),
            const SizedBox(width: 6),
            const Text("TODAY'S GLOW",
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    letterSpacing: 1.4,
                    fontWeight: FontWeight.w800)),
            const Spacer(),
            _iconBtn(
                _saved.contains(c.id)
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                'Save',
                Colors.white,
                () => _toggleSave(c)),
          ]),
          const SizedBox(height: 8),
          if (c.title.isNotEmpty) ...[
            Text(c.title,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
          ],
          Text(c.text,
              style: TextStyle(
                  color: Colors.white,
                  fontSize: c.kind == GlowKind.quote ? 17 : 14.5,
                  height: 1.45,
                  fontStyle: c.kind == GlowKind.quote
                      ? FontStyle.italic
                      : FontStyle.normal,
                  fontWeight: FontWeight.w500)),
          if (c.source.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(c.kind == GlowKind.quote ? '— ${c.source}' : c.source,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: 12)),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonalIcon(
              onPressed: () => _send(c),
              icon: const Icon(Icons.send_rounded, size: 16),
              label: Text(_sendLabel(c)),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white.withValues(alpha: 0.92),
                foregroundColor: Color.lerp(a, Colors.black, 0.2),
                visualDensity: VisualDensity.compact,
                shape: const StadiumBorder(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _sendLabel(GlowCard c) {
    final p = SongBridge.instance.partnerName?.call();
    final has = p != null && p.isNotEmpty;
    if (c.kind == GlowKind.together) return has ? 'Ask $p' : 'Copy';
    return has ? 'Send to $p' : 'Copy';
  }

  Widget _iconBtn(IconData i, String tip, Color c, VoidCallback onTap) =>
      IconButton(
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        icon: Icon(i, size: 20, color: c),
        onPressed: onTap,
      );

  Widget _card(ColorScheme scheme, bool isDark, GlowCard c) {
    final k = _kindOf(c.kind);
    final healthy = c.kind == GlowKind.healthy;
    final a = healthy ? const Color(0xFF26A69A) : scheme.primary;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      decoration: BoxDecoration(
        color: isDark ? scheme.surfaceContainerHigh : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: a.withValues(alpha: isDark ? 0.3 : 0.18)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(k.icon, size: 15, color: a),
            const SizedBox(width: 5),
            Text(k.label.toUpperCase(),
                style: TextStyle(
                    fontSize: 10.5,
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w800,
                    color: a)),
            const Spacer(),
            _iconBtn(
                _saved.contains(c.id)
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                'Save',
                _saved.contains(c.id) ? scheme.primary : scheme.onSurfaceVariant,
                () => _toggleSave(c)),
          ]),
          if (c.title.isNotEmpty) ...[
            Text(c.title,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface)),
            const SizedBox(height: 4),
          ],
          Text(c.text,
              style: TextStyle(
                  fontSize: c.kind == GlowKind.quote ? 15.5 : 13.5,
                  height: 1.45,
                  fontStyle: c.kind == GlowKind.quote
                      ? FontStyle.italic
                      : FontStyle.normal,
                  color: scheme.onSurface.withValues(alpha: 0.88))),
          Row(children: [
            Expanded(
              child: c.source.isEmpty
                  ? const SizedBox(height: 8)
                  : Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                          c.kind == GlowKind.quote
                              ? '— ${c.source}'
                              : c.source,
                          style: TextStyle(
                              fontSize: 11.5,
                              color: scheme.onSurfaceVariant)),
                    ),
            ),
            TextButton.icon(
              onPressed: () => _send(c),
              icon: Icon(
                  c.kind == GlowKind.together
                      ? Icons.favorite_rounded
                      : Icons.send_rounded,
                  size: 15),
              label: Text(_sendLabel(c)),
              style: TextButton.styleFrom(
                  foregroundColor: a, visualDensity: VisualDensity.compact),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _footer(ColorScheme scheme) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          'Glow shares classic love writing and ideas from relationship '
          'research in our own words. It’s encouragement, not '
          'professional advice. If you ever feel unsafe, call 116 (free, '
          '24/7) or the police on 112.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      );
}
