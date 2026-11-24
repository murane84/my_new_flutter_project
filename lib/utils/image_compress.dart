import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// One rule for every photo Aluta uploads (chat and status): downscale to
/// ≤1600px on the long edge and re-encode as JPEG q78 — or PNG when it has
/// see-through parts (a JPEG would turn them black; stickers and logos keep
/// their shape). Run it via `compute` (it decodes the whole image). Returns
/// the input unchanged if it can't decode.
Uint8List compressPhotoForUpload(Uint8List input) {
  try {
    final decoded = img.decodeImage(input);
    if (decoded == null) return input;
    const maxDim = 1600;
    img.Image out = decoded;
    if (decoded.width > maxDim || decoded.height > maxDim) {
      out = decoded.width >= decoded.height
          ? img.copyResize(decoded, width: maxDim)
          : img.copyResize(decoded, height: maxDim);
    }
    if (out.hasAlpha && _seeThrough(out)) {
      return Uint8List.fromList(img.encodePng(out, level: 6));
    }
    return Uint8List.fromList(img.encodeJpg(out, quality: 78));
  } catch (_) {
    return input;
  }
}

/// The type of what [compressPhotoForUpload] returned.
String compressedPhotoMime(List<int> b) =>
    b.length > 3 && b[0] == 0x89 ? 'image/png' : 'image/jpeg';

/// Photos at or under this size go up untouched.
const int kPhotoCompressOver = 350 * 1024;

/// Any pixel not fully opaque (sampled — a big image needn't be walked whole).
bool _seeThrough(img.Image im) {
  final step = math.max(1, (im.width * im.height / 40000).floor());
  var i = 0;
  for (final p in im) {
    if (i++ % step == 0 && p.a < p.maxChannelValue) return true;
  }
  return false;
}
