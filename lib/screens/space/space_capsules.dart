part of '../relationship_space_page.dart';

// Split out of relationship_space_page.dart (pure code movement, no behaviour
// change): time capsules, dedications, press-play countdown, voice player. A library `part`, so it shares the page's imports and
// private members.

/// A shared 3-2-1 "press play together" countdown for a sync-listen capsule —
/// a small ritual before the synchronized session starts.
class _PressPlayCountdown extends StatefulWidget {
  const _PressPlayCountdown({required this.accent});
  final Color accent;

  @override
  State<_PressPlayCountdown> createState() => _PressPlayCountdownState();
}

class _PressPlayCountdownState extends State<_PressPlayCountdown> {
  int _n = 3;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _n -= 1);
      if (_n <= 0) {
        _t?.cancel();
        Navigator.of(context).maybePop();
      }
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Press play together',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 18),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            transitionBuilder: (child, anim) => ScaleTransition(
              scale: anim,
              child: FadeTransition(opacity: anim, child: child),
            ),
            child: Container(
              key: ValueKey<int>(_n),
              width: 120,
              height: 120,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    widget.accent,
                    widget.accent.withValues(alpha: 0.7),
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                      color: widget.accent.withValues(alpha: 0.5),
                      blurRadius: 30,
                      spreadRadius: 2),
                ],
              ),
              child: Text(
                _n > 0 ? '$_n' : '♥',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 54,
                    fontWeight: FontWeight.w900),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(_n > 0 ? 'Get ready…' : 'Together 💞',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85), fontSize: 13)),
        ],
      ),
    );
  }
}

/// Compose a love capsule: a song + message sealed until a chosen time. Returns
/// true on a successful seal so the list refreshes.
class _CapsuleComposeSheet extends StatefulWidget {
  const _CapsuleComposeSheet({required this.spaceId, required this.accent});
  final int spaceId;
  final Color accent;

  @override
  State<_CapsuleComposeSheet> createState() => _CapsuleComposeSheetState();
}

class _CapsuleComposeSheetState extends State<_CapsuleComposeSheet> {
  Map<String, dynamic>? _song;
  final TextEditingController _msg = TextEditingController();
  DateTime? _unlockAt;
  String _mode = 'message'; // 'message' | 'sync_listen'
  bool _sending = false;

  @override
  void dispose() {
    _msg.dispose();
    super.dispose();
  }

