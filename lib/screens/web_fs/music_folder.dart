// Facade for the web-only "pick a whole music folder" helper.
//
// On web this resolves to a real folder picker (dart:html); on native it's a
// no-op stub (folderPickSupported == false), so callers degrade cleanly to the
// normal multi-file picker.
export 'music_folder_stub.dart'
    if (dart.library.html) 'music_folder_web.dart';
