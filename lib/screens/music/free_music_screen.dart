import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/metadata_overrides.dart';
import '../../utils/app_config.dart';
import '../../utils/toast_helper.dart';
import '../../widgets/tap_chip.dart';
import '../home_page.dart' show freeMusicInbox, playbackBus;
import '../token_helper.dart';

/// Free music: search songs artists released to be downloaded for free —
/// Jamendo (Creative Commons) and the Internet Archive (CC / public domain).
/// Never pirate sites. Preview a song, then Download drops it into the
/// playlist with its title, artist and a credit to the licence.
class FreeMusicScreen extends StatelessWidget {
  const FreeMusicScreen({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => const FreeMusicScreen()));

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: FreeMusicPanel(onBack: () => Navigator.of(context).pop()),
        ),
      );
}

/// The Free music page itself, built to sit inside the music player like the
/// playlist page: the same header bar (back chip, title, count pill), the
/// same card surface. [onBack] returns to wherever it was opened from.
class FreeMusicPanel extends StatefulWidget {
  const FreeMusicPanel({super.key, required this.onBack});
  final VoidCallback onBack;

  @override
  State<FreeMusicPanel> createState() => _FreeMusicPanelState();
}

class _FreeMusicPanelState extends State<FreeMusicPanel> {
  final _q = TextEditingController();
  final _player = AudioPlayer();
  Timer? _debounce;
  List<Map<String, dynamic>> _results = const [];
  bool _loading = false;
  String? _error;
  String? _previewId;
  bool _previewLoading = false;
  final Map<String, double> _progress = {}; // id → 0..1 while downloading
  final Set<String> _done = {};
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _search('');
    _player.playerStateStream.listen((s) {
      if (!mounted) return;
      if (s.processingState == ProcessingState.completed) {
        setState(() => _previewId = null);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _player.dispose();
    _q.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () => _search(v));
  }

  Future<void> _search(String q) async {
    final my = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final token = await getToken();
      final base = await AppConfig.baseUrl;
      final r = await http.get(
        Uri.parse('$base/music/free/search?q=${Uri.encodeQueryComponent(q.trim())}'),
        headers: {if (token != null) 'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 25));
      if (my != _seq || !mounted) return;
      if (r.statusCode >= 400) throw Exception('http ${r.statusCode}');
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      final list = ((j['results'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      setState(() {
        _results = list;
        _loading = false;
      });
    } catch (_) {
      if (my != _seq || !mounted) return;
      setState(() {
        _loading = false;
        _error = "Couldn't search right now — check your internet and try again.";
      });
    }
  }

  Future<void> _togglePreview(Map<String, dynamic> t) async {
    final id = t['id'].toString();
    if (_previewId == id) {
      await _player.pause();
      setState(() => _previewId = null);
      return;
    }
    playbackBus.onPause?.call(); // don't play over the main player
    setState(() {
      _previewId = id;
      _previewLoading = true;
    });
    try {
      await _player.setUrl(t['stream_url'].toString());
      if (!mounted || _previewId != id) return;
      unawaited(_player.play()); // completes at track end — never await
    } catch (_) {
      if (mounted) {
        showToast(context, "Couldn't play this preview", type: ToastType.error);
        setState(() => _previewId = null);
      }
    } finally {
      if (mounted) setState(() => _previewLoading = false);
    }
  }

  static String _safe(String s) => s
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Future<Directory> _desktopDir() async {
    if (!kIsWeb && Platform.isWindows) {
      final home = Platform.environment['USERPROFILE'];
      if (home != null) {
        final d = Directory('$home\\Music\\Aluta');
        if (!await d.exists()) await d.create(recursive: true);
        return d;
      }
    }
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}${Platform.pathSeparator}Aluta Music');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<void> _download(Map<String, dynamic> t) async {
    final id = t['id'].toString();
    if (_progress.containsKey(id) || _done.contains(id)) return;
    if (kIsWeb) {
      showToast(context,
          'Downloading songs works in the Aluta app on your phone or computer',
          type: ToastType.info);
      return;
    }
    final title = (t['title'] ?? '').toString().trim();
    final artist = (t['artist'] ?? '').toString().trim();
    final name = _safe(artist.isEmpty ? title : '$artist - $title');
    final fileName = '${name.isEmpty ? 'Free song' : name}.mp3';
    setState(() => _progress[id] = 0);
    final client = http.Client();
    try {
      final res = await client
          .send(http.Request('GET', Uri.parse(t['download_url'].toString())))
          .timeout(const Duration(seconds: 30));
      if (res.statusCode >= 400) throw Exception('http ${res.statusCode}');
      final total = res.contentLength ?? 0;
      final tmp = await getTemporaryDirectory();
      final part = File(
          '${tmp.path}${Platform.pathSeparator}free_${DateTime.now().millisecondsSinceEpoch}.mp3');
      final sink = part.openWrite();
      var got = 0;
      await for (final chunk
          in res.stream.timeout(const Duration(seconds: 30))) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0 && mounted) {
          setState(() => _progress[id] = got / total);
        }
      }
      await sink.close();
      String? path;
      if (Platform.isAndroid) {
        try {
          path = await const MethodChannel('aluta/downloads').invokeMethod<String>(
              'saveToMusic', {'srcPath': part.path, 'fileName': fileName});
        } catch (_) {}
      }
      if (path == null) {
        final dir = await _desktopDir();
        var dest = File('${dir.path}${Platform.pathSeparator}$fileName');
        var n = 1;
        while (await dest.exists()) {
          dest = File('${dir.path}${Platform.pathSeparator}$name ($n).mp3');
          n++;
        }
        await part.copy(dest.path);
        path = dest.path;
      }
      try {
        await part.delete();
      } catch (_) {}
      await metadataStore.set(
          path, TrackMeta(title: title.isEmpty ? null : title,
              artist: artist.isEmpty ? null : artist));
      freeMusicInbox.value = [path];
      if (!mounted) return;
      HapticFeedback.lightImpact();
      setState(() {
        _progress.remove(id);
        _done.add(id);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _progress.remove(id));
      showToast(context, "Couldn't download that song", type: ToastType.error);
    } finally {
      client.close();
    }
  }

  Future<void> _openPage(Map<String, dynamic> t) async {
    final u = (t['page_url'] ?? t['license_url'])?.toString();
    if (u == null || u.isEmpty) return;
    await launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
  }

  static String _dur(int s) =>
      s <= 0 ? '' : '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header — same bar as the playlist page.
        Container(
          padding: const EdgeInsets.fromLTRB(6, 8, 10, 8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withAlpha(120),
            border: Border(
                bottom:
                    BorderSide(color: scheme.outlineVariant.withAlpha(80))),
          ),
          child: Row(children: [
            AlutaTapChip(
              icon: Icons.arrow_back_rounded,
              tooltip: 'Back to playlist',
              onTap: widget.onBack,
            ),
            const SizedBox(width: 6),
            Icon(Icons.travel_explore_rounded, color: scheme.primary, size: 18),
            const SizedBox(width: 6),
            const Flexible(
              child: Text('Free music',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            ),
            if (_results.isNotEmpty) ...[
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                decoration: BoxDecoration(
                  color: scheme.primary.withAlpha(30),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text('${_results.length}',
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        color: scheme.primary)),
              ),
            ],
            const Spacer(),
            Tooltip(
              message: 'Creative Commons & public domain only',
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF2BB673).withAlpha(30),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text('LEGAL',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.6,
                        color: Color(0xFF2BB673))),
              ),
            ),
          ]),
        ),
        // Search — same field style as "Search tracks…".
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
          child: TextField(
            controller: _q,
            onChanged: _onChanged,
            onSubmitted: _search,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search free songs, artists, genres…',
              prefixIcon: const Icon(Icons.search, size: 18),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              filled: true,
              fillColor: scheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
          child: Text(
            'Songs artists chose to share for free — yours to keep, legally.',
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(child: _body(scheme)),
      ],
    );
  }

  Widget _body(ColorScheme scheme) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 10),
            OutlinedButton(
                onPressed: () => _search(_q.text), child: const Text('Retry')),
          ]),
        ),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _loading
                ? 'Searching…'
                : _q.text.trim().isEmpty
                    ? 'Search for a song, an artist or a mood to start'
                    : 'No free songs found for that — try other words',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 12),
      itemCount: _results.length,
      itemBuilder: (_, i) {
        final t = _results[i];
        final id = t['id'].toString();
        final playing = _previewId == id;
        final prog = _progress[id];
        final done = _done.contains(id);
        final cover = (t['cover'] ?? '').toString();
        final artist = (t['artist'] ?? '').toString();
        final dur = _dur((t['duration'] as num?)?.toInt() ?? 0);
        return ListTile(
          dense: true,
          visualDensity: const VisualDensity(vertical: -1),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          selected: playing,
          selectedTileColor: scheme.primary.withAlpha(22),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10),
          leading: GestureDetector(
            onTap: () => _togglePreview(t),
            child: Stack(alignment: Alignment.center, children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: cover.isEmpty
                      ? ColoredBox(
                          color: scheme.primary.withValues(alpha: 0.15),
                          child: Icon(Icons.music_note_rounded,
                              color: scheme.primary))
                      : Image.network(cover,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => ColoredBox(
                              color: scheme.primary.withValues(alpha: 0.15),
                              child: Icon(Icons.music_note_rounded,
                                  color: scheme.primary))),
                ),
              ),
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: BoxShape.circle),
                child: playing && _previewLoading
                    ? const Padding(
                        padding: EdgeInsets.all(7),
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Icon(
                        playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 20),
              ),
            ]),
          ),
          title: Text((t['title'] ?? '').toString(),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: playing ? scheme.primary : null)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  [if (artist.isNotEmpty) artist, if (dur.isNotEmpty) dur]
                      .join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5, color: scheme.onSurfaceVariant)),
              InkWell(
                onTap: () => _openPage(t),
                child: Text(
                  '${t['license'] ?? 'Free licence'} · ${t['source'] ?? ''}',
                  style: TextStyle(
                      fontSize: 11,
                      color: scheme.primary,
                      decoration: TextDecoration.underline,
                      decorationColor: scheme.primary.withValues(alpha: 0.5)),
                ),
              ),
            ],
          ),
          trailing: done
              ? const Tooltip(
                  message: 'In your playlist',
                  child: Icon(Icons.check_circle_rounded,
                      color: Color(0xFF2BB673)))
              : prog != null
                  ? SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                          strokeWidth: 3, value: prog > 0 ? prog : null))
                  : IconButton(
                      tooltip: 'Download to my playlist',
                      icon: Icon(Icons.download_rounded, color: scheme.primary),
                      onPressed: () => _download(t),
                    ),
          onTap: () => _togglePreview(t),
        );
      },
    );
  }
}
