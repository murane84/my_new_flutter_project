import 'dart:typed_data';

/// One file lifted off the clipboard (name + raw bytes + mime type).
class PastedFile {
  PastedFile(this.name, this.bytes, this.mime);
  final String name;
  final Uint8List bytes;
  final String mime;
}

/// No-op on native platforms.
void registerClipboardPaste(void Function(List<PastedFile>) onFiles) {}

/// No-op on native platforms.
void unregisterClipboardPaste() {}
