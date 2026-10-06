// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

/// One file lifted off the clipboard (name + raw bytes + mime type).
class PastedFile {
  PastedFile(this.name, this.bytes, this.mime);
  final String name;
  final Uint8List bytes;
  final String mime;
}

html.EventListener? _listener;

/// Listens for the browser paste event and, when the clipboard carries one or
/// more files, reads their bytes and hands them to [onFiles]. Only one handler
/// is active at a time (registering again replaces the previous one).
void registerClipboardPaste(void Function(List<PastedFile>) onFiles) {
  unregisterClipboardPaste();
  void handler(html.Event event) {
    if (event is! html.ClipboardEvent) return;
    final data = event.clipboardData;
    if (data == null) return;
    final files = data.files;
    if (files == null || files.isEmpty) return;
    // We'll handle these ourselves — stop the browser from also pasting a file
    // name / image into the focused text field.
    event.preventDefault();
    _collect(files).then((out) {
      if (out.isNotEmpty) onFiles(out);
    });
  }

  _listener = handler;
  html.document.addEventListener('paste', handler);
}

/// Stops listening for clipboard paste events.
void unregisterClipboardPaste() {
  final l = _listener;
  if (l != null) {
    html.document.removeEventListener('paste', l);
    _listener = null;
  }
}

Future<List<PastedFile>> _collect(List<html.File> files) async {
  final out = <PastedFile>[];
  for (final f in files) {
    final bytes = await _readBytes(f);
    if (bytes == null || bytes.isEmpty) continue;
    out.add(PastedFile(
      f.name.isNotEmpty ? f.name : 'pasted',
      bytes,
      f.type.isNotEmpty ? f.type : 'application/octet-stream',
    ));
  }
  return out;
}

Future<Uint8List?> _readBytes(html.File f) {
  final completer = Completer<Uint8List?>();
  final reader = html.FileReader();
  reader.onLoadEnd.listen((_) {
    final result = reader.result;
    if (result is Uint8List) {
      completer.complete(result);
    } else if (result is ByteBuffer) {
      completer.complete(Uint8List.view(result));
    } else if (result is List<int>) {
      completer.complete(Uint8List.fromList(result));
    } else {
      completer.complete(null);
    }
  });
  reader.onError.listen((_) => completer.complete(null));
  reader.readAsArrayBuffer(f);
  return completer.future;
}
