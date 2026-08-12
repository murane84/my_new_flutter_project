import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

/// The chat "attach" bottom sheet — a friendly grid of share options with a
/// swipe-up quick-access strip of the phone's most recent photos beneath it
/// (Android/iOS only). Keeps Aluta's own look (rounded cards, brand accents)
/// rather than copying WhatsApp: the grid stays visible and the sheet drags up
/// to reveal more photos, so sending a recent shot is one tap.
///
/// All actions are callbacks the chat page wires to its existing senders, so
/// this widget stays presentation-only (no networking, no message model).
class AttachSheet extends StatefulWidget {
  const AttachSheet({
    super.key,
    required this.isMobile,
    required this.onGallery,
    required this.onCamera,
    required this.onLocation,
    required this.onContact,
    required this.onDocument,
    required this.onListenTogether,
    required this.onPickPhoto,
  });

  /// Only Android/iOS have a device gallery to show the quick strip for.
  final bool isMobile;

  final VoidCallback onGallery;
  final VoidCallback onCamera;
  final VoidCallback onLocation;
  final VoidCallback onContact;
  final VoidCallback onDocument;
  final VoidCallback onListenTogether;

  /// Send a photo tapped in the quick strip (bytes + a filename).
  final void Function(Uint8List bytes, String name) onPickPhoto;

  @override
  State<AttachSheet> createState() => _AttachSheetState();
}

class _AttachSheetState extends State<AttachSheet> {
  List<AssetEntity> _recent = const [];
  bool _loadingPhotos = false;
  bool _photoDenied = false;
  bool _busy = false; // guards double-taps while a photo resolves to bytes

  @override
  void initState() {
    super.initState();
    if (widget.isMobile) _loadRecentPhotos();
  }

  Future<void> _loadRecentPhotos() async {
    setState(() => _loadingPhotos = true);
    try {
      final ps = await PhotoManager.requestPermissionExtend();
      // isAuth = full access; hasAccess covers iOS "limited" / partial grants.
      if (!(ps.isAuth || ps.hasAccess)) {
        if (mounted) {
          setState(() {
            _photoDenied = true;
            _loadingPhotos = false;
          });
        }
        return;
      }
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        onlyAll: true,
      );
      if (albums.isEmpty) {
        if (mounted) setState(() => _loadingPhotos = false);
        return;
      }
      final recent =
          await albums.first.getAssetListPaged(page: 0, size: 60);
      if (mounted) {
        setState(() {
          _recent = recent;
          _loadingPhotos = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingPhotos = false);
    }
  }

  Future<void> _sendAsset(AssetEntity asset) async {
    if (_busy) return;
    _busy = true;
    try {
      final file = await asset.file;
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return;
      final name = (asset.title != null && asset.title!.isNotEmpty)
          ? asset.title!
          : 'photo_${asset.id}.jpg';
      widget.onPickPhoto(bytes, name);
    } catch (_) {
      // ignore — the chat page shows its own error toasts for real sends
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A short sheet by default (grid + a peek of photos); drag up for the full
    // recent-photos grid. On desktop/web there are no device photos, so keep it
    // compact.
    final hasStrip = widget.isMobile && (_recent.isNotEmpty || _loadingPhotos);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: hasStrip ? 0.56 : 0.34,
      minChildSize: 0.30,
      maxChildSize: 0.92,
      builder: (context, controller) {
        return Container(
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(22)),
          ),
          child: CustomScrollView(
            controller: controller,
            slivers: [
              SliverToBoxAdapter(child: _header(scheme)),
              SliverToBoxAdapter(child: _optionsGrid(scheme)),
              if (widget.isMobile) ...[
                SliverToBoxAdapter(child: _stripHeader(scheme)),
                _photoSliver(scheme),
                const SliverToBoxAdapter(child: SizedBox(height: 12)),
              ] else
                const SliverToBoxAdapter(child: SizedBox(height: 8)),
            ],
          ),
        );
      },
    );
  }

  Widget _header(ColorScheme scheme) {
    return Column(
      children: [
        Container(
          margin: const EdgeInsets.only(top: 10, bottom: 6),
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: scheme.onSurfaceVariant.withAlpha(80),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ],
    );
  }

  Widget _optionsGrid(ColorScheme scheme) {
    final tiles = <Widget>[
      _tile(scheme, Icons.photo_library_rounded, 'Gallery',
          const Color(0xFF7C4DFF), widget.onGallery),
      _tile(scheme, Icons.photo_camera_rounded, 'Camera',
          const Color(0xFFEC407A), widget.onCamera),
      _tile(scheme, Icons.location_on_rounded, 'Location',
          const Color(0xFF26A69A), widget.onLocation),
      _tile(scheme, Icons.person_rounded, 'Contact',
          const Color(0xFF42A5F5), widget.onContact),
      _tile(scheme, Icons.insert_drive_file_rounded, 'Document',
          const Color(0xFF3D5AFE), widget.onDocument),
      _tile(scheme, Icons.headphones_rounded, 'Listen together',
          scheme.primary, widget.onListenTogether),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      child: GridView.count(
        crossAxisCount: 4,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 6,
        crossAxisSpacing: 4,
        childAspectRatio: 0.82,
        children: tiles,
      ),
    );
  }

  Widget _tile(ColorScheme scheme, IconData icon, String label, Color color,
      VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: color.withAlpha(30),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 26),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stripHeader(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 6),
      child: Row(
        children: [
          Icon(Icons.image_rounded,
              size: 15, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            'Recent photos',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          if (_recent.isNotEmpty)
            Text(
              'Swipe up for more',
              style: TextStyle(
                  fontSize: 11, color: scheme.onSurfaceVariant.withAlpha(160)),
            ),
        ],
      ),
    );
  }

  Widget _photoSliver(ColorScheme scheme) {
    if (_loadingPhotos) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 26),
          child: Center(
              child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          )),
        ),
      );
    }
    if (_photoDenied) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Allow photo access to quickly send recent pictures.',
                  style: TextStyle(
                      fontSize: 12.5, color: scheme.onSurfaceVariant),
                ),
              ),
              TextButton(
                onPressed: () => PhotoManager.openSetting(),
                child: const Text('Allow'),
              ),
            ],
          ),
        ),
      );
    }
    if (_recent.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, i) => _photoThumb(scheme, _recent[i]),
          childCount: _recent.length,
        ),
      ),
    );
  }

  Widget _photoThumb(ColorScheme scheme, AssetEntity asset) {
    return GestureDetector(
      onTap: () => _sendAsset(asset),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: FutureBuilder<Uint8List?>(
          future: asset.thumbnailDataWithSize(const ThumbnailSize.square(220)),
          builder: (context, snap) {
            final data = snap.data;
            if (data == null) {
              return Container(color: scheme.surfaceContainerHighest);
            }
            return Image.memory(data, fit: BoxFit.cover);
          },
        ),
      ),
    );
  }
}
