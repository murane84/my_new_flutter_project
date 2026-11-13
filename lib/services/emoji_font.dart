import 'package:flutter/foundation.dart';
import 'dart:io' show File, Platform;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../utils/app_config.dart';

/// Aluta's emoji on Windows: the same soft Noto set Android shows, instead
/// of Windows' own (Fluent) emoji — so a 😂 looks the same on every device.
///
/// The font (~10 MB) is NOT bundled (it would weigh down the Android APK and
/// the web build); the Windows app fetches it once from the Aluta server
/// (`/fonts/emoji.ttf`), keeps it in app support, and loads it at runtime.
/// Before switching to it a test emoji is drawn: if this PC can't draw the
/// font's colour bitmaps (blank glyphs), Aluta keeps Windows' emoji —
/// nothing ever goes missing. Android already is Noto; the web build's
/// renderer brings its own Noto emoji.
class EmojiFont {
  EmojiFont._();

  /// The family every theme text style falls back to for emoji.
  static const family = 'AlutaEmoji';
  static const _probeFamily = 'AlutaEmojiProbe';
  static const _file = 'aluta_emoji_v1.ttf';

  static bool get _wanted => !kIsWeb && Platform.isWindows;

  /// Fallback list for the theme (empty where it isn't used).
  static List<String> get fallback => _wanted ? const [family] : const [];

  /// Theme with the emoji fallback on every text style.
  static ThemeData applyTo(ThemeData t) {
    if (!_wanted) return t;
    return t.copyWith(
      textTheme: t.textTheme.apply(fontFamilyFallback: fallback),
      primaryTextTheme: t.primaryTextTheme.apply(fontFamilyFallback: fallback),
    );
  }

  static bool _started = false;

  /// Once, after the first frame: cached → load; else download, then load.
  static Future<void> init() async {
    if (!_wanted || _started) return;
    _started = true;
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}${Platform.pathSeparator}$_file');
      Uint8List? bytes;
      if (await f.exists() && await f.length() > 1000000) {
        bytes = await f.readAsBytes();
      } else {
        final base = await AppConfig.baseUrl;
        final r = await http
            .get(Uri.parse('$base/fonts/emoji.ttf'))
            .timeout(const Duration(minutes: 3));
        if (r.statusCode != 200 || r.bodyBytes.length < 1000000) return;
        bytes = r.bodyBytes;
        final tmp = File('${f.path}.part');
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(f.path);
      }
      // Test under a throw-away name first: only switch if it really draws.
      await (FontLoader(_probeFamily)
            ..addFont(Future.value(ByteData.sublistView(bytes))))
          .load();
      if (!await _draws()) return;
      await (FontLoader(family)
            ..addFont(Future.value(ByteData.sublistView(bytes))))
          .load();
      // (FontLoader tells the engine; text using the fallback re-lays out.)
    } catch (_) {
      // No network / odd file: Windows' own emoji stay. Next launch retries.
    }
  }

  /// Does a test emoji come out in colour with this font? (A font Windows
  /// can't draw gives an empty box, which we'd rather never show.)
  static Future<bool> _draws() async {
    try {
      const size = 48.0;
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      final tp = TextPainter(
        text: const TextSpan(
          text: '\u{1F600}',
          style: TextStyle(
              fontFamily: _probeFamily, fontSize: 40, height: 1),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset.zero);
      final img = await rec.endRecording().toImage(size.toInt(), size.toInt());
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      if (data == null) return false;
      var coloured = 0;
      for (var i = 0; i + 3 < data.lengthInBytes; i += 4) {
        final r = data.getUint8(i), g = data.getUint8(i + 1);
        final b = data.getUint8(i + 2), a = data.getUint8(i + 3);
        // The grinning face is mostly warm yellow.
        if (a > 200 && r > 180 && g > 120 && b < 120) coloured++;
      }
      return coloured > 120;
    } catch (_) {
      return false;
    }
  }
}
