part of '../chat_page.dart';

// Small, self-contained composer sub-widgets, pulled out of _ChatPageState.
// Each is a pure leaf: it takes a couple of values + a callback and reads its
// colours from the theme — no access to chat state. Behaviour is unchanged from
// the former _buildRecordingBar / _buildEditBanner / _buildOfflineBanner methods.

/// Shown in place of the composer while a voice note is recording.
class _RecordingBar extends StatelessWidget {
  const _RecordingBar({
    required this.durationLabel,
    required this.onCancel,
    required this.onSend,
  });

  final String durationLabel;
  final VoidCallback onCancel;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Cancel',
            icon: Icon(Icons.delete_outline_rounded, color: scheme.error),
            onPressed: onCancel,
          ),
          Container(
            width: 10,
            height: 10,
            decoration:
                BoxDecoration(color: scheme.error, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Text(
            durationLabel,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Recording voice note…',
              style:
                  TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: onSend,
            child: Container(
              width: 46,
              height: 46,
              decoration:
                  BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
              child:
                  const Icon(Icons.send_rounded, color: Colors.white, size: 22),
            ),
          ),
        ],
      ),
    );
  }
}

/// Banner above the composer while a message is being edited.
class _EditBanner extends StatelessWidget {
  const _EditBanner({required this.text, required this.onCancel});

  final String text;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A floating card on the wallpaper (like a bubble), not a flat strip.
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.45)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(Icons.edit_rounded, size: 15, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Editing message',
                  style: TextStyle(
                    color: scheme.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: scheme.onSurface.withAlpha(160), fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            onPressed: onCancel,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

/// Collapsing "you are offline" banner with a reconnect button.
class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({
    required this.isOffline,
    required this.isReconnecting,
    required this.onReconnect,
  });

  final bool isOffline;
  final bool isReconnecting;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A floating pill on the wallpaper rather than a full-width strip.
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      height: isOffline ? 38 : 0,
      margin: isOffline
          ? const EdgeInsets.fromLTRB(10, 6, 10, 0)
          : EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(19),
      ),
      child: isOffline
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(Icons.wifi_off_rounded,
                      size: 15, color: scheme.onErrorContainer),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'You are offline — messages are read-only',
                      style: TextStyle(
                          fontSize: 12, color: scheme.onErrorContainer),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Reconnect button
                  isReconnecting
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: scheme.onErrorContainer,
                          ),
                        )
                      : GestureDetector(
                          onTap: onReconnect,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: scheme.error,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              'Go Online',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: scheme.onError,
                              ),
                            ),
                          ),
                        ),
                ],
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}
