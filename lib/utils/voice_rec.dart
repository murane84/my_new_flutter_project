import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'net.dart' as http;

/// Voice recordings that work everywhere. Phones and the desktop app record
/// AAC (.m4a) into a temp file; a browser has no files or temp folder, so
/// the web app records in memory and gets a blob: address back — AAC where
/// the browser can (Safari), else Opus in WebM (Chrome, Edge, Firefox).
class VoiceRec {
  VoiceRec._();

  static bool _webm = false; // the last web recording was Opus / WebM

  static String get ext => _webm ? 'webm' : 'm4a';
  static String get mime => _webm ? 'audio/webm' : 'audio/mp4';

  /// Start recording with [r]; [prefix] names the temp file on devices.
  static Future<void> start(AudioRecorder r, String prefix) async {
    if (kIsWeb) {
      final aac = await r.isEncoderSupported(AudioEncoder.aacLc);
      _webm = !aac;
      await r.start(
          RecordConfig(encoder: aac ? AudioEncoder.aacLc : AudioEncoder.opus),
          path: '');
      return;
    }
    _webm = false;
    final dir = await getTemporaryDirectory();
    await r.start(
      const RecordConfig(
          encoder: AudioEncoder.aacLc, bitRate: 128000, sampleRate: 44100),
      path: '${dir.path}/${prefix}_${DateTime.now().millisecondsSinceEpoch}.m4a',
    );
  }

  /// The recorded bytes behind [path] (a file, or the web's blob: address).
  static Future<Uint8List> bytesOf(String path) async {
    if (kIsWeb) return (await http.get(Uri.parse(path))).bodyBytes;
    return File(path).readAsBytes();
  }

  /// Let go of a recording (deletes the temp file on devices).
  static Future<void> discard(String? path) async {
    if (path == null || path.isEmpty || kIsWeb) return;
    try {
      await File(path).delete();
    } catch (_) {}
  }
}
