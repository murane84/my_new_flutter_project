import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';

/// GIPHY API key.
///
/// This defaults to GIPHY's public "beta" key, which their own docs/tutorials
/// use for testing. It works out of the box with NO signup, so GIF stickers are
/// available immediately — but it's shared and rate-limited, so for production
/// reliability and higher limits grab a free key at https://developers.giphy.com
/// and paste it here (that's the only change needed).
const String kGiphyApiKey = 'dc6zaTOxFJmzC';

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
    });
    }
    try {
      final endpoint = query.isEmpty
          ? 'https://api.giphy.com/v1/gifs/trending'
          : 'https://api.giphy.com/v1/gifs/search';
      final uri = Uri.parse(endpoint).replace(queryParameters: {
        'api_key': kGiphyApiKey,
        if (query.isNotEmpty) 'q': query,
        'limit': '30',
        'rating': 'pg-13',
        'bundle': 'messaging_non_clips',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        if (mounted) {
          setState(() {
          _loading = false;
          _error = true;
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
                hintText: 'Search GIFs',
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
        child: Text('No GIFs found',
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
