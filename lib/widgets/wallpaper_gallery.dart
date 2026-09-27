import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/wallpapers_service.dart';
import '../services/media_store.dart';
import '../utils/net_image.dart' show authNetworkImageProvider;
import '../screens/token_helper.dart' show mediaAuthHeaders;

/// Resolve a possibly-relative wallpaper URL (e.g. "/wallpapers/w01") against
/// the API base into an absolute URL.
String resolveWallpaperUrl(String url, String apiBase) {
  if (url.isEmpty) return url;
  if (url.startsWith('http')) return url;
  final b =
      apiBase.endsWith('/') ? apiBase.substring(0, apiBase.length - 1) : apiBase;
  return url.startsWith('/') ? '$b$url' : '$b/$url';
}

/// A thumbnail that prefers the on-device cached file and falls back to an
/// authenticated network fetch — the same approach the full backdrops use, so a
/// picked wallpaper is already warm when it becomes the background.
class WallpaperThumb extends StatelessWidget {
  final String fullUrl;
  final BoxFit fit;
  const WallpaperThumb(this.fullUrl, {super.key, this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context) {
    final headers = mediaAuthHeaders(fullUrl);
    if (kIsWeb) {
      return Image(
        image: authNetworkImageProvider(fullUrl, headers),
        fit: fit,
        gaplessPlayback: true,
      );
    }
    return FutureBuilder<File?>(
      future: MediaStore.instance.getFile(fullUrl, headers),
      builder: (ctx, snap) {
        final ImageProvider provider = (snap.data != null)
            ? FileImage(snap.data!)
            : authNetworkImageProvider(fullUrl, headers);
        return Image(image: provider, fit: fit, gaplessPlayback: true);
      },
    );
  }
}

/// A grid of preset wallpapers. Purely presentational: it reports the tapped
/// preset via [onPick] and highlights whichever matches [selectedFullUrl]; the
/// host decides what a pick means (Space background vs chat wallpaper).
class WallpaperGalleryGrid extends StatelessWidget {
  final List<WallpaperPreset> presets;
  final String apiBase;
  final String? selectedFullUrl;
  final Color accent;
  final void Function(WallpaperPreset preset) onPick;

  const WallpaperGalleryGrid({
    super.key,
    required this.presets,
    required this.apiBase,
    required this.onPick,
    required this.accent,
    this.selectedFullUrl,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (presets.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Text(
          'No preset wallpapers available yet.',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
      );
    }
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.56,
      ),
      itemCount: presets.length,
      itemBuilder: (ctx, i) {
        final p = presets[i];
        final full = resolveWallpaperUrl(p.url, apiBase);
        final selected = selectedFullUrl != null && selectedFullUrl == full;
        return GestureDetector(
          onTap: () => onPick(p),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: selected ? accent : scheme.outlineVariant,
                      width: selected ? 2.5 : 1,
                    ),
                    color: scheme.surfaceContainerHighest,
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      WallpaperThumb(full),
                      if (selected)
                        Align(
                          alignment: Alignment.topRight,
                          child: Container(
                            margin: const EdgeInsets.all(6),
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                                color: accent, shape: BoxShape.circle),
                            child: const Icon(Icons.check_rounded,
                                size: 13, color: Colors.white),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                p.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 10.5,
                    color: scheme.onSurfaceVariant,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500),
              ),
            ],
          ),
        );
      },
    );
  }
}
