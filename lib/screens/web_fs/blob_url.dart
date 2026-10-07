// Facade: a browser object-URL helper for in-memory audio (web only).
// On native it's a no-op stub (the web music panel is web-only).
export 'blob_url_stub.dart' if (dart.library.html) 'blob_url_web.dart';
