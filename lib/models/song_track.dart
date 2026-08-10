import 'package:on_audio_query/on_audio_query.dart';
import 'base_track.dart';

class SongTrack implements BaseTrack {
  final SongModel song;

  SongTrack(this.song);

  String get id => song.id.toString();

  @override
  String get title => song.title;

  @override
  String get artist => song.artist ?? "Unknown";

  @override
  String get data => song.data;

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'song',
      'id': id,
      'title': title,
      'artist': artist,
      'data': data,
      'album': song.album ?? "Unknown",
      'duration': song.duration ?? 0,
    };
  }

  factory SongTrack.fromJson(Map<String, dynamic> json) {
    final fakeSong = SongModel({
      "_id": int.tryParse(json['id'].toString()) ?? 0,
      "title": json['title'] ?? "",
      "artist": json['artist'],
      "_data": json['data'] ?? "",
      "album": json['album'] ?? "Unknown",
      "duration": json['duration'] ?? 0,
      "_display_name": json['title'] ?? "",
      "_display_name_wo_ext": json['title']?.split('.').first ?? "",
      "_size": 0,
    });

    return SongTrack(fakeSong);
  }
}
