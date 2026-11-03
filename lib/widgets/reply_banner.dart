import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../screens/api_service.dart';
import '../utils/readable.dart';
import '../utils/toast_helper.dart';

/// Aluta's own message banner while the app is open: slides down from the
/// top when a message arrives for a chat that isn't on screen.
///
/// * Untouched, it slides away after a few seconds.
/// * Tap it → open the chat.
/// * Reply → a mini composer opens INSIDE the banner (same send button as
///   the chat, plus the mic for a voice note). From then on the banner
///   STAYS — tapping elsewhere never loses your draft — until you send it
///   or close it with ×.
class ReplyBanner {
  static OverlayEntry? _entry;
  static final GlobalKey<_ReplyBannerViewState> _key = GlobalKey();
  static String? _lastMessageId;

  /// Set by the home page while the app is up: an incoming chat message
  /// (from the live socket OR a foreground push) shows THIS banner instead
  /// of Android's notification — the reply box there loses your draft on a
  /// stray tap and its send arrow is the phone's, not Aluta's.
  static void Function({
    required String title,
    required String body,
    String? senderId,
    String? conversationId,
    String? groupTitle,
    String? messageId,
  })? onIncoming;

  /// True while the user is writing / recording a reply in the banner.
  static bool get busy => _key.currentState?._engaged ?? false;

  static void show(
    BuildContext context, {
    required String title,
    required String body,
    int? friendId,
    int? conversationId,
    required VoidCallback onOpen,
    required VoidCallback onVoiceInChat,
    String? messageId,
  }) {
    // Never replace a banner the user is writing in.
    if (busy) return;
    // Socket + push both report the same message → show it once.
    if (messageId != null && messageId.isNotEmpty) {
      if (messageId == _lastMessageId && _entry != null) return;
      _lastMessageId = messageId;
    }
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    hide();
    final entry = OverlayEntry(
      builder: (_) => _ReplyBannerView(
        key: _key,
        title: title,
        body: body,
        friendId: friendId,
        conversationId: conversationId,
        onOpen: () {
          hide();
          onOpen();
        },
        onVoiceInChat: () {
          hide();
          onVoiceInChat();
        },
        onClose: hide,
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  static void hide() {
    final e = _entry;
    _entry = null;
    if (e != null && e.mounted) e.remove();
  }
}

class _ReplyBannerView extends StatefulWidget {
  const _ReplyBannerView({
    super.key,
    required this.title,
    required this.body,
    required this.friendId,
    required this.conversationId,
    required this.onOpen,
    required this.onVoiceInChat,
    required this.onClose,
  });
  final String title;
  final String body;
  final int? friendId;
  final int? conversationId;
  final VoidCallback onOpen;
  final VoidCallback onVoiceInChat;
  final VoidCallback onClose;

  @override
  State<_ReplyBannerView> createState() => _ReplyBannerViewState();
}

class _ReplyBannerViewState extends State<_ReplyBannerView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 280))
    ..forward();
  final _text = TextEditingController();
  final _focus = FocusNode();
  Timer? _autoHide;
  bool _replying = false;
  bool _sending = false;

  // Voice note
  final _rec = AudioRecorder();
  bool _recording = false;
  int _recMs = 0;
  Timer? _recTimer;

