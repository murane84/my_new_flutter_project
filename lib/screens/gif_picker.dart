import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';

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

/// One GIF result: a small looping [previewUrl] for the grid, and the
/// [fullUrl] that actually gets sent into the conversation.
class GifResult {
  const GifResult({required this.previewUrl, required this.fullUrl});
  final String previewUrl;
  final String fullUrl;
}

/// A GIF sticker picker (GIPHY trending + search) sized to sit inside the chat
/// emoji panel. Calls [onSelected] with the chosen GIF; the caller sends it.
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
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _debounce;
  List<GifResult> _gifs = [];
  bool _loading = true;
  bool _error = false;
  // Human-readable reason for the last failure (bad key, rate limit, network),
  // shown under the error state so issues like a rejected key are obvious.
  String? _errorDetail;
  // false = GIFs, true = Stickers (GIPHY serves them from a separate endpoint;
  // stickers are transparent animated GIFs). Toggled by the header switch.
  bool _stickers = false;

  @override
  void initState() {
    super.initState();
    _fetch(''); // trending on open
    _searchCtrl.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400),
        () => _fetch(_searchCtrl.text.trim()));
  }

  Future<void> _fetch(String query) async {
    if (mounted) {
      setState(() {
      _loading = true;
      _error = false;
      _errorDetail = null;
    });
    }
    try {
      // GIFs and stickers share the same API/key but live on different paths.
      final kind = _stickers ? 'stickers' : 'gifs';
      final endpoint = query.isEmpty
          ? 'https://api.giphy.com/v1/$kind/trending'
          : 'https://api.giphy.com/v1/$kind/search';
      final uri = Uri.parse(endpoint).replace(queryParameters: {
        'api_key': kGiphyApiKey,
        if (query.isNotEmpty) 'q': query,
        'limit': '30',
        'rating': 'pg-13',
        // messaging_non_clips is a GIF messaging rendition bundle; it doesn't
        // apply to stickers, so only send it in GIF mode.
        if (!_stickers) 'bundle': 'messaging_non_clips',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        if (mounted) {
          setState(() {
          _loading = false;
          _error = true;
          _errorDetail = (res.statusCode == 401 || res.statusCode == 403)
              ? 'GIF service key was rejected (${res.statusCode}). '
                  'Check the GIPHY API key.'
              : res.statusCode == 429
                  ? 'GIF rate limit reached — try again in a bit.'
                  : 'GIF service error (${res.statusCode}).';
        });
        }
        return;
      }
      final data = (jsonDecode(res.body)['data'] as List?) ?? const [];
      final list = <GifResult>[];
      for (final g in data) {
        final images = g['images'] as Map<String, dynamic>?;
        if (images == null) continue;
        final preview = (images['fixed_width_small']?['url'] ??
            images['fixed_width']?['url']) as String?;
        final full = (images['downsized_medium']?['url'] ??
            images['downsized']?['url'] ??
            images['original']?['url']) as String?;
        if (preview != null && full != null) {
          list.add(GifResult(previewUrl: preview, fullUrl: full));
        }
      }
      if (!mounted) return;
      setState(() {
        _gifs = list;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
        _errorDetail = 'Couldn’t reach the GIF service. Check your connection.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        // Search box.
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
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
        _modeToggle(scheme),
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

  /// Compact GIFs / Stickers switch. Selecting the other mode re-fetches with
  /// the current search query.
  Widget _modeToggle(ColorScheme scheme) {
    Widget pill(String label, bool stickers) {
      final selected = _stickers == stickers;
      return Expanded(
        child: GestureDetector(
          onTap: () {
            if (_stickers == stickers) return;
            setState(() => _stickers = stickers);
            _fetch(_searchCtrl.text.trim());
          },
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primary
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Row(children: [pill('GIFs', false), pill('Stickers', true)]),
    );
  }

  Widget _buildGrid(ColorScheme scheme) {
    if (_loading) {
      return const Center(
        child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
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
                'Couldn’t load GIFs right now.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurface, fontSize: 13),
              ),
              if (_errorDetail != null) ...[
                const SizedBox(height: 4),
                Text(
                  _errorDetail!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: scheme.onSurfaceVariant, fontSize: 11),
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
    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        childAspectRatio: 1,
      ),
      itemCount: _gifs.length,
      itemBuilder: (_, i) {
        final gif = _gifs[i];
        return GestureDetector(
          onTap: () => widget.onSelected(gif),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: CachedNetworkImage(
              imageUrl: gif.previewUrl,
              fit: BoxFit.cover,
              placeholder: (_, _) => Container(
                color: scheme.surfaceContainerHighest,
              ),
              errorWidget: (_, _, _) => Container(
                color: scheme.surfaceContainerHighest,
                child: Icon(Icons.broken_image_rounded,
                    size: 18, color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        );
      },
    );
  }
}
