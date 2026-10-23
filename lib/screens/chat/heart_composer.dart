part of '../chat_page.dart';

// ── Secret heart: love-letter composer + receipts ───────────────────────────
// When the composer's ❤ toggle is on, a small tray rides above the input:
// pick the heart's mood (colour + cover + letter title), seal it until a
// moment ("Tonight 8 PM", "Tomorrow morning", a date…), and tap a prompt to
// start the note. Server side: my_aluta_api/hearts.py.

/// What a secret heart carries inside besides words: ONE photo, a short video
/// clip (≤ 30 s) or a voice clip (≤ 60 s). Uploaded when the heart is sent;
/// the server withholds it from anyone the heart isn't for.
class _HeartAttach {
  const _HeartAttach({
    required this.bytes,
    required this.name,
    required this.mime,
    required this.kind,
    this.durationMs,
  });
  final List<int> bytes;
  final String name;
  final String mime;
  final String kind; // photo | video | voice | song
  final int? durationMs;

  String get label => switch (kind) {
        'video' => 'Video clip',
        'voice' => 'Voice clip',
        'song' => 'Song',
        _ => 'Photo',
      };
  IconData get icon => switch (kind) {
        'video' => Icons.videocam_rounded,
        'voice' => Icons.mic_rounded,
        'song' => Icons.music_note_rounded,
        _ => Icons.photo_rounded,
      };
}

const int _kHeartClipMaxMs = 30500;
const int _kHeartVoiceMaxMs = 60000;
const int _kHeartMediaMaxBytes = 40 * 1024 * 1024;

extension _ChatHeartComposer on _ChatPageState {
  // ── What's sealed inside ───────────────────────────────────────────────────

