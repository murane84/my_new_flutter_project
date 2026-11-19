import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show SynchronousFuture, kIsWeb;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../e2ee/seal_media.dart';
import '../services/media_store.dart';

/// 🔒 A sealed photo (SealMedia): fetched, opened on this device with the
/// key its address carries, and shown from memory — no network loader can
/// read locked bytes.
class SealedImage extends ImageProvider<SealedImage> {
  const SealedImage(this.url, this.headers);
  final String url;
  final Map<String, String> headers;

  @override
  Future<SealedImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<SealedImage>(this);

  @override
  ImageStreamCompleter loadImage(SealedImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
          codec: _load(decode), scale: 1.0, debugLabel: 'sealed image');

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final data = await MediaStore.instance.bytes(url, headers);
    if (data == null || data.isEmpty) {
      throw StateError('sealed image unavailable');
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(data));
  }

  @override
  bool operator ==(Object other) => other is SealedImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

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
  // Decode the image DOWN to at most this many pixels wide/tall in memory. A
  // phone photo is ~4000px (~48MB decoded); shown in a 240px chat bubble that's
  // pure waste, and dozens of them exhaust memory → GC thrash → UI freeze/ANR.
  // Pass the on-screen size × devicePixelRatio for thumbnails; leave null for
  // the full-screen zoomable viewer that actually needs full resolution.
  int? cacheWidth,
  int? cacheHeight,
}) {
  if (SealMedia.isSealed(url)) {
    return Image(
      image: ResizeImage.resizeIfNeeded(
          cacheWidth, cacheHeight, SealedImage(url, headers)),
      width: width,
      height: height,
      fit: fit,
      gaplessPlayback: true,
      loadingBuilder: (ctx, child, progress) => progress == null
          ? child
          : (placeholder?.call(ctx) ?? _fallbackLoader()),
      frameBuilder: (ctx, child, frame, sync) => frame == null && !sync
          ? (placeholder?.call(ctx) ?? _fallbackLoader())
          : child,
      errorBuilder: (ctx, _, _) => error?.call(ctx) ?? _fallbackError(),
    );
  }
  if (kIsWeb) {
    return Image.network(
      _tokenUrl(url, headers),
      width: width,
      height: height,
      fit: fit,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
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
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
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
    memCacheWidth: cacheWidth,
    memCacheHeight: cacheHeight,
    placeholder: placeholder != null ? (c, _) => placeholder(c) : null,
    errorWidget: (c, _, _) => error?.call(c) ?? _fallbackError(),
  );
}

/// Cross-platform authenticated [ImageProvider] — for CircleAvatar.backgroundImage
/// and the like. On web the token rides in the URL (no header); NetworkImage on
/// desktop (no sqflite cache); CachedNetworkImage provider on mobile.
///
/// Pass [cacheSize] for avatars/thumbnails so the bitmap is decoded down to that
/// many pixels instead of full resolution — a screen full of full-res avatars is
/// a leading cause of the memory-pressure UI freeze. Leave it null where full
/// resolution is required (the zoomable full-screen image viewer).
ImageProvider authNetworkImageProvider(
    String url, Map<String, String> headers,
    {int? cacheSize}) {
  final ImageProvider base;
  if (SealMedia.isSealed(url)) {
    base = SealedImage(url, headers);
  } else if (kIsWeb) {
    base = NetworkImage(_tokenUrl(url, headers));
  } else if (_useNativeImage) {
    base = NetworkImage(url, headers: headers);
  } else {
    base = CachedNetworkImageProvider(url, headers: headers);
  }
  if (cacheSize != null) {
    // Keep the photo's own shape: an exact square decode squeezed every
    // portrait / landscape photo into a square (stretched faces in avatars).
    // `fit` shrinks it to fit a box twice the size, so even the shorter side
    // stays sharp when the circle crops it (BoxFit.cover).
    final box = (cacheSize * 2).clamp(64, 1024);
    return ResizeImage(base,
        width: box, height: box, policy: ResizeImagePolicy.fit);
  }
  return base;
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
