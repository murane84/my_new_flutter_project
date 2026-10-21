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
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        child: AnimatedOpacity(
          opacity: show ? 1 : 0,
          duration: const Duration(milliseconds: 180),
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
                            blurRadius: 10,
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
                            borderRadius: BorderRadius.circular(9),
                            border: Border.all(
                                color: scheme.primary, width: 1.2),
                          ),
                          child: Text('$n',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                  color: scheme.primary)),
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

  Widget _buildSeenAvatar(ColorScheme scheme) {
    final url = _friendAvatar;
    final name = widget.friendName;
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(right: 10, top: 1, bottom: 2),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 320),
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
