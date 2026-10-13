part of '../chat_page.dart';

// Split out of chat_page.dart (pure code movement, no behaviour change):
// helper methods of _ChatPageState that don't call setState, moved into a
// private extension. A library `part`, so it shares the page's imports
// and reaches every private field and method.

extension _ChatPageHelpers1 on _ChatPageState {
  Map<String, dynamic>? _otherMember(Map<String, dynamic> s) {
    final members = (s['members'] as List?) ?? const [];
    for (final m in members) {
      if (m is Map && (m['id']).toString() != _myId) {
        return Map<String, dynamic>.from(m);
      }
    }
    return null;
  }

  String _spaceTitle(Map<String, dynamic> s) {
    final name = (s['name'] ?? '').toString().trim();
    if (name.isNotEmpty) return name;
    final who = (_otherMember(s)?['username'] ?? '').toString().trim();
    return who.isNotEmpty ? 'You & $who' : 'Our Space';
  }

  String _spacePartnerName(Map<String, dynamic> s) {
    final who = (_otherMember(s)?['username'] ?? '').toString().trim();
    return who.isNotEmpty ? who : 'your partner';
  }

  /// Choose which bonded space to keep into. Auto when there's just one; a small
  /// sheet (partner's space pre-marked) when there are several. Null = cancel.
  Future<Map<String, dynamic>?> _pickKeepSpace() async {
    if (_mySpaces.isEmpty) return null;
    if (_mySpaces.length == 1) return _mySpaces.first;
    final def = _defaultKeepSpaceId;
    final chosenId = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (bctx) {
        final scheme = Theme.of(bctx).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
                child: Text('Keep to\u2026',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface)),
              ),
              for (final s in _mySpaces)
                ListTile(
                  leading: CircleAvatar(
                    radius: 20,
                    backgroundColor: scheme.primaryContainer,
                    child: Icon(Icons.favorite_rounded,
                        size: 18, color: scheme.primary),
                  ),
                  title: Text(_spaceTitle(s)),
                  trailing: (s['id'] as num?)?.toInt() == def
                      ? Icon(Icons.star_rounded,
                          size: 18, color: scheme.primary)
                      : null,
                  onTap: () =>
                      Navigator.pop(bctx, (s['id'] as num?)?.toInt()),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (chosenId == null) return null;
    for (final s in _mySpaces) {
      if ((s['id'] as num?)?.toInt() == chosenId) return s;
    }
    return null;
  }

  // ── Harmony / Our Space actions from a chat bubble ──────────────────────────
  /// A chat 'file' message that is actually a video (by mime or extension).
  bool _isVideoMsg(Map<String, dynamic> msg) {
    final mime = (msg['media_mime'] as String?)?.toLowerCase() ?? '';
    if (mime.startsWith('video/')) return true;
    final name = (msg['media_name'] as String?)?.toLowerCase() ?? '';
    return name.endsWith('.mp4') ||
        name.endsWith('.mov') ||
        name.endsWith('.webm') ||
        name.endsWith('.mkv') ||
        name.endsWith('.m4v') ||
        name.endsWith('.avi');
  }

  /// Which bubbles get the subtle quick "keep to Our Space" star on their
  /// side: real captured media — a photo, a video, a voice note / audio, or a
  /// song. GIFs/stickers (image/gif), text, call/live logs and plain files
  /// stay clean (they keep the press-and-hold menu, where Keepsake lives).
  bool _isQuickKeepBubble(Map<String, dynamic> msg) {
    if ((msg['media_url'] as String? ?? '').isEmpty) return false;
    final type = (msg['message_type'] as String?) ?? 'text';
    final mime = (msg['media_mime'] as String?)?.toLowerCase() ?? '';
    final name = (msg['media_name'] as String?)?.toLowerCase() ?? '';
    final isGif = mime.contains('gif') || name.endsWith('.gif');
    switch (type) {
      case 'audio': // voice note / audio
        return true;
      case 'song':
        return true;
      case 'video':
        return true;
      case 'image':
        return !isGif; // real photos only — GIFs/stickers stay clean
      case 'file':
        return _isVideoMsg(msg);
      default:
        return false;
    }
  }

