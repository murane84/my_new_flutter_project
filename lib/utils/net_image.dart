import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

/// Desktop (Windows/Linux/macOS) can't use cached_network_image's disk cache —
/// its backing store (sqflite) isn't available there, which showed up as broken
/// message images in the Windows app while tiny avatars still slipped through.
/// On desktop we fall back to Flutter's native Image.network (no sqflite); on
/// mobile we keep CachedNetworkImage for its on-disk cache. Web is handled
/// separately (see below).
bool get _useNativeImage =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

/// On the WEB a browser loads images via an <img> element and CANNOT attach an
/// Authorization header — so our token-protected /attachments|/media endpoints
/// would return 401 and the image breaks. The backend also accepts the JWT as a
/// `?token=` query param (see get_current_user_flexible), so on web we move the
/// bearer token from the header into the URL and load it with a plain
/// Image.network. Non-web platforms keep sending the header and ignore this.
String _tokenUrl(String url, Map<String, String> headers) {
  final auth = headers['Authorization'] ?? headers['authorization'] ?? '';
  if (!auth.startsWith('Bearer ')) return url;
  final tok = auth.substring(7).trim();
  if (tok.isEmpty) return url;
  final sep = url.contains('?') ? '&' : '?';
  return '$url${sep}token=${Uri.encodeQueryComponent(tok)}';
}

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
  if (kIsWeb) {
    return Image.network(
      _tokenUrl(url, headers),
      width: width,
      height: height,
      fit: fit,
      loadingBuilder: (ctx, child, progress) => progress == null
          ? child
          : (placeholder?.call(ctx) ?? _fallbackLoader()),
      errorBuilder: (ctx, _, _) => error?.call(ctx) ?? _fallbackError(),
    );
  }
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
/// and the like. On web the token rides in the URL (no header); NetworkImage on
/// desktop (no sqflite cache); CachedNetworkImage provider on mobile.
ImageProvider authNetworkImageProvider(
    String url, Map<String, String> headers) {
  if (kIsWeb) return NetworkImage(_tokenUrl(url, headers));
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
