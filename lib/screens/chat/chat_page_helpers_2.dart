part of '../chat_page.dart';

// Split out of chat_page.dart (pure code movement, no behaviour change):
// helper methods of _ChatPageState that don't call setState, moved into a
// private extension. A library `part`, so it shares the page's imports
// and reaches every private field and method.

extension _ChatPageHelpers2 on _ChatPageState {
  /// Derive a clean display title from a file path (basename without extension).
  String _titleFromPath(String path) {
    var name = path;
    final slash = name.lastIndexOf(RegExp(r'[\\/]'));
    if (slash >= 0) name = name.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    return name.trim().isEmpty ? 'Live song' : name.trim();
  }

  /// Ask whether to call over the internet (Aluta) or via the device dialer.
  /// Open a group member's profile card (tapped from their message header).
  void _openMemberProfile(String name, String phone, String avatarRel) {
    showUserProfile(
      context,
      username: name,
      phone: phone,
      avatarUrl: avatarRel.isNotEmpty ? fullMediaUrl(avatarRel) : null,
    );
  }

  /// Start an in-app WebRTC voice call. If we're offline, fall back to the
  /// device dialer, honouring "out of service → normal call".
  Future<void> _startAlutaCall() async {
    if (!ConnectionStatus.instance.isOnline) {
      if (mounted) {
        showToast(context, 'No internet — starting a phone call instead',
            type: ToastType.info);
      }
      _callFriend();
      return;
    }
    final myId = int.tryParse(_myId ?? '');
    if (myId == null) {
      if (mounted) {
        showToast(context, 'Please wait — still signing you in…',
            type: ToastType.error);
      }
      return;
    }
    final ok = await CallService.instance.startCall(
      peerId: widget.friendId,
      peerName: widget.friendName,
      peerAvatar: _friendAvatar,
      myName: _myName.isNotEmpty ? _myName : 'Aluta user',
      myAvatar: _myAvatar,
      fallbackPhone: _friendPhone,
    );
    if (!ok && mounted) {
      showToast(context, 'You’re already in a call', type: ToastType.info);
    }
  }

