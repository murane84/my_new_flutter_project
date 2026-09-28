import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

/// The chat "attach" bottom sheet — a compact, content-hugging sheet with a
/// vibrant grid of share options and, on Android/iOS, a horizontally-scrolling
/// strip of the phone's most recent photos so sending a recent shot is one tap.
///
/// It keeps Aluta's own energetic look (gradient icon chips, brand accents)
/// and sizes itself to its content, so it never leaves a big empty void when
/// there are no recent photos to show.
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
      final recent = await albums.first.getAssetListPaged(page: 0, size: 40);
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
    final media = MediaQuery.of(context);
    // Content-hugging sheet: it grows to fit the grid (+ the photo strip on
    // mobile) and no more, so there is never an empty white void beneath it.
    return Container(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.82),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
                alpha: scheme.brightness == Brightness.dark ? 0.40 : 0.12),
            blurRadius: 24,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _title(scheme),
                _optionsGrid(scheme),
                if (widget.isMobile) _recentSection(scheme),
                const SizedBox(height: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _title(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'Share',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
            color: scheme.onSurface,
          ),
        ),
      ),
    );
  }

  Widget _optionsGrid(ColorScheme scheme) {
    final options = <_Opt>[
      _Opt(Icons.photo_library_rounded, 'Gallery', const Color(0xFF7C4DFF),
          widget.onGallery),
      _Opt(Icons.photo_camera_rounded, 'Camera', const Color(0xFFEC407A),
          widget.onCamera),
      _Opt(Icons.location_on_rounded, 'Location', const Color(0xFF26A69A),
          widget.onLocation),
      _Opt(Icons.person_rounded, 'Contact', const Color(0xFF42A5F5),
          widget.onContact),
      _Opt(Icons.insert_drive_file_rounded, 'Document', const Color(0xFF3D5AFE),
          widget.onDocument),
      _Opt(Icons.headphones_rounded, 'Listen together', scheme.primary,
          widget.onListenTogether),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
      child: LayoutBuilder(
        builder: (context, c) {
          // Keep tiles compact at any width: target ~86px cells, 4-per-row on a
          // phone, more columns on wide screens. The aspect ratio is derived
          // from the real content height so cells never grow tall and leave
          // gaps between the rows.
          const target = 86.0;
          const contentH = 82.0;
          final cols = (c.maxWidth / target).floor().clamp(4, 8);
          final cellW = c.maxWidth / cols;
          final aspect = cellW / contentH;
          return GridView.count(
            crossAxisCount: cols,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 4,
            crossAxisSpacing: 0,
            childAspectRatio: aspect,
            children: [for (final o in options) _tile(scheme, o)],
          );
        },
      ),
    );
  }

  Widget _tile(ColorScheme scheme, _Opt o) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: o.onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // Glossy, top-lit gradient fill + a soft colored glow gives each
              // action a lively, tactile feel instead of a flat pale disc.
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.lerp(o.color, Colors.white, 0.26)!,
                  o.color,
                  Color.lerp(o.color, Colors.black, 0.10)!,
                ],
                stops: const [0.0, 0.55, 1.0],
              ),
              boxShadow: [
                BoxShadow(
                  color: o.color.withValues(alpha: 0.38),
                  blurRadius: 12,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Icon(o.icon, color: Colors.white, size: 25),
          ),
          const SizedBox(height: 7),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              o.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.0,
                color: scheme.onSurface.withAlpha(210),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Recent photos strip (mobile) ─────────────────────────────────────────
  Widget _recentSection(ColorScheme scheme) {
    if (_photoDenied) return _allowChip(scheme);
    if (_loadingPhotos) {
      return Column(
        children: [
          _stripHeader(scheme, showAction: false),
          _shimmerStrip(scheme),
        ],
      );
    }
    if (_recent.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        _stripHeader(scheme, showAction: true),
        _photoStrip(scheme),
      ],
    );
  }

  Widget _stripHeader(ColorScheme scheme, {required bool showAction}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 8, 14, 8),
      child: Row(
        children: [
          Icon(Icons.image_rounded, size: 16, color: scheme.primary),
          const SizedBox(width: 7),
          Text(
            'Recent',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface.withAlpha(210),
            ),
          ),
          const Spacer(),
          if (showAction)
            TextButton(
              onPressed: widget.onGallery,
              style: TextButton.styleFrom(
                foregroundColor: scheme.primary,
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Gallery',
                      style: TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w600)),
                  SizedBox(width: 2),
                  Icon(Icons.chevron_right_rounded, size: 18),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _photoStrip(ColorScheme scheme) {
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _recent.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) => _photoThumb(scheme, _recent[i]),
      ),
    );
  }

  Widget _photoThumb(ColorScheme scheme, AssetEntity asset) {
    return GestureDetector(
      onTap: () => _sendAsset(asset),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 96,
          height: 96,
          child: FutureBuilder<Uint8List?>(
            future:
                asset.thumbnailDataWithSize(const ThumbnailSize.square(240)),
            builder: (context, snap) {
              final data = snap.data;
              if (data == null) {
                return Container(color: scheme.surfaceContainerHighest);
              }
              return Image.memory(data, fit: BoxFit.cover);
            },
          ),
        ),
      ),
    );
  }

  Widget _shimmerStrip(ColorScheme scheme) {
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 5,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, _) => Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }

  Widget _allowChip(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 10),
      child: Material(
        color: scheme.primary.withAlpha(22),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => PhotoManager.openSetting(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(Icons.photo_library_rounded,
                    size: 20, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Allow photo access to quickly send recent pictures',
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.25,
                      color: scheme.onSurface.withAlpha(200),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Allow',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Opt {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _Opt(this.icon, this.label, this.color, this.onTap);
}
