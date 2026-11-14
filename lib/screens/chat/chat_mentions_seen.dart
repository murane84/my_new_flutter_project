part of '../chat_page.dart';

// ── "@ you" stepper + DM "seen" avatar ──────────────────────────────────────
// Groups: every message since my last visit that tags me (or @all) queues up
// behind a small Aluta "@" disc above the ⇊ button; each tap flash-jumps to
// the oldest one still waiting. A mention scrolled into view counts as seen.
// DMs: my newest message they've READ carries their tiny avatar beneath it,
// so "seen" reads at a glance without parsing ticks.

extension _ChatMentionsSeen on _ChatPageState {
  /// Pending mention ids, oldest first. Cached per `_messages` identity.
  List<String> get _pendingMentions {
    if (!_isGroup) return const [];
    if (identical(_mentionCacheOf, _messages)) return _mentionCache;
    final base = _mentionBase;
    final out = <String>[];
    if (base != null) {
      for (final m in _messages) {
        final id = int.tryParse(m['id'].toString());
        if (id == null) continue;
        if (id <= base) break; // newest-first: everything older was seen
        if (m['sender_id']?.toString() == _myId) continue;
        if (m['is_deleted'] == true) continue;
        if ((m['message_type'] ?? '') == 'heart') continue;
        final sid = m['id'].toString();
        if (_mentionCleared.contains(sid)) continue;
        if (mentionsMe(_stripQuote((m['content'] as String?) ?? ''))) {
          out.add(sid);
        }
      }
    }
    _mentionCacheOf = _messages;
    _mentionCache = out.reversed.toList();
    return _mentionCache;
  }

  void _clearMention(String id) {
    _mentionCleared.add(id);
    _mentionCacheOf = null;
  }

  /// Mentions that are actually on screen right now count as read.
  void _clearVisibleMentions() {
    final pending = _pendingMentions;
    if (pending.isEmpty) return;
    final h = MediaQuery.sizeOf(context).height;
    var changed = false;
    for (final id in pending) {
      final ro = _msgKeys[id]?.currentContext?.findRenderObject();
      if (ro is! RenderBox || !ro.attached || !ro.hasSize) continue;
      final top = ro.localToGlobal(Offset.zero).dy;
      final bottom = top + ro.size.height;
      if (bottom > 90 && top < h - 110) {
        _clearMention(id);
        changed = true;
      }
    }
    if (changed) rebuildWith(() {});
  }

