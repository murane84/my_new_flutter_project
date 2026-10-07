// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

import 'music_folder_types.dart';

export 'music_folder_types.dart';

bool get folderPickSupported => true;

final RegExp _audioRe =
    RegExp(r'\.(mp3|wav|m4a|aac|ogg|flac)$', caseSensitive: false);

/// Let the user pick a whole folder; return every audio file inside it
/// (recursively), newest browsers included. Each entry loads its bytes lazily.
Future<List<WebAudioEntry>> pickMusicFolder() {
  final input = html.FileUploadInputElement()
    ..multiple = true
    ..accept = 'audio/*';
  // webkitdirectory turns the picker into a folder chooser and returns the
  // folder's files (recursively). Supported in Chromium, Firefox and Safari.
  input.setAttribute('webkitdirectory', '');
  input.setAttribute('directory', '');

  final completer = Completer<List<WebAudioEntry>>();
  StreamSubscription<html.Event>? focusSub;
  void finish(List<WebAudioEntry> v) {
    if (!completer.isCompleted) completer.complete(v);
    focusSub?.cancel();
  }

  input.onChange.listen((_) {
    final files = input.files ?? const <html.File>[];
    final out = <WebAudioEntry>[];
    for (final f in files) {
      if (!_audioRe.hasMatch(f.name)) continue;
      out.add(WebAudioEntry(f.name, () => _read(f)));
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    finish(out);
  });

  // Cancel detection: a cancelled dialog fires no change event. When the window
  // regains focus, give change a moment to arrive, then resolve empty so the
  // caller's await never hangs.
  focusSub = html.window.onFocus.listen((_) {
    Future.delayed(const Duration(milliseconds: 700),
        () => finish(const <WebAudioEntry>[]));
  });

  input.click();
  return completer.future;
}

Future<Uint8List> _read(html.File f) {
  final reader = html.FileReader();
  final c = Completer<Uint8List>();
  reader.onLoadEnd.listen((_) {
    final r = reader.result;
    if (r is Uint8List) {
      c.complete(r);
    } else if (r is ByteBuffer) {
      c.complete(r.asUint8List());
    } else if (!c.isCompleted) {
      c.completeError(StateError('Could not read file'));
    }
  });
  reader.onError
      .listen((_) => c.completeError(StateError('Could not read file')));
  reader.readAsArrayBuffer(f);
  return c.future;
}
