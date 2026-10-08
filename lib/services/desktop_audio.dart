// Initialise the desktop (Windows) audio backend. Uses a conditional import so
// the web build never references media_kit (which has no web support): web gets
// the no-op stub, native builds get the real initialiser.
export 'desktop_audio_stub.dart'
    if (dart.library.io) 'desktop_audio_io.dart';
