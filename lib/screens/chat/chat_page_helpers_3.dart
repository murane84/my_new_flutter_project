part of '../chat_page.dart';

// Split out of chat_page.dart (pure code movement, no behaviour change):
// helper methods of _ChatPageState that don't call setState, moved into a
// private extension. A library `part`, so it shares the page's imports
// and reaches every private field and method.

extension _ChatPageHelpers3 on _ChatPageState {
  String _viewerSenderName(int i) {
    final m = (i >= 0 && i < _viewerMsgs.length) ? _viewerMsgs[i] : null;
    if (m == null) return '';
    final mine = m['sender_id']?.toString() == _myId;
    if (mine) return 'Me';
    if (_isGroup) {
      final sm = (m['sender'] as Map?) ?? const {};
      return ContactNames.instance.displayName(
          of: sm, registered: (sm['username'] ?? 'Member').toString());
    }
    return widget.friendName;
  }

  String _viewerSenderAvatar(int i) {
    final m = (i >= 0 && i < _viewerMsgs.length) ? _viewerMsgs[i] : null;
    if (m == null) return '';
    final mine = m['sender_id']?.toString() == _myId;
    if (mine) return _myAvatar ?? '';
    if (_isGroup) {
      final sm = (m['sender'] as Map?) ?? const {};
      return (sm['avatar_url'] ?? '').toString();
    }
    return _friendAvatar;
  }

  String _viewerSentTime(int i) {
    final m = (i >= 0 && i < _viewerMsgs.length) ? _viewerMsgs[i] : null;
    final iso = m?['timestamp']?.toString();
    final t = iso != null ? DateTime.tryParse(iso) : null;
    if (t == null) return '';
    final local = t.toLocal();
    final now = DateTime.now();
    final today = local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    final y = now.subtract(const Duration(days: 1));
    final yday =
        local.year == y.year && local.month == y.month && local.day == y.day;
    final hm = DateFormat('HH:mm').format(local);
    if (today) return 'Today at $hm';
    if (yday) return 'Yesterday at $hm';
    return DateFormat('MMM d, HH:mm').format(local);
  }

  Widget _videoBubble(
      String url, Map<String, dynamic> msg, ColorScheme scheme,
      {String? caption}) {
    final secs = (msg['media_duration'] as num?)?.toInt() ?? 0;
    // Shared poster + silent dwell-glimpse + tap-to-play; fullscreen opens the
    // existing in-app player. Same behaviour as Our Space moments. The caption
    // rides on the video and fades out while it plays.
    return GlimpseVideo(
      url: url,
      headers: mediaAuthHeaders(url),
      accent: scheme.primary,
      maxWidth: 260,
      maxStageHeight: 280,
      aspectRatioFallback: 16 / 10,
      durationSecs: secs > 0 ? secs : null,
      caption: caption,
      posterUrl: '$url/thumb',
      // Fullscreen opens the in-thread media gallery (swipe through every
      // photo/GIF/video here); its own control then opens the immersive player.
      onFullscreen: () => _openImageViewer(url),
    );
  }

  void _openVideo(String url, Map<String, dynamic> msg) {
    // Hush any inline gallery video playing behind the theater.
    _galleryVideoPauseAll.value++;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog<void>(
      context: context,
      barrierColor: isDark ? Colors.black : Colors.white,
      builder: (dctx) => _ChatVideoPlayer(
        url: url,
        onKeep: _canHarmony ? () => _keepsakeMessage(msg) : null,
      ),
    );
  }

