part of '../relationship_space_page.dart';

// ── Love letters — every secret heart between the two of you ────────────────
// A quiet shelf of the hearts you've sent each other, newest first, to reread
// any time. Each one reopens as its letter (behind the device unlock when
// "Lock secret hearts" is on). Timed hearts that haven't opened yet show when
// they will. Server: GET /messages/hearts/{peer} (my_aluta_api/hearts.py).

extension _SpaceLoveLetters on _RelationshipSpacePageState {
  Widget _loveLettersSection(ColorScheme scheme, {VoidCallback? onMenu}) {
    final pid = _partnerId;
    _lettersFuture ??= pid == null
        ? Future.value(const <Map<String, dynamic>>[])
        : ApiService().loveLetters(pid);
    final partner = _others.isNotEmpty
        ? ContactNames.instance.displayName(of: _others.first, registered: (_others.first['username'] ?? 'them').toString())
        : 'them';
    return _sectionPanel(
      scheme,
      Icons.mark_email_unread_rounded,
      'Love letters',
      onMenu: onMenu,
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _lettersFuture,
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2.4)),
            );
          }
          final letters = snap.data ?? const [];
          if (letters.isEmpty) return _lettersEmpty(scheme);
          // "On this day": hearts traded on today's date in earlier years.
          final now = DateTime.now();
          final onThisDay = letters.where((l) {
            final t = parseLocal(l['timestamp']);
            return t != null &&
                t.year < now.year &&
                t.month == now.month &&
                t.day == now.day;
          }).toList();
          return Column(children: [
            if (onThisDay.isNotEmpty) _onThisDay(scheme, onThisDay, partner),
            for (final l in letters) _letterCard(scheme, l, partner),
          ]);
        },
      ),
    );
  }

  Widget _onThisDay(ColorScheme scheme, List<Map<String, dynamic>> letters,
      String partner) {
    final t = parseLocal(letters.first['timestamp'])!;
    final years = DateTime.now().year - t.year;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _accent.withValues(alpha: 0.30),
            _accent.withValues(alpha: 0.10),
          ],
        ),
        border: Border.all(color: _accent.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, size: 18, color: _accent),
              const SizedBox(width: 8),
              Text(
                'On this day · ${years == 1 ? '1 year ago' : '$years years ago'}',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    color: scheme.onSurface),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final l in letters) _letterCard(scheme, l, partner),
        ],
      ),
    );
  }

  Widget _lettersEmpty(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
      child: Column(
        children: [
          Icon(Icons.favorite_border_rounded,
              size: 46, color: _accent.withValues(alpha: 0.7)),
          const SizedBox(height: 12),
          Text('No love letters yet',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurface)),
          const SizedBox(height: 6),
          Text(
            'Tap the ♡ in your chat composer to send a secret heart. '
            'Every one you trade lands here, to reread whenever you like.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _letterCard(
      ColorScheme scheme, Map<String, dynamic> l, String partner) {
    final mood = HeartMood.of(l['heart_mood']?.toString());
    final tint = mood.color;
    final mine = (l['sender_id'] as num?)?.toInt() == widget.myUserId;
    final sent = parseLocal(l['timestamp']);
    final unlock = parseLocal(l['unlock_at']);
    final sealed = unlock != null && DateTime.now().isBefore(unlock);
    final text = (l['content'] ?? '').toString();
    final opened = l['opened_at'] != null;
    final when = sent == null ? '' : DateFormat('d MMM y · h:mm a').format(sent);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: (sealed || text.isEmpty)
              ? () => showToast(
                  context,
                  sealed
                      ? 'Sealed · ${heartOpensLabel(unlock).toLowerCase()}'
                      : 'This one is opening — check back in a moment',
                  type: ToastType.info)
              : () => _rereadLetter(text, tint, mood),
          child: Ink(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  tint.withValues(alpha: 0.16),
                  tint.withValues(alpha: 0.05),
                ],
              ),
              border: Border.all(color: tint.withValues(alpha: 0.30)),
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: tint.withValues(alpha: 0.18),
                  ),
                  child: Icon(
                      sealed ? Icons.hourglass_top_rounded : mood.icon,
                      color: tint,
                      size: 21),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        mine ? 'To $partner · ${mood.title}' : 'From $partner · ${mood.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                            color: scheme.onSurface),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        sealed
                            ? heartOpensLabel(unlock)
                            : (mine
                                ? '$when · ${opened ? 'opened 💗' : 'not opened yet'}'
                                : when),
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Icon(
                    sealed ? Icons.lock_clock_rounded : Icons.lock_rounded,
                    size: 18,
                    color: tint.withValues(alpha: 0.8)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _rereadLetter(String text, Color tint, HeartMood mood) async {
    final ok = await HeartLock.instance.ensureUnlocked('Open love letter');
    if (!ok || !mounted) return;
    final size = MediaQuery.of(context).size;
    showHeartGenie(
      context,
      originRect: Rect.fromCenter(
          center: Offset(size.width / 2, size.height / 2),
          width: 10,
          height: 10),
      text: text,
      accent: tint,
      mood: mood,
    );
  }

  static DateTime? parseLocal(Object? raw) {
    final s = (raw ?? '').toString();
    if (s.isEmpty) return null;
    return parseServerTime(s);
  }
}
