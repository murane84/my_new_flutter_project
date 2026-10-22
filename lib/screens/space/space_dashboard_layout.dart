part of '../relationship_space_page.dart';

// ── Our Space dashboard layout ──────────────────────────────────────────────
// A compact, STICKY hero on top (identity on the left, the bond's pulse and
// "Thinking of you" on the right — using the width instead of stacking five
// rows in the middle), and below it the cards scroll on their own.
//
//  • Desktop / wide (≥900, paired): two balanced columns — the "doing" column
//    (listen together, today's question, the monthly recap) beside a rail
//    (streak, the next plan, and the four feature tiles).
//  • Phone / narrow: one column in priority order.
extension _SpaceDashboardLayout on _RelationshipSpacePageState {
  Widget _spaceDashboard(
      ColorScheme scheme, String title, List<Map<String, dynamic>> moments) {
    final isPair = _partnerId != null;
    return LayoutBuilder(builder: (ctx, c) {
      final twoCol = c.maxWidth >= 900 && isPair;
      final pad = twoCol ? 20.0 : 14.0;
      final hero = Padding(
        padding: EdgeInsets.fromLTRB(pad, 8, pad, 8),
        child: _compactHero(scheme, title, roomy: c.maxWidth >= 640),
      );

      final banners = <Widget>[
        _pendingPartnerBanner(scheme),
        _milestoneBanner(scheme),
      ];

      final Widget list;
      if (twoCol) {
        list = ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(pad, 10, pad, 24),
          children: [
            ...banners,
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 58,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _presenceHero(scheme),
                      _dailyQuestionCard(scheme),
                      _recapCard(scheme),
                    ],
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  flex: 42,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _streakCard(scheme),
                      _upcomingPlanBanner(scheme),
                      _tilesSection(scheme, moments),
                    ],
                  ),
                ),
              ],
            ),
          ],
        );
      } else {
        list = ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(pad, 10, pad, 20),
          children: [
            ...banners,
            if (isPair) _presenceHero(scheme),
            if (isPair) _dailyQuestionCard(scheme),
            if (isPair) _streakCard(scheme),
            if (isPair) _recapCard(scheme),
            _upcomingPlanBanner(scheme),
            const SizedBox(height: 4),
            _tilesSection(scheme, moments),
          ],
        );
      }

      final page = Column(
        children: [
          hero,
          // Cards scroll independently under the pinned hero and soften as
          // they slide beneath it.
          Expanded(
            // Settings take this area in place (same door in and out: a soft
            // fade + rise), the hero staying put above.
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween<Offset>(
                          begin: const Offset(0, 0.03), end: Offset.zero)
                      .animate(anim),
                  child: child,
                ),
              ),
              child: _settingsOpen
                  ? _settingsPanel()
                  : KeyedSubtree(
                      key: const ValueKey('space-cards'),
                      child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (r) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black],
                stops: [0.0, 0.035],
              ).createShader(r),
              child: list,
            ),
                    ),
            ),
          ),
        ],
      );
      // Phones: the same drawer as the sections (Overview · sections ·
      // Settings · Thinking of you), opened from the header's ☰.
      return c.maxWidth < 720 ? _withNavDrawer(scheme, page, c.maxWidth) : page;
    });
  }

  /// The compact hero. [roomy]: one row — avatars · name + days · pulse chips
  /// · Thinking of you. Narrow: avatars + name with a round Thinking-of-you
  /// button, and the pulse chips on a second row.
  Widget _compactHero(ColorScheme scheme, String title, {required bool roomy}) {
    final others = _others;
    final hasPartner = others.isNotEmpty;
    final stats = (_space['stats'] as Map?) ?? const {};
    final days = (stats['days_in_song'] as num?)?.toInt() ?? 0;
    final streak = (stats['listen_streak'] as num?)?.toInt() ?? 0;
    final hasStats = hasPartner && (days > 0 || streak > 0);
    final daysTogether = hasPartner ? _daysTogether() : null;

    const shadow = Shadow(
        color: Color(0x38000000), blurRadius: 4, offset: Offset(0, 1));

    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasPartner && roomy)
          Text('OUR WORLD',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2.2,
                  shadows: const [shadow])),
        Text(title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: Colors.white,
                fontSize: roomy ? 19 : 17,
                fontWeight: FontWeight.w800,
                shadows: const [shadow])),
        const SizedBox(height: 2),
        Text(
          [
            if (daysTogether != null)
              '$daysTogether day${daysTogether == 1 ? '' : 's'} together',
            'since ${_closeSince()}',
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.92),
              fontSize: roomy ? 12.5 : 11.5,
              fontWeight: FontWeight.w600,
              shadows: const [shadow]),
        ),
      ],
    );

    Widget chip(String emoji, String value, String label) => Container(
          padding: EdgeInsets.symmetric(
              horizontal: roomy ? 12 : 10, vertical: roomy ? 8 : 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white.withValues(alpha: 0.30),
                Colors.white.withValues(alpha: 0.12),
              ],
            ),
            border: Border.all(color: Colors.white.withValues(alpha: 0.45)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(emoji,
                  style: TextStyle(
                      fontSize: roomy ? 14 : 12, shadows: const [shadow])),
              const SizedBox(width: 6),
              Text(value,
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: roomy ? 16 : 13.5,
                      shadows: const [shadow])),
              const SizedBox(width: 5),
              Text(label,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.92),
                      fontSize: roomy ? 11.5 : 11,
                      shadows: const [shadow])),
            ],
          ),
        );

    final pulse = AnimatedOpacity(
      opacity: hasStats ? 1 : 0,
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeOut,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          chip('🔥', '$streak', 'day streak'),
          chip('🎧', '$days', days == 1 ? 'day in a song' : 'days in a song'),
        ],
      ),
    );

    // "Thinking of you" — a frosted white key on the banner.
    Widget thinking({required bool round}) => Tooltip(
          message: 'Thinking of you',
          child: Material(
            color: Colors.white,
            shape: round ? const CircleBorder() : const StadiumBorder(),
            elevation: 3,
            shadowColor: Colors.black.withValues(alpha: 0.3),
            child: InkWell(
              customBorder:
                  round ? const CircleBorder() : const StadiumBorder(),
              onTap: _nudging ? null : _nudge,
              child: Padding(
                padding: round
                    ? const EdgeInsets.all(10)
                    : const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _nudging
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: _accent))
                        : Icon(Icons.chat_bubble_rounded,
                            size: 16, color: _accent),
                    if (!round) ...[
                      const SizedBox(width: 8),
                      Text('Thinking of you',
                          style: TextStyle(
                              color: _accent,
                              fontWeight: FontWeight.w800,
                              fontSize: 13)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );

    final avatars = _heroAvatars(others, radius: roomy ? 24 : 20);

    final content = roomy
        ? Row(
            children: [
              avatars,
              const SizedBox(width: 14),
              Expanded(child: identity),
              if (hasPartner) ...[
                const SizedBox(width: 12),
                pulse,
                const SizedBox(width: 14),
                thinking(round: false),
              ],
            ],
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  avatars,
                  const SizedBox(width: 12),
                  Expanded(child: identity),
                  if (hasPartner) ...[
                    const SizedBox(width: 8),
                    thinking(round: true),
                  ],
                ],
              ),
              if (hasPartner) ...[
                const SizedBox(height: 10),
                pulse,
              ],
            ],
          );

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _accent.withValues(alpha: 0.95),
            _accent.withValues(alpha: 0.62),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: _accent.withValues(alpha: 0.30),
            blurRadius: 20,
            spreadRadius: -6,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Stack(
        children: [
          // Top-lit sheen so the banner reads as a lit, curved surface.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: RadialGradient(
                    center: const Alignment(-0.6, -1.2),
                    radius: 1.3,
                    colors: [
                      Colors.white.withValues(alpha: 0.22),
                      Colors.white.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(
                horizontal: roomy ? 20 : 14, vertical: roomy ? 14 : 12),
            child: content,
          ),
        ],
      ),
    );
  }

  /// Me + the other, slightly overlapped, in bevelled white rings.
  Widget _heroAvatars(List<Map<String, dynamic>> others,
      {required double radius}) {
    final rightUrl =
        others.isNotEmpty ? _full(others.first['avatar_url']) : null;
    final rightName =
        others.isNotEmpty ? (others.first['username'] ?? '').toString() : '';
    final me = _ringed(
      child: InitialsAvatar(
        name: (widget.myName ?? 'You').isEmpty ? 'You' : widget.myName!,
        radius: radius,
        imageUrl: widget.myAvatarUrl,
      ),
    );
    if (others.isEmpty) return me;
    final d = radius * 2 + 6;
    return SizedBox(
      width: d * 1.62,
      height: d,
      child: Stack(
        children: [
          Positioned(left: 0, child: me),
          Positioned(
            right: 0,
            child: _ringed(
              child: InitialsAvatar(
                  name: rightName.isEmpty ? '?' : rightName,
                  radius: radius,
                  imageUrl: rightUrl),
            ),
          ),
        ],
      ),
    );
  }
}