  Widget _fileBubble(String url, Map<String, dynamic> msg, Color textColor,
      ColorScheme scheme) {
    final name = (msg['media_name'] as String?) ?? 'File';
    final size = (msg['media_size'] as num?)?.toInt();
    // Live state comes from the app-wide DownloadManager (so it survives
    // leaving and re-opening the chat); the per-message flag only covers the
    // short "preparing" moment before the job starts.
    final job = DownloadManager.instance.job(url);
    final dlBusy = job != null || msg['__dlBusy'] == true;
    final dlP = job?.progress ?? (msg['__dlProgress'] as num?)?.toDouble();
    // "Owned" = the sender's own file (they always have it) OR a file this
    // device has already downloaded. Owned shows the Aluta mark; not-yet-owned
    // shows the download arrow.
    final isMine = msg['sender_id']?.toString() == _myId;
    final owned = isMine || _savedMediaKeys.contains(msg['media_url'] as String?);
    return GestureDetector(
      onTap: () => _openUrl(url, msg),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 244),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(20),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: scheme.primary.withAlpha(40),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(_fileIcon(name), color: scheme.primary, size: 22),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: textColor,
                          fontWeight: FontWeight.w600,
                          fontSize: 13)),
                  if (dlBusy)
                    Text(
                      dlP == null
                          ? 'Downloading\u2026'
                          : 'Downloading ${(dlP * 100).round()}%',
                      style: TextStyle(
                          color: scheme.primary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600),
                    )
                  else if (size != null && size > 0)
                    Text(_fmtBytes(size),
                        style: TextStyle(
                            color: textColor.withAlpha(150), fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(width: 2),
            // Explicit "Save to device" (Save As…) — becomes a live progress
            // ring while the file is downloading. Tapping the rest of the
            // bubble still opens/previews the file.
            if (dlBusy)
              // The progress ring doubles as the CANCEL button (✕ inside) —
              // for a download tapped by mistake.
              Tooltip(
                message: 'Cancel download',
                child: InkResponse(
                radius: 22,
                onTap: job == null
                    ? null
                    : () {
                        HapticFeedback.selectionClick();
                        DownloadManager.instance.cancel(url);
                      },
                child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: SizedBox(
                  width: 30,
                  height: 30,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 30,
                        height: 30,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.6,
                          value: dlP,
                          backgroundColor: textColor.withAlpha(38),
                          valueColor:
                              AlwaysStoppedAnimation<Color>(scheme.primary),
                        ),
                      ),
                      Icon(Icons.close_rounded,
                          size: 15, color: textColor.withAlpha(200)),
                    ],
                  ),
                ),
              ),
              ),
              )
            else if (owned)
              // Owned content → the file-open mark (always on the sender's
              // own bubble; on the receiver's once downloaded). Still tappable
              // to save again to a chosen location.
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                tooltip: isMine ? 'Your file' : 'Saved — tap to save again',
                // "It's here — open it": the file-open glyph in the brand
                // colour (was the Aluta logo, which read as branding, not
                // state).
                // A STATE mark, not another file glyph (the tile on the left
                // already says "file"): a tick over a tray = it's on this
                // device. Tap to save another copy.
                icon: Icon(Icons.download_done_rounded,
                    size: 22, color: scheme.primary),
                onPressed: () => _downloadMediaWithProgress(msg),
              )
            else
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                tooltip: 'Save to device',
                // Not yet owned → the plain download arrow.
                icon: Icon(Icons.download_rounded,
                    size: 20, color: textColor.withAlpha(180)),
                onPressed: () => _downloadMediaWithProgress(msg),
              ),
          ],
        ),
      ),
    );
  }

  IconData _fileIcon(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.pdf')) return Icons.picture_as_pdf_rounded;
    if (n.endsWith('.doc') || n.endsWith('.docx')) {
      return Icons.description_rounded;
    }
    if (n.endsWith('.xls') || n.endsWith('.xlsx') || n.endsWith('.csv')) {
      return Icons.table_chart_rounded;
    }
    if (n.endsWith('.zip') || n.endsWith('.rar')) return Icons.folder_zip_rounded;
    if (n.endsWith('.mp3') || n.endsWith('.wav') || n.endsWith('.m4a')) {
      return Icons.audiotrack_rounded;
    }
    if (n.endsWith('.mp4') || n.endsWith('.mov')) return Icons.movie_rounded;
    if (n.endsWith('.apk') || n.endsWith('.aab')) return Icons.android_rounded;
    if (n.endsWith('.exe') || n.endsWith('.msi') || n.endsWith('.msix')) {
      return Icons.desktop_windows_rounded;
    }
    if (n.endsWith('.ppt') || n.endsWith('.pptx')) return Icons.slideshow_rounded;
    if (n.endsWith('.txt') || n.endsWith('.md')) return Icons.article_rounded;
    return Icons.insert_drive_file_rounded;
  }

  Future<void> _openUrl(String url, Map<String, dynamic> msg) async {
    // Attachments are auth-protected: fetch the bytes WITH our token, save them
    // under the file's REAL name (with extension), and hand them to the system
    // viewer - a PDF opens in a PDF app, an APK goes to the package installer.
    // Reuse an already-downloaded copy when we can, and STREAM the fetch to disk
    // with a live % on the bubble (never buffer a big APK in RAM -> ANR).
    if (msg['__dlBusy'] == true) return;
    if (DownloadManager.instance.isBusy(url)) {
      showToast(context, 'Still downloading — it keeps going in the background');
      return;
    }
    try {
      final mime = ((msg['media_mime'] as String?) ?? '').trim();
      var name = ((msg['media_name'] as String?) ?? '').trim();
      if (name.isEmpty) {
        final seg = Uri.parse(url).pathSegments;
        name = seg.isNotEmpty ? seg.last : '';
      }
      name = name.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_').trim();
      if (name.isEmpty) {
        name = 'aluta_file_${DateTime.now().millisecondsSinceEpoch}';
      }
      if (!name.contains('.')) {
        final ext = _extForMime(mime);
        if (ext.isNotEmpty) name = '$name$ext';
      }

      final dir = await getTemporaryDirectory();
      // Each attachment gets its OWN temp subfolder, keyed by the unique
      // attachment id in its URL, so two files that share a display name
      // (e.g. two 'app-release.apk' builds) never collide and open the
      // wrong one. The file keeps its real name for the installer prompt.
      final seg = Uri.parse(url).pathSegments;
      final keyId = (seg.isNotEmpty ? seg.last : '${url.hashCode}')
          .replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
      final holder = Directory('${dir.path}/aluta_open/$keyId');
      if (!await holder.exists()) await holder.create(recursive: true);
      final file = File('${holder.path}/$name');
      final expected = (msg['media_size'] as num?)?.toInt() ?? 0;

      Future<bool> isComplete(File f) async {
        try {
          if (!await f.exists()) return false;
          final len = await f.length();
          return expected > 0 ? len == expected : len > 0;
        } catch (_) {
          return false;
        }
      }

      var ready = await isComplete(file);
      if (!ready) {
        File? cached;
        try {
          cached = await MediaStore.instance.cached(url);
        } catch (_) {}
        if (cached != null && await cached.length() > 0) {
          // Native file copy - no bytes through the Dart heap.
          if (cached.path != file.path) await cached.copy(file.path);
          ready = true;
        }
      }

      if (!ready) {
        // Runs in the app-wide DownloadManager: survives leaving this chat,
        // resumes from the partial file, keeps going with the screen off.
        // Tapping again while it runs just re-attaches to the same job.
        final res = await DownloadManager.instance.fetch(
          url,
          file,
          headers: mediaAuthHeaders(url),
          expectedTotal: expected,
          name: name,
          onRetry: (n) {
            if (n == 1 && mounted) {
              showToast(context,
                  'Connection dropped — it will continue where it stopped');
            }
          },
        );
        if (res.outcome == DownloadOutcome.cancelled) {
          if (mounted) showToast(context, 'Download cancelled');
          return;
        }
        if (!res.ok) {
          if (mounted) {
            showToast(
                context,
                res.outcome == DownloadOutcome.gone
                    ? 'This file has left the server (24 h) — ask to resend'
                    : 'Download paused — it continues from where it stopped',
                type: ToastType.error);
            // Gone from the server → whoever has it can send it again.
            if (res.outcome == DownloadOutcome.gone) _offerResendPill(msg);
          }
          return;
        }
        // Another caller may have fetched the same url to its own spot.
        if (res.file != null && res.file!.path != file.path) {
          await res.file!.copy(file.path);
        }
        _markMediaSaved(msg['media_url'] as String?);
        if (!mounted) {
          // Finished while you were elsewhere in the app: offer to open it
          // instead of throwing an installer/viewer over another screen.
          final effMime0 = (mime.isEmpty || mime == 'application/octet-stream')
              ? null
              : mime;
          scaffoldMessengerKey.currentState?.showSnackBar(SnackBar(
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 8),
            content: Text('$name downloaded'),
            action: SnackBarAction(
              label: 'Open',
              onPressed: () => OpenFilex.open(file.path, type: effMime0),
            ),
          ));
          return;
        }
      }

      final effMime =
          (mime.isEmpty || mime == 'application/octet-stream') ? null : mime;
      final result = await OpenFilex.open(file.path, type: effMime);
      if (result.type != ResultType.done) {
        await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
      }
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not open file', type: ToastType.error);
      }
    }
  }

  // Fallback extension for a file whose stored name lost its suffix, so the
  // system opener can still identify the type.
  String _extForMime(String mime) {
    switch (mime.toLowerCase()) {
      case 'application/pdf':
        return '.pdf';
      case 'application/vnd.android.package-archive':
        return '.apk';
      case 'application/msword':
        return '.doc';
      case 'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
        return '.docx';
      case 'application/vnd.ms-excel':
        return '.xls';
      case 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet':
        return '.xlsx';
      case 'application/vnd.ms-powerpoint':
        return '.ppt';
      case 'application/vnd.openxmlformats-officedocument.presentationml.presentation':
        return '.pptx';
      case 'text/plain':
        return '.txt';
      case 'application/zip':
        return '.zip';
      case 'audio/mpeg':
        return '.mp3';
      case 'video/mp4':
        return '.mp4';
      default:
        return '';
    }
  }

  /// Download a shared image and hand it to the system sheet so the user can
  /// save it to their gallery / Files. Reused by the image viewer's Save button.
  Future<void> _saveImage(String url) async {
    try {
      if (mounted) showToast(context, 'Downloading…');
      List<int>? bytes;
      // Prefer the on-device copy (survives the server purge).
      if (!kIsWeb) {
        try {
          final f = await MediaStore.instance.getFile(url, mediaAuthHeaders(url));
          if (f != null) bytes = await f.readAsBytes();
        } catch (_) {}
      }
      if (bytes == null || bytes.isEmpty) {
        final res = await appBusy.run(
            () => http.get(Uri.parse(url), headers: mediaAuthHeaders(url)));
        if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
          bytes = res.bodyBytes;
        }
      }
      if (bytes == null || bytes.isEmpty) {
        if (mounted) {
          showToast(context, 'Photo is no longer available',
              type: ToastType.error);
        }
        return;
      }
      var name = Uri.parse(url).pathSegments.isNotEmpty
          ? Uri.parse(url).pathSegments.last
          : '';
      if (name.isEmpty || !name.contains('.')) {
        name = 'aluta_image_${DateTime.now().millisecondsSinceEpoch}.jpg';
      }
      // Phone → gallery; desktop → a proper Save As… dialog.
      await _saveBytesToDevice(bytes, name, image: true);
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not save image', type: ToastType.error);
      }
    }
  }

  /// Save ANY received media message (shared song, PDF, doc, image, voice note)
  /// out to the user's own device storage. For ephemeral songs the server copy
  /// may already be purged, so we read from the LOCAL CACHE first and only fall
  /// back to the network while the bytes still live there. The bytes are then
  /// handed to [_saveBytesToDevice], which shows a real "Save As…" dialog.
  /// Download + save a file bubble's attachment while showing a live
  /// percentage in the bubble. Stashes transient progress on the message map
  /// (throttled to ~1% steps) and rebuilds.
  Future<void> _downloadMediaWithProgress(Map<String, dynamic> msg) async {
    if (msg['__dlBusy'] == true) return;
    rebuildWith(() {
      msg['__dlBusy'] = true;
      msg['__dlProgress'] = null;
    });
    try {
      final ok = await _saveMediaToDevice(msg, onProgress: (received, total) {
        if (!mounted) return;
        final q =
            total > 0 ? (received / total).clamp(0.0, 1.0).toDouble() : null;
        final prev = msg['__dlProgress'] as double?;
        if (q != null && prev != null && (q - prev).abs() < 0.01) return;
        rebuildWith(() => msg['__dlProgress'] = q);
      });
      if (ok) _markMediaSaved(msg['media_url'] as String?);
    } finally {
      if (mounted) {
        rebuildWith(() {
          msg['__dlBusy'] = false;
          msg['__dlProgress'] = null;
        });
      }
    }
  }

  Future<bool> _saveMediaToDevice(Map<String, dynamic> msg,
      {void Function(int received, int total)? onProgress}) async {
    final rel = msg['media_url'] as String?;
    if (rel == null || rel.isEmpty) return false;
    final name = (msg['media_name'] as String?)?.trim();
    final mime = msg['media_mime'] as String?;
    final type = (msg['message_type'] as String?) ?? 'file';
    final expected = (msg['media_size'] as num?)?.toInt() ?? 0;
    final ext = type == 'song' ? '.mp3' : '';
    // A song is saved under its real "Title - Artist" (the bubble's label),
    // not the raw upload name ("- Downloaded from clipzag.com (8).mp3"), and
    // the player is told the title/artist for the saved path.
    final song = type == 'song' ? _songTitleArtist(msg) : null;
    final outName = song != null
        ? _songFileName(song.$1, song.$2, name, mime)
        : (name == null || name.isEmpty)
            ? 'aluta_${type}_${DateTime.now().millisecondsSinceEpoch}$ext'
            : name;
    final meta = song == null
        ? null
        : track_meta.TrackMeta(
            title: song.$1, artist: song.$2.isEmpty ? null : song.$2);
    try {
      if (mounted) showToast(context, 'Preparing download…');

      // 1) Ephemeral song already on disk -> save straight from the cache file.
      final id = SongCache.assetId(rel);
      if (id != null) {
        final cached =
            await SongCache.cachedPath(id, filename: name, mime: mime);
        if (cached != null) {
          return await _saveFileToDevice(File(cached), outName, type,
              meta: meta);
        }
      }

      final url = fullMediaUrl(rel);

      // 2) Locally-persisted media-store copy (survives the server purge).
      if (!kIsWeb && id == null && onProgress == null) {
        try {
          final f =
              await MediaStore.instance.getFile(url, mediaAuthHeaders(url));
          if (f != null && await f.length() > 0) {
            return await _saveFileToDevice(f, outName, type, meta: meta);
          }
        } catch (_) {}
      }

      // 3) Stream the server copy to a temp file - never buffer a big file in
      //    RAM (that was the download-button ANR) - retrying on a dropped line.
      // A stable spot per attachment (not a timestamped temp name), so the
      // app-wide DownloadManager can resume it after navigation / sleep / a
      // restart, and a second tap joins the running job.
      final dir = await getTemporaryDirectory();
      final seg = Uri.parse(url).pathSegments;
      final keyId = (seg.isNotEmpty ? seg.last : '${url.hashCode}')
          .replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
      final tmp = File('${dir.path}/aluta_dl/$keyId/download');
      final res = await DownloadManager.instance.fetch(
        url,
        tmp,
        headers: mediaAuthHeaders(url),
        expectedTotal: expected,
        name: outName,
        onRetry: (n) {
          if (n == 1 && mounted) {
            showToast(context,
                'Connection dropped — it will continue where it stopped');
          }
        },
      );
      if (res.outcome == DownloadOutcome.cancelled) {
        if (mounted) showToast(context, 'Download cancelled');
        return false;
      }
      final ok = res.ok;
      if (ok && res.file != null && res.file!.path != tmp.path) {
        await res.file!.copy(tmp.path);
      }
      if (!ok || !await tmp.exists() || await tmp.length() == 0) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
        if (mounted) {
          showToast(context,
              type == 'song'
                  ? 'This song has left the server (24 h) — ask to resend'
                  : 'This file has left the server (24 h) — ask to resend',
              type: ToastType.error);
          _offerResendPill(msg);
        }
        return false;
      }
      // Cache the fetched copy so a later tap-to-open installs/opens straight
      // from disk (what the user asked for) instead of hitting the server again.
      await MediaStore.instance.store(url, tmp);
      final saved = await _saveFileToDevice(tmp, outName, type, meta: meta);
      try {
        await tmp.delete();
      } catch (_) {}
      return saved;
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not save', type: ToastType.error);
      }
      return false;
    }
  }

  /// Save an on-disk [src] to the user's device without loading a big file into
  /// the Dart heap: images to the gallery, files to Android's public Downloads
  /// (native, by PATH), everything else via the system Save dialog.
  /// (title, artist) of a song message from its "Title — Artist" label; null
  /// when the label is empty (then the file keeps its own name).
  (String, String)? _songTitleArtist(Map<String, dynamic> msg) {
    final label = (msg['content'] as String? ?? '').trim();
    if (label.isEmpty) return null;
    final i = label.indexOf(' — ');
    if (i <= 0) return (label, '');
    return (label.substring(0, i).trim(), label.substring(i + 3).trim());
  }

  /// "Title - Artist.mp3" — safe on every filesystem, keeping the original
  /// file's extension.
  String _songFileName(
      String title, String artist, String? original, String? mime) {
    var ext = '';
    final o = (original ?? '').trim();
    final dot = o.lastIndexOf('.');
    if (dot > 0 && o.length - dot <= 6) ext = o.substring(dot).toLowerCase();
    if (ext.isEmpty) {
      final m = (mime ?? '').toLowerCase();
      ext = m.contains('mp4') || m.contains('aac')
          ? '.m4a'
          : m.contains('wav')
              ? '.wav'
              : m.contains('ogg')
                  ? '.ogg'
                  : m.contains('flac')
                      ? '.flac'
                      : '.mp3';
    }
    final base = (artist.isEmpty ? title : '$title - $artist')
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final cut = base.length > 120 ? base.substring(0, 120).trim() : base;
    return '${cut.isEmpty ? 'Aluta song' : cut}$ext';
  }

  /// Tell the player the title/artist of a song file we just saved, so it
  /// never shows the raw file name when that file is played or added.
  Future<void> _rememberSavedSong(String path, track_meta.TrackMeta? meta) async {
    if (meta == null || path.isEmpty) return;
    try {
      await track_meta.metadataStore.load();
      await track_meta.metadataStore.set(path, meta);
    } catch (_) {}
  }

  Future<bool> _saveFileToDevice(File src, String fname, String type,
      {track_meta.TrackMeta? meta}) async {
    // Phone images -> gallery. Images are small, so reading the bytes here is
    // fine (PhotoManager has no by-path API).
    if (type == 'image' && _isMobile) {
      try {
        final perm = await PhotoManager.requestPermissionExtend();
        if (perm.hasAccess) {
          await PhotoManager.editor
              .saveImage(await src.readAsBytes(), filename: fname);
          if (mounted) {
            showToast(context, 'Saved to gallery', type: ToastType.success);
          }
          return true;
        }
      } catch (_) {/* fall through to the generic saver */}
    }
    // Android -> public Downloads by file PATH (no bytes through the heap).
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        final safe = fname.replaceAll(RegExp(r'[\\/]+'), '_').trim();
        final sdk = await _ChatPageState._downloadsCh.invokeMethod<int>('sdkInt') ?? 0;
        var allowed = true;
        if (sdk > 0 && sdk < 29) {
          allowed = (await Permission.storage.request()).isGranted;
        }
        if (allowed) {
          final where =
              await _ChatPageState._downloadsCh.invokeMethod<String>('saveToDownloads', {
            'srcPath': src.path,
            'fileName': safe.isEmpty ? 'aluta_file' : safe,
            'mimeType': null,
          });
          if (where != null) {
            // Public Downloads (MediaStore) — the path the device library
            // scan will report for it.
            await _rememberSavedSong(
                '/storage/emulated/0/Download/${safe.isEmpty ? 'aluta_file' : safe}',
                meta);
            if (mounted) {
              showToast(context, 'Saved to $where', type: ToastType.success);
            }
            return true;
          }
        }
      } catch (_) {/* fall through to the Save dialog */}
    }
    // Desktop / last resort -> Save As dialog. Reading bytes here is acceptable:
    // desktop has the RAM, and it is only the fallback on mobile.
    return await _saveBytesToDevice(await src.readAsBytes(), fname,
        image: type == 'image', meta: meta);
  }

  /// Present a real "Save As…" flow and write [bytes] there. `FilePicker.saveFile`
  /// (v12) shows a native Save dialog on desktop and the system "Save to"
  /// location picker on mobile, and — because `bytes` is passed — writes the
  /// file itself, returning the chosen path (null if the user cancels). If the
  /// platform doesn't support the dialog, we fall back to the share/save sheet.
  Future<bool> _saveBytesToDevice(List<int> bytes, String fname,
      {bool image = false, track_meta.TrackMeta? meta}) async {
    final data = Uint8List.fromList(bytes);
    // On a phone, drop images straight into the photo gallery (easy to find,
    // like WhatsApp) instead of a file-save dialog.
    if (image && _isMobile) {
      try {
        final perm = await PhotoManager.requestPermissionExtend();
        if (perm.hasAccess) {
          // saveImage returns a non-null AssetEntity on success and throws
          // otherwise, so reaching here means the save landed in the gallery.
          await PhotoManager.editor.saveImage(data, filename: fname);
          if (mounted) {
            showToast(context, 'Saved to gallery', type: ToastType.success);
          }
          return true;
        }
      } catch (_) {/* fall through to the generic saver */}
    }
    // Android: drop the file straight into the public Downloads folder — no
    // "Save to" picker. Falls through to the Save dialog only if that fails.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final where = await _saveToDownloads(data, fname);
      if (where != null) {
        await _rememberSavedSong(
            '/storage/emulated/0/Download/${fname.replaceAll(RegExp(r'[\\/]+'), '_').trim()}',
            meta);
        if (mounted) {
          showToast(context, 'Saved to Downloads', type: ToastType.success);
        }
        return true;
      }
    }
    try {
      final saved = await FilePicker.saveFile(
        dialogTitle: 'Save to device',
        fileName: fname,
        bytes: data,
      );
      // A null result is a user cancel, not an error.
      if (saved != null) {
        await _rememberSavedSong(saved, meta);
        if (mounted) {
          showToast(context, 'Saved to device', type: ToastType.success);
        }
        return true;
      }
      return false;
    } catch (_) {
      // saveFile unsupported here → fall back to the system share/save sheet.
      await _shareBytes(data, fname);
      return false;
    }
  }

  /// Fallback saver: write to a temp file and open the OS share/save sheet.
  Future<void> _shareBytes(Uint8List data, String fname) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$fname');
      await file.writeAsBytes(data, flush: true);
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not save', type: ToastType.error);
      }
    }
  }

  /// A desktop/window dropdown anchored at the pointer: a compact reaction row
  /// above the full action list, no full-screen blur. Tap outside or press
  /// Escape to dismiss.
  Future<void> _showAnchoredDropdown({
    required Offset anchor,
    required bool isMe,
    required WidgetBuilder reactionBarBuilder,
    required Widget Function(BuildContext, double) fullMenuBuilder,
  }) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Message actions',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 140),
      pageBuilder: (ctx, a1, a2) {
        final media = MediaQuery.of(ctx);
        final sw = media.size.width;
        final sh = media.size.height;
        final topSafe = media.padding.top + 8;
        final botSafe = media.padding.bottom + 8;
        const menuW = 250.0;
        double left = isMe ? anchor.dx - menuW : anchor.dx;
        left = left.clamp(8.0, (sw - 8 - menuW).clamp(8.0, sw));
        final belowRoom = sh - botSafe - anchor.dy;
        final aboveRoom = anchor.dy - topSafe;
        final below = belowRoom >= aboveRoom;
        final avail = (below ? belowRoom : aboveRoom) - 20;
        final menuMaxH = (avail - 72).clamp(120.0, sh);
        return AnimatedBuilder(
          animation: a1,
          builder: (context, _) {
            final t = Curves.easeOut.transform(a1.value.clamp(0.0, 1.0));
            final col = SizedBox(
              width: menuW,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  reactionBarBuilder(ctx),
                  const SizedBox(height: 8),
                  fullMenuBuilder(ctx, menuMaxH),
                ],
              ),
            );
            return Material(
              type: MaterialType.transparency,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(ctx).pop(),
                    ),
                  ),
                  Positioned(
                    left: left,
                    top: below ? anchor.dy.clamp(topSafe, sh - 40) : null,
                    bottom: below ? null : (sh - anchor.dy).clamp(0.0, sh),
                    child: Opacity(
                      opacity: t,
                      child: Transform.scale(
                        scale: 0.97 + 0.03 * t,
                        alignment:
                            isMe ? Alignment.topRight : Alignment.topLeft,
                        child: col,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Shows the message reaction bar + action menu as a SPOTLIGHT: the whole
  /// screen is dimmed and blurred EXCEPT a hole cut over the pressed bubble, so
  /// that one bubble stays crisp and lifted (WhatsApp / iMessage style). The
  /// reactions sit just above the bubble and the menu just below — flipping to
  /// the side with more room when the bubble is near a screen edge. Falls back
  /// to a centred panel if the bubble's rect couldn't be measured.
  Future<void> _showSpotlightPanel({
    required Rect? bubbleRect,
    required bool isMe,
    required WidgetBuilder reactionBarBuilder,
    required WidgetBuilder actionCardBuilder,
    bool separateBar = true,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Message actions',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, a1, a2) {
        final media = MediaQuery.of(ctx);
        final sw = media.size.width;
        final sh = media.size.height;
        final topSafe = media.padding.top + 8;
        final botSafe = media.padding.bottom + 8;
        return AnimatedBuilder(
          animation: a1,
          builder: (context, _) {
            final t = Curves.easeOutCubic.transform(a1.value.clamp(0.0, 1.0));
            final tb = Curves.easeOutBack.transform(a1.value.clamp(0.0, 1.0));
            final rect = bubbleRect;

            Widget dim = BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 8 * t, sigmaY: 8 * t),
              child: Container(
                color: Colors.black
                    .withValues(alpha: (isDark ? 0.34 : 0.24) * t),
              ),
            );
            if (rect != null) {
              dim = ClipPath(
                clipper: _HoleClipper(rect.inflate(4), 16),
                child: dim,
              );
            }

            final children = <Widget>[
              Positioned.fill(
                child: Opacity(
                  opacity: t,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(ctx).pop(),
                    child: dim,
                  ),
                ),
              ),
            ];

            if (rect == null) {
              children.add(Opacity(
                opacity: t,
                child: Transform.scale(
                  scale: 0.92 + 0.08 * tb,
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                          18, topSafe + 16, 18, botSafe + 16),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 440),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (separateBar) ...[
                              reactionBarBuilder(ctx),
                              const SizedBox(height: 10),
                            ],
                            Flexible(child: actionCardBuilder(ctx)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ));
            } else {
              final barH = separateBar ? 60.0 : 0.0;
              final gap = separateBar ? 10.0 : 8.0;
              final aboveRoom = rect.top - topSafe;
              final belowRoom = sh - botSafe - rect.bottom;
              final barAbove = separateBar && aboveRoom > barH + gap + 8;
              final barTop =
                  barAbove ? rect.top - gap - barH : rect.bottom + gap;

              // The unified card (reactions + actions) is a touch wider so six
              // emojis and five actions breathe in one line each.
              final menuW =
                  (sw - 24).clamp(0.0, separateBar ? 270.0 : 312.0);
              double menuLeft = isMe ? rect.right - menuW : rect.left;
              menuLeft = menuLeft.clamp(8.0, (sw - 8 - menuW).clamp(8.0, sw));

              // Reaction bar and action menu share the SAME width and left edge
              // so they stack as one balanced column aligned to the bubble's
              // side (matching the desktop dropdown), instead of the bar being
              // centred on the bubble and drifting out of line with the menu.
              final barW = menuW;
              final barLeft = menuLeft;

              // Prefer opening BELOW the bubble when the card fits there (like
              // the bubble "unfolds" its replies); otherwise above.
              final menuBelow = separateBar
                  ? belowRoom >= aboveRoom
                  : (belowRoom >= 150 || belowRoom >= aboveRoom);
              final Widget menu = Transform.scale(
                scale: 0.96 + 0.04 * tb,
                alignment: menuBelow
                    ? (isMe ? Alignment.topRight : Alignment.topLeft)
                    : (isMe ? Alignment.bottomRight : Alignment.bottomLeft),
                child: actionCardBuilder(ctx),
              );
              Widget menuPositioned;
              if (menuBelow) {
                final mTop = (barAbove || !separateBar)
                    ? rect.bottom + gap
                    : rect.bottom + gap + barH + gap;
                final maxH = (sh - botSafe - mTop).clamp(90.0, sh);
                menuPositioned = Positioned(
                  top: mTop,
                  left: menuLeft,
                  width: menuW,
                  child: Opacity(
                    opacity: t,
                    child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: maxH),
                        child: menu),
                  ),
                );
              } else {
                final mBottomY = (barAbove && separateBar)
                    ? rect.top - gap - barH - gap
                    : rect.top - gap;
                final maxH = (mBottomY - topSafe).clamp(90.0, sh);
                menuPositioned = Positioned(
                  bottom: sh - mBottomY,
                  left: menuLeft,
                  width: menuW,
                  child: Opacity(
                    opacity: t,
                    child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: maxH),
                        child: menu),
                  ),
                );
              }

              if (separateBar) {
                children.add(Positioned(
                top: barTop,
                left: barLeft,
                width: barW,
                child: Opacity(
                  opacity: t,
                  child: Transform.scale(
                    scale: 0.9 + 0.1 * tb,
                    child: reactionBarBuilder(ctx),
                  ),
                ),
              ));
              }
              children.add(menuPositioned);
            }

            return Material(
              type: MaterialType.transparency,
              child: Stack(children: children),
            );
          },
        );
      },
      transitionBuilder: (ctx, anim, sec, child) => child,
    );
  }

  /// WhatsApp-style "Message info": three buckets — Read, Delivered (received
  /// but not read), and Sent (not yet delivered) — for a message I sent to the
  /// group. One scrollable sheet, one section per category.
  void _showMessageInfo(Map<String, dynamic> msg) {
    final rawId = msg['id'];
    if (rawId == null) return;
    final mid = rawId is int ? rawId : int.tryParse(rawId.toString()) ?? 0;
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // No hand-made transitionAnimationController: one we own (vsynced to the
    // chat page or a Navigator) could stall on desktop, so pop() never
    // finished and the card stayed stuck on a black barrier. Let the route
    // own its controller; sheetAnimationStyle keeps the custom timing.
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: true,
      enableDrag: true,
      barrierColor: Colors.black54,
      // The card draws its own accent border — drop the theme's outer red
      // one so it isn't doubled up into a box-around-a-box.
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      elevation: 0,
      constraints: const BoxConstraints(maxWidth: 560),
      sheetAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 440),
        reverseDuration: Duration(milliseconds: 280),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.94,
        expand: false,
        builder: (c, scrollCtrl) {
          // Center it: the columns below stretch their children, which
          // otherwise turns this 40px handle into a full-width grey bar.
          final handle = Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10, bottom: 2),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          );

          Widget closeBtn() => Material(
                color: scheme.onSurface.withValues(alpha: isDark ? 0.14 : 0.06),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => Navigator.of(c).pop(),
                  child: Padding(
                    padding: const EdgeInsets.all(7),
                    child: Icon(Icons.close_rounded,
                        size: 18, color: scheme.onSurfaceVariant),
                  ),
                ),
              );

          Widget titleBar() => SizedBox(
                height: 42,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: scheme.primary.withValues(alpha: 0.14),
                          ),
                          child: Icon(Icons.done_all_rounded,
                              size: 15, color: scheme.primary),
                        ),
                        const SizedBox(width: 8),
                        Text('Message info',
                            style: TextStyle(
                                fontSize: 16.5,
                                fontWeight: FontWeight.w800,
                                color: scheme.onSurface)),
                      ],
                    ),
                    Positioned(
                      right: 6,
                      top: 0,
                      bottom: 0,
                      child: Center(child: closeBtn()),
                    ),
                  ],
                ),
              );

          Widget seenPill(int readCount, int total, {bool heart = false}) =>
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                        heart
                            ? Icons.favorite_rounded
                            : Icons.visibility_rounded,
                        size: 13,
                        color: scheme.primary),
                    const SizedBox(width: 6),
                    Text(
                        heart
                            ? 'Opened by $readCount of $total'
                            : 'Seen by $readCount of $total',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: scheme.primary)),
                  ],
                ),
              );

          final content = FutureBuilder<Map<String, dynamic>?>(
            future: ApiService().messageInfo(_cid, mid),
            builder: (c2, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    handle,
                    const SizedBox(height: 6),
                    titleBar(),
                    const SizedBox(height: 12),
                    const Divider(height: 1),
                    for (int k = 0; k < 4; k++) _infoSkeletonRow(scheme),
                  ],
                );
              }
              final data = snap.data;
              if (data == null) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    handle,
                    const SizedBox(height: 6),
                    titleBar(),
                    Padding(
                      padding: const EdgeInsets.all(30),
                      child: Text("Couldn't load message info.",
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                    ),
                  ],
                );
              }
              final read = (data['read'] as List?) ?? const [];
              final delivered = (data['delivered'] as List?) ?? const [];
              final sent = (data['sent'] as List?) ?? const [];
              // Secret heart: the server adds who actually OPENED it.
              final opened = data['opened'] as List?;
              final total = read.length + delivered.length + sent.length;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  handle,
                  const SizedBox(height: 6),
                  titleBar(),
                  if (total > 0) ...[
                    const SizedBox(height: 8),
                    Center(
                        child: opened != null
                            ? seenPill(opened.length, total, heart: true)
                            : seenPill(read.length, total)),
                  ],
                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  Flexible(
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      duration: const Duration(milliseconds: 360),
                      curve: Curves.easeOutCubic,
                      builder: (_, tv, child) => Opacity(
                        opacity: tv.clamp(0.0, 1.0),
                        child: Transform.translate(
                          offset: Offset(0, (1 - tv) * 14),
                          child: child,
                        ),
                      ),
                      child: ListView(
                        controller: scrollCtrl,
                        padding: const EdgeInsets.only(bottom: 16),
                        children: [
                          if (opened != null)
                            _infoSection('Opened the heart',
                                Icons.favorite_rounded,
                                const Color(0xFFE0447A), opened, scheme),
                          _infoSection('Read by', Icons.done_all_rounded,
                              const Color(0xFF1976D2), read, scheme),
                          _infoSection('Delivered to', Icons.done_all_rounded,
                              scheme.onSurfaceVariant, delivered, scheme),
                          _infoSection('Not yet received',
                              Icons.schedule_rounded, scheme.onSurfaceVariant,
                              sent, scheme),
                          if (read.isEmpty &&
                              delivered.isEmpty &&
                              sent.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(24),
                              child: Center(
                                child: Text(
                                    'No other members in this group yet.',
                                    style: TextStyle(
                                        color: scheme.onSurfaceVariant)),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          );

          return Container(
            margin: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(
                  color:
                      scheme.primary.withValues(alpha: isDark ? 0.26 : 0.12)),
              boxShadow: [
                BoxShadow(
                  color:
                      scheme.primary.withValues(alpha: isDark ? 0.20 : 0.10),
                  blurRadius: 30,
                  spreadRadius: -6,
                  offset: const Offset(0, 12),
                ),
                BoxShadow(
                  color: Colors.black.withAlpha(isDark ? 110 : 30),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): () =>
                    Navigator.of(c).pop(),
              },
              child: Focus(autofocus: true, child: content),
            ),
          );
        },
      ),
    );
  }

  /// A single shimmer-free skeleton row shown while message info loads.
  Widget _infoSkeletonRow(ColorScheme scheme) {
    Widget bar(double w, double h) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: scheme.onSurfaceVariant.withAlpha(28),
            borderRadius: BorderRadius.circular(6),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: scheme.onSurfaceVariant.withAlpha(28),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              bar(120, 11),
              const SizedBox(height: 7),
              bar(80, 9),
            ],
          ),
        ],
      ),
    );
  }

  /// One category block inside the Message-info sheet. Hidden when empty.
  /// The header is a soft tinted pill with a count chip; rows cascade in.
  Widget _infoSection(String title, IconData icon, Color color, List members,
      ColorScheme scheme) {
    if (members.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
            decoration: BoxDecoration(
              color: color.withAlpha(22),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 7),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: color,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(width: 7),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(
                    color: color.withAlpha(38),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${members.length}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        ...members.asMap().entries.map(
            (e) => _infoMemberTile(e.value, scheme, color, e.key)),
      ],
    );
  }

  Widget _infoMemberTile(
      dynamic m, ColorScheme scheme, Color accent, int index) {
    final username = (m['username'] ?? 'User').toString();
    final phone = (m['phone'] ?? '').toString();
    // Prefer the user's phonebook-saved name over the raw DB username.
    final saved =
        phone.isNotEmpty ? ContactNames.instance.nameFor(phone) : null;
    final name = (saved != null && saved.isNotEmpty) ? saved : username;
    final avatarRel = (m['avatar_url'] ?? '').toString();
    final avatar = avatarRel.isNotEmpty ? fullMediaUrl(avatarRel) : null;
    final ts = (m['timestamp'] ?? '').toString();

    final tile = ListTile(
      dense: true,
      leading: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: accent.withAlpha(110), width: 1.5),
        ),
        child: CircleAvatar(
          radius: 17,
          backgroundColor: scheme.primaryContainer,
          backgroundImage: avatar != null
              ? authNetworkImageProvider(avatar, mediaAuthHeaders(avatar))
              : null,
          child: avatar == null
              ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                  style: TextStyle(color: scheme.onPrimaryContainer))
              : null,
        ),
      ),
      title: Text(name,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: phone.isNotEmpty
          ? Text(phone,
              style: TextStyle(
                  fontSize: 11.5, color: scheme.onSurfaceVariant))
          : null,
      trailing: ts.isNotEmpty
          ? Text(_infoTime(ts),
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurfaceVariant))
          : null,
    );

    // Cascade: later rows arrive a touch after earlier ones.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 300 + index * 70),
      curve: Curves.easeOutCubic,
      builder: (_, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset((1 - t) * 10, 0),
          child: child,
        ),
      ),
      child: tile,
    );
  }

  /// Compact timestamp for a Message-info row (today → time only, else date).
  String _infoTime(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return '';
    final local = t.toLocal();
    final now = DateTime.now();
    final sameDay =
        local.year == now.year && local.month == now.month && local.day == now.day;
    return sameDay
        ? DateFormat('HH:mm').format(local)
        : DateFormat('MMM d, HH:mm').format(local);
  }

  // Parse the server reactions JSON ({"<uid>":"<emoji>"}) into a unique,
  // display-ready list of emojis.
  List<String> _reactionsOf(Map<String, dynamic> msg) {
    final raw = msg['reactions'];
    if (raw == null || (raw is String && raw.isEmpty)) return const [];
    try {
      final decoded = raw is String ? jsonDecode(raw) : raw;
      if (decoded is Map) {
        return decoded.values.map((e) => e.toString()).toSet().toList();
      }
    } catch (_) {}
    return const [];
  }

  // ── Jump to a quoted original ───────────────────────────────────────────────

  Map<String, dynamic>? _findQuotedMessage(String quoted, {String? replyId}) {
    final q = quoted.trim();
    if (q.isEmpty) return null;
    final qFirst = _quoteKey(q);
    // A heart quote: an older reply quoted just "❤️ Secret heart" (no
    // time), and a time written in another timezone won't match exactly —
    // so any heart is a fallback candidate for it.
    final heartQuote = q.startsWith('❤️ Secret heart');
    final exact = <Map<String, dynamic>>[];
    final loose = <Map<String, dynamic>>[];
    for (final m in _messages) {
      if (m['is_deleted'] == true) continue;
      // Match on the label a reply would have quoted (media → "📷 Photo",
      // heart → "❤️ Secret heart · 23 Oct, 9:12 PM", text → its text).
      final label = _replyQuoteText(m).trim();
      if (label.isEmpty) continue;
      if (label == q) {
        exact.add(m);
      } else if (_quoteKey(label) == qFirst ||
          (heartQuote && (m['message_type'] ?? '').toString() == 'heart')) {
        // Replies keep just the first line(s) of a long message.
        loose.add(m);
      }
    }
    final pool = exact.isNotEmpty ? exact : loose;
    if (pool.isEmpty) return null;
    if (pool.length == 1) return pool.first;
    // Several look the same ("📷 Photo", old heart quotes…): the one I was
    // replying to is the closest one sent BEFORE the reply.
    final rid = int.tryParse(replyId ?? '');
    if (rid != null) {
      Map<String, dynamic>? best;
      var bestId = -1;
      for (final m in pool) {
        final id = int.tryParse(m['id'].toString());
        if (id != null && id < rid && id > bestId) {
          bestId = id;
          best = m;
        }
      }
      if (best != null) return best;
    }
    return pool.first;
  }

  /// Normalised key for a quote: its first line, trimmed.
  String _quoteKey(String quoted) => quoted.trim().split('\n').first.trim();

  // ── Reply-author memory (this device) ─────────────────────────────────────
  // When I reply, I can SEE whose message I'm quoting, so remember it here,
  // per conversation, keyed by the quote's first line. Later — even after the
  // original has scrolled out of the loaded window or the app restarted — the
  // quote header still names that person. Members who never had the original
  // fall back to "Member".

  String get _quoteMemKey => 'quote_authors_v1_$_activeConvKey';

  Future<void> _loadQuoteAuthors() async {
    _quoteAuthors.clear(); // never carry another chat's memory over
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_quoteMemKey);
      if (raw == null || raw.isEmpty) return;
      final m = jsonDecode(raw);
      if (m is! Map) return;
      _quoteAuthors.addAll(m.map((k, v) =>
            MapEntry(k.toString(), Map<String, String>.from(v as Map))));
      if (mounted) rebuildWith(() {});
    } catch (_) {}
  }

  /// Remember who wrote [orig] under the quote [quoted]. Cheap + idempotent.
  void _rememberQuoteAuthor(String quoted, Map<String, dynamic> orig) {
    final key = _quoteKey(quoted);
    if (key.isEmpty) return;
    final Map sender = (orig['sender'] as Map?) ?? const {};
    final entry = <String, String>{
      'id': (orig['sender_id'] ?? '').toString(),
      'u': (sender['username'] ?? '').toString(),
      'p': (sender['phone'] ?? '').toString(),
    };
    final prev = _quoteAuthors[key];
    if (prev != null && prev['id'] == entry['id']) return;
    _quoteAuthors[key] = entry;
    // Keep the store small: drop the oldest beyond 400 quotes per chat.
    while (_quoteAuthors.length > 400) {
      _quoteAuthors.remove(_quoteAuthors.keys.first);
    }
    () async {
      try {
        final p = await SharedPreferences.getInstance();
        await p.setString(_quoteMemKey, jsonEncode(_quoteAuthors));
      } catch (_) {}
    }();
  }

  /// A remembered author → display label ("You", phone-book name, username).
  String? _rememberedAuthor(String quoted) {
    final e = _quoteAuthors[_quoteKey(quoted)];
    if (e == null) return null;
    if (e['id'] == _myId) return 'You';
    if (!_isGroup) return widget.friendName;
    return _groupMemberLabel({
      'sender_id': e['id'],
      'sender': {'username': e['u'] ?? '', 'phone': e['p'] ?? ''},
    });
  }

  /// The name to show on a reply-quote header — the author of the ORIGINAL
  /// quoted message, not of the reply. (Previously it used the reply's own
  /// sender, so a friend replying to your message showed her name instead of
  /// "You".) [replyIsMe] is only used as a fallback if the original isn't
  /// loaded, where a reply almost always quotes the other person.
  /// A quote that points at a STATUS (a status reply or a "caught you on my
  /// status" nudge), not at a chat message.
  bool _isStatusQuote(String q) =>
      q.startsWith('👀 Caught you on my status') ||
      q.startsWith('👀 You viewed my status') ||
      RegExp(r'^(📷|🎬|🎵|💬|✨) Status').hasMatch(q);

  bool _isStatusNudgeQuote(String q) =>
      q.startsWith('👀 Caught you on my status') ||
      q.startsWith('👀 You viewed my status');

  String _quotedAuthor(String quotedText, bool replyIsMe, {String? replyId}) {
    if (_isStatusQuote(quotedText)) {
      // Whose status: a nudge comes from the status's owner; a reply goes
      // TO the owner.
      final first = widget.friendName.split(' ').first;
      final ownerIsMe =
          _isStatusNudgeQuote(quotedText) ? replyIsMe : !replyIsMe;
      return ownerIsMe ? 'Your status' : '$first\'s status';
    }
    final orig = _findQuotedMessage(quotedText, replyId: replyId);
    if (orig != null) {
      _rememberQuoteAuthor(quotedText, orig);
      if (orig['sender_id'].toString() == _myId) return 'You';
      // In a GROUP, widget.friendName is the GROUP's title ("Family") — name
      // the member who actually wrote the quoted message instead: my saved
      // phone-book name for them, else their Aluta username.
      if (_isGroup) return _groupMemberLabel(orig);
      return widget.friendName;
    }
    // Not loaded right now → what this device remembers from when it saw it.
    final remembered = _rememberedAuthor(quotedText);
    if (remembered != null) return remembered;
    if (_isGroup) return 'Member';
    return replyIsMe ? widget.friendName : 'You';
  }

  /// A group message author's display name (phone-book name, else username).
  String _groupMemberLabel(Map<String, dynamic> m) {
    final Map sender = (m['sender'] as Map?) ?? const {};
    final phone = (sender['phone'] ?? '').toString();
    final saved = phone.isNotEmpty ? ContactNames.instance.nameFor(phone) : null;
    if (saved != null && saved.isNotEmpty) return saved;
    final uname = (sender['username'] ?? '').toString();
    if (uname.isNotEmpty) return uname;
    // Sender object missing (e.g. an optimistic copy): look them up in the
    // loaded member list.
    for (final mem in _groupMembers) {
      if (mem['user_id']?.toString() == m['sender_id']?.toString()) {
        return _memberName(mem);
      }
    }
    return 'Member';
  }

  // ── Pin a message (for a duration) ────────────────────────────────────────

  /// True if [msg] is currently pinned (pinned_until is in the future).
  bool _isPinned(Map<String, dynamic> msg) {
    final p = msg['pinned_until'];
    if (p == null) return false;
    final dt = DateTime.tryParse(p.toString());
    return dt != null && dt.isAfter(DateTime.now());
  }

  /// The message that should show in the pinned banner: the one with the
  /// latest still-active pin (single-pin-per-conversation), or null.
  Map<String, dynamic>? _activePinned() {
    Map<String, dynamic>? best;
    DateTime? bestUntil;
    for (final m in _messages) {
      if (m['is_deleted'] == true) continue;
      final p = m['pinned_until'];
      if (p == null) continue;
      final dt = DateTime.tryParse(p.toString());
      if (dt == null || !dt.isAfter(DateTime.now())) continue;
      if (bestUntil == null || dt.isAfter(bestUntil)) {
        best = m;
        bestUntil = dt;
      }
    }
    return best;
  }

  int _asId(dynamic id) => id is int ? id : int.tryParse(id.toString()) ?? -1;

  /// WhatsApp-style duration chooser, then pins for the chosen span.
  void _showPinDurationSheet(Map<String, dynamic> msg) {
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.symmetric(vertical: 10),
                width: 36,
                height: 3,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: Row(
                  children: [
                    Icon(Icons.push_pin_rounded,
                        size: 20, color: scheme.primary),
                    const SizedBox(width: 10),
                    Text('Pin this message for…',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface)),
                  ],
                ),
              ),
              const Divider(height: 1),
              _ActionTile(
                icon: Icons.schedule_rounded,
                label: '24 hours',
                onTap: () {
                  Navigator.pop(ctx);
                  _pinMessage(msg, 24);
                },
              ),
              _ActionTile(
                icon: Icons.schedule_rounded,
                label: '7 days',
                onTap: () {
                  Navigator.pop(ctx);
                  _pinMessage(msg, 24 * 7);
                },
              ),
              _ActionTile(
                icon: Icons.schedule_rounded,
                label: '30 days',
                onTap: () {
                  Navigator.pop(ctx);
                  _pinMessage(msg, 24 * 30);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// The banner shown at the top of the thread for the active pinned message.
  Widget _buildPinnedBanner() {
    final pinned = _activePinned();
    if (pinned == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: InkWell(
        onTap: () => _jumpDebounced(pinned['id'].toString()),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: scheme.primary, width: 3),
              bottom:
                  BorderSide(color: scheme.outlineVariant.withAlpha(80)),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              Icon(Icons.push_pin_rounded, size: 18, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Pinned message',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: scheme.primary)),
                    const SizedBox(height: 2),
                    Text(
                      _replyQuoteText(pinned),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurface),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Unpin',
                icon: Icon(Icons.close_rounded,
                    size: 18, color: scheme.onSurfaceVariant),
                onPressed: () => _unpinMessage(pinned),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Strip reply quote ─────────────────────────────────────────────────────

  String _stripQuote(String content) {
    final lines = content.split('\n');
    final skip = lines.takeWhile((l) => l.startsWith('> ')).length;
    if (skip == 0) return content;
    return lines.skip(skip + 1).join('\n').trim();
  }

  // Renders a shared location (message_type 'location'); content is JSON
  // {lat,lng}. A compact pin card that opens the coordinates in the device's
  // maps app.
  Widget _locationContent(Map<String, dynamic> msg, bool isMe, Color textColor,
      ColorScheme scheme) {
    double? lat, lng;
    String address = '';
    try {
      final j = jsonDecode((msg['content'] ?? '{}').toString());
      if (j is Map) {
        lat = (j['lat'] as num?)?.toDouble();
        lng = (j['lng'] as num?)?.toDouble();
        address = (j['address'] ?? '').toString();
      }
    } catch (_) {}
    final coords = (lat != null && lng != null)
        ? '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'
        : 'Shared location';
    // Lead with the address when we have it; fall back to raw coordinates.
    final detail = address.isNotEmpty ? address : coords;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: (lat != null && lng != null) ? () => _openMap(lat!, lng!) : null,
      child: Container(
        width: 232,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: textColor.withAlpha(18),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF26A69A).withAlpha(40),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.location_on_rounded,
                  color: Color(0xFF26A69A)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Location',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: textColor)),
                  const SizedBox(height: 2),
                  Text(detail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12, color: textColor.withAlpha(185))),
                  if (address.isNotEmpty)
                    Text(coords,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 10.5,
                            color: textColor.withAlpha(120))),
                  const SizedBox(height: 4),
                  const Text('Open in Maps',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF26A69A))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openMap(double lat, double lng) async {
    final geo = Uri.parse('geo:$lat,$lng?q=$lat,$lng');
    final web = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    try {
      if (await canLaunchUrl(geo)) {
        await launchUrl(geo, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(web, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not open maps', type: ToastType.error);
      }
    }
  }

  // Renders a shared contact (message_type 'contact'); content is JSON
  // {name, phone, phones}. A contact card with call + save actions.
  Widget _contactContent(Map<String, dynamic> msg, bool isMe, Color textColor,
      ColorScheme scheme) {
    String name = 'Contact';
    String phone = '';
    try {
      final j = jsonDecode((msg['content'] ?? '{}').toString());
      if (j is Map) {
        final n = (j['name'] ?? '').toString().trim();
        if (n.isNotEmpty) name = n;
        phone = (j['phone'] ?? '').toString().trim();
      }
    } catch (_) {}
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      width: 244,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: textColor.withAlpha(18),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: const Color(0xFF42A5F5).withAlpha(45),
                child: Text(initial,
                    style: const TextStyle(
                        color: Color(0xFF1E88E5),
                        fontWeight: FontWeight.bold,
                        fontSize: 18)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: textColor)),
                    if (phone.isNotEmpty)
                      Text(phone,
                          style: TextStyle(
                              fontSize: 12.5,
                              color: textColor.withAlpha(170))),
                  ],
                ),
              ),
            ],
          ),
          if (phone.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _dialNumber(phone),
                    icon: const Icon(Icons.call_rounded, size: 16),
                    label: const Text('Call'),
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        visualDensity: VisualDensity.compact),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _saveContact(name, phone),
                    icon: const Icon(Icons.person_add_alt_1_rounded, size: 16),
                    label: const Text('Save'),
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        visualDensity: VisualDensity.compact),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _dialNumber(String phone) async {
    try {
      await launchUrl(Uri(scheme: 'tel', path: phone));
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not open dialer', type: ToastType.error);
      }
    }
  }

  Future<void> _saveContact(String name, String phone) async {
    if (!_isMobile) return;
    try {
      final c = Contact()
        ..name.first = name
        ..phones = [Phone(phone)];
      // Opens the OS "new contact" editor prefilled — the user confirms.
      await FlutterContacts.openExternalInsert(c);
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not open contacts', type: ToastType.error);
      }
    }
  }

  // Open a tapped link from a message bubble in the external browser.
  Future<void> _openLink(String url) async {
    try {
      // Bare www./domain links (from LooseUrlLinkifier) carry no scheme — assume
      // https so the OS opens them in a browser rather than rejecting them.
      // Emails come through as mailto: from EmailLinkifier and are left as-is.
      var target = url.trim();
      if (!target.contains('://') && !target.startsWith('mailto:')) {
        target = 'https://$target';
      }
      final uri = Uri.parse(target);
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        showToast(context, 'Could not open link', type: ToastType.error);
      }
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not open link', type: ToastType.error);
      }
    }
  }

  // [muted] tints "sending / sent / delivered"; [read] highlights the read
  // receipt. Both are passed in so the ticks stay legible on either the dark
  // teal-green or the pale-mint sent bubble.
  Widget _buildStatusIcon(Map<String, dynamic> msg,
      {required Color muted, required Color read}) {
    final status = msg['status']?.toString();
    // Still uploading / sending: a small spinner sits in the tick slot — no
    // single tick yet. The composer stays free so more messages can queue.
    if (status == 'sending') {
      return SizedBox(
        width: 11,
        height: 11,
        child: CircularProgressIndicator(strokeWidth: 1.6, color: muted),
      );
    }
    // Send failed: a tappable retry marker in the tick slot.
    if (status == 'failed') {
      return GestureDetector(
        onTap: () => _retrySend(msg),
        child: Icon(Icons.error_outline_rounded,
            size: 14, color: Colors.redAccent),
      );
    }
    if (msg['is_read'] == true) {
      return Icon(Icons.done_all, size: 13, color: read);
    }
    if (msg['delivered'] == true) {
      return Icon(Icons.done_all, size: 13, color: muted);
    }
    return Icon(Icons.done, size: 13, color: muted);
  }

  // Checks if two adjacent messages (list is reversed = newer first) should
  // be grouped: same sender, within 3 minutes of each other.
  // Stable, readable colour per sender name (group sender labels) — same idea
  // as WhatsApp's per-participant name colours.
  // [on]: the bubble it's painted on — the colour is nudged to stay readable
  // there whatever the bubble theme.
  Color _senderColor(String name, bool isDark, {Color? on}) {
    int h = 0;
    for (final c in name.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    final hue = (h % 360).toDouble();
    final base =
        HSLColor.fromAHSL(1.0, hue, 0.55, isDark ? 0.72 : 0.42).toColor();
    return on == null ? base : bubbleTintOn(base, on);
  }

  bool _grouped(int index) {
    if (index + 1 >= _messages.length) return false;
    final curr = _messages[index];
    final prev = _messages[index + 1]; // older
    if (curr['sender_id'] != prev['sender_id']) return false;
    final tc = DateTime.tryParse(curr['timestamp'] ?? '');
    final tp = DateTime.tryParse(prev['timestamp'] ?? '');
    if (tc == null || tp == null) return false;
    // Group messages from the same sender sent within 30 s of each other
    // (the tight "almost the same time" window social apps use).
    return tc.difference(tp).inSeconds < 30;
  }

  Widget _buildDateSeparator(String label) {
    final scheme = Theme.of(context).colorScheme;
    final lineColor = scheme.onSurface.withAlpha(35);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      child: Row(
        children: [
          Expanded(child: Divider(height: 1, color: lineColor)),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 10),
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              // Solid, so no wallpaper can wash the date out.
              color: scheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: lineColor),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
          ),
          Expanded(child: Divider(height: 1, color: lineColor)),
        ],
      ),
    );
  }

  Widget _buildTypingIndicator() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    final recvBubble = isDark ? const Color(0xFF241E20) : Colors.white;

    // Who to show: group -> each typing member (avatar + kind); DM -> friend.
    final who = _isGroup
        ? _groupTypers.values.toList()
        : <({String avatar, String kind})>[
            (avatar: _friendAvatar, kind: _friendPresenceKind)
          ];
    if (who.isEmpty) return const SizedBox.shrink();
    final anyRecording = who.any((w) => w.kind == 'recording');
    final shown = who.take(3).toList();

    Widget avatarCircle(String rel) {
      final full = rel.isNotEmpty ? fullMediaUrl(rel) : '';
      return Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: scheme.surfaceContainerHighest,
          border: Border.all(color: scheme.primary.withAlpha(90), width: 1.5),
        ),
        child: ClipOval(
          child: full.isEmpty
              ? Icon(Icons.person_rounded,
                  size: 18, color: scheme.onSurfaceVariant)
              : Image(
                  image: authNetworkImageProvider(full, mediaAuthHeaders(full)),
                  width: 30,
                  height: 30,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Icon(Icons.person_rounded,
                      size: 18, color: scheme.onSurfaceVariant),
                ),
        ),
      );
    }

    final avatarStack = SizedBox(
      width: 30 + (shown.length - 1) * 16.0,
      height: 30,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(left: i * 16.0, child: avatarCircle(shown[i].avatar)),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(left: 12, top: 10, bottom: 6),
      child: TweenAnimationBuilder<double>(
        key: ValueKey('typing-${anyRecording ? 'rec' : 'dot'}-${shown.length}'),
        tween: Tween(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutBack,
        builder: (context, t, child) {
          final c = t.clamp(0.0, 1.0);
          return Opacity(
            opacity: c,
            child: Transform.scale(
                scale: 0.92 + 0.08 * c,
                alignment: Alignment.bottomLeft,
                child: child),
          );
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            avatarStack,
            const SizedBox(width: 2),
            CustomPaint(
                size: const Size(6, 14), painter: _TypingTail(recvBubble)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: recvBubble,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(14),
                  topRight: Radius.circular(14),
                  bottomRight: Radius.circular(14),
                  bottomLeft: Radius.circular(4),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(isDark ? 46 : 20),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: anyRecording
                    ? const _RecordingPulse(key: ValueKey('rec'))
                    : Row(
                        key: const ValueKey('dots'),
                        mainAxisSize: MainAxisSize.min,
                        children:
                            List.generate(3, (i) => _Dot(delay: i * 200)),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Short label describing a message for a reply quote/preview — media messages
  // get a typed label (📷 Photo / 🎤 Voice message / 📎 name) instead of blank.
  String _replyQuoteText(Map<String, dynamic> msg) {
    final type = (msg['message_type'] as String?) ?? 'text';
    // A secret heart never shows its note outside the heart itself — not in a
    // reply quote, not in the pinned banner (both read this label).
    // The heart's own time makes the quote point at THAT heart (several
    // "❤️ Secret heart" quotes all looked alike → a tap found the newest).
    if (type == 'heart') {
      final ts = (msg['timestamp'] ?? '').toString();
      if (ts.isEmpty) return '❤️ Secret heart';
      return '❤️ Secret heart · '
          '${DateFormat('d MMM, h:mm a').format(parseServerTime(ts))}';
    }
    final caption = _stripQuote((msg['content'] as String?) ?? '').trim();
    final isMedia =
        type != 'text' && (msg['media_url'] as String? ?? '').isNotEmpty;
    if (isMedia && caption.isEmpty) {
      switch (type) {
        case 'image':
          return '📷 Photo';
        case 'video':
          return '🎥 Video';
        case 'audio':
          return '🎤 Voice message';
        default:
          return '📎 ${(msg['media_name'] as String?) ?? 'File'}';
      }
    }
    // Structured cards store JSON in `content`; show a friendly label instead.
    if (type == 'location') return '📍 Location';
    if (type == 'contact') return '👤 Contact';
    return caption;
  }

  // Slim tappable banner inviting the user to save an unknown number.
  Widget _buildSaveContactBanner() {
    if (!_needsContactSave) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primary.withValues(alpha: 0.10),
      child: InkWell(
        onTap: _addFriendToContacts,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.person_add_alt_1_rounded,
                  size: 20, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Add to contacts',
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                            color: scheme.onSurface)),
                    Text(_friendPhone,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded,
                  size: 20, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmojiPicker(ColorScheme scheme) =>
      _emojiPickerFor(scheme, _ctrl);

  Widget _emojiPickerFor(ColorScheme scheme, TextEditingController controller,
      {double height = 262}) {
    return EmojiPicker(
                // When `textEditingController` is provided, EmojiPicker already
                // inserts the tapped emoji into it (at the cursor). Do NOT also
                // append it here — doing both made every emoji appear twice.
                onEmojiSelected: (_, _) {},
                textEditingController: controller,
                config: Config(
                  height: height,
                  emojiViewConfig: EmojiViewConfig(
                    emojiSizeMax: 26,
                    columns: 8,
                    backgroundColor: scheme.surface,
                    gridPadding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    recentsLimit: 40,
                    buttonMode: ButtonMode.MATERIAL,
                    noRecents: Text(
                      'No recent emoji yet',
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant),
                    ),
                  ),
                  categoryViewConfig: CategoryViewConfig(
                    backgroundColor: scheme.surfaceContainerHighest,
                    indicatorColor: scheme.primary,
                    iconColor: scheme.onSurfaceVariant,
                    iconColorSelected: scheme.primary,
                    dividerColor: scheme.outlineVariant.withAlpha(80),
                  ),
                  bottomActionBarConfig: BottomActionBarConfig(
                    backgroundColor: scheme.surfaceContainerHighest,
                    buttonColor: scheme.surfaceContainerHighest,
                    buttonIconColor: scheme.primary,
                  ),
                  searchViewConfig: SearchViewConfig(
                    backgroundColor: scheme.surfaceContainerHighest,
                    buttonIconColor: scheme.primary,
                    hintText: 'Search emoji',
                  ),
                ),
              );
  }
}

// A small speech-bubble tail (beak) pointing left toward the typist's avatar.
class _TypingTail extends CustomPainter {
  final Color color;
  _TypingTail(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(size.width, 2)
      ..lineTo(0, size.height / 2)
      ..lineTo(size.width, size.height - 2)
      ..close();
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant _TypingTail old) => old.color != color;
}

// A gently pulsing mic shown in the presence bubble while a peer records audio.
class _RecordingPulse extends StatefulWidget {
  const _RecordingPulse({super.key});
  @override
  State<_RecordingPulse> createState() => _RecordingPulseState();
}

class _RecordingPulseState extends State<_RecordingPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: SizedBox(
        height: 18,
        child: FadeTransition(
          opacity: Tween<double>(begin: 0.45, end: 1.0).animate(_c),
          child:
              const Icon(Icons.mic_rounded, size: 18, color: Colors.redAccent),
        ),
      ));
}
