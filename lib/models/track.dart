import 'base_track.dart';

class Track implements BaseTrack {
  final String id;
  @override
  final String title;
  @override
  final String artist;
  @override
  final String data;

  Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.data,
  });

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'track',
      'id': id,
      'title': title,
      'artist': artist,
      'data': data,
    };
  }

  factory Track.fromJson(Map<String, dynamic> json) {
    return Track(
      id: json['id'] ?? "0",
      title: json['title'] ?? "Unknown",
      artist: json['artist'] ?? "Unknown",
      data: json['data'] ?? "",
    );
  }
}
