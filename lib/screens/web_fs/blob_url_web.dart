// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:typed_data';

/// Wrap in-memory audio bytes as a browser object URL so just_audio_web can
/// play it via setUrl — which reliably swaps the audio element when the track
/// changes (unlike switching a StreamAudioSource, which can keep the old one).
String makeBlobUrl(Uint8List bytes, String contentType) {
  try {
    final blob = html.Blob(<dynamic>[bytes], contentType);
    return html.Url.createObjectUrlFromBlob(blob);
  } catch (_) {
    return '';
  }
}

void revokeBlobUrl(String url) {
  try {
    html.Url.revokeObjectUrl(url);
  } catch (_) {}
}
