part of '../home_page.dart';

// Split out of home_page.dart (pure code-movement, no behaviour change):
// phone layout body + expandable player sheet. A private extension on HomePageState — a library `part`, so it
// shares the file's imports and reaches every private field/method. None
// of these methods call setState directly, so the extension stays clear of
// @protected members.

extension _HomePhoneBody on HomePageState {
  // ── Phone layout ───────────────────────────────────────────────────────────
  // Chat is the primary full-width surface. The music player stays mounted the
  // whole time (so audio never stops) but lives off-screen below; a slim
  // now-playing bar sits above the footer and expands the player on tap.

  Widget _buildPhoneBody(BuildContext context, BoxConstraints constraints) {
    return rp.Consumer(
      // Rebuild the bar/sheet visibility when the track or live session changes.
      // (Was: ListenableBuilder over merged nowPlayingNotifier+liveSessionNotifier.)
      builder: (context, ref, _) {
        final hasTrack = ref.watch(nowPlayingProvider).track.isNotEmpty;
        // The now-playing bar is for the user's OWN music (the live session has
        // its own audio and is surfaced by the top banner). Show it when a
        // personal track is loaded and the user hasn't dismissed it; otherwise
        // a compact pill docked in the footer centre is the entry point.
        final barVisible = hasTrack && !_barDismissed;
        // Reserve just enough chat space for the now-playing bar (grab handle +
        // title + progress row) so it sits flush under the composer with no gap.
        final barSpace = 70.0;

        return Stack(
          children: [
            // Chat surface — full width; reserve room for the collapsed bar.
            // AnimatedPadding so the reflow eases in step with the bar's genie.
            Positioned.fill(
              child: AnimatedPadding(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                padding: EdgeInsets.only(
                    bottom: (_playerExpanded || !barVisible) ? 0 : barSpace),
                child: _buildChatContent(context, phone: true),
              ),
            ),

            // Full player — ALWAYS mounted (AudioPlayer stays alive). Instead of
            // sliding from the top it "genie" scales into / out of the footer-pill
            // spot (bottom-centre anchor, smooth, no bounce), so it reads as being
            // pulled out of the pill and sucked back into it.
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_playerExpanded,
                child: AnimatedScale(
                  scale: _playerExpanded ? 1.0 : 0.0,
                  alignment: Alignment.bottomCenter,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    opacity: _playerExpanded ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOut,
                    child: _buildPhonePlayerSheet(context),
                  ),
                ),
              ),
            ),

            // Collapsed now-playing bar. Kept mounted while a track is loaded so
            // it can genie-scale DOWN into the footer pill on dismiss and back
            // OUT of it on resume (bottom-centre anchor, no bounce).
            if (hasTrack && !_playerExpanded)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  ignoring: _barDismissed,
                  child: AnimatedScale(
                    scale: _barDismissed ? 0.0 : 1.0,
                    alignment: Alignment.bottomCenter,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    child: AnimatedOpacity(
                      opacity: _barDismissed ? 0.0 : 1.0,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      child: _buildNowPlayingBar(context),
                    ),
                  ),
                ),
              ),

            // When collapsed the entry point is a compact pill docked in the
            // footer centre (see _footerMusicChip) — not a button over the chat.
          ],
        );
      },
    );
  }

  Widget _buildPhonePlayerSheet(BuildContext context) {
    // Now Playing is a dark "stage" — header + surface + controls — regardless
    // of the app's Light/Dark mode; the accent colours the controls (PlayerTheme).
    return PlayerTheme(
      child: Builder(builder: (context) {
    final scheme = Theme.of(context).colorScheme;
    return _panelDecor(
      context,
      Column(
        children: [
          // Grab handle + header. Swiping DOWN anywhere on this handle/header
          // area minimises the panel (in addition to the chevron button), and a
          // tap on the handle collapses it too.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _closePanel,
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) > 120) {
                _closePanel();
              }
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Draggable grab handle — the swipe-down affordance.
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: scheme.onSurfaceVariant.withAlpha(90),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                Row(
                  children: [
                    _PanelToggleBtn(
                      isFullScreen: false,
                      customIcon: Icons.keyboard_arrow_down_rounded,
                      onTap: _closePanel,
                    ),
                    const SizedBox(width: 10),
                    Icon(Icons.music_note_rounded,
                        color: scheme.primary, size: 20),
                    const SizedBox(width: 6),
                    // Theme-aware so the title stays legible in dark mode (an
                    // uncoloured Text here fell back to black → invisible on the
                    // dark panel surface).
                    Text('Now Playing',
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                            color: scheme.onSurface)),
                    const Spacer(),
                    // Live badge in the sheet header too, for context.
                    if (ref.read(liveSessionProvider).active) _liveChip(context),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Stack(
              children: [
                kIsWeb
                    ? WebMusicPanel(textColor: scheme.onSurface)
                    : MusicControls(
                        key: _musicPanelKey, textColor: scheme.onSurface),
                _playlistDrawerHost(context, music: true),
              ],
            ),
          ),
        ],
      ),
      isMusicPanel: true,
    );
      }),
    );
  }
}
