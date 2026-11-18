import 'dart:typed_data';

// Native platforms don't use object URLs (the web panel is web-only).
String makeBlobUrl(Uint8List bytes, String contentType) => '';
void revokeBlobUrl(String url) {}
bool downloadBytes(Uint8List bytes, String name, String contentType) =>
    false;
bool openBytesInTab(Uint8List bytes, String contentType) => false;