  Future<void> _pickSong() async {
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _PlaylistAddSheet(accent: widget.accent),
    );
    if (picked != null && mounted) setState(() => _song = picked);
  }

  Future<void> _pickWhen() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _unlockAt ?? now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: DateTime(now.year + 5),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
          _unlockAt ?? now.add(const Duration(hours: 1))),
    );
    if (t == null || !mounted) return;
    setState(() =>
        _unlockAt = DateTime(d.year, d.month, d.day, t.hour, t.minute));
  }

  Future<void> _seal() async {
    final hasSong = _song != null;
    final msg = _msg.text.trim();
    if (!hasSong && msg.isEmpty) {
      showToast(context, 'Add a song or a message.', type: ToastType.info);
      return;
    }
    if (_unlockAt == null) {
      showToast(context, 'Pick when it should unlock.', type: ToastType.info);
      return;
    }
    if (!_unlockAt!.isAfter(DateTime.now())) {
      showToast(context, 'Pick a time in the future.', type: ToastType.info);
      return;
    }
    setState(() => _sending = true);
    final res = await ApiService().createCapsule(
      widget.spaceId,
      trackTitle: _song?['title'] as String?,
      trackArtist: _song?['artist'] as String?,
      trackRef: _song?['ref'] as String?,
      message: msg.isEmpty ? null : msg,
      unlockAtIso: _unlockAt!.toUtc().toIso8601String(),
      mode: _mode,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (res != null) {
      showToast(context, 'Capsule sealed 💌', type: ToastType.success);
      Navigator.pop(context, true);
    } else {
      showToast(context, 'Could not seal the capsule', type: ToastType.error);
    }
  }

  Widget _modeSeg(ColorScheme scheme, String m, IconData icon, String label) {
    final sel = _mode == m;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _mode = m),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            color: sel ? widget.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 16,
                  color: sel ? Colors.white : scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: sel ? Colors.white : scheme.onSurface)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pickTile(
      ColorScheme scheme, IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: widget.accent.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Icon(icon, color: widget.accent, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600)),
            ),
            Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final songLabel = _song == null
        ? 'Add a song (optional)'
        : (((_song!['artist'] ?? '').toString().isNotEmpty)
            ? '${_song!['title']} — ${_song!['artist']}'
            : (_song!['title'] ?? '').toString());
    final whenLabel = _unlockAt == null
        ? 'Choose unlock time'
        : DateFormat('EEE, MMM d · h:mm a').format(_unlockAt!);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Text('Seal a love capsule',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 17,
                    color: scheme.onSurface)),
            const SizedBox(height: 4),
            Text('A song + a message that stays sealed until the moment you '
                'choose.',
                style:
                    TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 14),
            _pickTile(scheme, Icons.music_note_rounded, songLabel, _pickSong),
            const SizedBox(height: 10),
            TextField(
              controller: _msg,
              maxLines: 3,
              maxLength: 600,
              decoration: InputDecoration(
                hintText: 'Write the message they\'ll open…',
                filled: true,
                fillColor: scheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 4),
            _pickTile(scheme, Icons.schedule_rounded, whenLabel, _pickWhen),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  _modeSeg(scheme, 'message', Icons.mail_rounded,
                      'Just a message'),
                  const SizedBox(width: 4),
                  _modeSeg(scheme, 'sync_listen', Icons.headphones_rounded,
                      'Listen together'),
                ],
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _sending ? null : _seal,
                style: FilledButton.styleFrom(
                    backgroundColor: widget.accent,
                    foregroundColor: readableOn(widget.accent)),
                icon: _sending
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: readableOn(widget.accent)))
                    : const Icon(Icons.lock_clock_rounded, size: 18),
                label: Text(_sending ? 'Sealing…' : 'Seal the capsule'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compose a dedication: pick a song, choose a mood, add a line. Returns true on
/// a successful send so the inbox refreshes.
class _DedicateComposeSheet extends StatefulWidget {
  const _DedicateComposeSheet({required this.spaceId, required this.accent});
  final int spaceId;
  final Color accent;

  @override
  State<_DedicateComposeSheet> createState() => _DedicateComposeSheetState();
}

class _DedicateComposeSheetState extends State<_DedicateComposeSheet> {
  Map<String, dynamic>? _song;
  String? _mood;
  final TextEditingController _noteCtrl = TextEditingController();
  bool _sending = false;
  final AudioRecorder _rec = AudioRecorder();
  bool _recording = false;
  String? _voicePath;
  int _voiceMs = 0;
  Timer? _voiceTimer;

  static const List<String> _moods = [
    '❤️ Loved',
    '🥰 Missing you',
    '🌙 Thinking of you',
    '🙏 Grateful',
    '🔥 Hyped',
    '😌 Calm',
    '🎉 Celebrating',
    '😢 Blue',
  ];

  @override
  void dispose() {
    _noteCtrl.dispose();
    _voiceTimer?.cancel();
    _rec.dispose();
    super.dispose();
  }

  Future<void> _toggleRecord() async {
    if (_recording) {
      _voiceTimer?.cancel();
      try {
        final p = await _rec.stop();
        if (!mounted) return;
        setState(() {
          _recording = false;
          _voicePath = p;
        });
      } catch (_) {
        if (mounted) setState(() => _recording = false);
      }
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
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/ded_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _rec.start(
        const RecordConfig(
            encoder: AudioEncoder.aacLc, bitRate: 128000, sampleRate: 44100),
        path: path,
      );
      if (!mounted) return;
      setState(() {
        _recording = true;
        _voiceMs = 0;
        _voicePath = null;
      });
      _voiceTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (mounted) setState(() => _voiceMs += 200);
      });
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not start recording',
            type: ToastType.error);
      }
    }
  }

  void _clearVoice() {
    final p = _voicePath;
    setState(() => _voicePath = null);
    if (p != null) {
      try {
        File(p).delete();
      } catch (_) {}
    }
  }

  String _fmtMs(int ms) {
    final s = (ms / 1000).floor();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Widget _voiceRow(ColorScheme scheme) {
    if (_recording) {
      return Row(
        children: [
          IconButton(
            onPressed: _toggleRecord,
            icon: const Icon(Icons.stop_circle_rounded, color: Colors.red),
          ),
          Text('Recording… ${_fmtMs(_voiceMs)}',
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ],
      );
    }
    if (_voicePath != null) {
      return Row(
        children: [
          Icon(Icons.mic_rounded, size: 18, color: widget.accent),
          const SizedBox(width: 6),
          Text('Voice note (${_fmtMs(_voiceMs)})',
              style: TextStyle(
                  color: scheme.onSurface, fontWeight: FontWeight.w600)),
          const Spacer(),
          IconButton(
            onPressed: _clearVoice,
            icon: Icon(Icons.close_rounded,
                size: 18, color: scheme.onSurfaceVariant),
          ),
        ],
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: _toggleRecord,
        icon: Icon(Icons.mic_none_rounded, color: widget.accent),
        label:
            Text('Add a voice note', style: TextStyle(color: widget.accent)),
      ),
    );
  }

  Future<void> _pickSong() async {
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _PlaylistAddSheet(accent: widget.accent),
    );
    if (picked != null && mounted) setState(() => _song = picked);
  }

  Future<void> _send() async {
    if (_song == null) {
      showToast(context, 'Pick a song to dedicate.', type: ToastType.info);
      return;
    }
    setState(() => _sending = true);
    String? voiceUrl;
    if (_voicePath != null) {
      try {
        final bytes = await File(_voicePath!).readAsBytes();
        if (bytes.isNotEmpty) {
          final up = await ApiService().uploadMedia(
            bytes: bytes,
            filename: _voicePath!.replaceAll('\\', '/').split('/').last,
            mime: 'audio/mp4',
          );
          voiceUrl = up?['url'] as String?;
        }
      } catch (_) {}
    }
    final res = await ApiService().createDedication(
      widget.spaceId,
      title: (_song!['title'] ?? '').toString(),
      artist: _song!['artist'] as String?,
      ref: _song!['ref'] as String?,
      mood: _mood,
      note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
      voiceNoteUrl: voiceUrl,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (res != null) {
      showToast(context, 'Dedication sent 💝', type: ToastType.success);
      Navigator.pop(context, true);
    } else {
      showToast(context, 'Could not send the dedication',
          type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final songLabel = _song == null
        ? 'Pick a song'
        : ((_song!['artist'] ?? '').toString().isNotEmpty
            ? '${_song!['title']} — ${_song!['artist']}'
            : (_song!['title'] ?? '').toString());
    return Padding(
      padding: EdgeInsets.fromLTRB(18, 14, 18, 18 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Dedicate a song 💝',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurface)),
          const SizedBox(height: 14),
          InkWell(
            onTap: _pickSong,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: _song == null
                        ? scheme.outlineVariant
                        : widget.accent.withValues(alpha: 0.5)),
              ),
              child: Row(
                children: [
                  Icon(Icons.library_music_rounded,
                      size: 20, color: widget.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(songLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: _song == null
                                ? scheme.onSurfaceVariant
                                : scheme.onSurface,
                            fontWeight: FontWeight.w600)),
                  ),
                  Icon(Icons.chevron_right_rounded,
                      color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text('Mood',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in _moods)
                GestureDetector(
                  onTap: () =>
                      setState(() => _mood = (_mood == m) ? null : m),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: _mood == m
                          ? widget.accent.withValues(alpha: 0.18)
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: _mood == m
                              ? widget.accent
                              : Colors.transparent),
                    ),
                    child: Text(m,
                        style: TextStyle(
                            fontSize: 12.5,
                            color: scheme.onSurface,
                            fontWeight: _mood == m
                                ? FontWeight.w700
                                : FontWeight.w500)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _noteCtrl,
            minLines: 1,
            maxLines: 3,
            maxLength: 300,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: 'A line, if you like…',
              filled: true,
              fillColor: scheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 10),
          _voiceRow(scheme),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: widget.accent),
              onPressed: _sending ? null : _send,
              icon: const Icon(Icons.send_rounded, size: 18),
              label: Text(_sending ? 'Sending…' : 'Send dedication'),
            ),
          ),
        ],
      ),
    );
  }
}