  bool get _engaged => _replying || _recording || _text.text.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    _autoHide = Timer(const Duration(seconds: 6), _leave);
  }

  @override
  void dispose() {
    _autoHide?.cancel();
    _recTimer?.cancel();
    _rec.dispose();
    _text.dispose();
    _focus.dispose();
    _in.dispose();
    super.dispose();
  }

  Future<void> _leave() async {
    if (!mounted || _engaged) return;
    await _in.reverse();
    widget.onClose();
  }

  void _startReply() {
    _autoHide?.cancel();
    setState(() => _replying = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  Future<void> _close() async {
    _autoHide?.cancel();
    if (_recording) await _cancelRecording();
    _focus.unfocus();
    await _in.reverse();
    widget.onClose();
  }

  Future<void> _sendText() async {
    final t = _text.text.trim();
    if (t.isEmpty || _sending) return;
    setState(() => _sending = true);
    final res = await ApiService().sendMessage(widget.friendId ?? 0, t,
        conversationId: widget.conversationId);
    if (!mounted) return;
    setState(() => _sending = false);
    if (res == null) {
      showToast(context, "Couldn't send — check your connection",
          type: ToastType.error);
      return; // keep the draft
    }
    HapticFeedback.lightImpact();
    _text.clear();
    _replying = false;
    _close();
  }

  // ── voice ───────────────────────────────────────────────────────────────
  Future<void> _startRecording() async {
    // Web has no temp files for the recorder → record in the chat instead.
    if (kIsWeb) {
      widget.onVoiceInChat();
      return;
    }
    try {
      if (!await _rec.hasPermission()) {
        if (mounted) {
          showToast(context, 'Microphone permission needed',
              type: ToastType.error);
        }
        return;
      }
      _autoHide?.cancel();
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _rec.start(
        const RecordConfig(
            encoder: AudioEncoder.aacLc, bitRate: 128000, sampleRate: 44100),
        path: path,
      );
      _recMs = 0;
      _recTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (mounted) setState(() => _recMs += 200);
      });
      setState(() {
        _recording = true;
        _replying = true;
      });
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not start recording', type: ToastType.error);
      }
    }
  }

  Future<void> _cancelRecording() async {
    _recTimer?.cancel();
    try {
      final p = await _rec.stop();
      if (p != null) await File(p).delete();
    } catch (_) {}
    if (mounted) setState(() => _recording = false);
  }

  Future<void> _sendRecording() async {
    _recTimer?.cancel();
    final ms = _recMs;
    setState(() {
      _recording = false;
      _sending = true;
    });
    try {
      final path = await _rec.stop();
      if (path == null) return;
      final bytes = await File(path).readAsBytes();
      try {
        await File(path).delete();
      } catch (_) {}
      if (bytes.isEmpty || ms < 700) {
        if (mounted) showToast(context, 'Hold longer to record');
        return;
      }
      final api = ApiService();
      final up = await api.uploadMedia(
          bytes: bytes, filename: 'voice_$ms.m4a', mime: 'audio/mp4');
      final url = up?['url'] as String?;
      final res = url == null
          ? null
          : await api.sendMessage(widget.friendId ?? 0, '',
              conversationId: widget.conversationId,
              messageType: 'audio',
              mediaUrl: url,
              mediaName: (up?['name'] ?? 'voice_$ms.m4a') as String?,
              mediaMime: 'audio/mp4',
              mediaSize: (up?['size'] as num?)?.toInt(),
              mediaDuration: ms);
      if (!mounted) return;
      if (res == null) {
        showToast(context, "Couldn't send the voice note",
            type: ToastType.error);
        return;
      }
      HapticFeedback.lightImpact();
      _replying = false;
      _close();
    } catch (_) {
      if (mounted) {
        showToast(context, "Couldn't send the voice note",
            type: ToastType.error);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _fmt(int ms) {
    final s = ms ~/ 1000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final media = MediaQuery.of(context);
    final a = scheme.primary;
    final hasText = _text.text.trim().isNotEmpty;
    final initial =
        widget.title.trim().isEmpty ? '?' : widget.title.trim()[0].toUpperCase();

    Widget sendBtn({required bool send, required VoidCallback? onTap}) =>
        // Same as the chat composer: solid brand disc with a white send
        // arrow while typing; a soft tinted disc with the mic when empty.
        GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: send
                  ? a
                  : Color.alphaBlend(
                      a.withValues(alpha: isDark ? 0.18 : 0.10),
                      scheme.surface),
              shape: BoxShape.circle,
              border: Border.all(
                  color: send
                      ? Colors.transparent
                      : a.withValues(alpha: isDark ? 0.40 : 0.28)),
              boxShadow: [
                BoxShadow(
                  color: (send ? a : Colors.black)
                      .withValues(alpha: send ? 0.40 : (isDark ? 0.45 : 0.16)),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: _sending
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: send ? readableOn(a) : a),
                  )
                : Icon(send ? Icons.send_rounded : Icons.mic_rounded,
                    size: 20,
                    color: send
                        ? readableOn(a)
                        : (isDark ? const Color(0xFFFF8A93) : a)),
          ),
        );

    final composer = _recording
        ? Row(children: [
            IconButton(
              tooltip: 'Cancel',
              icon: Icon(Icons.delete_outline_rounded, color: scheme.error),
              onPressed: _cancelRecording,
            ),
            Container(
              width: 9,
              height: 9,
              decoration: const BoxDecoration(
                  color: Colors.redAccent, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(_fmt(_recMs),
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                    fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Recording voice note…',
                  style: TextStyle(
                      fontSize: 12.5, color: scheme.onSurfaceVariant)),
            ),
            sendBtn(send: true, onTap: _sending ? null : _sendRecording),
          ])
        : Row(children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: a.withValues(alpha: 0.25)),
                ),
                child: TextField(
                  controller: _text,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _sendText(),
                  decoration: const InputDecoration(
                    hintText: 'Write a reply…',
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 11),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            sendBtn(
                send: hasText,
                onTap: _sending
                    ? null
                    : (hasText ? _sendText : _startRecording)),
          ]);

    return Positioned(
      top: media.padding.top + 8,
      left: 10,
      right: 10,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, -1.4), end: Offset.zero)
            .animate(CurvedAnimation(parent: _in, curve: Curves.easeOutCubic)),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: GestureDetector(
              // Swipe up to dismiss (only while not writing).
              onVerticalDragEnd: (d) {
                if ((d.primaryVelocity ?? 0) < -200 && !_engaged) _close();
              },
              child: Material(
                color: scheme.surface,
                elevation: 10,
                shadowColor: Colors.black54,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: a.withValues(alpha: 0.30)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: _engaged ? null : widget.onOpen,
                        child: Row(children: [
                          CircleAvatar(
                            radius: 18,
                            backgroundColor: a.withValues(alpha: 0.18),
                            child: Text(initial,
                                style: TextStyle(
                                    color: a, fontWeight: FontWeight.w800)),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(widget.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        color: scheme.onSurface)),
                                Text(widget.body,
                                    maxLines: _replying ? 2 : 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: scheme.onSurfaceVariant)),
                              ],
                            ),
                          ),
                          if (!_replying)
                            TextButton(
                              onPressed: _startReply,
                              child: const Text('Reply'),
                            ),
                          IconButton(
                            tooltip: 'Close',
                            visualDensity: VisualDensity.compact,
                            icon: Icon(Icons.close_rounded,
                                size: 20,
                                color: scheme.onSurfaceVariant),
                            onPressed: _close,
                          ),
                        ]),
                      ),
                      if (_replying) ...[
                        const SizedBox(height: 8),
                        composer,
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
