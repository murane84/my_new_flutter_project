import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import '../utils/readable.dart' show accentInk;
import 'edge_scroll_row.dart';

/// What the person chose in [showRecentPhotoPicker].
class PhotoPick {
  const PhotoPick.photo(this.bytes, this.name) : action = null;
  const PhotoPick.action(this.action)
      : bytes = null,
        name = null;

  /// A recent photo, already read (bytes + a filename).
  final Uint8List? bytes;
  final String? name;

  /// Or one of: 'camera', 'files', 'aluta', 'view'.
  final String? action;
}

bool get _hasDeviceGallery =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Telegram-style "Choose photo" sheet: slides up with the phone's most
/// recent pictures in a 3-column grid (first tile = camera), plus quick
/// chips for Aluta's own pictures, device files and viewing the current
/// photo. Drag it up for more of the grid. Desktop / web have no device
/// gallery, so they get just the chips.
Future<PhotoPick?> showRecentPhotoPicker(
  BuildContext context, {
  String title = 'Choose photo',
  bool canView = false,
  bool alutaPictures = true,
}) {
  return showModalBottomSheet<PhotoPick>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _RecentPhotoSheet(
        title: title, canView: canView, alutaPictures: alutaPictures),
  );
}

class _RecentPhotoSheet extends StatefulWidget {
  const _RecentPhotoSheet(
      {required this.title,
      required this.canView,
      required this.alutaPictures});
  final String title;
  final bool canView;
  final bool alutaPictures;

  @override
  State<_RecentPhotoSheet> createState() => _RecentPhotoSheetState();
}

class _RecentPhotoSheetState extends State<_RecentPhotoSheet> {
  static const _pageSize = 60;
  AssetPathEntity? _album;
  final List<AssetEntity> _photos = [];
  int _page = 0;
  bool _loading = _hasDeviceGallery;
  bool _more = true;
  bool _denied = false;
  String? _busyId; // the tile being read (guards double taps)
  bool _fetching = false;

  @override
  void initState() {
    super.initState();
    if (_hasDeviceGallery) _load();
  }