class _DedVoicePlayer extends StatefulWidget {
  const _DedVoicePlayer({required this.url, required this.accent});
  final String url;
  final Color accent;

  @override
  State<_DedVoicePlayer> createState() => _DedVoicePlayerState();
}

class _DedVoicePlayerState extends State<_DedVoicePlayer> {
  final ja.AudioPlayer _p = ja.AudioPlayer();
  bool _playing = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _load();
    _p.playerStateStream.listen((st) {
      if (!mounted) return;
      final done = st.processingState == ja.ProcessingState.completed;
      setState(() => _playing = st.playing && !done);
      if (done) {
        _p.seek(Duration.zero);
        _p.pause();
      }
    });
  }

  Future<void> _load() async {
    try {
      final full = widget.url.startsWith('http')
          ? widget.url
          : '${await AppConfig.baseUrl}${widget.url}';
      await _p.setUrl(full, headers: mediaAuthHeaders(full));
      if (mounted) setState(() => _ready = true);
    } catch (_) {}
  }

  @override
  void dispose() {
    _p.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: !_ready ? null : () => _playing ? _p.pause() : _p.play(),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: widget.accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: widget.accent),
            const SizedBox(width: 6),
            Text(_ready ? 'Voice note' : 'Loading…',
                style: TextStyle(
                    color: scheme.onSurface, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
