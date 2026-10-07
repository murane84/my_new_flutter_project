import 'dart:typed_data';

// Native platforms don't use object URLs (the web panel is web-only).
String makeBlobUrl(Uint8List bytes, String contentType) => '';
void revokeBlobUrl(String url) {}
