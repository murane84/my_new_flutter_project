import 'dart:typed_data';

/// One audio file discovered from a web "folder pick". Bytes load LAZILY (only
/// when the track is actually played) so a large library never has to sit in
/// memory all at once — the browser reads each file from disk on demand.
class WebAudioEntry {
  WebAudioEntry(this.name, this.load);
  final String name;
  final Future<Uint8List> Function() load;
}
