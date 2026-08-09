import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimmer/shimmer.dart';

/// GIPHY API key.
///
/// This is Aluta's own GIPHY API key (a free "beta" key, rate-limited to 100
/// calls/hour — plenty for the picker, which only calls GIPHY on open/search).
/// GIPHY's old shared public key (`dc6zaTOxFJmzC`) was disabled and now returns
/// 403, which is why GIFs stopped loading; this replaces it.
///
/// Overridable at build time without editing code (same pattern as PROD_URL /
/// SERVER_IP), so a production key can be supplied via CI without committing it:
///   flutter build apk --dart-define=GIPHY_API_KEY=your_prod_key
const String kGiphyApiKey = String.fromEnvironment(
  'GIPHY_API_KEY',
  defaultValue: 'OG5iS6Z0Yu1D7XrOXy9BWsr6uu5wCLhf',
);

/// One GIF result: a small looping [previewUrl] for the grid, the [fullUrl] that
/// actually gets sent into the conversation, and the [aspectRatio] (w/h) of the
/// preview so the masonry grid can keep the tile's true shape.
class GifResult {
  const GifResult({
    required this.previewUrl,
    required this.fullUrl,
    this.aspectRatio = 1.0,
  });

  final String previewUrl;
  final String fullUrl;
  final double aspectRatio;

  Map<String, dynamic> toJson() =>
      {'p': previewUrl, 'f': fullUrl, 'a': aspectRatio};

  factory GifResult.fromJson(Map<String, dynamic> j) => GifResult(
        previewUrl: (j['p'] ?? '').toString(),
        fullUrl: (j['f'] ?? '').toString(),
        aspectRatio: (j['a'] as num?)?.toDouble() ?? 1.0,
      );
}

/// A GIF / sticker picker (GIPHY trending + search) sized to sit inside the chat
/// emoji panel. Features: masonry grid (true aspect ratios), infinite scroll,
/// recently-used strip, shimmer placeholders, and sticker category shortcuts.
/// Calls [onSelected] with the chosen GIF; the caller sends it.
class GifPicker extends StatefulWidget {
  const GifPicker({
    super.key,
    required this.onSelected,
  });

  final void Function(GifResult gif) onSelected;

  @override
  State<GifPicker> createState() => _GifPickerState();
}

class _GifPickerState extends State<GifPicker> {
  static const int _pageSize = 30;

  // Quick sticker moods → search queries, shown as chips in sticker mode.
  static const List<String> _stickerCategories = [
    'Love', 'Reactions', 'Happy', 'Sad', 'Cute',
    'Memes', 'Party', 'Angry', 'Thumbs up', 'Sorry',
  ];

  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  Timer? _debounce;