  // A friendly song title for a 'song' bubble (its spoken title lives in
  // `content`, falling back to the file name).
  String _songTitleOf(Map<String, dynamic> msg) {
    final text = _stripQuote((msg['content'] as String?) ?? '').trim();
    if (text.isNotEmpty) return text;
    final name = (msg['media_name'] as String?)?.trim();
    return (name != null && name.isNotEmpty) ? name : 'A song';
  }

  /// Capture a DURABLE, moment-owned server copy of a kept media file so the
  /// moment survives the chat's store-and-forward purge — and so the partner,
  /// who may never have been in the source chat, can fetch it through Our Space.
  /// Reads the device's local cache first (what it already holds), falls back to
  /// a server fetch while the bytes are still there, then re-uploads them as a
  /// NON-ephemeral asset. Returns the new ref, or [rel] unchanged on any failure
  /// so keeping never hard-fails.
  Future<String> _durableMediaRef(String rel, String mime) async {
    if (rel.isEmpty || rel.startsWith('http')) return rel;
    try {
      final url = fullMediaUrl(rel);
      List<int>? bytes;
      if (!kIsWeb) {
        try {
          final f =
              await MediaStore.instance.getFile(url, mediaAuthHeaders(url));
          if (f != null) bytes = await f.readAsBytes();
        } catch (_) {}
      }
      if (bytes == null || bytes.isEmpty) {
        final res =
            await http.get(Uri.parse(url), headers: mediaAuthHeaders(url));
        if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
          bytes = res.bodyBytes;
        }
      }
      if (bytes == null || bytes.isEmpty) return rel;
      final name = rel.split('/').last;
      final up = await ApiService().uploadMedia(
        bytes: bytes,
        filename: name.isEmpty ? 'keepsake' : name,
        mime: mime.isNotEmpty ? mime : 'application/octet-stream',
        ephemeral: false,
      );
      final newUrl = (up?['url'] as String?) ?? '';
      return newUrl.isNotEmpty ? newUrl : rel;
    } catch (_) {
      return rel;
    }
  }

  /// Keep [msg] into Our Space as a PinnedMoment, mapping the bubble type to a
  /// moment kind: text→note, photo→photo, voice→voice, song→song.
  Future<void> _keepsakeMessage(Map<String, dynamic> msg) async {
    final space = await _pickKeepSpace();
    if (space == null || !mounted) return;
    final sid = (space['id'] as num).toInt();
    final type = (msg['message_type'] as String?) ?? 'text';
    final rel = (msg['media_url'] as String?) ?? '';
    final mime = (msg['media_mime'] as String?)?.toLowerCase() ?? '';
    final text = _stripQuote((msg['content'] as String?) ?? '').trim();
    String kind;
    String? ref;
    String? caption;
    switch (type) {
      case 'image':
        // A kept GIF/sticker (image/gif) gets its own kind so Our Space labels
        // it "A GIF" (and still animates) instead of flattening to a photo.
        kind = ((mime).contains('gif') ||
                ((msg['media_name'] as String?) ?? '')
                    .toLowerCase()
                    .endsWith('.gif'))
            ? 'gif'
            : 'photo';
        ref = rel;
        break;
      case 'audio':
        kind = 'voice';
        ref = rel;
        break;
      case 'song':
        kind = 'song';
        ref = jsonEncode({'title': _songTitleOf(msg), 'ref': rel});
        break;
      case 'video':
        kind = 'video';
        ref = rel;
        break;
      case 'file':
        if (_isVideoMsg(msg) && rel.isNotEmpty) {
          kind = 'video';
          ref = rel;
        } else {
          final label = _replyQuoteText(msg).trim();
          if (label.isEmpty) {
            showToast(context, 'This can only be kept from Our Space',
                type: ToastType.info);
            return;
          }
          kind = 'note';
          caption = label;
        }
        break;
      case 'text':
        if (text.isEmpty) {
          showToast(context, 'Nothing to keep here', type: ToastType.info);
          return;
        }
        // A kept line IS its own words, so it keeps in one tap; the text lands
        // in `caption`, which is what the moment card renders.
        kind = 'note';
        caption = text;
        break;
      default:
        // call / live / location / contact / file — keep a friendly label.
        final label = _replyQuoteText(msg).trim();
        if (label.isEmpty) {
          showToast(context, 'This can only be kept from Our Space',
              type: ToastType.info);
          return;
        }
        kind = 'note';
        caption = label;
    }
    // For photo / voice / song, let the keeper add an optional one-line note —
    // warmth about the two of them ("so you"), never where it came from, so the
    // moment stays pointed at the couple rather than a third person. The
    // original chat caption is deliberately NOT carried across.
    if (kind == 'photo' ||
        kind == 'voice' ||
        kind == 'song' ||
        kind == 'video' ||
        kind == 'gif') {
      final note = await _keepsakeNoteSheet(msg, type, space);
      if (note == null || !mounted) return; // cancelled
      final t = note.trim();
      caption = t.isEmpty ? null : t;
      // Durable, moment-owned copy (see _durableMediaRef) so the photo / voice
      // / song never breaks after the chat media is purged. (A GIF is an
      // external CDN url, so _durableMediaRef returns it unchanged.)
      final durable = await _durableMediaRef(
          rel, mime.isNotEmpty ? mime : (type == 'image' ? 'image/jpeg' : ''));
      if (!mounted) return;
      ref = (kind == 'song')
          ? jsonEncode({'title': _songTitleOf(msg), 'ref': durable})
          : durable;
    }
    final res = await ApiService()
        .addMoment(sid, kind: kind, ref: ref, caption: caption);
    if (!mounted) return;
    if (res != null) spaceEventBus.value++;
    showToast(
        context,
        res != null ? 'Kept in Our Space 💛' : 'Could not keep that',
        type: res != null ? ToastType.success : ToastType.error);
  }

  /// A small sheet shown when keeping a photo / voice / song: a preview of what
  /// is being kept, an OPTIONAL note (with emoji + quick warmth chips), and a
  /// reminder of which space it lands in. Returns the note text (possibly empty)
  /// on Keep, or null if cancelled. Warmth for the two of them — it never
  /// records where the content came from.
  Future<String?> _keepsakeNoteSheet(
      Map<String, dynamic> msg, String type, Map<String, dynamic> space) {
    final ctrl = TextEditingController();
    final rel = (msg['media_url'] as String?) ?? '';
    final dest = _spaceTitle(space);
    const chips = <String>[
      'so you 🥰',
      'this made me smile',
      'us 🥹',
      'never forget this',
      'my favourite',
    ];
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (bctx) {
        final scheme = Theme.of(bctx).colorScheme;
        bool showEmoji = false;
        Widget preview;
        if (type == 'image' && rel.isNotEmpty) {
          final url = fullMediaUrl(rel);
          preview = ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: authNetworkImage(
                url: url,
                headers: mediaAuthHeaders(url),
                fit: BoxFit.cover,
                width: double.infinity,
                cacheWidth: 900,
              ),
            ),
          );
        } else {
          final isVid = _isVideoMsg(msg);
          final icon = isVid
              ? Icons.movie_rounded
              : (type == 'song'
                  ? Icons.music_note_rounded
                  : (type == 'audio'
                      ? Icons.mic_rounded
                      : Icons.sticky_note_2_rounded));
          final label = isVid
              ? ((msg['media_name'] as String?)?.trim().isNotEmpty == true
                  ? (msg['media_name'] as String).trim()
                  : 'Video')
              : (type == 'song'
                  ? _songTitleOf(msg)
                  : (type == 'audio' ? 'Voice message' : 'Moment'));
          preview = Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                  scheme.primary.withValues(alpha: 0.08), scheme.surface),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                Icon(icon, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          );
        }
        return StatefulBuilder(
          builder: (bctx, setSheet) {
            return Padding(
              padding: EdgeInsets.only(
                  left: 20,
                  right: 20,
                  top: 2,
                  bottom: MediaQuery.of(bctx).viewInsets.bottom + 16),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.auto_awesome_rounded,
                            size: 20, color: scheme.primary),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text('Keep in Our Space',
                              style: TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.lock_rounded,
                            size: 13, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                              'Private to $dest — only you two see it',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    preview,
                    const SizedBox(height: 14),
                    TextField(
                      controller: ctrl,
                      autofocus: true,
                      minLines: 1,
                      maxLines: 3,
                      textCapitalization: TextCapitalization.sentences,
                      onTap: () {
                        if (showEmoji) setSheet(() => showEmoji = false);
                      },
                      decoration: InputDecoration(
                        hintText: 'Add a note for you two… (optional)',
                        filled: true,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14)),
                        suffixIcon: IconButton(
                          tooltip: showEmoji ? 'Keyboard' : 'Emoji',
                          icon: Icon(
                              showEmoji
                                  ? Icons.keyboard_rounded
                                  : Icons.emoji_emotions_outlined,
                              color: scheme.primary),
                          onPressed: () {
                            if (!showEmoji) {
                              FocusManager.instance.primaryFocus?.unfocus();
                            }
                            setSheet(() => showEmoji = !showEmoji);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final c in chips)
                          ActionChip(
                            label: Text(c,
                                style: const TextStyle(fontSize: 12.5)),
                            visualDensity: VisualDensity.compact,
                            onPressed: () => _appendNote(ctrl, c),
                          ),
                      ],
                    ),
                    if (showEmoji) ...[
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 250,
                        child: _emojiPickerFor(scheme, ctrl, height: 250),
                      ),
                    ],
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                            onPressed: () => Navigator.pop(bctx, null),
                            child: const Text('Cancel')),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          onPressed: () => Navigator.pop(bctx, ctrl.text),
                          icon: const Icon(Icons.auto_awesome_rounded,
                              size: 18),
                          label: const Text('Keep'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Append a quick note suggestion / emoji to the keepsake note field.
  void _appendNote(TextEditingController c, String text) {
    final base = c.text.trimRight();
    c.text = base.isEmpty ? text : '$base $text';
    c.selection = TextSelection.collapsed(offset: c.text.length);
  }

  /// Pin a shared song into the couple's Our Playlist (Soundtrack of Us).
  Future<void> _addSongToPlaylist(Map<String, dynamic> msg) async {
    final space = await _pickKeepSpace();
    if (space == null || !mounted) return;
    final sid = (space['id'] as num).toInt();
    final rel = (msg['media_url'] as String?) ?? '';
    final durable =
        await _durableMediaRef(rel, (msg['media_mime'] as String?) ?? '');
    if (!mounted) return;
    final res = await ApiService().addTrack(sid,
        title: _songTitleOf(msg), ref: durable, source: 'share');
    if (!mounted) return;
    if (res != null) spaceEventBus.value++;
    showToast(
        context,
        res != null ? 'Added to Our Playlist 🎵' : 'Could not add that',
        type: res != null ? ToastType.success : ToastType.error);
  }

  /// Dedicate a shared song to the partner — a one-line note turns it into a
  /// feeling. Reuses the dedication flow already in Our Space.
  Future<void> _dedicateSong(Map<String, dynamic> msg) async {
    final space = await _pickKeepSpace();
    if (space == null || !mounted) return;
    final sid = (space['id'] as num).toInt();
    final rel = (msg['media_url'] as String?) ?? '';
    final title = _songTitleOf(msg);
    final note = await _promptDedicationNote(title);
    if (note == null) return; // cancelled
    final trimmed = note.trim();
    final durable =
        await _durableMediaRef(rel, (msg['media_mime'] as String?) ?? '');
    if (!mounted) return;
    final res = await ApiService().createDedication(sid,
        title: title, ref: durable, note: trimmed.isEmpty ? null : trimmed);
    if (!mounted) return;
    if (res != null) spaceEventBus.value++;
    showToast(
        context,
        res != null
            ? 'Dedicated to ${_spacePartnerName(space)} 💫'
            : 'Could not dedicate',
        type: res != null ? ToastType.success : ToastType.error);
  }

  /// A small sheet to add an optional note when dedicating a song from a bubble.
  /// Returns the note text (possibly empty) on confirm, or null if cancelled.
  Future<String?> _promptDedicationNote(String title) {
    final ctrl = TextEditingController();
    return showDialog<String?>(
      context: context,
      builder: (dctx) {
        final scheme = Theme.of(dctx).colorScheme;
        return AlertDialog(
          title: const Text('Dedicate this song'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.music_note_rounded,
                      size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                controller: ctrl,
                autofocus: true,
                minLines: 1,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Say why… (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dctx, null),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(dctx, ctrl.text),
                child: const Text('Dedicate')),
          ],
        );
      },
    );
  }

  /// Send a shared-in video: compress a big clip on-device, enforce the cap,
  /// then upload (same flow as the in-chat video picker).
  Future<void> _sendSharedVideo(
      List<int> bytes, String filename, String ext, String path) async {
    String mime = ext == 'mov'
        ? 'video/quicktime'
        : (ext == 'webm' ? 'video/webm' : 'video/mp4');
    const cap = 200 * 1024 * 1024;
    const compressAbove = 12 * 1024 * 1024;
    if (!kIsWeb && _isMobile && bytes.length > compressAbove) {
      if (mounted) showToast(context, 'Compressing video…');
      try {
        final info = await VideoCompress.compressVideo(
          path,
          quality: VideoQuality.MediumQuality,
          deleteOrigin: false,
          includeAudio: true,
        );
        final cf = info?.file;
        if (cf != null) {
          final cb = await cf.readAsBytes();
          if (cb.isNotEmpty && cb.length < bytes.length) {
            bytes = cb;
            mime = 'video/mp4';
            final dot = filename.lastIndexOf('.');
            filename =
                '${dot > 0 ? filename.substring(0, dot) : filename}.mp4';
          }
        }
      } catch (_) {/* keep the original bytes on any failure */}
    }
    if (bytes.length > cap) {
      if (mounted) {
        showToast(context, 'Video is too large to send (max 200 MB).',
            type: ToastType.error);
      }
      return;
    }
    await _uploadAndSend(
        bytes: bytes,
        filename: filename,
        mime: mime,
        type: 'video',
        ephemeral: bytes.length > 15 * 1024 * 1024);
    try {
      await VideoCompress.deleteAllCache();
    } catch (_) {}
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  // ── Keepalive: ping the server every 60s while chat is open and active ──
  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
      if (!mounted) return;
      final secsSinceActivity =
          DateTime.now().difference(_lastActivityTime).inSeconds;
      if (secsSinceActivity < 180) {
        // User was active in the last 3 minutes — keep them online.
        final ok = await ApiService().setOnlineStatus(true);
        ConnectionStatus.instance.set(ok);
      }
    });
  }

  void _markActivity() {
    _lastActivityTime = DateTime.now();
    if (_isUserOffline && mounted) {
      // Quietly try to go back online when user resumes activity
      ApiService().setOnlineStatus(true).then((ok) {
        if (ok) ConnectionStatus.instance.set(true);
      });
    }
  }
  Future<File?> _chatBgFileFuture(String url, Map<String, String> headers) {
    if (_chatBgUrl != url || _chatBgFuture == null) {
      _chatBgUrl = url;
      _chatBgFuture = MediaStore.instance.getFile(url, headers);
    }
    return _chatBgFuture!;
  }

  Widget _chatPhotoWallpaper(ChatBg bg, bool isDark) {
    final veil = isDark ? Colors.black : Colors.white;
    return LayoutBuilder(
      builder: (ctx, c) {
        // Wide screens (tablet/desktop): prefer a landscape variant when the
        // wallpaper has one; otherwise tile the portrait by height so it fills
        // the width without an empty band (same as Our Space).
        final wide = c.maxWidth >= 600;
        final useWide = wide && (bg.wideUrl ?? '').isNotEmpty;
        final url = useWide ? bg.wideUrl! : (bg.url ?? '');
        final headers = mediaAuthHeaders(url);
        return FutureBuilder<File?>(
          future: _chatBgFileFuture(url, headers),
          builder: (ctx, snap) {
            final ImageProvider prov = snap.data != null
                ? FileImage(snap.data!)
                : authNetworkImageProvider(url, headers);
            final DecorationImage deco = (wide && !useWide)
                ? DecorationImage(
                    image: prov,
                    fit: BoxFit.fitHeight,
                    repeat: ImageRepeat.repeatX,
                    onError: (Object e, StackTrace? st) {},
                  )
                : DecorationImage(
                    image: prov,
                    fit: BoxFit.cover,
                    onError: (Object e, StackTrace? st) {},
                  );
            return Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(decoration: BoxDecoration(image: deco)),
                ValueListenableBuilder<double>(
                  valueListenable: wallpaperClarity,
                  builder: (_, _, _) => DecoratedBox(
                    decoration: BoxDecoration(
                      color: veil.withValues(
                          alpha: wallpaperVeilAlpha(isDark ? 0.55 : 0.62)),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _chatMotifWallpaper(ColorScheme scheme, bool isDark) {
    final motifColor = isDark ? Colors.white : scheme.primary;
    // Concentration follows the user's motif-strength setting, live.
    return ValueListenableBuilder<double>(
      valueListenable: motifStrength,
      builder: (_, _, _) => DecoratedBox(
        decoration: BoxDecoration(color: scheme.surface),
        child: CustomPaint(
          painter: RomanticPatternPainter(
            color: motifColor
                .withValues(alpha: motifAccentAlpha(isDark ? 0.06 : 0.055)),
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  // ── Chat wallpaper chooser ───────────────────────────────────────────────
  Future<void> _openChatWallpaperSheet() => showChatWallpaperSheet(
        context,
        convKey: _convKey,
        title: _isGroup ? widget.groupTitle : widget.friendName,
        apiBase: _apiBase,
      );

  Future<void> _saveMessagesCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Keep the FULL conversation on-device (append-only): merge the current
      // window into whatever is already cached so the local copy never shrinks
      // to a small window. With server-side purge of delivered messages, THIS
      // is the durable copy — it must hold the history, not just the latest
      // few. Bounded to the most recent 3000 per chat to cap storage.
      List<Map<String, dynamic>> stored = const [];
      final raw = prefs.getString(_cacheKey);
      if (raw != null) {
        try {
          stored = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
        } catch (_) {}
      }
      // Pending (optimistic) messages are transient and carry non-JSON local
      // bytes — never persist them.
      final live = _messages.where((m) => m['__pending'] != true).toList();
      final full = _merge(stored, live);
      final toCache = full.length > 3000 ? full.take(3000).toList() : full;
      await prefs.setString(_cacheKey, jsonEncode(toCache));
      // We now durably hold this history locally → let the server purge its
      // copy of what BOTH devices have cached (store-and-forward). Throttled.
      _ackCachedToServer(toCache);
    } catch (_) {}
  }

  int _msgId(Map<String, dynamic> m) {
    final v = m['id'];
    return v is int ? v : int.tryParse('$v') ?? 0;
  }

  /// Tell the server how far we've DURABLY cached — which lets it purge those
  /// messages' media. Crucially, we do NOT ack past a photo whose bytes we
  /// don't yet hold on this device: we first try to persist each image locally
  /// (while the server still has it), and STOP the pointer at any recent image
  /// we couldn't save, so the server keeps holding it until we actually have
  /// it. A single old/unavailable item can't freeze the pointer (7-day grace).
  Future<void> _ackCachedToServer(List<Map<String, dynamic>> cached) async {
    final now = DateTime.now();
    final sorted = [...cached]..sort((a, b) => _msgId(a).compareTo(_msgId(b)));
    int safe = 0;
    for (final m in sorted) {
      final id = _msgId(m);
      if (id <= 0) continue;
      if (!kIsWeb && (m['message_type'] as String?) == 'image') {
        final rel = (m['media_url'] as String?) ?? '';
        if (rel.isNotEmpty) {
          final url = fullMediaUrl(rel);
          File? f;
          try {
            f = await MediaStore.instance.cached(url);
            f ??= await MediaStore.instance.getFile(url, mediaAuthHeaders(url));
          } catch (_) {}
          if (f == null) {
            // No local copy yet. If the photo is recent the server still holds
            // it → stop here so it isn't purged before we've saved it. If it's
            // old it's likely already handled/purged → let the pointer move on.
            final ts = DateTime.tryParse((m['timestamp'] as String?) ?? '');
            final recent = ts != null && now.difference(ts).inDays < 7;
            if (recent) break;
          }
        }
      }
      safe = id;
    }
    if (safe <= _lastCachedAck) return;
    _lastCachedAck = safe;
    if (_isGroup) {
      ApiService().ackChatCached(conversationId: _cid, upTo: safe);
    } else {
      ApiService().ackChatCached(friendId: widget.friendId, upTo: safe);
    }
  }

  // ── Connectivity watcher (WhatsApp-style auto-reconnect) ──────────────────

  void _startConnectivityWatch() {
    _connectivitySub?.cancel();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final hasNet = results.any((r) => r != ConnectivityResult.none);
      if (hasNet && _isUserOffline) {
        _autoReconnect();
      } else if (!hasNet) {
        ConnectionStatus.instance.set(false);
      }
    });
  }

  List<Map<String, dynamic>> _merge(
    List<Map<String, dynamic>> existing,
    List<Map<String, dynamic>> fetched, {
    bool markRead = false,
  }) {
    final map = <String, Map<String, dynamic>>{};
    // Clone existing entries so merged items have fresh identities — that lets
    // _listEq detect in-place field changes (edits, reactions, tombstones,
    // read/delivered) every poll and trigger a rebuild.
    for (final m in existing) {
      map[m['id'].toString()] = Map<String, dynamic>.from(m);
    }
    for (final m in fetched) {
      final id = m['id'].toString();
      if (map.containsKey(id)) {
        final ex = map[id]!;
        // Status always follows the server.
        ex['delivered'] = m['delivered'];
        ex['is_read'] = m['is_read'];
        ex['edited'] = m['edited'];
        ex['is_deleted'] = m['is_deleted'];
        ex['reactions'] = m['reactions'];
        ex['pinned_until'] = m['pinned_until'];
        // Store-and-forward: once the server has PURGED its copy after delivery
        // it sends an emptied tombstone (purged:true) — keep OUR local content
        // and media, which are now the durable copy. Otherwise take the
        // server's content/media as before (covers real edits + media).
        if (m['purged'] == true) {
          ex['purged'] = true;
        } else {
          ex['content'] = m['content'];
          ex['message_type'] = m['message_type'];
          ex['media_url'] = m['media_url'];
          ex['media_name'] = m['media_name'];
          ex['media_mime'] = m['media_mime'];
          ex['media_size'] = m['media_size'];
          ex['media_duration'] = m['media_duration'];
        }
      } else {
        map[id] = m;
      }
    }
    return map.values.toList()
      ..sort((a, b) {
        final ta = DateTime.tryParse(a['timestamp'] ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final tb = DateTime.tryParse(b['timestamp'] ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return tb.compareTo(ta);
      });
  }

  bool _listEq(List<Map<String, dynamic>> a, List<Map<String, dynamic>> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i]['id'] != b[i]['id'] ||
          a[i]['is_read'] != b[i]['is_read'] ||
          a[i]['delivered'] != b[i]['delivered'] ||
          a[i]['content'] != b[i]['content'] ||
          a[i]['edited'] != b[i]['edited'] ||
          a[i]['is_deleted'] != b[i]['is_deleted'] ||
          a[i]['pinned_until'] != b[i]['pinned_until'] ||
          a[i]['reactions'] != b[i]['reactions']) { return false; }
    }
    return true;
  }

  /// Bottom-sheet picker over the player's loaded songs. Returns the chosen
  /// file path, or null if dismissed.
  Future<String?> _pickFromLoadedPlaylist(List<String> paths) {
    final scheme = Theme.of(context).colorScheme;
    // Surface the currently-playing track first, flagged, so the DJ can share
    // what they're already listening to in one tap.
    final nowPath = playbackBus.currentPath?.call();
    final ordered = <String>[
      if (nowPath != null && paths.contains(nowPath)) nowPath,
      ...paths.where((p) => p != nowPath),
    ];
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: scheme.primary.withAlpha(130)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header — headphones badge + title + subtitle.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 2, 18, 10),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: scheme.primary.withAlpha(28),
                          ),
                          child: Icon(Icons.headphones_rounded,
                              color: scheme.primary, size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'Listen together',
                                style: TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 16),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                'Pick a song to stream to $_livePeerLabel',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(
                      height: 1,
                      color: scheme.outlineVariant.withAlpha(60)),
                  Flexible(
                    child: ScrollConfiguration(
                      // Drop the always-on desktop scrollbar and use one that
                      // fades out shortly after scrolling stops, so it never
                      // sits over the row's broadcast icons.
                      behavior: ScrollConfiguration.of(ctx)
                          .copyWith(scrollbars: false),
                      child: Scrollbar(
                        controller: _pickerScrollCtrl,
                        thumbVisibility: false,
                        child: ListView.builder(
                      controller: _pickerScrollCtrl,
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(top: 6, bottom: 6, right: 8),
                      itemCount: ordered.length,
                      itemBuilder: (_, i) {
                        final p = ordered[i];
                        final isNow = p == nowPath;
                        final tile = ListTile(
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 8),
                          leading: CircleAvatar(
                            radius: 18,
                            backgroundColor: isNow
                                ? scheme.primary
                                : scheme.primaryContainer,
                            child: Icon(
                              isNow
                                  ? Icons.graphic_eq_rounded
                                  : Icons.music_note_rounded,
                              size: 17,
                              color: isNow
                                  ? Colors.white
                                  : scheme.onPrimaryContainer,
                            ),
                          ),
                          title: MarqueeText(
                            text: _titleFromPath(p),
                            height: 18,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: isNow
                                  ? FontWeight.bold
                                  : FontWeight.w500,
                              color:
                                  isNow ? scheme.primary : scheme.onSurface,
                            ),
                          ),
                          subtitle: isNow
                              ? Text('Now playing — share from here',
                                  style: TextStyle(
                                      fontSize: 11, color: scheme.primary))
                              : null,
                          trailing: Icon(Icons.sensors_rounded,
                              size: 18,
                              color: isNow
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant.withAlpha(120)),
                          onTap: () => Navigator.pop(ctx, p),
                        );
                        if (!isNow) return tile;
                        // Highlight the now-playing row as a rounded chip.
                        return Container(
                          margin: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: scheme.primary.withAlpha(22),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                                color: scheme.primary.withAlpha(90)),
                          ),
                          child: tile,
                        );
                      },
                    ),
                      ),
                    ),
                  ),
                  Divider(
                      height: 1,
                      color: scheme.outlineVariant.withAlpha(60)),
                  // Let the user still browse files if the song isn't loaded.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonalIcon(
                        onPressed: () => Navigator.pop(ctx, '__browse__'),
                        icon: const Icon(Icons.folder_open_rounded, size: 18),
                        label: const Text('Choose a file instead'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
              ),
            ),
          ),
        );
      },
    ).then((choice) async {
      if (choice == '__browse__') {
        // Deferred: reopen via the file browser path.
        final token = await getToken();
        final myUserId = int.tryParse(_myId ?? '');
        if (token != null && myUserId != null && mounted) {
          await _startListenTogetherFromFile(token, myUserId);
        }
        return null;
      }
      return choice;
    });
  }

  /// Fallback: pick a song from the device's file browser and start the
  /// session (used when the player has no loaded songs, or on the user's
  /// explicit request).
  Future<void> _startListenTogetherFromFile(String token, int myUserId) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'wav', 'm4a', 'aac', 'ogg', 'flac'],
    );
    if (result == null || result.files.isEmpty) return;

    final picked = result.files.single;
    final Uint8List bytes = await picked.readAsBytes();
    if (bytes.isEmpty) {
      if (mounted) {
        showToast(context, 'Could not read that audio file.',
            type: ToastType.error);
      }
      return;
    }
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => LiveSessionScreen.host(
        token: token,
        myUserId: myUserId,
        receiverId: widget.friendId,
        audioBytes: bytes,
        title: picked.name,
        peerName: _livePeerLabel,
      ),
    ));
  }
}
