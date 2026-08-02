import 'package:audioplayers/audioplayers.dart';

class AudioService {
  static final AudioService _instance = AudioService._internal();
  factory AudioService() => _instance;

  final AudioPlayer _player = AudioPlayer();
  final List<String> _playlist = [];

  int _currentIndex = 0;

  AudioService._internal();

  AudioPlayer get player => _player; // ✅ Public getter added here

  Future<void> playSingleFile(String path) async {
    await _player.stop();
    await _player.play(DeviceFileSource(path));
  }

  Future<void> loadPlaylist(List<String> paths, {int startIndex = 0}) async {
    _playlist.clear();
    _playlist.addAll(paths);
    _currentIndex = startIndex;
    await playCurrent();
  }

  Future<void> playCurrent() async {
    if (_playlist.isEmpty || _currentIndex >= _playlist.length) return;
    await _player.stop();
    await _player.play(DeviceFileSource(_playlist[_currentIndex]));
  }

  void playNext() {
    if (_currentIndex < _playlist.length - 1) {
      _currentIndex++;
      playCurrent();
    }
  }

  void playPrevious() {
    if (_currentIndex > 0) {
      _currentIndex--;
      playCurrent();
    }
  }

  Future<void> setRepeat(bool repeat) async {
    await _player.setReleaseMode(repeat ? ReleaseMode.loop : ReleaseMode.stop);
  }

  void dispose() {
    _player.dispose();
  }

  bool get hasPlaylist => _playlist.length > 1;
  int get currentIndex => _currentIndex;
  int get playlistLength => _playlist.length;

  String? get currentTrackPath {
    if (_playlist.isEmpty || _currentIndex >= _playlist.length) return null;
    return _playlist[_currentIndex];
  }

  String? get currentTrackName {
    if (_playlist.isEmpty || _currentIndex >= _playlist.length) return null;
    return _playlist[_currentIndex].split('/').last.split('.').first;
  }

  List<String> get playlist => List.unmodifiable(_playlist);
  void addToPlaylist(String path) {
    if (!_playlist.contains(path)) {
      _playlist.add(path);
    }
  }

  void removeFromPlaylist(String path) {
    _playlist.remove(path);
    if (_currentIndex >= _playlist.length) {
      _currentIndex = _playlist.length - 1;
    }
  }
}
