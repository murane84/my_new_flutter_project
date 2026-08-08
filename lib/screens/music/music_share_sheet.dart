part of '../music_controls.dart';

// Share a song into a chat: send the actual audio FILE (async attachment, ≤15 MB)
// or a "now playing" text RECOMMENDATION. Reuses the existing chat attachment
// pipeline (ApiService.uploadMedia + sendMessage) — this is asynchronous, unlike
// the WebRTC path used for live calls / Listen-Together.

class _ShareSheet extends StatefulWidget {
  final String path;
  final String title;
  final String artist;

  const _ShareSheet({
    required this.path,
    required this.title,
    required this.artist,
  });

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  static const int _maxBytes = 15 * 1024 * 1024;

  bool _asFile = true; // true = send file, false = recommend as text
  bool _sending = false;
  int? _sendingTo; // friend id currently being sent to
  late final Future<List<Map<String, dynamic>>> _friends;

  @override
  void initState() {
    super.initState();
    _friends = ApiService().getFriends();
  }

  String _guessMime() {
    final p = widget.path.toLowerCase();
    if (p.endsWith('.mp3')) return 'audio/mpeg';
    if (p.endsWith('.m4a') || p.endsWith('.aac')) return 'audio/mp4';
    if (p.endsWith('.wav')) return 'audio/wav';
    if (p.endsWith('.ogg') || p.endsWith('.opus')) return 'audio/ogg';
    if (p.endsWith('.flac')) return 'audio/flac';
    return 'audio/mpeg';
  }

  String _fileName() =>
      widget.path.replaceAll('\\', '/').split('/').last;

  Future<void> _send(Map<String, dynamic> friend) async {
    if (_sending) return;
    final id = (friend['id'] as num?)?.toInt();
    if (id == null) return;
    final name = (friend['username'] ?? 'friend').toString();
    setState(() {
      _sending = true;
      _sendingTo = id;
    });
    try {
      final api = ApiService();
      if (_asFile) {
        final file = File(widget.path);
        final len = await file.length();
        if (len > _maxBytes) {
          if (mounted) {
            showToast(context, 'Song is too large to send (max 15 MB)',
                type: ToastType.error);
            setState(() {
              _sending = false;
              _sendingTo = null;
            });
          }
          return;
        }
        final bytes = await file.readAsBytes();
        final up = await api.uploadMedia(
            bytes: bytes, filename: _fileName(), mime: _guessMime());
        if (up == null || up['url'] == null) throw Exception('upload failed');
        final ok = await api.sendMessage(
          id,
          widget.title,
          messageType: 'audio',
          mediaUrl: up['url'].toString(),
          mediaName: (up['name'] ?? _fileName()).toString(),
          mediaMime: (up['mime'] ?? _guessMime()).toString(),
          mediaSize: (up['size'] as num?)?.toInt() ?? len,
        );
        if (ok == null) throw Exception('send failed');
      } else {
        final artist = widget.artist.trim();
        final msg =
            '🎵 Now playing: ${widget.title}${artist.isNotEmpty ? ' — $artist' : ''}';
        final ok = await api.sendMessage(id, msg, messageType: 'text');
        if (ok == null) throw Exception('send failed');
      }
      if (mounted) {
        Navigator.pop(context);
        showToast(context,
            _asFile ? 'Song sent to $name' : 'Recommended to $name',
            type: ToastType.success);
      }
    } catch (_) {
      if (mounted) {
        showToast(context, 'Couldn’t share — check your connection',
            type: ToastType.error);
        setState(() {
          _sending = false;
          _sendingTo = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, sc) => Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 42,
              height: 5,
              decoration: BoxDecoration(
                color: scheme.onSurfaceVariant.withAlpha(90),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            // Header.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.share_rounded, color: scheme.primary, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Share to chat',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15)),
                        Text(
                          widget.artist.isEmpty
                              ? widget.title
                              : '${widget.title} — ${widget.artist}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Mode toggle (matches the playlist chip style).
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  ChoiceChip(
                    label: const Text('Send file'),
                    selected: _asFile,
                    showCheckmark: false,
                    selectedColor: scheme.primary,
                    labelStyle: TextStyle(
                        color: _asFile ? scheme.onPrimary : scheme.onSurface),
                    onSelected: (_) => setState(() => _asFile = true),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('Recommend'),
                    selected: !_asFile,
                    showCheckmark: false,
                    selectedColor: scheme.primary,
                    labelStyle: TextStyle(
                        color: !_asFile ? scheme.onPrimary : scheme.onSurface),
                    onSelected: (_) => setState(() => _asFile = false),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _asFile
                      ? 'Send the audio file — they can play or save it.'
                      : 'Send a text recommendation (no file).',
                  style:
                      TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                ),
              ),
            ),
            Divider(height: 1, color: scheme.outlineVariant.withAlpha(70)),
            // Friend picker.
            Expanded(
              child: FutureBuilder<List<Map<String, dynamic>>>(
                future: _friends,
                builder: (ctx, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return Center(
                      child: CircularProgressIndicator(
                          strokeWidth: 2.4, color: scheme.primary),
                    );
                  }
                  final friends = snap.data ?? const [];
                  if (friends.isEmpty) {
                    return Center(
                      child: Text('No contacts yet',
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                    );
                  }
                  return ListView.builder(
                    controller: sc,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: friends.length,
                    itemBuilder: (_, i) {
                      final f = friends[i];
                      final uname = (f['username'] ?? 'Friend').toString();
                      final fid = (f['id'] as num?)?.toInt();
                      final busy = _sendingTo != null && _sendingTo == fid;
                      return ListTile(
                        leading: CircleAvatar(
                          radius: 18,
                          backgroundColor: scheme.primaryContainer,
                          child: Text(
                            uname.isNotEmpty ? uname[0].toUpperCase() : '?',
                            style: TextStyle(
                                color: scheme.onPrimaryContainer,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                        title: Text(uname,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: busy
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: scheme.primary),
                              )
                            : Icon(_asFile
                                ? Icons.send_rounded
                                : Icons.recommend_rounded),
                        enabled: !_sending,
                        onTap: () => _send(f),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
