import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../utils/app_config.dart';
import '../utils/avatar_widget.dart';
import '../utils/file_bytes.dart';
import '../utils/toast_helper.dart';
import 'api_service.dart';
import 'chat_page.dart';

/// One shared image, loaded into memory (bytes read once via the platform-safe
/// [readFileBytes] helper, so this screen never touches dart:io directly and
/// stays web-compile-safe even though it only ever runs on Android/iOS).
class _SharedImage {
  _SharedImage(this.bytes, this.name, this.mime);
  final Uint8List bytes;
  final String name;
  final String mime;
}

/// Recipient picker shown when images are shared INTO Aluta from another app
/// (screenshot → Share → Aluta). Pick a contact and the image(s) are uploaded
/// and sent as chat messages, then that chat opens.
class ShareTargetScreen extends StatefulWidget {
  const ShareTargetScreen({super.key, required this.imagePaths});

  final List<String> imagePaths;

  @override
  State<ShareTargetScreen> createState() => _ShareTargetScreenState();
}

class _ShareTargetScreenState extends State<ShareTargetScreen> {
  final ApiService _api = ApiService();
  final TextEditingController _searchCtrl = TextEditingController();

  final List<_SharedImage> _images = [];
  List<Map<String, dynamic>> _friends = [];
  bool _loadingFriends = true;
  bool _sending = false;
  String _base = '';

  @override
  void initState() {
    super.initState();
    AppConfig.baseUrl.then((b) {
      if (mounted) setState(() => _base = b);
    });
    _loadImages();
    _loadFriends();
    _searchCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String _mimeFor(String path) {
    final p = path.toLowerCase();
    if (p.endsWith('.png')) return 'image/png';
    if (p.endsWith('.gif')) return 'image/gif';
    if (p.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  Future<void> _loadImages() async {
    for (final path in widget.imagePaths) {
      try {
        final bytes = await readFileBytes(path);
        if (bytes.isEmpty) continue;
        var name = path.split('/').last.split('\\').last;
        if (name.isEmpty) name = 'shared_image.jpg';
        _images.add(_SharedImage(
            Uint8List.fromList(bytes), name, _mimeFor(path)));
      } catch (_) {/* skip unreadable file */}
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadFriends() async {
    try {
      final f = await _api.getFriends();
      if (!mounted) return;
      setState(() {
        _friends = f;
        _loadingFriends = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingFriends = false);
    }
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return _friends;
    return _friends
        .where((f) =>
            (f['username'] as String? ?? '').toLowerCase().contains(q))
        .toList();
  }

  String? _avatarFull(dynamic rel) {
    final s = rel?.toString() ?? '';
    if (s.isEmpty) return null;
    return s.startsWith('http') ? s : '$_base$s';
  }

  Future<void> _sendTo(Map<String, dynamic> friend) async {
    if (_sending || _images.isEmpty) return;
    final fid = friend['id'];
    final friendId = fid is int ? fid : int.tryParse(fid.toString());
    if (friendId == null) return;

    setState(() => _sending = true);
    var okCount = 0;
    try {
      for (final img in _images) {
        try {
          final up = await _api.uploadMedia(
            bytes: img.bytes,
            filename: img.name,
            mime: img.mime,
          );
          if (up == null || up['url'] == null) continue;
          final sent = await _api.sendMessage(
            friendId,
            '',
            messageType: 'image',
            mediaUrl: up['url'] as String,
            mediaName: (up['name'] as String?) ?? img.name,
            mediaMime: (up['mime'] as String?) ?? img.mime,
            mediaSize: (up['size'] as num?)?.toInt(),
          );
          if (sent != null) okCount++;
        } catch (_) {/* skip this image, keep going */}
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
    if (!mounted) return;
    if (okCount == 0) {
      showToast(context, 'Couldn’t send. Try again.', type: ToastType.error);
      return;
    }
    // Open the recipient's chat so the sent image is visible.
    Navigator.of(context).pushReplacementNamed(
      ChatPage.routeName,
      arguments: {
        'friendId': friendId,
        'friendName': friend['username'] ?? 'Chat',
        'friendAvatar': (friend['avatar_url'] as String?) ?? '',
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = widget.imagePaths.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(count > 1 ? 'Share $count images to…' : 'Share to…'),
      ),
      body: Column(
        children: [
          _previewStrip(scheme),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Search contacts',
              ),
            ),
          ),
          if (_sending) const LinearProgressIndicator(minHeight: 3),
          Expanded(child: _friendList(scheme)),
        ],
      ),
    );
  }

  Widget _previewStrip(ColorScheme scheme) {
    return Container(
      height: 92,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      color: scheme.surfaceContainerHighest.withAlpha(60),
      child: _images.isEmpty
          ? Center(
              child: Text(
                'Preparing image…',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
            )
          : ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _images.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) => ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(
                  _images[i].bytes,
                  width: 72,
                  height: 72,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    width: 72,
                    height: 72,
                    color: scheme.surfaceContainerHighest,
                    child: const Icon(Icons.broken_image_rounded),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _friendList(ColorScheme scheme) {
    if (_loadingFriends) {
      return const Center(child: CircularProgressIndicator());
    }
    final list = _filtered;
    if (list.isEmpty) {
      return Center(
        child: Text('No contacts',
            style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (_, i) {
        final f = list[i];
        final name = f['username'] as String? ?? '';
        return ListTile(
          leading: InitialsAvatar(
            name: name,
            radius: 22,
            isOnline: f['is_online'] == true,
            imageUrl: _avatarFull(f['avatar_url']),
          ),
          title: Text(name),
          trailing: const Icon(Icons.send_rounded, size: 18),
          onTap: _sending ? null : () => _sendTo(f),
        );
      },
    );
  }
}
