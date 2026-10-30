// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:typed_data';
import 'dart:web_audio' as wa;

/// Mono PCM samples (−1…1) and their sample rate, decoded by the browser's
/// own audio engine (mp3 / m4a / ogg / wav — whatever it can play).
Future<(Float32List, int)?> decodePcm(Uint8List bytes) async {
  wa.AudioContext? ctx;
  try {
    ctx = wa.AudioContext();
    // decodeAudioData detaches the buffer it's given — hand it a copy.
    final copy = Uint8List.fromList(bytes).buffer;
    final buf = await ctx.decodeAudioData(copy);
    final data = buf.getChannelData(0);
    final num? rate = buf.sampleRate;
    return (data, rate?.round() ?? 44100);
  } catch (_) {
    return null;
  } finally {
    try {
      await ctx?.close();
    } catch (_) {}
  }
}