  Future<void> _pickHeartAttach() async {
    final scheme = Theme.of(context).colorScheme;
    final tint = HeartMood.of(_heartMood).color;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Widget tile(String id, IconData icon, String title,
                  [String? sub]) =>
              ListTile(
                dense: true,
                leading: Icon(icon, color: tint),
                title: Text(title),
                subtitle: sub == null ? null : Text(sub),
                onTap: () => Navigator.pop(ctx, id),
              );
          return SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                    child: Text('Seal something inside 💌',
                        style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                            color: scheme.onSurface)),
                  ),
                  // The in-app camera works on phones, computers and the web.
                  tile('shoot', Icons.photo_camera_rounded, 'Take a photo'),
                  tile('record', Icons.videocam_rounded, 'Record a video',
                      'Stops by itself at 30 seconds'),
                  tile('photo', Icons.photo_library_rounded,
                      'Photo from gallery'),
                  tile('video', Icons.video_library_rounded,
                      'Video from gallery', 'Up to 30 seconds'),
                  tile('voice', Icons.mic_rounded, 'Voice clip',
                      'Up to 1 minute — hold the mic'),
                  tile('song', Icons.music_note_rounded, 'Dedicate a song',
                      'From your music or any audio file'),
                  if (_heartAttach != null)
                    ListTile(
                      dense: true,
                      leading: Icon(Icons.delete_outline_rounded,
                          color: scheme.error),
                      title: Text(
                          'Remove ${_heartAttach!.label.toLowerCase()}'),
                      onTap: () => Navigator.pop(ctx, 'remove'),
                    ),
                  const Divider(height: 12),
                  // View-only by default: a secret stays a secret unless the
                  // sender chooses otherwise.
                  SwitchListTile(
                    dense: true,
                    secondary: Icon(Icons.download_rounded, color: tint),
                    title: const Text('Let them save it'),
                    subtitle: Text(_heartSave
                        ? 'They can keep the photo, clip or song'
                        : 'View only — no save button'),
                    value: _heartSave,
                    activeThumbColor: tint,
                    onChanged: (v) {
                      rebuildWith(() => _heartSave = v);
                      setSheet(() {});
                    },
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'shoot':
        await _heartPickVisual(video: false, camera: true);
      case 'record':
        await _heartPickVisual(video: true, camera: true);
      case 'photo':
        await _heartPickVisual(video: false);
      case 'video':
        await _heartPickVisual(video: true);
      case 'voice':
        if (_heartAttach != null) rebuildWith(() => _heartAttach = null);
        showToast(
            context,
            _ctrl.text.trim().isEmpty
                ? 'Hold 🎤 to record your voice clip — words can follow'
                : 'Record first: clear the words, hold 🎤, then write again');
      case 'song':
        await _pickHeartSong();
      case 'remove':
        rebuildWith(() => _heartAttach = null);
    }
  }

  /// Photo / video for the heart — from the gallery or the in-app camera.
  Future<void> _heartPickVisual({required bool video, bool camera = false}) async {
    try {
      XFile? x;
      var isVideo = video;
      if (camera) {
        final r = await captureMedia(context,
            allowVideo: video,
            maxVideoDuration: const Duration(seconds: 30));
        if (r == null) return;
        x = r.file;
        isVideo = r.isVideo;
      } else {
        x = video
            ? await ImagePicker().pickVideo(
                source: ImageSource.gallery,
                maxDuration: const Duration(seconds: 30))
            : await ImagePicker().pickImage(
                source: ImageSource.gallery, imageQuality: 90, maxWidth: 2048);
      }
      if (x == null || !mounted) return;
      await _heartUseFile(x, video: isVideo);
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not add that', type: ToastType.error);
      }
    }
  }

  Future<void> _heartUseFile(XFile x, {required bool video}) async {
    var bytes = await x.readAsBytes();
    final ext = x.name.contains('.')
        ? x.name.split('.').last.toLowerCase()
        : (video ? 'mp4' : 'jpg');
    var mime = video
        ? (ext == 'mov'
            ? 'video/quicktime'
            : (ext == 'webm' ? 'video/webm' : 'video/mp4'))
        : (ext == 'png'
            ? 'image/png'
            : (ext == 'gif'
                ? 'image/gif'
                : (ext == 'webp' ? 'image/webp' : 'image/jpeg')));
    var name = x.name.isNotEmpty
        ? x.name
        : 'heart_${video ? 'clip.mp4' : 'photo.jpg'}';
    int? durMs;
    if (video && !kIsWeb && _isMobile) {
      try {
        final info = await VideoCompress.getMediaInfo(x.path);
        durMs = info.duration?.round();
      } catch (_) {}
      if (durMs != null && durMs > _kHeartClipMaxMs) {
        if (mounted) {
          showToast(context, 'Heart clips are up to 30 seconds — pick a shorter one',
              type: ToastType.error);
        }
        return;
      }
      if (bytes.length > 12 * 1024 * 1024) {
        try {
          final info = await VideoCompress.compressVideo(x.path,
              quality: VideoQuality.MediumQuality,
              deleteOrigin: false,
              includeAudio: true);
          final cb = await info?.file?.readAsBytes();
          if (cb != null && cb.isNotEmpty && cb.length < bytes.length) {
            bytes = cb;
            mime = 'video/mp4';
            final dot = name.lastIndexOf('.');
            name = '${dot > 0 ? name.substring(0, dot) : name}.mp4';
          }
        } catch (_) {}
      }
    }
    if (bytes.length > _kHeartMediaMaxBytes) {
      if (mounted) {
        showToast(context, 'That one is too big for a heart (max 40 MB)',
            type: ToastType.error);
      }
      return;
    }
    if (!mounted) return;
    rebuildWith(() => _heartAttach = _HeartAttach(
        bytes: bytes,
        name: name,
        mime: mime,
        kind: video ? 'video' : 'photo',
        durationMs: durMs));
  }

  // ── Dedicate a song ────────────────────────────────────────────────────────

  static String _audioMime(String ext) => switch (ext) {
        'mp3' => 'audio/mpeg',
        'm4a' || 'mp4' => 'audio/mp4',
        'aac' => 'audio/aac',
        'ogg' || 'opus' => 'audio/ogg',
        'wav' => 'audio/wav',
        'flac' => 'audio/flac',
        _ => 'audio/mpeg',
      };

  /// A song from my music library (phones) or any audio file.
  Future<void> _pickHeartSong() async {
    // Phones: the same library the music player uses, searchable.
    if (!kIsWeb && _isMobile) {
      List<dynamic> lib = const [];
      try {
        lib = await SongLibrary.songs();
      } catch (_) {}
      if (!mounted) return;
      if (lib.isNotEmpty) {
        final picked = await _heartSongSheet(lib);
        if (!mounted || picked == null) return;
        if (picked == 'files') {
          await _heartSongFromFiles();
          return;
        }
        await _heartUseSong(
          path: picked.data as String,
          title: (picked.title as String?) ?? 'Song',
          artist: picked.artist as String?,
          durationMs: picked.duration as int?,
        );
        return;
      }
    }
    await _heartSongFromFiles();
  }

  Future<dynamic> _heartSongSheet(List<dynamic> lib) {
    final scheme = Theme.of(context).colorScheme;
    final tint = HeartMood.of(_heartMood).color;
    var q = '';
    return showModalBottomSheet<dynamic>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        final ql = q.toLowerCase();
        final shown = ql.isEmpty
            ? lib
            : lib
                .where((s) =>
                    ((s.title as String?) ?? '').toLowerCase().contains(ql) ||
                    ((s.artist as String?) ?? '').toLowerCase().contains(ql))
                .toList();
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.72,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    autofocus: false,
                    onChanged: (v) => setSheet(() => q = v),
                    decoration: InputDecoration(
                      hintText: 'Find a song to dedicate…',
                      prefixIcon: Icon(Icons.search_rounded, color: tint),
                      isDense: true,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
                ListTile(
                  dense: true,
                  leading: Icon(Icons.folder_open_rounded, color: tint),
                  title: const Text('Browse audio files…'),
                  onTap: () => Navigator.pop(ctx, 'files'),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (_, i) {
                      final s = shown[i];
                      final artist = (s.artist as String?) ?? '';
                      return ListTile(
                        dense: true,
                        leading: Icon(Icons.music_note_rounded, color: tint),
                        title: Text((s.title as String?) ?? 'Song',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: artist.isEmpty || artist == '<unknown>'
                            ? null
                            : Text(artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: scheme.onSurfaceVariant)),
                        onTap: () => Navigator.pop(ctx, s),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }

  Future<void> _heartSongFromFiles() async {
    try {
      final res = await FilePicker.pickFiles(type: FileType.audio);
      final f = res?.files.single;
      if (f == null || !mounted) return;
      final dot = f.name.lastIndexOf('.');
      final base = dot > 0 ? f.name.substring(0, dot) : f.name;
      // readAsBytes works on every platform (web included) with this
      // file_picker version — no withData / .bytes needed.
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty || !mounted) return;
      await _heartUseSongBytes(bytes: bytes, fileName: f.name, title: base);
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not add that song', type: ToastType.error);
      }
    }
  }

  Future<void> _heartUseSong({
    required String path,
    required String title,
    String? artist,
    int? durationMs,
  }) async {
    try {
      final bytes = await File(path).readAsBytes();
      final fileName = path.split(RegExp(r'[\\/]')).last;
      await _heartUseSongBytes(
          bytes: bytes,
          fileName: fileName,
          title: title,
          artist: artist,
          durationMs: durationMs);
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not read that song', type: ToastType.error);
      }
    }
  }

  Future<void> _heartUseSongBytes({
    required List<int> bytes,
    required String fileName,
    required String title,
    String? artist,
    int? durationMs,
  }) async {
    if (bytes.length > _kHeartMediaMaxBytes) {
      if (mounted) {
        showToast(context, 'That song is too big for a heart (max 40 MB)',
            type: ToastType.error);
      }
      return;
    }
    final ext = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : 'mp3';
    final a = (artist ?? '').trim();
    final shown = (a.isEmpty || a == '<unknown>') ? title : '$a - $title';
    final safe = shown.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();
    if (!mounted) return;
    rebuildWith(() => _heartAttach = _HeartAttach(
        bytes: bytes,
        name: '$safe.$ext',
        mime: _audioMime(ext),
        kind: 'song',
        durationMs: durationMs));
  }

  // ── Showing it ─────────────────────────────────────────────────────────────

  /// 'photo' | 'video' | 'voice' | 'song' for a heart carrying media (from its
  /// mime — a locked copy keeps the kind so the cover can hint at it). Voice
  /// clips are recorded as heart_voice_*; any other audio is a dedicated song.
  String? _heartMediaKind(Map<String, dynamic> msg) {
    final mime = (msg['media_mime'] ?? '').toString().toLowerCase();
    if (mime.startsWith('image/')) return 'photo';
    if (mime.startsWith('video/')) return 'video';
    if (mime.startsWith('audio/')) {
      final name = (msg['media_name'] ?? '').toString();
      return name.startsWith('heart_voice_') ? 'voice' : 'song';
    }
    return null;
  }

  /// A group heart meant for someone other than me (and not sent by me).
  bool _heartLockedForMe(Map<String, dynamic> msg) {
    if (msg['heart_locked'] == true) return true;
    final f = msg['heart_for']?.toString();
    if (f == null || f.isEmpty || _myId == null) return false;
    return f != _myId && msg['sender_id']?.toString() != _myId;
  }

  /// "you", or the first name of the member a group heart is for.
  String? _heartForLabel(Map<String, dynamic> msg) {
    final f = msg['heart_for']?.toString();
    if (f == null || f.isEmpty) return null;
    if (f == _myId) return 'you';
    final known = (msg['heart_for_name'] ?? '').toString();
    if (known.isNotEmpty) return known;
    for (final m in _groupMembers) {
      if (m['user_id']?.toString() == f) {
        return _memberName(m).split(' ').first;
      }
    }
    return 'someone';
  }

  /// The sender chose "Let them save it" (and I always may keep my own).
  bool _heartMaySave(Map<String, dynamic> msg) =>
      msg['heart_save'] == true || msg['sender_id']?.toString() == _myId;

  /// A heart's photo, full screen — its own viewer (never mixed into the
  /// thread's gallery), with Save only when the sender allowed it.
  void _openHeartPhoto(String url, Map<String, dynamic> msg) {
    final maySave = _heartMaySave(msg);
    showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      builder: (dctx) => Stack(
        fit: StackFit.expand,
        children: [
          InteractiveViewer(
            maxScale: 5,
            child: Center(
              child: authNetworkImage(
                  url: url,
                  headers: mediaAuthHeaders(url),
                  fit: BoxFit.contain),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (maySave)
                    IconButton(
                      tooltip: 'Save to device',
                      icon: const Icon(Icons.download_rounded,
                          color: Colors.white),
                      onPressed: () => _saveMediaToDevice(msg),
                    ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                    onPressed: () => Navigator.of(dctx).pop(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// A small frosted "Save" chip over the letter's media (when allowed).
  Widget _heartSaveChip(Map<String, dynamic> msg) => Material(
        color: Colors.black.withValues(alpha: 0.45),
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => _saveMediaToDevice(msg),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.download_rounded, size: 15, color: Colors.white),
              SizedBox(width: 4),
              Text('Save',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      );

  /// Draws a heart's photo / video clip / voice clip / song on its letter.
  Widget Function(double width)? _heartMediaBuilder(Map<String, dynamic> msg) {
    final rel = (msg['media_url'] ?? '').toString();
    final kind = _heartMediaKind(msg);
    if (rel.isEmpty || kind == null || _heartLockedForMe(msg)) return null;
    final url = fullMediaUrl(rel);
    final maySave = _heartMaySave(msg);
    final playKey = 'heart-${msg['id']}';
    Widget withSave(Widget child) => !maySave
        ? child
        : Stack(children: [
            child,
            Positioned(top: 8, right: 8, child: _heartSaveChip(msg)),
          ]);
    switch (kind) {
      case 'photo':
        return (w) => withSave(GestureDetector(
              onTap: () => _openHeartPhoto(url, msg),
              child: authNetworkImage(
                url: url,
                headers: mediaAuthHeaders(url),
                width: w,
                height: w * 0.8,
                fit: BoxFit.cover,
              ),
            ));
      case 'video':
        return (w) => withSave(GestureDetector(
              onTap: () {
                _galleryVideoPauseAll.value++;
                showDialog<void>(
                  context: context,
                  barrierColor: Colors.black,
                  builder: (_) => _ChatVideoPlayer(url: url),
                );
              },
              child: Container(
                width: w,
                height: w * 9 / 16,
                color: Colors.black.withValues(alpha: 0.55),
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 54,
                      height: 54,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.92),
                      ),
                      child: const Icon(Icons.play_arrow_rounded,
                          size: 34, color: Colors.black87),
                    ),
                    const SizedBox(height: 8),
                    Text('Play the clip',
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.9),
                            fontWeight: FontWeight.w700,
                            fontSize: 12.5)),
                  ],
                ),
              ),
            ));
      case 'voice':
        return (w) => Container(
              width: w,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              color: Colors.white.withValues(alpha: 0.14),
              child: Row(children: [
                Expanded(
                  child: _VoiceNotePlayer(
                    url: url,
                    durationMs: (msg['media_duration'] as num?)?.toInt() ?? 0,
                    accent: Colors.white,
                    onColor: Colors.white,
                    onPlaying: heartPlaybackReporter(playKey),
                  ),
                ),
                if (maySave)
                  IconButton(
                    tooltip: 'Save to device',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.download_rounded,
                        color: Colors.white, size: 20),
                    onPressed: () => _saveMediaToDevice(msg),
                  ),
              ]),
            );
      case 'song':
        final name = (msg['media_name'] ?? 'Song').toString();
        final dot = name.lastIndexOf('.');
        final title = dot > 0 ? name.substring(0, dot) : name;
        return (w) => Container(
              width: w,
              color: Colors.white.withValues(alpha: 0.14),
              child: _SongBubble(
                assetId: SongCache.assetId(rel),
                url: url,
                title: '🎵 $title',
                fileName: msg['media_name'] as String?,
                mime: msg['media_mime'] as String?,
                isMe: false,
                accent: Colors.white,
                onColor: Colors.white,
                onDownload: maySave ? () => _saveMediaToDevice(msg) : null,
                onPlaying: heartPlaybackReporter(playKey),
              ),
            );
    }
    return null;
  }

  // ── Who it's for (groups) ──────────────────────────────────────────────────

  Future<void> _pickHeartFor() async {
    final scheme = Theme.of(context).colorScheme;
    final tint = HeartMood.of(_heartMood).color;
    final others = _groupMembers
        .where((m) => m['user_id']?.toString() != _myId)
        .toList();
    final picked = await showModalBottomSheet<Map<String, dynamic>?>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text('Who may open it?',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: scheme.onSurface)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                    'Everyone sees the sealed heart — only they can open it.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
              ),
              ListTile(
                leading: Icon(Icons.groups_rounded, color: tint),
                title: const Text('Everyone in the group'),
                trailing: _heartFor == null
                    ? Icon(Icons.check_rounded, color: tint)
                    : null,
                onTap: () => Navigator.pop(ctx, <String, dynamic>{}),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final m in others)
                      ListTile(
                        leading: Icon(Icons.favorite_rounded, color: tint),
                        title: Text(_memberName(m)),
                        trailing: (m['user_id'] as num?)?.toInt() == _heartFor
                            ? Icon(Icons.check_rounded, color: tint)
                            : null,
                        onTap: () => Navigator.pop(ctx, m),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || picked == null) return;
    HapticFeedback.selectionClick();
    rebuildWith(() {
      if (picked.isEmpty) {
        _heartFor = null;
        _heartForName = null;
      } else {
        _heartFor = (picked['user_id'] as num?)?.toInt();
        _heartForName = _memberName(picked).split(' ').first;
      }
    });
  }

  /// First open by me (the recipient) → the sender's "Opened 💗" receipt.
  void _reportHeartOpened(Map<String, dynamic> msg) {
    final id = int.tryParse(msg['id'].toString());
    if (id == null || _myId == null || _myHeartOpen(msg) != null) return;
    final now = DateTime.now().toUtc().toIso8601String();
    final opens = _heartOpens(msg)..[_myId!] = now;
    msg['heart_opens'] = jsonEncode(opens);
    msg['opened_at'] ??= now;
    unawaited(_saveMessagesCache()); // survives a restart
    // "Send opened receipts" off → the sender isn't told (it still counts as
    // opened HERE, so the knock and stars stop).
    if (!HeartLock.instance.sendReceipts) return;
    unawaited(ApiService().heartOpened(id));
  }

  /// Answer a heart with a heart: the composer switches to heart mode with a
  /// fitting mood (a "sorry" is best answered with love).
  void _startHeartBack(Map<String, dynamic> msg) {
    final m = (msg['heart_mood'] ?? 'love').toString();
    HapticFeedback.selectionClick();
    final sid = int.tryParse(msg['sender_id']?.toString() ?? '');
    final sm = (msg['sender'] as Map?) ?? const {};
    rebuildWith(() {
      _heartMode = true;
      _heartMood = (m == 'sorry') ? 'love' : (HeartMood.of(m).key);
      _heartUnlockAt = null;
      _replyTo = null;
      _heartAttach = null;
      _heartSave = false;
      // In a group, a heart back goes to the one who sent it — not everyone.
      if (_isGroup && sid != null) {
        _heartFor = sid;
        final match = _groupMembers.where(
            (g) => g['user_id']?.toString() == sid.toString());
        _heartForName = match.isNotEmpty
            ? _memberName(match.first).split(' ').first
            : ContactNames.instance.displayName(
                    of: sm, registered: (sm['username'] ?? 'them').toString())
                .split(' ')
                .first;
      } else {
        _heartFor = null;
        _heartForName = null;
      }
    });
    showToast(context, 'Write your heart back 💌');
  }

  /// Unsend a heart nobody has opened yet (it never lands).
  Future<void> _takeBackHeart(Map<String, dynamic> msg) async {
    final id = int.tryParse(msg['id'].toString());
    if (id == null) return;
    await _deleteMessage(id, true);
    if (mounted) showToast(context, 'Heart taken back — they never saw it');
  }

  /// Who opened this heart: user id → ISO time (from `heart_opens`).
  Map<String, String> _heartOpens(Map<String, dynamic> msg) {
    final raw = msg['heart_opens'];
    if (raw is! String || raw.isEmpty) return <String, String>{};
    try {
      final m = jsonDecode(raw);
      if (m is Map) {
        return m.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {}
    return <String, String>{};
  }

  /// When *I* opened it (null = not yet). DMs from before per-member opens
  /// existed fall back to the single opened_at.
  DateTime? _myHeartOpen(Map<String, dynamic> msg) {
    final mine = _myId == null ? null : _heartOpens(msg)[_myId!];
    if (mine != null && mine.isNotEmpty) return parseServerTime(mine);
    if (!_isGroup) {
      final o = (msg['opened_at'] ?? '').toString();
      if (o.isNotEmpty) return parseServerTime(o);
    }
    return null;
  }

  /// A timed heart's moment passed but the note isn't here yet → fetch it.
  Future<void> _unsealHeart(Map<String, dynamic> msg) async {
    final id = int.tryParse(msg['id'].toString());
    if (id == null) return;
    final fresh = await ApiService().heartUnseal(id);
    if (fresh == null || !mounted) return;
    final content = (fresh['content'] ?? '').toString();
    final hasMedia = (fresh['media_url'] ?? '').toString().isNotEmpty;
    if (content.isEmpty && !hasMedia) return;
    rebuildWith(() {
      final idx =
          _messages.indexWhere((m) => m['id'].toString() == id.toString());
      if (idx == -1) return;
      _messages[idx]['content'] = content;
      for (final k in const ['media_url', 'media_name', 'media_mime',
          'media_size', 'media_duration']) {
        if (fresh[k] != null) _messages[idx][k] = fresh[k];
      }
    });
  }

  /// The tray shown above the composer while a secret heart is being written.
  Widget _buildHeartTray(ColorScheme scheme, bool isDark) {
    final mood = HeartMood.of(_heartMood);
    final tint = mood.color;
    final empty = _ctrl.text.trim().isEmpty;

    Widget chip({
      required Widget label,
      required bool on,
      required VoidCallback onTap,
      IconData? icon,
      Color? color,
    }) {
      final c = color ?? tint;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Material(
          color: on ? c.withValues(alpha: 0.18) : scheme.surface,
          shape: StadiumBorder(
              side: BorderSide(
                  color: on ? c : scheme.outlineVariant.withValues(alpha: 0.6))),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 14, color: on ? c : scheme.onSurfaceVariant),
                    const SizedBox(width: 5),
                  ],
                  DefaultTextStyle.merge(
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                        color: on ? c : scheme.onSurface),
                    child: label,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            tint.withValues(alpha: isDark ? 0.22 : 0.12),
            tint.withValues(alpha: isDark ? 0.08 : 0.04),
          ],
        ),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.favorite_rounded, size: 15, color: tint),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _heartUnlockAt == null
                      ? (_heartForName != null
                          ? 'Secret heart · only $_heartForName can open it'
                          : (_isGroup
                              ? 'Secret heart · for everyone here 💞'
                              : 'Secret heart · they hold it to open'))
                      : 'Sealed · ${heartOpensLabel(_heartUnlockAt!).toLowerCase()}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: tint),
                ),
              ),
              IconButton(
                tooltip: 'Back to a normal message',
                visualDensity: VisualDensity.compact,
                onPressed: () => rebuildWith(() {
                  _heartMode = false;
                  _heartMood = 'love';
                  _heartUnlockAt = null;
                  _heartAttach = null;
                  _heartFor = null;
                  _heartForName = null;
                  _heartSave = false;
                }),
                icon: Icon(Icons.close_rounded,
                    size: 17, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Moods.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final m in HeartMood.all)
                  chip(
                    label: Text(m.label),
                    icon: m.icon,
                    color: m.color,
                    on: m.key == _heartMood,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      rebuildWith(() => _heartMood = m.key);
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // When it opens + note starters.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                // Something sealed inside: photo / video clip / voice clip.
                chip(
                  label: Text(_heartAttach?.label ?? 'Photo · clip · voice'),
                  icon: _heartAttach?.icon ?? Icons.add_photo_alternate_rounded,
                  on: _heartAttach != null,
                  onTap: _pickHeartAttach,
                ),
                // Groups: the one member who may open it.
                if (_isGroup)
                  chip(
                    label: Text(_heartForName == null
                        ? 'For everyone'
                        : 'For $_heartForName'),
                    icon: _heartFor == null
                        ? Icons.groups_rounded
                        : Icons.person_pin_rounded,
                    on: _heartFor != null,
                    onTap: _pickHeartFor,
                  ),
                // Timed hearts are a one-to-one ritual (DMs only).
                if (!_isGroup)
                  chip(
                    label: Text(_heartUnlockAt == null
                        ? 'Open anytime'
                        : heartOpensLabel(_heartUnlockAt!, prefix: '')),
                    icon: _heartUnlockAt == null
                        ? Icons.schedule_rounded
                        : Icons.hourglass_top_rounded,
                    on: _heartUnlockAt != null,
                    onTap: _pickHeartUnlock,
                  ),
                if (empty)
                  for (final p in mood.prompts)
                    chip(
                      label: Text('${p.trim()}…'),
                      icon: Icons.edit_note_rounded,
                      on: false,
                      color: scheme.onSurfaceVariant,
                      onTap: () {
                        _ctrl.value = TextEditingValue(
                          text: p,
                          selection: TextSelection.collapsed(offset: p.length),
                        );
                        rebuildWith(() {});
                      },
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// "When should it open?" — quick presets + a date & time picker.
  Future<void> _pickHeartUnlock() async {
    final now = DateTime.now();
    DateTime at(int dayOffset, int hour, [int minute = 0]) =>
        DateTime(now.year, now.month, now.day + dayOffset, hour, minute);
    final tonight = now.hour < 20 ? at(0, 20) : at(1, 20);
    final morning = at(now.hour < 7 ? 0 : 1, 7);
    final presets = <(String, IconData, DateTime)>[
      ('In 1 hour', Icons.timelapse_rounded, now.add(const Duration(hours: 1))),
      (now.hour < 20 ? 'Tonight, 8:00 PM' : 'Tomorrow night, 8:00 PM',
          Icons.nights_stay_rounded, tonight),
      ('${now.hour < 7 ? 'This' : 'Tomorrow'} morning, 7:00 AM',
          Icons.wb_twilight_rounded, morning),
    ];
    // Our anniversary (day + month this device remembers for this friend).
    final annivKey = 'heart_anniv_${widget.friendId}';
    String? annivMd;
    try {
      final p = await SharedPreferences.getInstance();
      annivMd = p.getString(annivKey);
    } catch (_) {}
    DateTime? nextOf(String? md) {
      if (md == null) return null;
      final parts = md.split('-');
      if (parts.length != 2) return null;
      final mo = int.tryParse(parts[0]), d = int.tryParse(parts[1]);
      if (mo == null || d == null) return null;
      var c = DateTime(now.year, mo, d, 8);
      if (!c.isAfter(now.add(const Duration(minutes: 1)))) {
        c = DateTime(now.year + 1, mo, d, 8);
      }
      return c;
    }

    final anniv = nextOf(annivMd);
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    final choice = await showModalBottomSheet<Object>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Container(
          margin: const EdgeInsets.all(10),
          constraints: const BoxConstraints(maxWidth: 520),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(24),
            border:
                Border.all(color: scheme.primary.withValues(alpha: 0.18)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 14),
              Icon(Icons.hourglass_top_rounded, color: scheme.primary),
              const SizedBox(height: 6),
              Text('When should it open?',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface)),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
                child: Text(
                  'It stays sealed — even to you — until then, and you both '
                  'get a little ping when it opens.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12.5, color: scheme.onSurfaceVariant),
                ),
              ),
              for (final p in presets)
                ListTile(
                  leading: Icon(p.$2, color: scheme.primary),
                  title: Text(p.$1),
                  onTap: () => Navigator.pop(ctx, p.$3),
                ),
              ListTile(
                leading: Icon(Icons.celebration_rounded, color: scheme.primary),
                title: Text(anniv == null
                    ? 'On our anniversary…'
                    : 'On our anniversary · ${DateFormat('d MMM').format(anniv)}'),
                subtitle: Text(anniv == null
                    ? 'Set the date once — opens that morning every year you pick it'
                    : 'Opens at 8:00 AM · long-press to change the date'),
                onTap: () => Navigator.pop(ctx, anniv ?? 'anniv'),
                onLongPress: () => Navigator.pop(ctx, 'anniv'),
              ),
              ListTile(
                leading: Icon(Icons.event_rounded, color: scheme.primary),
                title: const Text('Pick a date & time…'),
                subtitle: const Text('An anniversary, a birthday, a reunion'),
                onTap: () => Navigator.pop(ctx, 'pick'),
              ),
              if (_heartUnlockAt != null)
                ListTile(
                  leading: Icon(Icons.lock_open_rounded,
                      color: scheme.onSurfaceVariant),
                  title: const Text('Open anytime (no seal)'),
                  onTap: () => Navigator.pop(ctx, 'clear'),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'clear') {
      rebuildWith(() => _heartUnlockAt = null);
      return;
    }
    DateTime? when = choice is DateTime ? choice : null;
    if (choice == 'anniv') {
      final d = await showDatePicker(
        context: context,
        initialDate: anniv ?? now,
        firstDate: DateTime(now.year - 60),
        lastDate: DateTime(now.year + 1, 12, 31),
        helpText: 'Our anniversary',
      );
      if (d == null || !mounted) return;
      final md = '${d.month}-${d.day}';
      try {
        final p = await SharedPreferences.getInstance();
        await p.setString(annivKey, md);
      } catch (_) {}
      when = nextOf(md);
    }
    if (!mounted) return;
    if (choice == 'pick') {
      final d = await showDatePicker(
        context: context,
        initialDate: now.add(const Duration(days: 1)),
        firstDate: now,
        lastDate: now.add(const Duration(days: 365)),
        helpText: 'Open on',
      );
      if (d == null || !mounted) return;
      final t = await showTimePicker(
        context: context,
        initialTime: const TimeOfDay(hour: 20, minute: 0),
        helpText: 'At',
      );
      if (t == null || !mounted) return;
      when = DateTime(d.year, d.month, d.day, t.hour, t.minute);
    }
    if (when == null || !mounted) return;
    if (when.isBefore(DateTime.now().add(const Duration(minutes: 1)))) {
      showToast(context, 'Pick a moment a little later', type: ToastType.info);
      return;
    }
    rebuildWith(() => _heartUnlockAt = when);
  }
}
