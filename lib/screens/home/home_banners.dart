part of '../home_page.dart';

// Split out of home_page.dart (pure code-movement, no behaviour change):
// live-session + call-return banners, live chip. A private extension on HomePageState — a library `part`, so it
// shares the file's imports and reaches every private field/method. None
// of these methods call setState directly, so the extension stays clear of
// @protected members.

extension _HomeBanners on HomePageState {
  Widget _liveChip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final session = ref.read(liveSessionProvider);
    final peer = session.peer;
    final asHost = session.asHost;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.primary.withAlpha(30),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.primary.withAlpha(120)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Pulsing dot connotes a live stream.
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primary,
              boxShadow: [
                BoxShadow(
                    color: scheme.primary.withAlpha(160),
                    blurRadius: 6,
                    spreadRadius: 1),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              asHost ? 'Streaming to $peer' : 'Listening with $peer',
              style: TextStyle(
                color: scheme.primary,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // ── Live session banner (both layouts) ──────────────────────────────────────
  Widget _buildLiveBanner(BuildContext context) {
    return rp.Consumer(
      builder: (context, ref, _) {
        final session = ref.watch(liveSessionProvider);
        if (!session.active) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        final peer = session.peer;
        final host = session.asHost;
        return Material(
          color: scheme.primary,
          child: InkWell(
            onTap: _reopenLiveSession,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 7, 6, 7),
              child: Row(
                children: [
                  // Pulsing live dot.
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(
                            color: Colors.white.withAlpha(160),
                            blurRadius: 6,
                            spreadRadius: 1),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(Icons.headphones_rounded,
                      size: 17, color: Colors.white.withAlpha(230)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      host
                          ? 'Live · streaming to $peer'
                          : 'Live · listening with $peer',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Text('Tap to open',
                      style: TextStyle(color: Colors.white70, fontSize: 11)),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: _endLiveSession,
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(host ? 'End' : 'Leave',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// A persistent "return to call" bar shown when a GROUP call is active but its
  /// full-screen UI is minimized — lets the user keep chatting and jump back in,
  /// with a live MM:SS timer, plus a one-tap Leave. Sits above every surface.
  Widget _buildCallReturnBanner(BuildContext context) {
    return rp.Consumer(
      builder: (context, ref, _) {
        // Rebuild whenever the group-call phase changes.
        ref.watch(groupCallProvider);
        final call = GroupCallService.instance;
        // Only when a call is live AND its screen is minimized (not on top).
        if (!call.isActive || _groupCallScreenOpen) {
          return const SizedBox.shrink();
        }
        // Tick the elapsed label once a second while this bar is showing.
        return _CallTicker(
          builder: () {
            final elapsed = call.elapsedLabel;
            final title = call.title.isEmpty ? 'Group call' : call.title;
            return Material(
              color: const Color(0xFF1F8B4C),
              child: InkWell(
                onTap: _openGroupCallScreen,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 7, 6, 7),
                  child: Row(
                    children: [
                      const Icon(Icons.call_rounded,
                          size: 17, color: Colors.white),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          elapsed.isEmpty
                              ? 'Ongoing call · $title'
                              : '$elapsed · $title',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Text('Tap to return',
                          style:
                              TextStyle(color: Colors.white70, fontSize: 11)),
                      const SizedBox(width: 4),
                      TextButton(
                        onPressed: () => GroupCallService.instance.leave(),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          minimumSize: const Size(0, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('Leave',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Return-to-call banner for a MINIMIZED 1:1 (DM) call — the sibling of the
  /// group-call banner above. Shows only while a call is live and its full-
  /// screen UI is minimized; tap to reopen, End to hang up. If the call ends
  /// while minimized, the screen isn't mounted to reset CallService, so we do
  /// it here (otherwise the "ended" state would linger).
  Widget _buildDmCallReturnBanner(BuildContext context) {
    return rp.Consumer(
      builder: (context, ref, _) {
        ref.watch(callProvider);
        ref.listen<CallSnapshot>(callProvider, (prev, next) {
          if (next.state == CallState.ended && !_callScreenOpen) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              CallService.instance.reset();
            });
          }
        });
        final call = CallService.instance;
        if (!call.isActive || _callScreenOpen) {
          return const SizedBox.shrink();
        }
        return _CallTicker(
          builder: () {
            final elapsed = call.elapsedLabel;
            final name = call.peerName.isEmpty ? 'Aluta call' : call.peerName;
            return Material(
              // Call-red, to read distinctly from the group-call green banner.
              color: const Color(0xFFB4322E),
              child: InkWell(
                onTap: _openCallScreen,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 7, 6, 7),
                  child: Row(
                    children: [
                      const Icon(Icons.call_rounded,
                          size: 17, color: Colors.white),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          elapsed.isEmpty
                              ? 'Ongoing call · $name'
                              : '$elapsed · $name',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Text('Tap to return',
                          style:
                              TextStyle(color: Colors.white70, fontSize: 11)),
                      const SizedBox(width: 4),
                      TextButton(
                        onPressed: () => CallService.instance.hangUp(),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          minimumSize: const Size(0, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('End',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
