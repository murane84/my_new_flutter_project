// Facade: decode in-memory audio to PCM in the browser (Web Audio). On other
// platforms the stub returns null (they decode natively).
export 'vocal_decode_stub.dart' if (dart.library.html) 'vocal_decode_web.dart';
