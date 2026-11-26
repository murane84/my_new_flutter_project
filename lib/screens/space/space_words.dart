part of '../relationship_space_page.dart';

// ── This month in your words ────────────────────────────────────────────────
// "You said 'miss you' 14 times this month 🥹" — counted by the server from
// the two of you's own chat this month (counts only, never the messages).
extension _SpaceWords on _RelationshipSpacePageState {
  static const _emoji = {
    'miss you': '🥹',
    'love you': '💞',
    'good night': '🌙',
    'good morning': '☀️',
    'baby': '🥰',
    '❤️': '❤️',
  };

  Widget _wordsCard(ColorScheme scheme) {
    final items = ((_words?['items'] as List?) ?? const [])
        .whereType<Map>()
        .toList();
    if (_partnerId == null || items.isEmpty) return const SizedBox.shrink();
    final top = items.first;
    final phrase = '${top['phrase']}';
    final total = (top['total'] as num?)?.toInt() ?? 0;
    final me = (top['me'] as num?)?.toInt() ?? 0;
    final them = (top['them'] as num?)?.toInt() ?? 0;
    final partner = _partnerFirstName;
    String said(String p) => p == '❤️' ? 'sent ❤️' : 'said “$p”';
    final headline = 'You two ${said(phrase)} $total times this month '
        '${_emoji[phrase] ?? '💞'}';
    // Who said it — gently, never a score: "From you, both times".
    String from(String who, int n) => n == 1
        ? 'From $who'
        : n == 2
            ? 'From $who, both times'
            : 'From $who, all $n times';
    final split = (me > 0 && them > 0)
        ? 'You $me · $partner $them'
        : (me > 0 ? from('you', me) : from(partner, them));
    final rest = items.skip(1).take(3).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: _auraCard(scheme),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _eyebrow(Icons.chat_bubble_outline_rounded,
                'This month in your words'),
            const SizedBox(height: 6),
            Text(headline,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface)),
            const SizedBox(height: 2),
            Text(split,
                style:
                    TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            if (rest.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final r in rest)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: BorderRadius.circular(Radii.md),
                      border: Border.all(
                          color: _accent.withValues(alpha: 0.22)),
                    ),
                    child: Text(
                        '${_emoji['${r['phrase']}'] ?? '💞'} '
                        '${r['phrase'] == '❤️' ? 'hearts' : r['phrase']} '
                        '× ${r['total']}',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurface)),
                  ),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  String get _partnerFirstName {
    final o = _others;
    if (o.isEmpty) return 'them';
    final n = ContactNames.instance.displayName(
        of: o.first, registered: (o.first['username'] ?? '').toString());
    final f = n.trim().split(RegExp(r'\s+')).first;
    return f.isEmpty ? 'them' : f;
  }
}
