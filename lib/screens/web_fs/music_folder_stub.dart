import 'music_folder_types.dart';

export 'music_folder_types.dart';

/// Native platforms don't use this (the whole web panel is web-only); folder
/// picking degrades to the normal multi-file picker.
const bool folderPickSupported = false;

Future<List<WebAudioEntry>> pickMusicFolder() async => const <WebAudioEntry>[];
