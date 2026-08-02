import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../models/base_track.dart';

class TrackShareHelper {
  /// Share track via OS (Android / Windows)
  static Future<void> shareTrack({
    required BuildContext context,
    required BaseTrack track,
  }) async {
    try {
      // 🔹 Machine-readable payload (USED ✅)
      final payload = jsonEncode(track.toJson());

      // 🔹 Human-readable text
      final prettyText = _humanReadable(track);

      // 🔹 Combined share message
      final shareText =
          '''
$prettyText

---TRACK_PAYLOAD---
$payload
'''
              .trim();

      await SharePlus.instance.share(ShareParams(text: shareText));

      if (!context.mounted) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Track shared')));
    } catch (e) {
      _showSnack(context, "Failed to share track", success: false);
    }
  }

  /// Convert track to user-friendly text
  static String _humanReadable(BaseTrack track) {
    final json = track.toJson();

    final title = json['title'] ?? 'Unknown';
    final artist = json['artist'] ?? 'Unknown';

    return '''
🎵 $title
👤 $artist
'''
        .trim();
  }

  static void _showSnack(
    BuildContext context,
    String message, {
    required bool success,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: success ? Colors.green : Colors.red,
      ),
    );
  }
}
