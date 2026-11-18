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

/// Hand [bytes] to the browser as a download named [name] (the browser's
/// own Save / Downloads). False when the browser refused.
bool downloadBytes(Uint8List bytes, String name, String contentType) {
  final url = makeBlobUrl(bytes, contentType);
  if (url.isEmpty) return false;
  try {
    final a = html.AnchorElement(href: url)
      ..download = name
      ..style.display = 'none';
    html.document.body?.append(a);
    a.click();
    a.remove();
    // Give the browser time to start the download before letting go.
    Future<void>.delayed(const Duration(minutes: 1), () => revokeBlobUrl(url));
    return true;
  } catch (_) {
    revokeBlobUrl(url);
    return false;
  }
}

void revokeBlobUrl(String url) {
  try {
    html.Url.revokeObjectUrl(url);
  } catch (_) {}
}
