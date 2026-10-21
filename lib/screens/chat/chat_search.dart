part of '../chat_page.dart';

/// Bumped by hosts (home DM header, group menu) to open the in-chat search
/// on whichever chat is showing.
final ValueNotifier<int> chatSearchRequest = ValueNotifier<int>(0);

// ── In-chat search ──────────────────────────────────────────────────────────
// A frosted Aluta pill floats over the top of the thread: type, and every
// match lights up in its bubble; ⌃/⌄ step through them newest → oldest with
// the same flash-jump used for quotes. The first search pulls a deeper slice
// of history once so older messages can be found too. Secret hearts are
// never searched — their notes stay sealed.
extension _ChatSearch on _ChatPageState {
  void _onSearchRequest() {
    if (!mounted) return;
    _openSearch();
  }

  void _openSearch() {
    if (_searchOpen) {
      _searchFocus.requestFocus();
      return;
    }
    rebuildWith(() {
      _searchOpen = true;
      _searchHits = const [];
      _searchIdx = 0;
    });
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _searchFocus.requestFocus());
    _searchDeepLoad();
  }

  void _closeSearch() {
    _searchDebounce?.cancel();
    _searchCtrl.clear();
    _searchFocus.unfocus();
    rebuildWith(() {
      _searchOpen = false;
      _searchHits = const [];
      _searchIdx = 0;
    });
  }

  String get _searchTerm => _searchOpen ? _searchCtrl.text.trim() : '';

  /// Once per chat: fetch a deeper window so the search reaches beyond the
  /// 60 messages the thread normally holds. Merged in (never replacing).
  Future<void> _searchDeepLoad() async {
    if (_searchDeepLoaded) return;
    _searchDeepLoaded = true;
    try {
      List<Map<String, dynamic>> msgs;
      if (_isGroup) {
        msgs = await ApiService()
            .fetchConversationMessages(_cid, skip: 0, limit: 500);
      } else {
        final uid = int.tryParse(_myId ?? '') ?? 0;
        if (uid == 0) return;
        msgs = await ApiService()
            .fetchMessagesBetween(uid, widget.friendId, skip: 0, limit: 500);
      }
      if (!mounted || msgs.isEmpty) return;
      final merged = _merge(_messages, msgs);
      if (merged.length != _messages.length) {
        rebuildWith(() => _messages = merged);
        if (_searchTerm.length >= 2) _runSearch(jump: false);
      }
    } catch (_) {
      _searchDeepLoaded = false; // offline → try again next time
    }
  }

  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce =
        Timer(const Duration(milliseconds: 220), () => _runSearch());
  }

  bool _searchable(Map<String, dynamic> m) =>
      m['is_deleted'] != true && (m['message_type'] ?? '') != 'heart';

  String _searchTextOf(Map<String, dynamic> m) {
    final b = StringBuffer(_stripQuote((m['content'] as String?) ?? ''));
    final fn = m['media_name'];
    if (fn is String && fn.isNotEmpty) b.write('\n$fn');
    return b.toString().toLowerCase();
  }

  void _runSearch({bool jump = true}) {
    if (!mounted || !_searchOpen) return;
    final q = _searchTerm.toLowerCase();
    if (q.length < 2) {
      rebuildWith(() {
        _searchHits = const [];
        _searchIdx = 0;
      });
      return;
    }
    // _messages is newest-first → hits are too (index 0 = latest match).
    final hits = <String>[
      for (final m in _messages)
        if (_searchable(m) && _searchTextOf(m).contains(q)) m['id'].toString(),
    ];
    final keep = _searchHits.isNotEmpty && _searchIdx < _searchHits.length
        ? hits.indexOf(_searchHits[_searchIdx])
        : -1;
    rebuildWith(() {
      _searchHits = hits;
      _searchIdx = keep >= 0 ? keep : 0;
    });
    if (jump && hits.isNotEmpty) _jumpToMessage(hits[_searchIdx]);
  }

  /// [older] = step up the thread (towards older matches).
  void _searchStep(bool older) {
    if (_searchHits.isEmpty) return;
    final n = _searchHits.length;
    final next = (_searchIdx + (older ? 1 : -1) + n) % n;
    rebuildWith(() => _searchIdx = next);
    _jumpToMessage(_searchHits[next]);
  }

  Widget _buildSearchBar(ColorScheme scheme, bool isDark) {
    final has = _searchTerm.length >= 2;
    final none = has && _searchHits.isEmpty;
    final ink = isDark ? Colors.white : const Color(0xFF2B2829);
    final soft = ink.withValues(alpha: 0.55);
    Widget chev(IconData i, String tip, bool older) => IconButton(
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
          icon: Icon(i,
              size: 22,
              color: _searchHits.isEmpty ? soft.withValues(alpha: 0.3) : ink),
          onPressed: _searchHits.isEmpty ? null : () => _searchStep(older),
        );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _closeSearch,
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _searchStep(true),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _searchStep(false),
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 48,
            padding: const EdgeInsets.only(left: 6, right: 4),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.black.withValues(alpha: 0.42)
                  : Colors.white.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(
                color: none
                    ? scheme.error.withValues(alpha: 0.45)
                    : scheme.primary.withValues(alpha: isDark ? 0.5 : 0.4),
              ),
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.14),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                // Aluta signature: the logo disc leads the pill.
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(colors: [
                      scheme.primary,
                      Color.lerp(scheme.primary, Colors.white, 0.25)!,
                    ]),
                  ),
                  child: const Icon(Icons.search_rounded,
                      size: 18, color: Colors.white),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    focusNode: _searchFocus,
                    onChanged: _onSearchChanged,
                    onSubmitted: (_) {
                      if (_searchHits.isEmpty) {
                        _runSearch();
                      } else {
                        _searchStep(true);
                      }
                      _searchFocus.requestFocus();
                    },
                    textInputAction: TextInputAction.search,
                    cursorColor: scheme.primary,
                    style: TextStyle(color: ink, fontSize: 15),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: _isGroup
                          ? 'Search ${widget.groupTitle}'
                          : 'Search chat with ${widget.friendName}',
                      hintStyle: TextStyle(color: soft, fontSize: 14),
                    ),
                  ),
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  child: !has
                      ? const SizedBox.shrink()
                      : Padding(
                          key: ValueKey('${_searchIdx}_${_searchHits.length}'),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            none
                                ? 'No match'
                                : '${_searchIdx + 1}/${_searchHits.length}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: none ? scheme.error : soft,
                              fontFeatures: const [
                                ui.FontFeature.tabularFigures()
                              ],
                            ),
                          ),
                        ),
                ),
                chev(Icons.keyboard_arrow_up_rounded, 'Older match', true),
                chev(Icons.keyboard_arrow_down_rounded, 'Newer match', false),
                IconButton(
                  tooltip: 'Close search',
                  visualDensity: VisualDensity.compact,
                  constraints:
                      const BoxConstraints(minWidth: 34, minHeight: 34),
                  icon: Icon(Icons.close_rounded, size: 20, color: soft),
                  onPressed: _closeSearch,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