  List<GifResult> _gifs = [];
  List<GifResult> _recent = [];
  bool _loading = true;      // first page loading
  bool _loadingMore = false; // pagination
  bool _error = false;
  String? _errorDetail;
  bool _stickers = false;    // false = GIFs, true = Stickers
  String _query = '';
  int _offset = 0;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _loadRecent();
    _fetch(''); // trending on open
    _searchCtrl.addListener(_onSearchChanged);
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 500) {
      _fetch(_query, more: true);
    }
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400),
        () => _fetch(_searchCtrl.text.trim()));
  }

  String get _recentKey => _stickers ? 'recent_stickers_v1' : 'recent_gifs_v1';

  Future<void> _loadRecent() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_recentKey) ?? const [];
      final list = <GifResult>[];
      for (final s in raw) {
        try {
          final m = jsonDecode(s);
          if (m is Map<String, dynamic>) list.add(GifResult.fromJson(m));
        } catch (_) {}
      }
      if (mounted) setState(() => _recent = list);
    } catch (_) {/* best-effort */}
  }

  Future<void> _recordRecent(GifResult g) async {
    _recent.removeWhere((e) => e.fullUrl == g.fullUrl);
    _recent.insert(0, g);
    if (_recent.length > 16) _recent = _recent.sublist(0, 16);
    if (mounted) setState(() {});
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
          _recentKey, _recent.map((e) => jsonEncode(e.toJson())).toList());
    } catch (_) {/* best-effort */}
  }

  void _pick(GifResult g) {
    _recordRecent(g);
    widget.onSelected(g);
  }

  Future<void> _fetch(String query, {bool more = false}) async {
    if (more) {
      if (_loadingMore || _loading || !_hasMore) return;
      setState(() => _loadingMore = true);
    } else {
      _query = query;
      if (mounted) {
        setState(() {
          _loading = true;
          _error = false;
          _errorDetail = null;
          _offset = 0;
          _hasMore = true;
        });
      }
    }
    final offset = more ? _offset : 0;
    try {
      // GIFs and stickers share the same API/key but live on different paths.
      final kind = _stickers ? 'stickers' : 'gifs';
      final endpoint = query.isEmpty
          ? 'https://api.giphy.com/v1/$kind/trending'
          : 'https://api.giphy.com/v1/$kind/search';
      final uri = Uri.parse(endpoint).replace(queryParameters: {
        'api_key': kGiphyApiKey,
        if (query.isNotEmpty) 'q': query,
        'limit': '$_pageSize',
        'offset': '$offset',
        'rating': 'pg-13',
        if (!_stickers) 'bundle': 'messaging_non_clips',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        if (mounted) {
          setState(() {
            _loading = false;
            _loadingMore = false;
            if (!more) {
              _error = true;
              _errorDetail = (res.statusCode == 401 || res.statusCode == 403)
                  ? 'GIF service key was rejected (${res.statusCode}). '
                      'Check the GIPHY API key.'
                  : res.statusCode == 429
                      ? 'GIF rate limit reached — try again in a bit.'
                      : 'GIF service error (${res.statusCode}).';
            }
          });
        }
        return;
      }
      final data = (jsonDecode(res.body)['data'] as List?) ?? const [];
      final list = <GifResult>[];
      for (final g in data) {
        final images = g['images'] as Map<String, dynamic>?;
        if (images == null) continue;
        final small = images['fixed_width_small'] as Map<String, dynamic>?;
        final preview =
            (small?['url'] ?? images['fixed_width']?['url']) as String?;
        final full = (images['downsized_medium']?['url'] ??
            images['downsized']?['url'] ??
            images['original']?['url']) as String?;
        if (preview == null || full == null) continue;
        double ar = 1.0;
        final w = double.tryParse('${small?['width'] ?? ''}');
        final h = double.tryParse('${small?['height'] ?? ''}');
        if (w != null && h != null && h > 0) {
          ar = (w / h).clamp(0.6, 2.0);
        }
        list.add(GifResult(previewUrl: preview, fullUrl: full, aspectRatio: ar));
      }
      if (!mounted) return;
      setState(() {
        if (more) {
          _gifs = [..._gifs, ...list];
        } else {
          _gifs = list;
        }
        _offset = offset + list.length;
        _hasMore = list.length >= _pageSize;
        _loading = false;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (!more) {
          _error = true;
          _errorDetail = 'Couldn’t reach the GIF service. Check your connection.';
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final showRecent = _query.isEmpty && _recent.isNotEmpty && !_error;
    return Column(
      children: [
        // Search field + GIFs/Stickers pills, all on ONE compact row.
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: TextField(
                    controller: _searchCtrl,
                    textInputAction: TextInputAction.search,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      hintText: _stickers ? 'Search stickers' : 'Search GIFs',
                      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
                      filled: true,
                      fillColor: scheme.surfaceContainerHighest,
                      contentPadding: const EdgeInsets.symmetric(vertical: 0),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      suffixIcon: _searchCtrl.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: () {
                                _searchCtrl.clear();
                                _fetch('');
                              },
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _modePill(scheme, 'GIFs', false),
              const SizedBox(width: 6),
              _modePill(scheme, 'Stickers', true),
            ],
          ),
        ),

        // Sticker category shortcuts (only in sticker mode).
        if (_stickers) _categoryChips(scheme),

        // Recently used strip (trending view only).
        if (showRecent) _recentStrip(scheme),

        Expanded(child: _buildGrid(scheme)),

        // GIPHY attribution (required by their terms).
        Padding(
          padding: const EdgeInsets.only(bottom: 4, top: 2),
          child: Text(
            'Powered by GIPHY',
            style: TextStyle(
                fontSize: 10,
                letterSpacing: 0.5,
                color: scheme.onSurfaceVariant.withAlpha(150)),
          ),
        ),
      ],
    );
  }

  /// Compact GIFs / Stickers pill, sized to its label so it sits inline on the
  /// search row. Selecting the other mode reloads recents + re-fetches.
  Widget _modePill(ColorScheme scheme, String label, bool stickers) {
    final selected = _stickers == stickers;
    return GestureDetector(
      onTap: () {
        if (_stickers == stickers) return;
        setState(() => _stickers = stickers);
        _loadRecent();
        _fetch(_searchCtrl.text.trim());
      },
      child: Container(
        height: 40,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: selected ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _categoryChips(ColorScheme scheme) {
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
        itemCount: _stickerCategories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final cat = _stickerCategories[i];
          final active = _query.toLowerCase() == cat.toLowerCase();
          return GestureDetector(
            onTap: () {
              _searchCtrl.text = cat;
              _searchCtrl.selection =
                  TextSelection.collapsed(offset: cat.length);
              _debounce?.cancel();
              _fetch(cat);
            },
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: active
                    ? scheme.primary.withAlpha(38)
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: active
                        ? scheme.primary.withAlpha(150)
                        : Colors.transparent),
              ),
              child: Text(
                cat,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: active ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _recentStrip(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
          child: Row(
            children: [
              Icon(Icons.history_rounded,
                  size: 13, color: scheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text('Recently used',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
        SizedBox(
          height: 62,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            itemCount: _recent.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (_, i) {
              final g = _recent[i];
              return GestureDetector(
                onTap: () => _pick(g),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: CachedNetworkImage(
                    imageUrl: g.previewUrl,
                    width: 62,
                    height: 62,
                    fit: BoxFit.cover,
                    placeholder: (_, _) => _shimmerBox(scheme),
                    errorWidget: (_, _, _) => Container(
                        width: 62,
                        height: 62,
                        color: scheme.surfaceContainerHighest),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _buildGrid(ColorScheme scheme) {
    if (_loading) return _shimmerGrid(scheme);
    if (_error) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.gif_box_outlined,
                  size: 34, color: scheme.onSurfaceVariant),
              const SizedBox(height: 8),
              Text(
                'Couldn’t load ${_stickers ? 'stickers' : 'GIFs'} right now.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurface, fontSize: 13),
              ),
              if (_errorDetail != null) ...[
                const SizedBox(height: 4),
                Text(
                  _errorDetail!,
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
                ),
              ],
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => _fetch(_searchCtrl.text.trim()),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (_gifs.isEmpty) {
      return Center(
        child: Text(_stickers ? 'No stickers found' : 'No GIFs found',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
      );
    }
    // Masonry grid: each tile keeps the GIF's true aspect ratio (Telegram-style)
    // instead of being cropped to a square. Dense, responsive columns.
    return Stack(
      children: [
        MasonryGridView.extent(
          controller: _scrollCtrl,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          maxCrossAxisExtent: _stickers ? 92 : 128,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          itemCount: _gifs.length,
          itemBuilder: (_, i) {
            final gif = _gifs[i];
            return GestureDetector(
              onTap: () => _pick(gif),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: AspectRatio(
                  aspectRatio: gif.aspectRatio,
                  child: CachedNetworkImage(
                    imageUrl: gif.previewUrl,
                    fit: BoxFit.cover,
                    placeholder: (_, _) => _shimmerBox(scheme),
                    errorWidget: (_, _, _) => Container(
                      color: scheme.surfaceContainerHighest,
                      child: Icon(Icons.broken_image_rounded,
                          size: 18, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        // Pagination spinner pinned at the bottom while loading more.
        if (_loadingMore)
          Positioned(
            left: 0,
            right: 0,
            bottom: 6,
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: scheme.surface.withAlpha(220),
                  shape: BoxShape.circle,
                ),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: scheme.primary),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// A single shimmering placeholder box (fills its parent's size).
  Widget _shimmerBox(ColorScheme scheme) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Shimmer.fromColors(
      baseColor: scheme.surfaceContainerHighest,
      highlightColor: isDark
          ? scheme.surfaceContainerHighest.withAlpha(140)
          : Colors.white.withAlpha(180),
      child: Container(color: scheme.surfaceContainerHighest),
    );
  }

  /// Initial-load state: a grid of shimmering boxes (varied heights) so the
  /// panel reads as "loading tiles" rather than one lonely spinner.
  Widget _shimmerGrid(ColorScheme scheme) {
    const heights = [96.0, 128.0, 108.0, 140.0, 100.0, 120.0];
    return MasonryGridView.extent(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      maxCrossAxisExtent: _stickers ? 92 : 128,
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      itemCount: 12,
      itemBuilder: (_, i) => ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          height: heights[i % heights.length],
          child: _shimmerBox(scheme),
        ),
      ),
    );
  }
}
