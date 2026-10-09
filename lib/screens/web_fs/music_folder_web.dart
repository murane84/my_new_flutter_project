// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

import 'music_folder_types.dart';

export 'music_folder_types.dart';

bool get folderPickSupported => true;

final RegExp _audioRe =
    RegExp(r'\.(mp3|wav|m4a|aac|ogg|flac)$', caseSensitive: false);

/// Open the OS file chooser for audio. When [directory] is true we request a
/// whole-folder pick (webkitdirectory, desktop browsers); otherwise it's a
/// plain multi-FILE pick, which is the reliable path on mobile where folder
/// selection and file_picker's allowMultiple are both flaky.
///
/// Robustness notes (these are why the Queue "+"/folder buttons used to look
/// dead on phones):
///  * The input is appended to the DOM before .click() — iOS Safari and some
///    Android WebViews silently ignore a click on a detached input, so the
///    chooser never opened and the caller hung (leaving the panel "loading",
///    which disabled the buttons).
///  * Cancel/slow-selection is detected by polling input.files after the
///    window regains focus, instead of a flat timeout that discarded picks the
///    mobile browser delivered late.
Future<List<WebAudioEntry>> _pickAudio({required bool directory}) {
  final input = html.FileUploadInputElement()
    ..multiple = true
    ..accept = 'audio/*';
  if (directory) {
    input.setAttribute('webkitdirectory', '');
    input.setAttribute('directory', '');
  }
  // Keep it out of sight but in the DOM so .click() reliably opens the chooser.
  input.style
    ..position = 'fixed'
    ..left = '0'
    ..top = '0'
    ..width = '1px'
    ..height = '1px'
    ..opacity = '0'
    ..pointerEvents = 'none';
  html.document.body?.append(input);

  final completer = Completer<List<WebAudioEntry>>();
  StreamSubscription<html.Event>? changeSub;
  StreamSubscription<html.Event>? focusSub;
  Timer? pollTimer;

  void cleanup() {
    pollTimer?.cancel();
    changeSub?.cancel();
    focusSub?.cancel();
    input.remove();
  }

  List<WebAudioEntry> parse() {
    final files = input.files ?? const <html.File>[];
    final out = <WebAudioEntry>[];
    for (final f in files) {
      // A folder pick can also return cover art etc.; keep audio only. A plain
      // file pick already filtered by the accept attribute.
      if (directory && !_audioRe.hasMatch(f.name)) continue;
      out.add(WebAudioEntry(f.name, () => _read(f)));
    }
    if (directory) {
      out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
    return out;
  }

  void finish(List<WebAudioEntry> v) {
    if (!completer.isCompleted) completer.complete(v);
    cleanup();
  }

  changeSub = input.onChange.listen((_) => finish(parse()));

  // When the chooser closes the window regains focus, but on mobile the picked
  // files may not be attached yet — so poll briefly rather than giving up at
  // once. Resolve as soon as files appear; resolve empty (a cancel) only after
  // the grace window passes with none.
  focusSub = html.window.onFocus.listen((_) {
    if (completer.isCompleted) return;
    var elapsedMs = 0;
    pollTimer?.cancel();
    pollTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (completer.isCompleted) return;
      elapsedMs += 250;
      final n = input.files?.length ?? 0;
      if (n > 0) {
        finish(parse());
      } else if (elapsedMs >= 3000) {
        finish(const <WebAudioEntry>[]);
      }
    });
  });

  input.click();
  return completer.future;
}

/// Let the user pick a whole folder; return every audio file inside it
/// (recursively) on browsers that honor webkitdirectory. Each entry loads its
/// bytes lazily.
Future<List<WebAudioEntry>> pickMusicFolder() => _pickAudio(directory: true);

/// A plain multi-FILE audio picker (no folder): the reliable multi-select path
/// on mobile web. Bytes load lazily.
Future<List<WebAudioEntry>> pickMusicFiles() => _pickAudio(directory: false);

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