  Future<void> _load() async {
    try {
      final ps = await PhotoManager.requestPermissionExtend();
      if (!(ps.isAuth || ps.hasAccess)) {
        if (mounted) {
          setState(() {
            _denied = true;
            _loading = false;
          });
        }
        return;
      }
      final albums = await PhotoManager.getAssetPathList(
          type: RequestType.image, onlyAll: true);
      if (albums.isEmpty) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      _album = albums.first;
      await _nextPage();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _nextPage() async {
    final a = _album;
    if (a == null || !_more || _fetching) return;
    _fetching = true;
    final List<AssetEntity> got;
    try {
      got = await a.getAssetListPaged(page: _page, size: _pageSize);
    } catch (_) {
      _fetching = false;
      if (mounted) setState(() => _loading = false);
      return;
    }
    _fetching = false;
    if (!mounted) return;
    setState(() {
      _photos.addAll(got);
      _page++;
      _more = got.length == _pageSize;
      _loading = false;
    });
  }

  Future<void> _pick(AssetEntity a) async {
    if (_busyId != null) return;
    setState(() => _busyId = a.id);
    try {
      final file = await a.file;
      final bytes = await file?.readAsBytes();
      if (!mounted) return;
      if (bytes == null || bytes.isEmpty) {
        setState(() => _busyId = null);
        return;
      }
      final name = (a.title != null && a.title!.isNotEmpty)
          ? a.title!
          : 'photo_${a.id}.jpg';
      Navigator.pop(context, PhotoPick.photo(bytes, name));
    } catch (_) {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chips = <Widget>[
      if (widget.canView)
        _chip(scheme, Icons.zoom_out_map_rounded, 'View photo', 'view'),
      if (widget.alutaPictures)
        _chip(scheme, Icons.auto_awesome_rounded, 'Aluta pictures', 'aluta'),
      _chip(scheme, Icons.folder_open_rounded,
          _hasDeviceGallery ? 'Files' : 'Upload a photo', 'files'),
    ];

    final header = Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        margin: const EdgeInsets.only(top: 8, bottom: 6),
        width: 40,
        height: 4,
        decoration: BoxDecoration(
            color: scheme.outlineVariant,
            borderRadius: BorderRadius.circular(2)),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 8, 6),
        child: Row(children: [
          Expanded(
            child: Text(widget.title,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface)),
          ),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.pop(context),
          ),
        ]),
      ),
      SizedBox(
        height: 40,
        child: EdgeScrollRow(builder: (_, edgeCtrl) => ListView.separated(controller: edgeCtrl, 
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          itemCount: chips.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (_, i) => chips[i],
        )),
      ),
      const SizedBox(height: 10),
    ]);

    // Desktop / web: no device gallery — a short sheet of chips only.
    if (!_hasDeviceGallery) {
      return _card(scheme,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: header,
          ));
    }

    return DraggableScrollableSheet(
      initialChildSize: 0.62,
      minChildSize: 0.35,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scroll) => _card(
        scheme,
        child: Column(children: [
          header,
          Expanded(child: _grid(scheme, scroll)),
        ]),
      ),
    );
  }

  Widget _card(ColorScheme scheme, {required Widget child}) => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: child,
      );

  Widget _grid(ColorScheme scheme, ScrollController scroll) {
    if (_denied) {
      return ListView(controller: scroll, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
          child: Text('Allow photo access to pick from your recent pictures.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
        Center(
          child: FilledButton.icon(
            onPressed: () => PhotoManager.openSetting(),
            icon: const Icon(Icons.photo_library_rounded, size: 18),
            label: const Text('Allow access'),
          ),
        ),
        const SizedBox(height: 12),
        Center(child: _cameraButton(scheme)),
      ]);
    }
    final count = 1 + (_loading ? 11 : _photos.length);
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels > n.metrics.maxScrollExtent - 600) _nextPage();
        return false;
      },
      child: GridView.builder(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(2, 0, 2, 12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3, mainAxisSpacing: 2, crossAxisSpacing: 2),
        itemCount: count,
        itemBuilder: (_, i) {
          if (i == 0) return _cameraTile(scheme);
          if (_loading) {
            return ColoredBox(color: scheme.surfaceContainerHighest);
          }
          return _thumb(scheme, _photos[i - 1]);
        },
      ),
    );
  }

  Widget _cameraTile(ColorScheme scheme) {
    final a = scheme.primary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => Navigator.pop(context, const PhotoPick.action('camera')),
        child: Ink(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color.lerp(a, Colors.white, 0.15)!, Color.lerp(a, Colors.black, 0.3)!],
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.photo_camera_rounded,
                  size: 34, color: _onFill(a)),
              const SizedBox(height: 6),
              Text('Camera',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: _onFill(a))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cameraButton(ColorScheme scheme) => OutlinedButton.icon(
        onPressed: () => Navigator.pop(context, const PhotoPick.action('camera')),
        icon: const Icon(Icons.photo_camera_rounded, size: 18),
        label: const Text('Take a photo'),
      );

  Widget _thumb(ColorScheme scheme, AssetEntity a) {
    final busy = _busyId == a.id;
    return GestureDetector(
      onTap: () => _pick(a),
      child: Stack(fit: StackFit.expand, children: [
        FutureBuilder<Uint8List?>(
          future: a.thumbnailDataWithSize(const ThumbnailSize.square(240)),
          builder: (_, snap) {
            final d = snap.data;
            if (d == null) {
              return ColoredBox(color: scheme.surfaceContainerHighest);
            }
            return Image.memory(d, fit: BoxFit.cover, gaplessPlayback: true);
          },
        ),
        if (busy)
          const ColoredBox(
            color: Colors.black45,
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _chip(ColorScheme scheme, IconData icon, String label, String action) {
    return ActionChip(
      avatar: Icon(icon, size: 18, color: accentInk(scheme)),
      label: Text(label),
      labelStyle: TextStyle(
          fontWeight: FontWeight.w700, color: scheme.onSurface, fontSize: 13),
      shape: const StadiumBorder(),
      side: BorderSide(color: scheme.outlineVariant),
      backgroundColor: scheme.surfaceContainerHigh,
      onPressed: () => Navigator.pop(context, PhotoPick.action(action)),
    );
  }

  static Color _onFill(Color c) =>
      c.computeLuminance() > 0.5 ? const Color(0xFF111111) : Colors.white;
}
