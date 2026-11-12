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
    final split = (me > 0 && them > 0)
        ? 'You $me · $partner $them'
        : (me > 0 ? 'All you — $me times' : 'All $partner — $them times');
    final rest = items.skip(1).take(3).toList();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.lg),
          color: _accent.withValues(alpha: 0.08),
          border: Border.all(color: _accent.withValues(alpha: 0.30)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('💬 THIS MONTH IN YOUR WORDS',
                style: TextStyle(
                    fontSize: 10.5,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w800,
                    color: _accent)),
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
