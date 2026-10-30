import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

/// Mono PCM samples (−1…1) and their sample rate, decoded by the browser's
/// own audio engine (mp3 / m4a / ogg / wav — whatever it can play).
Future<(Float32List, int)?> decodePcm(Uint8List bytes) async {
  JSObject? ctx;
  try {
    final ctor = globalContext.getProperty<JSFunction?>('AudioContext'.toJS) ??
        globalContext.getProperty<JSFunction?>('webkitAudioContext'.toJS);
    if (ctor == null) return null;
    ctx = ctor.callAsConstructor<JSObject>();
    // decodeAudioData detaches the buffer it's given — hand it a copy.
    final ab = Uint8List.fromList(bytes).buffer.toJS;
    final buf = await ctx
        .callMethod<JSPromise<JSObject>>('decodeAudioData'.toJS, ab)
        .toDart;
    final data = buf
        .callMethod<JSFloat32Array>('getChannelData'.toJS, 0.toJS)
        .toDart;
    final rate =
        buf.getProperty<JSNumber>('sampleRate'.toJS).toDartDouble.round();
    return (data, rate);
  } catch (_) {
    return null;
  } finally {
    try {
      ctx?.callMethod<JSAny?>('close'.toJS);
    } catch (_) {}
  }
}
