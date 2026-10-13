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
      return (sm['username'] ?? 'Member').toString();
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
      onFullscreen: () => _openVideo(url, msg),
    );
  }

  void _openVideo(String url, Map<String, dynamic> msg) {
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
    final dlBusy = msg['__dlBusy'] == true;
    final dlP = (msg['__dlProgress'] as num?)?.toDouble();
    // "Owned" = the sender's own file (they always have it) OR a file this
    // device has already downloaded. Owned shows the Aluta mark; not-yet-owned
    // shows the download arrow.
    final isMine = msg['sender_id']?.toString() == _myId;
    final owned = isMine || _savedMediaKeys.contains(msg['media_url'] as String?);
    return GestureDetector(
      onTap: () => _openUrl(url),
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
              Padding(
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
                      if (dlP != null)
                        Text('${(dlP * 100).round()}',
                            style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                color: textColor)),
                    ],
                  ),
                ),
              )
            else if (owned)
              // Owned content → the Aluta mark (always on the sender's own
              // bubble; on the receiver's once downloaded). Still tappable to
              // save again to a chosen location.
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                tooltip: isMine ? 'Your file' : 'Saved — tap to save again',
                icon: ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: Image.asset(
                    'assets/images/logo.png',
                    width: 20,
                    height: 20,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Icon(
                        Icons.verified_rounded,
                        size: 20,
                        color: scheme.primary),
                  ),
                ),
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
    return Icons.insert_drive_file_rounded;
  }

  Future<void> _openUrl(String url) async {
    // Attachments are auth-protected now, so an external browser can't fetch
    // them. Download the bytes WITH our token, then hand the file to the system
    // sheet (open / save / share) — same pattern as saving an image.
    try {
      if (mounted) showToast(context, 'Opening…');
      final res = await http.get(Uri.parse(url), headers: mediaAuthHeaders(url));
      if (res.statusCode != 200) {
        if (mounted) {
          showToast(context, 'Could not open file', type: ToastType.error);
        }
        return;
      }
      var name = Uri.parse(url).pathSegments.isNotEmpty
          ? Uri.parse(url).pathSegments.last
          : '';
      if (name.isEmpty) {
        name = 'aluta_file_${DateTime.now().millisecondsSinceEpoch}';
      }
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(res.bodyBytes, flush: true);
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    } catch (_) {
      if (mounted) showToast(context, 'Could not open file', type: ToastType.error);
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
  /// Streamed GET that reports download progress (received/total) as bytes
  /// arrive, so a file bubble can show a live percentage. Returns the status
  /// and the full bytes (empty on non-200).
  Future<({int status, List<int> bytes})> _httpGetProgress(
      String url, void Function(int received, int total)? onProgress) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url))
        ..headers.addAll(mediaAuthHeaders(url));
      final resp = await client.send(req);
      if (resp.statusCode != 200) {
        return (status: resp.statusCode, bytes: const <int>[]);
      }
      final total = resp.contentLength ?? 0;
      final out = <int>[];
      var received = 0;
      await for (final chunk in resp.stream) {
        out.addAll(chunk);
        received += chunk.length;
        if (onProgress != null) onProgress(received, total);
      }
      return (status: 200, bytes: out);
    } finally {
      client.close();
    }
  }

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
        final q = total > 0 ? received / total : null;
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
    try {
      if (mounted) showToast(context, 'Preparing download…');
      List<int>? bytes;
      // Ephemeral song → prefer the on-device cache (survives server purge).
      final id = SongCache.assetId(rel);
      if (id != null) {
        final cached =
            await SongCache.cachedPath(id, filename: name, mime: mime);
        if (cached != null) bytes = await File(cached).readAsBytes();
      }
      // Prefer the locally-persisted copy (images/files survive the server's
      // store-and-forward purge on device), then fall back to the server while
      // it still holds the bytes.
      if (bytes == null || bytes.isEmpty) {
        final url = fullMediaUrl(rel);
        if (!kIsWeb && id == null && onProgress == null) {
          try {
            final f =
                await MediaStore.instance.getFile(url, mediaAuthHeaders(url));
            if (f != null) bytes = await f.readAsBytes();
          } catch (_) {}
        }
        // A dropped connection mid-download shouldn't fail the save: retry a
        // couple of times with a short pause. 410 (gone from the server) is
        // final, so stop there.
        for (var attempt = 0;
            attempt < 3 && (bytes == null || bytes.isEmpty);
            attempt++) {
          if (attempt > 0) {
            if (mounted) showToast(context, 'Connection dropped — retrying…');
            await Future.delayed(Duration(seconds: 2 * attempt));
          }
          try {
            final r =
                await appBusy.run(() => _httpGetProgress(url, onProgress));
            if (r.status == 200 && r.bytes.isNotEmpty) {
              bytes = r.bytes;
            } else if (r.status == 410 || r.status == 404) {
              break;
            }
          } catch (_) {
            // network error — loop and retry
          }
        }
      }
      if (bytes == null || bytes.isEmpty) {
        if (mounted) {
          showToast(context,
              type == 'song'
                  ? 'Song is no longer available'
                  : 'File is no longer available',
              type: ToastType.error);
        }
        return false;
      }
      final ext = type == 'song' ? '.mp3' : '';
      final fallback =
          'aluta_${type}_${DateTime.now().millisecondsSinceEpoch}$ext';
      return await _saveBytesToDevice(
          bytes, (name == null || name.isEmpty) ? fallback : name,
          image: type == 'image');
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not save', type: ToastType.error);
      }
      return false;
    }
  }

  /// Present a real "Save As…" flow and write [bytes] there. `FilePicker.saveFile`
  /// (v12) shows a native Save dialog on desktop and the system "Save to"
  /// location picker on mobile, and — because `bytes` is passed — writes the
  /// file itself, returning the chosen path (null if the user cancels). If the
  /// platform doesn't support the dialog, we fall back to the share/save sheet.
  Future<bool> _saveBytesToDevice(List<int> bytes, String fname,
      {bool image = false}) async {
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
                            reactionBarBuilder(ctx),
                            const SizedBox(height: 10),
                            Flexible(child: actionCardBuilder(ctx)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ));
            } else {
              const barH = 60.0;
              const gap = 10.0;
              final aboveRoom = rect.top - topSafe;
              final belowRoom = sh - botSafe - rect.bottom;
              final barAbove = aboveRoom > barH + gap + 8;
              final barTop =
                  barAbove ? rect.top - gap - barH : rect.bottom + gap;

              final menuW = (sw - 32).clamp(0.0, 270.0);
              double menuLeft = isMe ? rect.right - menuW : rect.left;
              menuLeft = menuLeft.clamp(8.0, (sw - 8 - menuW).clamp(8.0, sw));

              // Reaction bar and action menu share the SAME width and left edge
              // so they stack as one balanced column aligned to the bubble's
              // side (matching the desktop dropdown), instead of the bar being
              // centred on the bubble and drifting out of line with the menu.
              final barW = menuW;
              final barLeft = menuLeft;

              final menuBelow = belowRoom >= aboveRoom;
              final Widget menu = Transform.scale(
                scale: 0.96 + 0.04 * tb,
                alignment:
                    isMe ? Alignment.topRight : Alignment.topLeft,
                child: actionCardBuilder(ctx),
              );
              Widget menuPositioned;
              if (menuBelow) {
                final mTop = barAbove
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
                final mBottomY = barAbove
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

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.62,
        minChildSize: 0.4,
        maxChildSize: 0.94,
        expand: false,
        builder: (c, scrollCtrl) => Container(
          margin: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(20),
          ),
          clipBehavior: Clip.antiAlias,
          child: FutureBuilder<Map<String, dynamic>?>(
            future: ApiService().messageInfo(_cid, mid),
            builder: (c, snap) {
              final handle = Container(
                margin: const EdgeInsets.symmetric(vertical: 10),
                width: 36,
                height: 3,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              );
              if (snap.connectionState == ConnectionState.waiting) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    handle,
                    const Padding(
                      padding: EdgeInsets.all(40),
                      child: CircularProgressIndicator(),
                    ),
                  ],
                );
              }
              final data = snap.data;
              if (data == null) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    handle,
                    Padding(
                      padding: const EdgeInsets.all(30),
                      child: Text('Couldn\'t load message info.',
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                    ),
                  ],
                );
              }
              final read = (data['read'] as List?) ?? const [];
              final delivered = (data['delivered'] as List?) ?? const [];
              final sent = (data['sent'] as List?) ?? const [];
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  handle,
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('Message info',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface)),
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: ListView(
                      controller: scrollCtrl,
                      padding: const EdgeInsets.only(bottom: 16),
                      children: [
                        _infoSection('Read by', Icons.done_all_rounded,
                            const Color(0xFF1976D2), read, scheme),
                        _infoSection(
                            'Delivered to',
                            Icons.done_all_rounded,
                            scheme.onSurfaceVariant,
                            delivered,
                            scheme),
                        _infoSection('Not yet received', Icons.check_rounded,
                            scheme.onSurfaceVariant, sent, scheme),
                        if (read.isEmpty && delivered.isEmpty && sent.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Center(
                              child: Text('No other members in this group yet.',
                                  style: TextStyle(
                                      color: scheme.onSurfaceVariant)),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// One category block inside the Message-info sheet. Hidden when empty.
  Widget _infoSection(String title, IconData icon, Color color, List members,
      ColorScheme scheme) {
    if (members.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Text(
                '$title · ${members.length}',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: color,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
        ...members.map((m) => _infoMemberTile(m, scheme)),
      ],
    );
  }

  Widget _infoMemberTile(dynamic m, ColorScheme scheme) {
    final username = (m['username'] ?? 'User').toString();
    final phone = (m['phone'] ?? '').toString();
    // Prefer the user's phonebook-saved name over the raw DB username.
    final saved =
        phone.isNotEmpty ? ContactNames.instance.nameFor(phone) : null;
    final name = (saved != null && saved.isNotEmpty) ? saved : username;
    final avatarRel = (m['avatar_url'] ?? '').toString();
    final avatar = avatarRel.isNotEmpty ? fullMediaUrl(avatarRel) : null;
    final ts = (m['timestamp'] ?? '').toString();
    return ListTile(
      dense: true,
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: scheme.primaryContainer,
        backgroundImage: avatar != null
            ? authNetworkImageProvider(avatar, mediaAuthHeaders(avatar))
            : null,
        child: avatar == null
            ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: TextStyle(color: scheme.onPrimaryContainer))
            : null,
      ),
      title: Text(name, overflow: TextOverflow.ellipsis),
      subtitle: phone.isNotEmpty
          ? Text(phone,
              style: TextStyle(
                  fontSize: 11.5, color: scheme.onSurfaceVariant))
          : null,
      trailing: ts.isNotEmpty
          ? Text(_infoTime(ts),
              style: TextStyle(
                  fontSize: 11, color: scheme.onSurfaceVariant))
          : null,
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

  Map<String, dynamic>? _findQuotedMessage(String quoted) {
    final q = quoted.trim();
    if (q.isEmpty) return null;
    for (final m in _messages) {
      if (m['is_deleted'] == true) continue;
      final c = _stripQuote((m['content'] as String?) ?? '').trim();
      if (c.isNotEmpty && c == q) return m;
    }
    return null;
  }

  /// The name to show on a reply-quote header — the author of the ORIGINAL
  /// quoted message, not of the reply. (Previously it used the reply's own
  /// sender, so a friend replying to your message showed her name instead of
  /// "You".) [replyIsMe] is only used as a fallback if the original isn't
  /// loaded, where a reply almost always quotes the other person.
  String _quotedAuthor(String quotedText, bool replyIsMe) {
    final orig = _findQuotedMessage(quotedText);
    if (orig != null) {
      return orig['sender_id'].toString() == _myId ? 'You' : widget.friendName;
    }
    return replyIsMe ? widget.friendName : 'You';
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
        onTap: () => _jumpToMessage(pinned['id'].toString()),
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
    try {
      final j = jsonDecode((msg['content'] ?? '{}').toString());
      if (j is Map) {
        lat = (j['lat'] as num?)?.toDouble();
        lng = (j['lng'] as num?)?.toDouble();
      }
    } catch (_) {}
    final coords = (lat != null && lng != null)
        ? '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'
        : 'Shared location';
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
                  Text(coords,
                      style: TextStyle(
                          fontSize: 12, color: textColor.withAlpha(170))),
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
  Color _senderColor(String name, bool isDark) {
    int h = 0;
    for (final c in name.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    final hue = (h % 360).toDouble();
    return HSLColor.fromAHSL(1.0, hue, 0.55, isDark ? 0.72 : 0.42).toColor();
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
              // Slightly translucent — sits on top of wallpaper
              color: scheme.surface.withAlpha(220),
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
    return Padding(
      // Top gap gives the indicator room to breathe below the last bubble
      // (the list is reversed, so this padding sits ABOVE the indicator,
      // between it and the most recent message). Was tight before.
      padding: const EdgeInsets.only(left: 44, top: 12, bottom: 6),
      child: Builder(builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        // Match the incoming-message bubble: clean white on light, charcoal on
        // dark, with the same soft drop-shadow — so the dots read as a real
        // "received" bubble rather than a flat grey pill.
        final recvBubble =
            isDark ? const Color(0xFF241E20) : Colors.white;
        return Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: recvBubble,
              // Rounded like a bubble, with a slightly tighter bottom-left
              // corner echoing the received-bubble tail side.
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomRight: Radius.circular(18),
                bottomLeft: Radius.circular(6),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(isDark ? 46 : 20),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (i) => _Dot(delay: i * 200)),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${widget.friendName} is typing…',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withAlpha(130),
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
        );
      }),
    );
  }

  // Short label describing a message for a reply quote/preview — media messages
  // get a typed label (📷 Photo / 🎤 Voice message / 📎 name) instead of blank.
  String _replyQuoteText(Map<String, dynamic> msg) {
    final caption = _stripQuote((msg['content'] as String?) ?? '').trim();
    final type = (msg['message_type'] as String?) ?? 'text';
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
