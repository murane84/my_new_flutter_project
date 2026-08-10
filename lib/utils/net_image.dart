import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

/// Desktop (Windows/Linux/macOS) can't use cached_network_image's disk cache —
/// its backing store (sqflite) isn't available there, which showed up as broken
/// message images in the Windows app while tiny avatars still slipped through.
/// On desktop we fall back to Flutter's native Image.network (no sqflite); on
/// mobile/web we keep CachedNetworkImage for its on-disk cache.
bool get _useNativeImage =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

/// A cross-platform authenticated network image. Same call for every platform;
/// it picks the loader that actually works there.
Widget authNetworkImage({
  required String url,
  required Map<String, String> headers,
  double? width,
  double? height,
  BoxFit fit = BoxFit.cover,
  Widget Function(BuildContext context)? placeholder,
  Widget Function(BuildContext context)? error,
}) {
  if (_useNativeImage) {
    return Image.network(
      url,
      headers: headers,
      width: width,
      height: height,
      fit: fit,
      loadingBuilder: (ctx, child, progress) => progress == null
          ? child
          : (placeholder?.call(ctx) ?? _fallbackLoader()),
      errorBuilder: (ctx, _, _) => error?.call(ctx) ?? _fallbackError(),
    );
  }
  return CachedNetworkImage(
    imageUrl: url,
    httpHeaders: headers,
    width: width,
    height: height,
    fit: fit,
    placeholder: placeholder != null ? (c, _) => placeholder(c) : null,
    errorWidget: (c, _, _) => error?.call(c) ?? _fallbackError(),
  );
}

/// Cross-platform authenticated [ImageProvider] — for CircleAvatar.backgroundImage
/// and the like. NetworkImage on desktop (no sqflite cache), CachedNetworkImage
/// provider on mobile/web.
ImageProvider authNetworkImageProvider(
    String url, Map<String, String> headers) {
  if (_useNativeImage) return NetworkImage(url, headers: headers);
  return CachedNetworkImageProvider(url, headers: headers);
}

Widget _fallbackLoader() => const Center(
      child: SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );

Widget _fallbackError() => const ColoredBox(
      color: Color(0x22000000),
      child: Center(child: Icon(Icons.broken_image_rounded)),
    );