  // Direct call to the friend's saved phone number (tel: dialer).
  Future<void> _callFriend() async {
    final phone = _friendPhone.trim();
    if (phone.isEmpty) {
      if (mounted) {
        showToast(context, '${widget.friendName} has no phone number saved',
            type: ToastType.info);
      }
      return;
    }
    try {
      await launchUrl(Uri(scheme: 'tel', path: phone));
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not start the call', type: ToastType.error);
      }
    }
  }

  // ── Forward a message to another contact ──────────────────────────────────
  Future<void> _showForwardPicker(Map<String, dynamic> msg) async {
    List<Map<String, dynamic>> friends;
    try {
      friends = await ApiService().getFriends();
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not load contacts', type: ToastType.error);
      }
      return;
    }
    // Don't offer to forward to yourself.
    friends =
        friends.where((f) => f['id'].toString() != _myId).toList();
    if (!mounted) return;
    if (friends.isEmpty) {
      showToast(context, 'No contacts to forward to', type: ToastType.info);
      return;
    }
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(10),
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.6),
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
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Forward to',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface)),
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: friends.length,
                  itemBuilder: (_, i) {
                    final f = friends[i];
                    final name = (f['username'] ?? 'Friend').toString();
                    final rawA = f['avatar_url'] as String?;
                    final avatarUrl =
                        (rawA != null && rawA.isNotEmpty) ? fullMediaUrl(rawA) : null;
                    return ListTile(
                      leading: CircleAvatar(
                        radius: 20,
                        backgroundColor: scheme.primary.withAlpha(38),
                        backgroundImage: avatarUrl != null
                            ? authNetworkImageProvider(avatarUrl, mediaAuthHeaders(avatarUrl))
                            : null,
                        child: avatarUrl == null
                            ? Text(
                                name.isNotEmpty ? name[0].toUpperCase() : '?',
                                style: TextStyle(color: scheme.primary))
                            : null,
                      ),
                      title: Text(name),
                      onTap: () {
                        Navigator.pop(ctx);
                        _forwardTo(msg, f);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A genuine tap on the thread reveals the quick stars for a few seconds,
  /// then they fade away on their own (idle).
  void _pokeStars() {
    _quickStarsOn.value = true;
    _starTimer?.cancel();
    _starTimer = Timer(const Duration(milliseconds: 2600), () {
      _quickStarsOn.value = false;
    });
  }

  // Word-doc-style lists: pressing Enter after a "- ", "* ", "• " or
  // a numbered line continues the list with the next marker; pressing Enter
  // on an empty item ends the list. Triggered on the newline insertion (mobile
  // Enter, or desktop Shift+Enter — plain desktop Enter sends).
  void _maybeContinueList() {
    final text = _ctrl.text;
    final old = _lastComposerText;
    if (text.length != old.length + 1) return; // only a single-char insert
    final sel = _ctrl.selection;
    if (!sel.isValid || !sel.isCollapsed) return;
    final caret = sel.baseOffset;
    if (caret <= 0 || caret > text.length || text[caret - 1] != '\n') return;
    final before = text.substring(0, caret - 1);
    final lineStart = before.lastIndexOf('\n') + 1;
    final line = before.substring(lineStart);

    final bullet = RegExp(r'^(\s*)([-*•])\s+(.*)$').firstMatch(line);
    final number = RegExp(r'^(\s*)(\d+)([.)])\s+(.*)$').firstMatch(line);

    String nextMarker;
    bool emptyItem;
    if (bullet != null) {
      emptyItem = bullet.group(3)!.trim().isEmpty;
      nextMarker = '${bullet.group(1)}${bullet.group(2)} ';
    } else if (number != null) {
      emptyItem = number.group(4)!.trim().isEmpty;
      final n = int.tryParse(number.group(2)!) ?? 0;
      nextMarker = '${number.group(1)}${n + 1}${number.group(3)} ';
    } else {
      return;
    }

    if (emptyItem) {
      // End the list: drop the empty marker line and the newline.
      final newText = text.substring(0, lineStart) + text.substring(caret);
      _applyComposerEdit(newText, lineStart);
    } else {
      final newText =
          text.substring(0, caret) + nextMarker + text.substring(caret);
      _applyComposerEdit(newText, caret + nextMarker.length);
    }
  }

  void _applyComposerEdit(String newText, int caret) {
    _applyingListEdit = true;
    _ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: caret),
    );
    _applyingListEdit = false;
    _lastComposerText = newText;
  }

  // Desktop keyboards can't long-press a key for ½, so auto-convert a typed
  // "1/2" (etc.) to its glyph the moment a boundary char (space/punctuation,
  // not a digit or '/') is typed after it. Enter is left to the list handler.
  static final RegExp _fractionTrail = RegExp(r'(\d{1,3})/(\d{1,3})$');
  void _maybeFractionReplace() {
    final text = _ctrl.text;
    if (text.length != _lastComposerText.length + 1) return; // single insert
    final sel = _ctrl.selection;
    if (!sel.isValid || !sel.isCollapsed) return;
    final caret = sel.baseOffset;
    if (caret <= 0 || caret > text.length) return;
    final boundary = text[caret - 1];
    if (boundary == '\n' || RegExp(r'[0-9/]').hasMatch(boundary)) return;
    final before = text.substring(0, caret - 1);
    final m = _fractionTrail.firstMatch(before);
    if (m == null) return;
    final glyph = fractionGlyph(m.group(0)!);
    if (glyph == null) return;
    // Don't convert if a digit sits right before the fraction (e.g. 51/2).
    if (m.start > 0 && RegExp(r'\d').hasMatch(before[m.start - 1])) return;
    final newText =
        text.substring(0, m.start) + glyph + text.substring(caret - 1);
    _applyComposerEdit(newText, m.start + glyph.length + 1);
  }

  void _showErrorSnack(String msg) =>
      showToast(context, msg, type: ToastType.error);

  // ── Optimistic send ───────────────────────────────────────────────────────
  // A message shows in the thread the instant it's sent, with a spinner in the
  // tick slot, while its upload/send runs in the background. This keeps the
  // composer free (the user can fire off more while one is still in flight) and
  // moves the "working" feedback onto the bubble itself.
  String _newTempId() => 'tmp-${DateTime.now().microsecondsSinceEpoch}';

  Map<String, dynamic> _optimisticMsg(String tempId, String type, String content) {
    return {
      'id': tempId,
      'sender_id': _myId ?? '',
      'content': content,
      'message_type': type,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'status': 'sending',
      'delivered': false,
      'is_read': false,
      '__pending': true,
    };
  }

  // Shared presenter for the chat's floating popups (attach sheet, message
  // menu): a frosted-blur backdrop with a spring scale + slide-up, all wrapped
  // in a Material so text/ink render properly (no raw-overlay default style).
  // A menu that genies out of a screen anchor (the composer's "+" button):
  // it scales up from the button on open and collapses back into it on
  // dismiss, with a tail pointing down to it. A full-screen tap layer closes
  // it reliably on every platform — desktop/web included — not just by swipe.
  // A menu that genies out of a screen anchor (the composer's "+" button).
  // The anchor is read LIVE from [anchorKey] on every build, and the build
  // depends on MediaQuery, so as the keyboard retracts and the composer slides
  // down the menu follows the button to its real resting place — no timing
  // guesswork. It collapses back into the button on dismiss, with a tail
  // pointing at it; a full-screen tap layer closes it on every platform.
  Future<void> _showGeniePanel({
    required GlobalKey anchorKey,
    required Widget Function(BuildContext, Rect) builder,
    String label = 'Menu',
  }) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: label,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (ctx, a1, a2) {
        return Material(
          type: MaterialType.transparency,
          child: AnimatedBuilder(
            animation: a1,
            builder: (context, _) {
              // Read screen + "+" position EACH build. Touching viewInsets
              // registers a keyboard dependency so this rebuilds (and re-reads
              // the button) throughout the keyboard animation.
              final mq = MediaQuery.of(context);
              final screen = mq.size;
              // ignore: unused_local_variable
              final kbTick = mq.viewInsets.bottom;
              Rect anchor;
              final ro = anchorKey.currentContext?.findRenderObject();
              if (ro is RenderBox && ro.attached && ro.hasSize) {
                anchor = ro.localToGlobal(Offset.zero) & ro.size;
              } else {
                anchor = Rect.fromLTWH(
                    screen.width - 60, screen.height - 120, 44, 44);
              }

              const margin = 8.0;
              const radius = 20.0;
              const tailW = 20.0;
              const tailH = 10.0;
              // Phone: centred + capped so it never reaches the edges. Wide:
              // hug the "+". Either way the tail aims at the "+".
              final narrow = screen.width < 520;
              final cardW =
                  narrow ? (screen.width - 48).clamp(240.0, 320.0) : 340.0;
              final double cardRight;
              if (narrow) {
                final left = (screen.width - cardW) / 2;
                cardRight = screen.width - left;
              } else {
                cardRight =
                    (anchor.right + 8).clamp(120.0, screen.width - margin);
              }
              final rightInset = screen.width - cardRight;
              final bottomInset = screen.height - anchor.top + 6;
              final tailFromRight = (cardRight - anchor.center.dx)
                  .clamp(radius + tailW / 2, cardW - radius - tailW / 2);
              final cardColor = isDark
                  ? Color.alphaBlend(
                      Colors.white.withValues(alpha: 0.09), scheme.surface)
                  : scheme.surface;

              final v = a1.value.clamp(0.0, 1.0);
              final t = Curves.easeOutCubic.transform(v);
              final tb = Curves.easeOutBack.transform(v);
              return Stack(
                children: [
                  // Tap anywhere outside the card to dismiss (works on desktop
                  // and web too). A faint scrim, no blur.
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(ctx).pop(),
                      child: Container(
                        color: Colors.black.withValues(
                            alpha: (isDark ? 0.28 : 0.12) * t),
                      ),
                    ),
                  ),
                  Positioned(
                    right: rightInset,
                    bottom: bottomInset,
                    child: Opacity(
                      opacity: t,
                      child: Transform.scale(
                        alignment: Alignment.bottomRight,
                        scale: 0.16 + 0.84 * tb,
                        child: Material(
                          color: cardColor,
                          elevation: 12,
                          shadowColor: Colors.black
                              .withValues(alpha: isDark ? 0.6 : 0.22),
                          shape: _MenuBubbleBorder(
                            radius: radius,
                            tailWidth: tailW,
                            tailHeight: tailH,
                            tailFromRight: tailFromRight,
                          ),
                          child: SizedBox(
                              width: cardW, child: builder(context, anchor)),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
      transitionBuilder: (ctx, anim, sec, child) => child,
    );
  }

  /// When a chosen contact has several numbers, ask which one to share.
  Future<String?> _chooseNumber(String name, List<String> phones) {
    return showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text('$name — choose a number',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
            ),
            ...phones.map((p) => ListTile(
                  leading: const Icon(Icons.phone_rounded),
                  title: Text(p),
                  onTap: () => Navigator.pop(ctx, p),
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      // The camera opens the shared in-app camera, which can return a PHOTO or
      // a recorded VIDEO (Photo/Video toggle, plus hold-to-record on mobile).
      // A recorded clip is routed through the same compress+send path as a
      // gallery video; a still goes to the image preview. The in-app camera
      // also gives accurate, cause-specific messages (https-needed,
      // allow-permission, in-use, or truly no camera).
      if (source == ImageSource.camera) {
        final r = await captureMedia(context);
        if (r == null) return;
        if (r.isVideo) {
          await _processAndSendVideo(r.file);
        } else {
          final bytes = await r.file.readAsBytes();
          await _previewAndSendImage(bytes, r.file.name, 'image/jpeg');
        }
        return;
      }
      // Pick at high quality; the compress-on-upload step (or the HD toggle in
      // the preview) decides final size, so HD can send near-original quality.
      final x = await ImagePicker()
          .pickImage(source: source, imageQuality: 92, maxWidth: 2560);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      await _previewAndSendImage(bytes, x.name, 'image/jpeg');
    } catch (_) {
      if (mounted) showToast(context, 'Could not pick image', type: ToastType.error);
    }
  }

  /// Show a full-screen preview of the picked image with a caption box, so the
  /// user can add a message and send image + text as ONE bubble. Returns
  /// without sending if the user backs out of the preview.
  Future<bool> _previewAndSendImage(
      Uint8List bytes, String filename, String mime,
      {int index = 0, int total = 0}) async {
    if (!mounted) return false;
    final result = await Navigator.of(context).push<Map<String, dynamic>?>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _ImagePreviewScreen(
          imageBytes: bytes,
          friendName: widget.friendName,
          index: index,
          total: total,
        ),
      ),
    );
    // null → the user cancelled/backed out. Otherwise the map carries the
    // (possibly annotated) bytes, its mime, and the caption.
    if (result == null || !mounted) return false;
    final outBytes = (result['bytes'] as Uint8List?) ?? bytes;
    final outMime = (result['mime'] as String?) ?? mime;
    final caption = ((result['caption'] as String?) ?? '').trim();
    final hd = (result['hd'] as bool?) ?? false;
    // If the editor flattened to PNG, make the filename match so the server
    // stores the right extension/content-type.
    var outName = filename;
    if (outMime == 'image/png' && !outName.toLowerCase().endsWith('.png')) {
      final dot = outName.lastIndexOf('.');
      outName = '${dot > 0 ? outName.substring(0, dot) : outName}.png';
    }
    await _uploadAndSend(
      bytes: outBytes,
      filename: outName,
      mime: outMime,
      type: 'image',
      caption: caption,
      hd: hd,
    );
    return true;
  }

  // Gallery supports selecting several photos at once. A single pick keeps the
  // normal preview; multiple are previewed + sent one after another ("Photo i
  // of N"), and backing out of a preview stops the remaining ones.
  Future<void> _pickGalleryImages() async {
    try {
      final files = await ImagePicker()
          .pickMultiImage(imageQuality: 92, maxWidth: 2560);
      if (files.isEmpty) return;
      if (files.length == 1) {
        final x = files.first;
        final bytes = await x.readAsBytes();
        await _previewAndSendImage(bytes, x.name, 'image/jpeg');
        return;
      }
      for (var i = 0; i < files.length; i++) {
        if (!mounted) break;
        final x = files[i];
        final bytes = await x.readAsBytes();
        final sent = await _previewAndSendImage(
            bytes, x.name, 'image/jpeg',
            index: i + 1, total: files.length);
        if (!sent) break; // user backed out → stop sending the rest
      }
    } catch (_) {
      if (mounted) {
        showToast(context, 'Could not pick images', type: ToastType.error);
      }
    }
  }

  String _mimeForExt(String ext) {
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'pdf':
        return 'application/pdf';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
      case 'aac':
        return 'audio/mp4';
      case 'wav':
        return 'audio/wav';
      case 'mp4':
        return 'video/mp4';
      case 'apk':
        return 'application/vnd.android.package-archive';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'pptx':
        return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      case 'zip':
        return 'application/zip';
      default:
        return 'application/octet-stream';
    }
  }

  Future<void> _uploadAndSend({
    required List<int> bytes,
    required String filename,
    required String mime,
    required String type,
    int? durationMs,
    String caption = '',
    bool hd = false,
    bool ephemeral = false,
  }) async {
    // Show the bubble immediately with a spinner in the tick slot; the upload +
    // send run in the background so the composer never blocks. The original
    // (uncompressed) bytes/mime/name are captured for the attempt so a retry
    // starts clean.
    final tempId = _newTempId();
    final convKey = _activeConvKey;
    final optimistic = _optimisticMsg(tempId, type, caption);
    optimistic['media_name'] = filename;
    optimistic['media_mime'] = mime;
    optimistic['media_size'] = bytes.length;
    optimistic['media_duration'] = durationMs;
    optimistic['__upProgress'] = 0.0;
    if (type == 'image') {
      // A local preview so the sent photo shows while it uploads.
      optimistic['__localBytes'] = Uint8List.fromList(bytes);
    }
    _insertOptimistic(optimistic);

    final origBytes = bytes;
    final origMime = mime;
    final origName = filename;

    Future<void> attempt() async {
      var sendBytes = origBytes;
      var sendMime = origMime;
      var sendName = origName;
      try {
        // Compress images before upload to keep server storage + bandwidth
        // down. Skipped when HD is on (send the original) — but still forced if
        // the original exceeds the 15 MB upload cap. GIFs and small images pass
        // through untouched.
        final tooBigForRaw = sendBytes.length > 15 * 1024 * 1024;
        if (type == 'image' &&
            sendMime != 'image/gif' &&
            (!hd || tooBigForRaw) &&
            sendBytes.length > 350 * 1024) {
          try {
            final compressed = await compute(
                _compressChatImage, Uint8List.fromList(sendBytes));
            if (compressed.isNotEmpty && compressed.length < sendBytes.length) {
              sendBytes = compressed;
              sendMime = 'image/jpeg';
              final dot = sendName.lastIndexOf('.');
              sendName =
                  '${dot > 0 ? sendName.substring(0, dot) : sendName}.jpg';
              if (hd && tooBigForRaw && mounted) {
                showToast(context, 'Original too large — sent compressed',
                    type: ToastType.info);
              }
            }
          } catch (_) {/* keep the original bytes on any failure */}
        }
        final up = await appBusy.run(() => ApiService().uploadMedia(
            bytes: sendBytes,
            filename: sendName,
            mime: sendMime,
            ephemeral: ephemeral,
            onProgress: (sent, total) => UploadManager.instance.progress(
                convKey,
                tempId,
                // Bytes handed to the socket aren't "done" — the server still
                // has to receive + accept them, then we create the message.
                // Map the byte phase to 0..90% and let the final steps carry
                // it smoothly to 100%, so it never slams to ~99% then stalls.
                total > 0 ? (sent / total * 0.90).clamp(0.0, 0.90) : null)));
        if (up == null || up['url'] == null) {
          UploadManager.instance.finish(convKey, tempId, null);
          if (mounted) {
            showToast(context, 'Upload failed — tap the ! to retry',
                type: ToastType.error);
          }
          return;
        }
        // File is on the server; keep the ring moving while the message row is
        // created (the animated bar eases, so this reads as one smooth fill).
        UploadManager.instance.progress(convKey, tempId, 0.96);
        final sent = await appBusy.run(() => ApiService().sendMessage(
              widget.friendId,
              // Caption travels as the message content, so an image + text
              // render in ONE bubble (image, then this text below).
              caption,
              messageType: type,
              mediaUrl: up['url'] as String,
              mediaName: (up['name'] ?? sendName) as String?,
              mediaMime: (up['mime'] ?? sendMime) as String?,
              mediaSize: (up['size'] as num?)?.toInt(),
              mediaDuration: durationMs,
              conversationId: widget.conversationId,
            ));
        if (sent != null) {
          // Truly done now (uploaded AND the message was created). Fill the
          // ring to 100% and confirm with a "Sent" toast, then let the
          // optimistic bubble swap to the real sent message.
          UploadManager.instance.progress(convKey, tempId, 1.0);
          if (mounted) showToast(context, 'Sent', type: ToastType.success);
          await Future.delayed(const Duration(milliseconds: 600));
        } else if (mounted) {
          showToast(context, 'Could not send — tap the ! to retry',
              type: ToastType.error);
        }
        UploadManager.instance.finish(convKey, tempId, sent);
      } catch (_) {
        UploadManager.instance.finish(convKey, tempId, null);
        if (mounted) {
          showToast(context, 'Upload failed — tap the ! to retry',
              type: ToastType.error);
        }
      }
    }

    UploadManager.instance.begin(convKey, optimistic, attempt);
  }

  String _fmtBytes(int? n) {
    if (n == null || n <= 0) return '';
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _fmtDur(int ms) {
    final s = ms ~/ 1000;
    final m = s ~/ 60;
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$m:$ss';
  }


  // ── Media message rendering ─────────────────────────────────────────────
  // Renders an optimistic (still-uploading) media bubble: the local photo for
  // images, otherwise a compact "Uploading…" card with the right icon. The
  // spinner lives in the tick slot, so this just shows what's on its way.
  Widget _pendingMediaContent(
      String type, Map<String, dynamic> msg, Color textColor) {
    final local = msg['__localBytes'];
    if (type == 'image' && local is Uint8List) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
              maxWidth: 240, maxHeight: 300, minWidth: 120, minHeight: 80),
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              Image.memory(local, fit: BoxFit.cover),
              Positioned.fill(
                child: Container(color: Colors.black.withValues(alpha: 0.12)),
              ),
            ],
          ),
        ),
      );
    }
    IconData ic;
    String fallbackLabel;
    switch (type) {
      case 'video':
        ic = Icons.videocam_rounded;
        fallbackLabel = 'Video';
        break;
      case 'audio':
        ic = Icons.mic_rounded;
        fallbackLabel = 'Voice note';
        break;
      case 'song':
        ic = Icons.music_note_rounded;
        fallbackLabel = 'Song';
        break;
      default:
        ic = Icons.insert_drive_file_rounded;
        fallbackLabel = 'File';
    }
    final name = (msg['media_name'] as String?)?.trim();
    final label = (name == null || name.isEmpty) ? fallbackLabel : name;
    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: textColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Builder(builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        final p = (msg['__upProgress'] as num?)?.toDouble();
        final determinate = p != null && p > 0;
        final target = (p ?? 0.0).clamp(0.0, 1.0);
        // TweenAnimationBuilder eases the ring + percent between milestone
        // targets, so the fill reads as one continuous motion to 100% instead
        // of racing to ~99% and jumping.
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: target),
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeOut,
          builder: (context, v, _) {
            final pctInt = (v * 100).round();
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(ic, size: 22, color: textColor.withValues(alpha: 0.85)),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: textColor,
                              fontWeight: FontWeight.w600,
                              fontSize: 13)),
                      const SizedBox(height: 3),
                      Text(
                        determinate ? 'Uploading $pctInt%' : 'Uploading\u2026',
                        style: TextStyle(
                            color: scheme.primary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                // Same progress ring as the download bubble, for symmetry.
                SizedBox(
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
                          value: determinate ? v : null,
                          backgroundColor: textColor.withValues(alpha: 0.15),
                          valueColor:
                              AlwaysStoppedAnimation<Color>(scheme.primary),
                        ),
                      ),
                      if (determinate)
                        Text('$pctInt',
                            style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                color: textColor)),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      }),
    );
  }

  Widget _mediaContent(String type, String rel, Map<String, dynamic> msg,
      bool isMe, Color textColor, ColorScheme scheme, {String? caption}) {
    // Still uploading: show a local preview (images) or a compact placeholder.
    if (msg['__pending'] == true) {
      return _pendingMediaContent(type, msg, textColor);
    }
    final url = fullMediaUrl(rel);
    switch (type) {
      case 'image':
        return _imageBubble(url);
      case 'audio':
        return _VoiceNotePlayer(
          url: url,
          durationMs: (msg['media_duration'] as num?)?.toInt() ?? 0,
          accent: scheme.primary,
          onColor: textColor,
        );
      case 'song':
        return _SongBubble(
          assetId: SongCache.assetId(rel),
          url: url,
          title: (msg['content'] as String?)?.trim().isNotEmpty == true
              ? (msg['content'] as String).trim()
              : ((msg['media_name'] as String?) ?? 'Song'),
          fileName: msg['media_name'] as String?,
          mime: msg['media_mime'] as String?,
          isMe: isMe,
          accent: scheme.primary,
          onColor: textColor,
          onDownload: () => _saveMediaToDevice(msg),
        );
      case 'video':
        return _videoBubble(url, msg, scheme, caption: caption);
      default:
        return _fileBubble(url, msg, textColor, scheme);
    }
  }
  Future<File?> _imgFile(String url) =>
      _imgFileCache.putIfAbsent(
          url, () => MediaStore.instance.getFile(url, mediaAuthHeaders(url)));

  Widget _imgLoader() => Container(
        width: 200,
        height: 150,
        color: Colors.black.withAlpha(20),
        child: const Center(
          child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );

  Widget _imgBroken() => Container(
        width: 180,
        height: 120,
        color: Colors.black.withAlpha(20),
        child: const Icon(Icons.broken_image_rounded),
      );

  // The decoded photo (cache-first: on-device copy, else network), shared by
  // the full image bubble and the side-by-side caption thumbnail. Decodes at
  // ~bubble size, not full resolution, so a thread of photos doesn't exhaust
  // memory (full res still loads in the tap-to-open viewer).
  Widget _imageData(String url) {
    final dpr = MediaQuery.of(context).devicePixelRatio.clamp(1.0, 3.0);
    final thumbW = (240 * dpr).round();
    final headers = mediaAuthHeaders(url);
    Widget net() => authNetworkImage(
          url: url,
          headers: headers,
          fit: BoxFit.cover,
          cacheWidth: thumbW,
          placeholder: (_) => _imgLoader(),
          error: (_) => _imgBroken(),
        );
    if (kIsWeb) return net();
    return FutureBuilder<File?>(
      future: _imgFile(url),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) return net();
        final f = snap.data;
        if (f != null) {
          return Image.file(f,
              fit: BoxFit.cover,
              cacheWidth: thumbW,
              errorBuilder: (_, _, _) => _imgBroken());
        }
        return net();
      },
    );
  }

  Widget _imageBubble(String url) {
    final dpr = MediaQuery.of(context).devicePixelRatio.clamp(1.0, 3.0);
    final thumbW = (240 * dpr).round();
    ImageProvider provider(File? f) => ResizeImage.resizeIfNeeded(
        thumbW,
        null,
        f != null
            ? FileImage(f)
            : authNetworkImageProvider(url, mediaAuthHeaders(url)));
    Widget box(ImageProvider p) => _StableImage(
          key: ValueKey(url),
          sizeKey: url,
          provider: p,
          loader: _imgLoader,
          broken: _imgBroken,
        );
    return GestureDetector(
      onTap: () => _openImageViewer(url),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: kIsWeb
            ? box(provider(null))
            : FutureBuilder<File?>(
                future: _imgFile(url),
                builder: (ctx, snap) =>
                    snap.connectionState == ConnectionState.waiting
                        ? box(provider(null))
                        : box(provider(snap.data)),
              ),
      ),
    );
  }

  // Image + caption laid out as a card: the photo as a portrait thumbnail on
  // the left with the caption filling the space beside it, so a tall photo and
  // its text no longer leave a blank column. A compact look that is ours, not
  // the usual stacked photo-then-caption.
  // A linkified, wrappable text span for a caption (clickable URLs / emails),
  // shared by the image+caption layouts so text can flow around the photo.
  TextSpan _captionSpan(
      String caption, TextStyle style, TextStyle linkStyle) {
    final elements = linkify(
      caption,
      options: const LinkifyOptions(humanize: false),
      linkifiers: const [UrlLinkifier(), EmailLinkifier(), LooseUrlLinkifier()],
    );
    return buildTextSpan(
      elements,
      style: style,
      linkStyle: linkStyle,
      onOpen: (link) => _openLink(link.url),
    );
  }

  TextStyle _capStyle(Color c) =>
      (Theme.of(context).textTheme.bodyMedium ?? const TextStyle())
          .merge(TextStyle(color: c, fontSize: 15, height: 1.38));

  TextStyle _capLinkStyle(Color linkColor) => _capStyle(linkColor).copyWith(
        decoration: TextDecoration.underline,
        decorationColor: linkColor,
      );

  // Plain text bubble (no image), rendered through FloatColumn with the SAME
  // span + style + scaler as image captions — so every bubble, image or not,
  // shares one text engine and one font. Links stay tappable via _captionSpan.
  Widget _bubbleTextOnly(String text, Color textColor, Color linkColor) {
    // Rich inline formatting (*bold* _italic_ ~strike~ __underline__ `code`
    // ==highlight== ||spoiler|| + fractions + auto-links) plus block quotes
    // and bulleted/numbered lists. Selectable with a mouse (desktop/web).
    return FormattedText(
      text: text,
      style: _capStyle(textColor),
      linkStyle: _capLinkStyle(linkColor),
      onOpenLink: (url) => _openLink(url),
      codeBg: textColor.withValues(alpha: 0.12),
      highlightBg: const Color(0x66FFC107),
      spoilerCover: textColor.withValues(alpha: 0.40),
      quoteBar: linkColor,
      selectable: RendererBinding.instance.mouseTracker.mouseIsConnected,
      searchTerm: _searchTerm,
      searchBg: Theme.of(context).colorScheme.primary.withValues(alpha: 0.30),
    );
  }

  // Image + caption. The layout adapts to the caption so the bubble never
  // shows a dead gap: a caption long enough to wrap down the side of the photo
  // FLOATS (photo left, words beside it, then full-width below); a short one
  // STACKS under the photo instead of sitting beside it with blank space. Both
  // render their text through the same FloatColumn/WrappableText path (the
  // stack via _bubbleTextOnly) so the caption font matches every other bubble.
  Widget _imageCaption(
      String url, String caption, Color textColor, Color linkColor) {
    return LayoutBuilder(
      builder: (ctx, c) {
        final scaler = MediaQuery.textScalerOf(ctx);
        final maxW = c.maxWidth.isFinite ? c.maxWidth : 280.0;
        final span = _captionSpan(
            caption, _capStyle(textColor), _capLinkStyle(linkColor));
        // Float geometry: photo on the left, caption in the column beside it.
        final imgW = (maxW * 0.42).clamp(118.0, 160.0).toDouble();
        final imgH = imgW / 0.78; // _imageThumb uses aspectRatio 0.78
        final besideW = maxW - imgW - 10;
        final tp = TextPainter(
          text: span,
          textDirection: TextDirection.ltr,
          textScaler: scaler,
        )..layout(maxWidth: besideW > 40 ? besideW : maxW);
        // If the caption (wrapped at the beside width) runs most of the way
        // down the photo, floating fills the side nicely. If it is shorter it
        // would leave a blank gap beside the photo, so stack it below instead.
        final useFloat = tp.height >= imgH * 0.85;
        if (useFloat) {
          return FloatColumn(
            children: [
              Floatable(
                float: FCFloat.start,
                padding:
                    const EdgeInsetsDirectional.only(end: 10, bottom: 6),
                child: _imageThumb(url, imgW, 0.78),
              ),
              WrappableText(text: span, textScaler: scaler),
            ],
          );
        }
        // Stacked: photo on top, caption below, bubble sized to the photo width.
        final iw = (maxW * 0.52).clamp(150.0, 220.0).toDouble();
        return SizedBox(
          width: iw,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _imageThumb(url, iw, 0.82),
              const SizedBox(height: 6),
              _bubbleTextOnly(caption, textColor, linkColor),
            ],
          ),
        );
      },
    );
  }

  // Back (gesture / app-bar arrow) closes the open photo before leaving chat.
  Widget _wrapViewerBack(Widget child) => PopScope(
        canPop: _viewerImages == null && _mediaBrowser == null,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          if (_viewerImages != null) {
            _closeViewer();
          } else {
            _closeMediaBrowser();
          }
        },
        child: child,
      );

  // Desktop/web: Ctrl/Cmd+V pastes a clipboard IMAGE (e.g. a screenshot) into
  // the composer's preview + caption flow. Text paste, undo (Ctrl+Z), redo and
  // the other standard field shortcuts are Flutter defaults and keep working —
  // this only adds image paste on top.
  Widget _pasteWrapper(Widget child) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.keyV &&
            (HardwareKeyboard.instance.isControlPressed ||
                HardwareKeyboard.instance.isMetaPressed)) {
          _tryPasteAttachment();
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }

  Future<void> _tryPasteImage() async {
    try {
      final bytes = await Pasteboard.image;
      if (bytes == null || bytes.isEmpty || !mounted) return;
      final ts = DateTime.now().millisecondsSinceEpoch;
      await _previewAndSendImage(bytes, 'pasted_$ts.png', 'image/png');
    } catch (_) {
      // No image on the clipboard (or unsupported) — the default text paste
      // already handled the keystroke.
    }
  }

  // Ctrl/Cmd+V: first try FILES copied from a file manager (APK, PDF, Excel,
  // ...), then an image, then fall through to the default text paste.
  Future<void> _tryPasteAttachment() async {
    // On web, clipboard files arrive via the DOM paste listener instead
    // (browsers don't expose them to the key handler / pasteboard).
    if (kIsWeb) return;
    try {
      final paths = await Pasteboard.files();
      if (paths.isNotEmpty) {
        await _pasteFilesFlow(paths);
        return;
      }
    } catch (_) {/* no files on the clipboard */}
    await _tryPasteImage();
  }

  Future<void> _pasteFilesFlow(List<String> paths) async {
    const imgExt = ['jpg', 'jpeg', 'png', 'gif', 'webp'];
    const fileCap = 200 * 1024 * 1024; // server cap for arbitrary files
    const ephemeralOver = 15 * 1024 * 1024; // big files: cache-then-purge
    for (var i = 0; i < paths.length; i++) {
      final path = paths[i];
      List<int> bytes;
      try {
        bytes = await readFileBytes(path);
      } catch (_) {
        if (mounted) {
          showToast(context, 'Could not read that file',
              type: ToastType.error);
        }
        continue;
      }
      if (bytes.isEmpty) continue;
      final name = path.split(RegExp(r'[\\/]+')).last;
      final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
      if (imgExt.contains(ext)) {
        await _previewAndSendImage(
            Uint8List.fromList(bytes), name, _mimeForExt(ext));
        continue;
      }
      if (bytes.length > fileCap) {
        if (mounted) {
          showToast(context, '"$name" is too large to send (max 200 MB).',
              type: ToastType.error);
        }
        continue;
      }
      // Only the FIRST file gets the caption sheet; extra files send plain so a
      // multi-file paste isn't a caption gauntlet.
      String? caption = '';
      if (i == 0) {
        caption = await _askFileCaption(name);
        if (caption == null) return; // cancelled the whole paste
      }
      await _uploadAndSend(
        bytes: bytes,
        filename: name,
        mime: _mimeForExt(ext),
        type: 'file',
        caption: caption,
        // Large files ride as ephemeral: the server purges the bytes once the
        // recipient caches them (or after the TTL), so a 200 MB file never
        // lives on the server long-term.
        ephemeral: bytes.length > ephemeralOver,
      );
    }
  }

  // Compact caption panel (file chip + caption field + send) that stands in
  // for the composer while a pasted file is awaiting its caption. WhatsApp-
  // style: it lives in the conversation's input slot, not over the whole app.
  Widget _buildFileCaptionBar(ColorScheme scheme) {
    final name = _captionFileName ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.insert_drive_file_rounded,
                      color: scheme.primary, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface)),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  color: scheme.onSurfaceVariant,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Cancel',
                  onPressed: _cancelFileCaption,
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                // Same pill (and keystroke ticks) as the chat composer.
                child: AlutaComposerField(
                  controller: _captionCtrl,
                  hint: 'Add a caption…',
                  maxLines: 4,
                  autofocus: true,
                  onSubmit: _submitFileCaption,
                ),
              ),
              const SizedBox(width: 6),
              Material(
                color: scheme.primary,
                shape: const CircleBorder(),
                child: IconButton(
                  icon: const Icon(Icons.send_rounded, color: Colors.white),
                  onPressed: _submitFileCaption,
                  tooltip: 'Send',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
