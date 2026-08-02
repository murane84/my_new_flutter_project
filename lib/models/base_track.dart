import 'dart:io';
import 'song_track.dart';
import 'track.dart';

abstract class BaseTrack {
  String get title;
  String get data;
  String? get artist;

  /// Every track type must be serializable
  Map<String, dynamic> toJson();

  /// Factory for decoding JSON back into the right subclass
  factory BaseTrack.fromJson(Map<String, dynamic> json) {
    switch (json['type']) {
      case 'song':
        return SongTrack.fromJson(json);
      case 'track':
        return Track.fromJson(json);
      case 'file':
        return FileTrack(json['path']);
      case 'directory':
        return DirectoryTrack(Directory(json['path']));
      case 'stream':
        return StreamTrack(
          url: json['url'],
          title: json['title'] ?? "Online Stream",
          artist: json['artist'] ?? "Unknown",
        );
      default:
        throw Exception("Unknown track type: ${json['type']}");
    }
  }
}

/// --- File Track ---
class FileTrack implements BaseTrack {
  final String path;
  FileTrack(this.path);

  @override
  String get title => path.split(Platform.pathSeparator).last;

  @override
  String get data => path;

  @override
  String? get artist => null;

  @override
  Map<String, dynamic> toJson() {
    return {'type': 'file', 'path': path};
  }
}

/// --- Directory Track ---
class DirectoryTrack implements BaseTrack {
  final Directory directory;
  DirectoryTrack(this.directory);

  @override
  String get title => directory.path.split(Platform.pathSeparator).last;

  @override
  String get data => directory.path;

  @override
  String? get artist => null;

  @override
  Map<String, dynamic> toJson() {
    return {'type': 'directory', 'path': directory.path};
  }
}

/// --- Stream Track (NEW) ---
class StreamTrack implements BaseTrack {
  final String url;
  @override
  final String title;
  @override
  final String artist;

  StreamTrack({
    required this.url,
    this.title = "Online Stream",
    this.artist = "Unknown",
  });

  @override
  String get data => url;

  @override
  Map<String, dynamic> toJson() {
    return {'type': 'stream', 'url': url, 'title': title, 'artist': artist};
  }
}
