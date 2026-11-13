import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps voice notes and recordings out of the playlist — they aren't songs.
///
/// File type alone can't tell (WhatsApp audio can be .mp3 / .m4a / .opus just
/// like real songs), so it goes by where a file came from and what it looks
/// like:
/// * always out: WhatsApp voice notes (PTT-… / "Voice Notes" folders),
///   recorder and call-recording folders, ringtones / notifications / alarms
///   (Android already marks those as "not music"), .amr / .3gp voice files;
/// * WhatsApp audio (AUD-…-WA…) can be a forwarded real song: it stays only
///   when it looks like music (an artist tag, or a long .mp3 / .flac / .wav);
/// * very short untagged clips (< 30 s) are out too.
///
/// The person has the final word: "Not a song" hides any file, "This is a
/// song" brings one back — both remembered. Nothing is ever deleted.
class SongFilter {
  SongFilter._();
  static final SongFilter instance = SongFilter._();

  static const _kHidden = 'song_filter_hidden_v1'; // "Not a song"
  static const _kKept = 'song_filter_kept_v1'; // "This is a song"
  static const _kAuto = 'song_filter_auto_v1'; // what the last scan hid

  final Set<String> _hidden = <String>{};
  final Set<String> _kept = <String>{};
  final Set<String> _auto = <String>{};
  bool _loaded = false;

  /// Everything hidden right now (auto + by hand, minus "this is a song").
  final ValueNotifier<List<String>> hiddenList =
      ValueNotifier<List<String>>(const []);

  /// Set by the music screen: put these paths (back) into the playlist.
  void Function(List<String> paths)? onBringBack;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      _hidden.addAll(p.getStringList(_kHidden) ?? const []);
      _kept.addAll(p.getStringList(_kKept) ?? const []);
      _auto.addAll(p.getStringList(_kAuto) ?? const []);
    } catch (_) {}
    _publish();
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_kHidden, _hidden.toList());
      await p.setStringList(_kKept, _kept.toList());
      await p.setStringList(_kAuto, _auto.toList());
    } catch (_) {}
  }

  void _publish() {
    final all = {..._auto, ..._hidden}..removeAll(_kept);
    final list = all.toList()..sort();
    hiddenList.value = List.unmodifiable(list);
  }

  /// Should this file stay out of the playlist? [info] = the MediaStore row
  /// (Android) when there is one — tags, duration and the "not music" flags.
  bool isHidden(String path, {Map<dynamic, dynamic>? info}) {
    if (_kept.contains(path)) return false;
    if (_hidden.contains(path)) return true;
    return looksLikeRecording(path, info: info);
  }

  /// Split a scanned list into songs and hidden (and remember what was hidden
  /// so the "N hidden · Show" line can list it).
  List<String> keepSongs(List<String> paths,
      {Map<String, Map<dynamic, dynamic>>? infos}) {
    final keep = <String>[];
    for (final p in paths) {
      if (isHidden(p, info: infos?[p])) {
        if (!_hidden.contains(p)) _auto.add(p);
      } else {
        keep.add(p);
      }
    }
    _publish();
    _save();
    return keep;
  }

  /// ⋮ → "Not a song".
  void hide(String path) {
    _kept.remove(path);
    _hidden.add(path);
    _publish();
    _save();
  }

  /// "This is a song" (from the hidden list) → back in the playlist.
  void bringBack(List<String> paths) {
    for (final p in paths) {
      _hidden.remove(p);
      _auto.remove(p);
      _kept.add(p);
    }
    _publish();
    _save();
    onBringBack?.call(paths);
  }

  // ── the rules ─────────────────────────────────────────────────────────────
  static final _ptt = RegExp(r'^ptt-\d{8}-wa\d+', caseSensitive: false);
  static final _aud = RegExp(r'^aud-\d{8}-wa\d+', caseSensitive: false);
  static final _recName = RegExp(
      r'^(rec|recording|voice|voice ?memo|record|call|callrec|call ?recording|'
      r'audio ?record(ing)?|sound ?record(ing)?)[\s_\-]*\d',
      caseSensitive: false);
  static const _recFolders = [
    '/whatsapp voice notes/',
    '/whatsapp business voice notes/',
    '/voice notes/',
    '/recordings/',
    '/call recordings/',
    '/callrecordings/',
    '/call/',
    '/voice recorder/',
    '/voicerecorder/',
    '/sound recorder/',
    '/soundrecorder/',
    '/recorder/',
    '/notifications/',
    '/ringtones/',
    '/alarms/',
    '/miui/sound_recorder/',
  ];

  static bool looksLikeRecording(String path, {Map<dynamic, dynamic>? info}) {
    final p = path.replaceAll('\\', '/').toLowerCase();
    final slash = p.lastIndexOf('/');
    final file = slash >= 0 ? p.substring(slash + 1) : p;
    final dot = file.lastIndexOf('.');
    final ext = dot > 0 ? file.substring(dot + 1) : '';
    final name = dot > 0 ? file.substring(0, dot) : file;

    bool flag(String k) {
      final v = info?[k];
      return v == true || v == 1 || v == '1' || v == 'true';
    }

    final artist = (info?['artist'] ?? '').toString().trim().toLowerCase();
    final hasArtist = artist.isNotEmpty &&
        artist != '<unknown>' &&
        artist != 'unknown' &&
        artist != 'unknown artist';
    final durRaw = info?['duration'];
    final durMs = durRaw is int ? durRaw : int.tryParse('${durRaw ?? ''}') ?? 0;

    // Android says it's a ringtone / alert / alarm.
    if (flag('is_ringtone') || flag('is_notification') || flag('is_alarm')) {
      return true;
    }
    if (_ptt.hasMatch(name)) return true; // WhatsApp voice note
    for (final f in _recFolders) {
      if (p.contains(f)) return true;
    }
    if (ext == 'amr' || ext == '3gp' || ext == '3ga') return true;
    if (_recName.hasMatch(name) && !hasArtist) return true;
    if (_aud.hasMatch(name) || ext == 'opus') {
      // WhatsApp audio / opus: a real song keeps its artist tag, or is a
      // long mp3 / flac / wav. Otherwise it's someone talking.
      if (hasArtist) return false;
      final musicExt = ext == 'mp3' || ext == 'flac' || ext == 'wav';
      return !(musicExt && durMs >= 120000);
    }
    // A very short untagged clip isn't a song (only when we know the length).
    if (durMs > 0 && durMs < 30000 && !hasArtist) return true;
    return false;
  }
}
