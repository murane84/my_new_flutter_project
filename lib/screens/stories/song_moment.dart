import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../../services/live_session_service.dart' show BytesAudioSource;
import '../../services/track_title.dart' show displayTitleForPath;
import '../../utils/adaptive_sheet.dart';
import '../../utils/file_bytes.dart';
import '../../utils/radii.dart';
import '../api_service.dart';
import '../home_page.dart' show playlistNotifier, playbackBus;

/// A song moment for a status: which song, where its 15 s start.
class SongMoment {
  SongMoment({
    required this.title,
    required this.fileName,
    required this.load,
    required this.startMs,
    required this.durationMs,
  });
  final String title;
  final String fileName;
  final Future<List<int>> Function() load;
  final int startMs;
  final int durationMs;

  bool get isMp3 => fileName.toLowerCase().endsWith('.mp3');

  String get mime {
    final f = fileName.toLowerCase();
    if (f.endsWith('.m4a') || f.endsWith('.aac') || f.endsWith('.mp4')) {
      return 'audio/mp4';
    }
    if (f.endsWith('.ogg') || f.endsWith('.opus')) return 'audio/ogg';
    if (f.endsWith('.wav')) return 'audio/wav';
    if (f.endsWith('.flac')) return 'audio/flac';
    return 'audio/mpeg';
  }
}

const Duration kSongMoment = Duration(seconds: 15);

/// A song loaded in my player, readable as bytes.
class LoadedSong {
  LoadedSong(this.title, this.fileName, this.load);
  final String title;
  final String fileName;
  final Future<List<int>> Function() load;
}

/// The songs loaded in my player (phone/desktop: files; web: the queue).
List<LoadedSong> loadedSongs() {
  if (kIsWeb) {
    final q = playbackBus.webQueue?.call() ?? const [];
    return [
      for (final s in q) LoadedSong(s.title, '${s.title}.mp3', () => s.load()),
    ];
  }
  return [
    for (final p in playlistNotifier.value)
      LoadedSong(displayTitleForPath(p), p.split(RegExp(r'[\\/]')).last,
          () => readFileBytes(p)),
  ];
}

/// Pick one of the songs loaded in my player (null if none / cancelled).
Future<LoadedSong?> pickLoadedSong(BuildContext context,
    {String title = 'Choose a song', String? subtitle}) async {
  final songs = loadedSongs();
  if (songs.isEmpty) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
        content: Text('Load some songs in the music player first')));
    return null;
  }
  return showAdaptiveSheet<LoadedSong>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) => ConstrainedBox(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.6),
      child: ListView(shrinkWrap: true, children: [
        ListTile(
            title: Text(title,
                style: const TextStyle(fontWeight: FontWeight.w800)),
            subtitle: subtitle == null ? null : Text(subtitle)),
        for (final s in songs)
          ListTile(
            leading: const Icon(Icons.music_note_rounded),
            title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => Navigator.pop(c, s),
          ),
      ]),
    ),
  );
}

/// Pick a song from my player, then the 15-second moment to use.
Future<SongMoment?> pickSongMoment(BuildContext context) async {
  final pick = await pickLoadedSong(context,
      title: 'Add a song', subtitle: 'Then choose the 15 seconds that say it');
  if (pick == null || !context.mounted) return null;
  return showAdaptiveSheet<SongMoment>(
    context: context,
    showDragHandle: true,
    builder: (_) => _MomentSheet(pick: pick),
  );
}

class _MomentSheet extends StatefulWidget {
  const _MomentSheet({required this.pick});
  final LoadedSong pick;

  @override
  State<_MomentSheet> createState() => _MomentSheetState();
}