  /// The "back to latest" glass pill. Quiet (just a chevron) until there's
  /// a reason to look: someone wrote while I was up here → their face and a
  /// count ("🙂 3 ⌄"); a message tags me → an accent "@" that takes me to
  /// it first. Small either way, so it never competes with the mic.
  Widget _latestPill(ColorScheme scheme) {
    final mentions = _isGroup ? _pendingMentions.length : 0;
    final waiting = _newWhileUp.length;
    final ink = accentInk(scheme);
    Widget face() {
      final m = _newWhileUp.last;
      final sm = (m['sender'] as Map?) ?? const {};
      final rel = _isGroup
          ? (sm['avatar_url'] ?? '').toString()
          : _friendAvatar;
      final name = _isGroup
          ? (sm['username'] ?? '').toString()
          : widget.friendName;
      final url = rel.isEmpty ? null : fullMediaUrl(rel);
      return CircleAvatar(
        radius: 9,
        backgroundColor: scheme.primary.withValues(alpha: 0.18),
        backgroundImage: url == null
            ? null
            : authNetworkImageProvider(url, mediaAuthHeaders(url)),
        child: url != null
            ? null
            : Text(name.isEmpty ? '•' : name[0].toUpperCase(),
                style: TextStyle(
                    fontSize: 9.5, fontWeight: FontWeight.w800, color: ink)),
      );
    }

    final String tip;
    final List<Widget> kids;
    if (mentions > 0) {
      tip = mentions == 1 ? 'You were mentioned' : '$mentions mentions';
      kids = [
        Text('@',
            style: TextStyle(
                fontSize: 15,
                height: 1,
                fontWeight: FontWeight.w900,
                color: ink)),
        if (mentions > 1) ...[
          const SizedBox(width: 3),
          Text('$mentions',
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w800, color: ink)),
        ],
      ];
    } else if (waiting > 0) {
      tip = waiting == 1 ? '1 new message' : '$waiting new messages';
      kids = [
        face(),
        const SizedBox(width: 5),
        Text(waiting > 99 ? '99+' : '$waiting',
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w800, color: ink)),
        const SizedBox(width: 1),
        Icon(Icons.keyboard_arrow_down_rounded, color: ink, size: 18),
      ];
    } else {
      tip = 'Back to latest';
      kids = [Icon(Icons.keyboard_arrow_down_rounded, color: ink, size: 20)];
    }
    return GestureDetector(
      onTap: mentions > 0 ? _jumpToNextMention : _jumpToLatest,
      child: Tooltip(
        message: tip,
        child: AnimatedSize(
          duration: Motion.quick,
          curve: Curves.easeOutCubic,
          child: _alutaGlass(
            scheme,
            height: 28,
            padding: EdgeInsets.symmetric(
                horizontal: (mentions > 0 || waiting > 0) ? 7 : 9),
            Row(mainAxisSize: MainAxisSize.min, children: kids),
          ),
        ),
      ),
    );
  }

  void _jumpToNextMention() {
    final p = _pendingMentions;
    if (p.isEmpty) return;
    final id = p.first;
    rebuildWith(() => _clearMention(id));
    _jumpToMessage(id);
  }

  Widget _buildMentionChip(ColorScheme scheme) {
    final n = _pendingMentions.length;
    final show = n > 0;
    return IgnorePointer(
      ignoring: !show,
      child: AnimatedScale(
        scale: show ? 1 : 0.5,
        duration: Motion.standard,
        curve: Curves.easeOutBack,
        child: AnimatedOpacity(
          opacity: show ? 1 : 0,
          duration: Motion.quick,
          child: Tooltip(
            message: n == 1 ? 'You were mentioned' : '$n mentions',
            child: GestureDetector(
              onTap: _jumpToNextMention,
              child: SizedBox(
                width: 46,
                height: 46,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color.lerp(scheme.primary, Colors.white, 0.18)!,
                            scheme.primary,
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: scheme.primary.withValues(alpha: 0.35),
                            blurRadius: Depth.sm,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      alignment: Alignment.center,
                      child: const Text('@',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              height: 1.0,
                              fontWeight: FontWeight.w800)),
                    ),
                    if (n > 1)
                      Positioned(
                        top: -2,
                        right: -2,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          constraints: const BoxConstraints(minWidth: 18),
                          decoration: BoxDecoration(
                            color: scheme.surface,
                            borderRadius: BorderRadius.circular(Radii.md),
                            border: Border.all(
                                color: scheme.primary, width: 1.2),
                          ),
                          child: Text('$n',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                  color: accentInk(scheme))),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── DM: "seen" avatar ────────────────────────────────────────────────────
  /// Id of my newest message the friend has read (DM only), cached.
  String? get _seenByFriendId {
    if (_isGroup) return null;
    if (identical(_seenCacheOf, _messages)) return _seenCache;
    String? out;
    for (final m in _messages) {
      if (m['sender_id']?.toString() != _myId) continue;
      if (m['is_deleted'] == true) continue;
      if (m['is_read'] == true) {
        out = m['id'].toString();
        break;
      }
    }
    _seenCacheOf = _messages;
    _seenCache = out;
    return out;
  }

  /// [inline]: just the little photo (it rides beside a reaction chip).
  Widget _buildSeenAvatar(ColorScheme scheme, {bool inline = false}) {
    final url = _friendAvatar;
    final name = widget.friendName;
    return Align(
      alignment: Alignment.centerRight,
      widthFactor: inline ? 1 : null,
      heightFactor: inline ? 1 : null,
      child: Padding(
        padding: inline
            ? EdgeInsets.zero
            : const EdgeInsets.only(right: 10, top: 1, bottom: 2),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: Motion.emphasized,
          curve: Curves.easeOutBack,
          builder: (_, t, child) => Transform.scale(
            scale: 0.6 + 0.4 * t,
            child: Opacity(opacity: t.clamp(0.0, 1.0), child: child),
          ),
          child: Semantics(
            label: 'Seen by $name',
            child: Container(
              padding: const EdgeInsets.all(1.2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.primary.withValues(alpha: 0.55),
              ),
              child: CircleAvatar(
                radius: 7.5,
                backgroundColor: scheme.primaryContainer,
                backgroundImage: url.isNotEmpty
                    ? authNetworkImageProvider(
                        fullMediaUrl(url), mediaAuthHeaders(fullMediaUrl(url)))
                    : null,
                child: url.isNotEmpty
                    ? null
                    : Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                        style: TextStyle(
                            fontSize: 8,
                            fontWeight: FontWeight.w800,
                            color: scheme.onPrimaryContainer)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
