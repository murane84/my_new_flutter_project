import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../screens/token_helper.dart' show mediaAuthHeaders;
import '../services/download_manager.dart';
import '../utils/net_image.dart';

/// An Our Space photo that lives on the PHONE too: the first time it's seen it
/// is quietly saved into the app's own storage (no permission needed), and from
/// then on it opens from there — instantly, offline, and even if the server's
/// copy is ever gone. Web just shows the server copy.
class KeepsakePhoto extends StatefulWidget {
  const KeepsakePhoto({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.cacheWidth,
  });

  final String url;
  final BoxFit fit;
  final int? cacheWidth;

  @override
  State<KeepsakePhoto> createState() => _KeepsakePhotoState();
}

class _KeepsakePhotoState extends State<KeepsakePhoto> {
  File? _local;

  static final RegExp _id = RegExp(r'/attachments/([0-9a-fA-F]{32})');
  static Directory? _dir;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant KeepsakePhoto old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _local = null;
      _resolve();
    }
  }

  static Future<Directory?> _keepDir() async {
    if (_dir != null) return _dir;
    try {
      final base = await getApplicationSupportDirectory();
      final d = Directory('${base.path}/keepsakes');
      if (!await d.exists()) await d.create(recursive: true);
      return _dir = d;
    } catch (_) {
      return null;
    }
  }

  Future<void> _resolve() async {
    if (kIsWeb) return;
    final id = _id.firstMatch(widget.url)?.group(1);
    if (id == null) return;
    final url = widget.url;
    final d = await _keepDir();
    if (d == null) return;
    final f = File('${d.path}/$id.img');
    try {
      if (await f.exists() && await f.length() > 0) {
        if (mounted && widget.url == url) setState(() => _local = f);
        return;
      }
      // Not on the phone yet → save it in the background (no notification).
      final res = await DownloadManager.instance.fetch(url, f,
          headers: mediaAuthHeaders(url), name: 'Keepsake', notify: false);
      if (res.ok && res.file != null && res.file!.path != f.path) {
        await res.file!.copy(f.path);
      }
      if (await f.exists() && await f.length() > 0 && mounted &&
          widget.url == url) {
        setState(() => _local = f);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final local = _local;
    if (local != null) {
      return Image.file(
        local,
        fit: widget.fit,
        cacheWidth: widget.cacheWidth,
        errorBuilder: (_, _, _) => _network(),
      );
    }
    return _network();
  }

  Widget _network() => authNetworkImage(
        url: widget.url,
        headers: mediaAuthHeaders(widget.url),
        fit: widget.fit,
        cacheWidth: widget.cacheWidth,
      );
}