class _MomentSheetState extends State<_MomentSheet> {
  final ja.AudioPlayer _p = ja.AudioPlayer();
  int _dur = 0;
  double _start = 0;
  bool _ready = false;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _load();
    _p.playerStateStream.listen((s) {
      if (mounted) setState(() => _playing = s.playing);
    });
    _p.positionStream.listen((pos) {
      // The preview stops at the end of the moment.
      if (_playing &&
          pos.inMilliseconds >=
              _start.round() + kSongMoment.inMilliseconds) {
        _p.pause();
      }
    });
  }

  Future<void> _load() async {
    try {
      final b = Uint8List.fromList(await widget.pick.load());
      final d = await _p.setAudioSource(BytesAudioSource(b,
          contentType: SongMoment(
                  title: '',
                  fileName: widget.pick.fileName,
                  load: widget.pick.load,
                  startMs: 0,
                  durationMs: 0)
              .mime));
      if (!mounted) return;
      setState(() {
        _dur = d?.inMilliseconds ?? 0;
        // Most choruses sit around a third in.
        _start = (_dur * 0.33).clamp(0, (_dur - 15000).clamp(0, _dur)).toDouble();
        _ready = true;
      });
    } catch (_) {
      if (mounted) setState(() => _ready = true);
    }
  }

  @override
  void dispose() {
    _p.dispose();
    super.dispose();
  }

  String _t(num ms) {
    final s = (ms / 1000).round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _preview() async {
    if (_playing) {
      await _p.pause();
      return;
    }
    await _p.seek(Duration(milliseconds: _start.round()));
    _p.play();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxStart = (_dur - 15000).clamp(0, _dur).toDouble();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.pick.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(
                _ready
                    ? 'Your moment: ${_t(_start)} – ${_t(_start + 15000)}'
                    : 'Getting the song ready…',
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            if (_ready && _dur > 0)
              Slider(
                value: _start.clamp(0.0, maxStart).toDouble(),
                max: maxStart <= 0 ? 1 : maxStart,
                onChanged: maxStart <= 0
                    ? null
                    : (v) => setState(() => _start = v),
                onChangeEnd: (_) {
                  if (_playing) {
                    _p.seek(Duration(milliseconds: _start.round()));
                  }
                },
              ),
            const SizedBox(height: 6),
            Row(children: [
              OutlinedButton.icon(
                onPressed: _ready && _dur > 0 ? _preview : null,
                icon: Icon(
                    _playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                label: Text(_playing ? 'Pause' : 'Preview'),
                style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Radii.lg))),
              ),
              const Spacer(),
              FilledButton(
                onPressed: !_ready
                    ? null
                    : () {
                        _p.pause();
                        Navigator.pop(
                            context,
                            SongMoment(
                              title: widget.pick.title,
                              fileName: widget.pick.fileName,
                              load: widget.pick.load,
                              startMs: _start.round(),
                              durationMs: _dur,
                            ));
                      },
                child: const Text('Use this moment'),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// Upload the moment for a status: an MP3 is cut to just its ~16 s (MP3
/// frames re-sync, so a byte slice plays); other formats go whole and play
/// from [SongMoment.startMs]. Returns (asset id, start ms) or null.
Future<(String, int)?> uploadSongMoment(SongMoment m) async {
  try {
    var bytes = await m.load();
    var start = m.startMs;
    if (m.isMp3 && m.durationMs > 20000 && bytes.length > 600000) {
      // Skip the ID3 tag (cover art can be big) before mapping time → bytes.
      var audio0 = 0;
      if (bytes.length > 10 &&
          bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) {
        audio0 = 10 +
            ((bytes[6] & 0x7f) << 21 |
                (bytes[7] & 0x7f) << 14 |
                (bytes[8] & 0x7f) << 7 |
                (bytes[9] & 0x7f));
      }
      final audioLen = bytes.length - audio0;
      int at(int ms) =>
          (audio0 + audioLen * ms / m.durationMs).round().clamp(0, bytes.length);
      final from = at(m.startMs);
      final to = at(m.startMs + kSongMoment.inMilliseconds + 1500);
      if (to - from > 20000) {
        bytes = bytes.sublist(from, to);
        start = 0;
      }
    } else if (bytes.length > 15 * 1024 * 1024) {
      return null; // too big to send whole
    }
    final id = await ApiService().uploadStoryMedia(
      bytes: bytes,
      filename: m.isMp3 ? 'moment.mp3' : m.fileName,
      mime: m.mime,
    );
    return id == null ? null : (id, start);
  } catch (_) {
    return null;
  }
}
