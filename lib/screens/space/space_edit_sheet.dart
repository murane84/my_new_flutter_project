part of '../relationship_space_page.dart';

// Split out of relationship_space_page.dart (pure code movement, no behaviour
// change): edit-space sheet + wallpaper picker. A library `part`, so it shares the page's imports and
// private members.

// ── edit sheet (name + theme) ─────────────────────────────────────────────
class _EditSpaceSheet extends StatefulWidget {
  final String initialName;
  final String initialTheme;
  final bool initialPrimary;
  final int spaceId;
  final String? initialBackgroundUrl;
  final String apiBase;
  final void Function(Map<String, dynamic>)? onSpaceUpdated;
  // Whether the bond has earned the "In tune" shared theme (§5.7) — adds its
  // swatch to the palette.
  final bool inTuneUnlocked;
  const _EditSpaceSheet({
    super.key,
    required this.initialName,
    required this.initialTheme,
    required this.initialPrimary,
    required this.spaceId,
    this.initialBackgroundUrl,
    required this.apiBase,
    this.onSpaceUpdated,
    this.inTuneUnlocked = false,
    this.onDone,
    this.onPreviewTheme,
  });

  /// Live preview: called as you tap a theme, so the whole page can wear it.
  final ValueChanged<String?>? onPreviewTheme;

  /// Embedded mode (inside Our Space, under the pinned hero): no page chrome,
  /// a responsive layout, and the result ('saved' / 'unpin' / null) comes
  /// back here instead of popping a route.
  final ValueChanged<String?>? onDone;

  @override
  State<_EditSpaceSheet> createState() => _EditSpaceSheetState();
}

class _EditSpaceSheetState extends State<_EditSpaceSheet> {
  late final TextEditingController _c =
      TextEditingController(text: widget.initialName);
  late String _theme = widget.initialTheme;
  late bool _primary = widget.initialPrimary;
  late String? _bgUrl = widget.initialBackgroundUrl;
  // Remember the last wallpaper and the last device photo separately, so each
  // background tile keeps its own preview and the user can flip between them
  // without the other tile going blank.
  late String? _lastGalleryUrl =
      (widget.initialBackgroundUrl ?? '').startsWith('/wallpapers/')
          ? widget.initialBackgroundUrl
          : null;
  late final String? _lastPhotoUrl =
      (widget.initialBackgroundUrl ?? '').startsWith('/attachments/')
          ? widget.initialBackgroundUrl
          : null;
  bool _busy = false;
  // A background change previews LOCALLY and only applies to the whole Our
  // Space on Save. A freshly-picked photo is held as bytes until then.
  Uint8List? _pendingBytes;
  String? _pendingName;
  String? _pendingMime;
  bool _bgDirty = false;

  /// Anything changed since the page opened? Save only lights up then.
  bool get _dirty =>
      _bgDirty ||
      _c.text.trim() != widget.initialName.trim() ||
      _theme != widget.initialTheme ||
      _primary != widget.initialPrimary;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onNameChanged); // so Save wakes as you type
  }

  void _onNameChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _pickPhoto() async {
    FilePickerResult? res;
    try {
      res = await FilePicker.pickFiles(type: FileType.image);
    } catch (_) {
      return;
    }
    if (res == null || res.files.isEmpty) return;
    final f = res.files.single;
    final bytes = await f.readAsBytes();
    if (bytes.isEmpty || !mounted) return;
    final name = f.name;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : 'jpg';
    final mime = ext == 'png'
        ? 'image/png'
        : ext == 'webp'
            ? 'image/webp'
            : ext == 'gif'
                ? 'image/gif'
                : 'image/jpeg';
    // Preview only — the photo is uploaded on Save.
    setState(() {
      _pendingBytes = bytes;
      _pendingName = name;
      _pendingMime = mime;
      _bgUrl = '__pending_photo__';
      _bgDirty = true;
    });
  }

  void _selectDefault() {
    setState(() {
      _bgUrl = null;
      _pendingBytes = null;
      _bgDirty = true;
    });
  }

  Future<void> _openSpaceGallery() async {
    final presets = await WallpapersService.instance.load();
    if (!mounted) return;
    final accent = spaceThemeColor(_theme);
    final selFull = (_bgUrl ?? '').startsWith('/wallpapers/')
        ? resolveAvatarUrl(_bgUrl, widget.apiBase)
        : null;
    // Full-screen sub-page: the header stays put while the grid scrolls, and
    // tapping a wallpaper pops straight back to Settings with the pick.
    final pickedId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => _WallpaperPickerPage(
          presets: presets,
          apiBase: widget.apiBase,
          accent: accent,
          selectedFullUrl: selFull,
        ),
      ),
    );
    if (!mounted || pickedId == null) return;
    if (pickedId == '__upload__') {
      await _pickPhoto();
      return;
    }
    _selectPreset(pickedId);
  }

  void _selectPreset(String id) {
    setState(() {
      _bgUrl = '/wallpapers/$id';
      _lastGalleryUrl = _bgUrl;
      _pendingBytes = null;
      _bgDirty = true;
    });
  }

  /// Instantly re-apply the last-used gallery wallpaper (a preset — allowed by
  /// the server without a re-upload). Falls back to opening the picker.
  void _selectLastGallery() {
    final url = _lastGalleryUrl;
    if (url == null || !url.startsWith('/wallpapers/')) {
      _openSpaceGallery();
      return;
    }
    setState(() {
      _bgUrl = url;
      _pendingBytes = null;
      _bgDirty = true;
    });
  }

  Widget _bgOption(ColorScheme scheme,
      {required bool selected,
      required VoidCallback? onTap,
      required IconData icon,
      Widget? thumbnail,
      bool dim = false,
      required String label}) {
    final accent = spaceThemeColor(_theme);
    return Expanded(
      child: Column(
        children: [
          SizedBox(
            height: 92,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: onTap,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: selected
                          ? accent
                          : scheme.outlineVariant.withValues(alpha: 0.7),
                      width: selected ? 2.5 : 1.2,
                    ),
                    boxShadow: selected
                        ? [
                            BoxShadow(
                              color: accent.withValues(alpha: 0.22),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ]
                        : null,
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (thumbnail != null)
                        thumbnail
                      else
                        Center(
                          child: Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.14),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(icon, size: 21, color: accent),
                          ),
                        ),
                      // Inactive preview: soften it and show the type icon, so
                      // it clearly invites a tap to switch back / change.
                      if (thumbnail != null && dim) ...[
                        Container(color: Colors.black.withValues(alpha: 0.28)),
                        Center(
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.35),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(icon, size: 18, color: readableOn(accent)),
                          ),
                        ),
                      ],
                      if (selected)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                                color: accent, shape: BoxShape.circle),
                            child: Icon(Icons.check_rounded,
                                size: 13, color: readableOn(accent)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: selected ? accent : scheme.onSurface)),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _c.removeListener(_onNameChanged);
    _c.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    // Apply the previewed background choice now — this is what makes it take
    // effect on the whole Our Space page for this bond.
    Map<String, dynamic>? bgUpdated;
    if (_bgDirty) {
      if (_pendingBytes != null) {
        bgUpdated = await ApiService().uploadSpaceBackground(
          widget.spaceId,
          _pendingBytes!,
          filename: _pendingName ?? 'background.jpg',
          mime: _pendingMime ?? 'image/jpeg',
        );
      } else if ((_bgUrl ?? '').startsWith('/wallpapers/')) {
        bgUpdated = await ApiService()
            .updateSpace(widget.spaceId, backgroundUrl: _bgUrl);
      } else if ((_bgUrl ?? '').isEmpty) {
        bgUpdated = await ApiService().clearSpaceBackground(widget.spaceId);
      }
      if (!mounted) return;
    }
    final ok = await ApiService().updateSpace(
      widget.spaceId,
      name: _c.text.trim(),
      theme: _theme,
      // Only ever promote to hero here (never demote to headless).
      isPrimary: (_primary && !widget.initialPrimary) ? true : null,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    final updated = ok ?? bgUpdated;
    if (updated != null) widget.onSpaceUpdated?.call(updated);
    _finish((ok != null || bgUpdated != null) ? 'saved' : null);
  }

  void _finish(String? result) {
    final done = widget.onDone;
    if (done != null) {
      done(result);
    } else {
      Navigator.pop(context, result);
    }
  }

  Widget _label(ColorScheme scheme, String t) => Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Text(t,
            style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
                color: scheme.onSurfaceVariant)),
      );

  // An OPAQUE card colour so sections sit cleanly over the wallpaper backdrop
  // (no translucent bleed). Slightly lifted in dark mode.
  Color _cardColor(ColorScheme scheme) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return dark
        ? Color.alphaBlend(Colors.white.withValues(alpha: 0.06), scheme.surface)
        : scheme.surface;
  }

  // A modern grouped section: opaque fill, hairline border, soft shadow.
  Widget _card(ColorScheme scheme, Widget child, {EdgeInsetsGeometry? padding}) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardColor(scheme),
        borderRadius: BorderRadius.circular(18),
        border:
            Border.all(color: scheme.outlineVariant.withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: child,
    );
  }

  /// A theme swatch with a clean COLOURED halo (outer ring in the swatch's own
  /// colour + a white gap) when picked — softer and more premium than the old
  /// hard black ring, and it grows a touch so the choice is unmistakable.
  Widget _swatch(MapEntry<String, Color> entry, {double size = 38}) {
    final sel = _theme == entry.key;
    return GestureDetector(
      onTap: () {
        setState(() => _theme = entry.key);
        widget.onPreviewTheme?.call(entry.key);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        padding: EdgeInsets.all(sel ? 3 : 0),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
              color: sel ? entry.value : Colors.transparent, width: 2),
        ),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: entry.value,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: sel ? 2 : 0),
            boxShadow: [
              BoxShadow(
                color: entry.value.withValues(alpha: sel ? 0.45 : 0.25),
                blurRadius: sel ? 10 : 5,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: sel
              ? Icon(Icons.check_rounded,
                  color: readableOn(entry.value), size: 20)
              : null,
        ),
      ),
    );
  }

  /// The settings page wears the CURRENT background choice live — the chosen
  /// wallpaper (or the theme colour's wash when on "Default") — with a veil so
  /// the form stays readable, so you can see your pick take effect right here.
  Widget _settingsBackdrop(ColorScheme scheme, Color accent) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final url = (_bgUrl ?? '').trim();
    final isPhotoUrl = url.startsWith('/wallpapers/') ||
        url.startsWith('/attachments/') ||
        url.startsWith('http');
    ImageProvider? provider;
    if (_pendingBytes != null) {
      provider = MemoryImage(_pendingBytes!);
    } else if (isPhotoUrl) {
      final full = resolveAvatarUrl(url, widget.apiBase) ?? url;
      provider = authNetworkImageProvider(full, mediaAuthHeaders(full));
    }
    if (provider != null) {
      final veil = isDark ? Colors.black : Colors.white;
      return Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: scheme.surface),
          DecoratedBox(
            decoration: BoxDecoration(
              image: DecorationImage(
                image: provider,
                fit: BoxFit.cover,
                onError: (Object e, StackTrace? st) {},
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  veil.withValues(alpha: isDark ? 0.52 : 0.64),
                  veil.withValues(alpha: isDark ? 0.44 : 0.54),
                ],
              ),
            ),
          ),
        ],
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: scheme.surface),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                accent.withValues(alpha: 0.12),
                accent.withValues(alpha: 0.0),
                accent.withValues(alpha: 0.08),
              ],
              stops: const [0.0, 0.5, 1.0],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    // The settings preview the CHOSEN theme live: the picked swatch, the Save
    // button and the Hero switch all adopt this colour as you tap around.
    final accent = spaceThemeColor(_theme);

    final nameCard = _card(scheme, Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
          _label(scheme, 'NAME'),
          TextField(
            controller: _c,
            decoration: InputDecoration(
              hintText: 'What do you call this bond?',
              filled: true,
              fillColor: scheme.surfaceContainerHighest,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: accent, width: 1.6),
              ),
            ),
          ),
            ],
          ));
    final themeCard = _card(scheme, Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
          _label(scheme, 'THEME'),
          // Aluta's shared palette — the same families and order as the app
          // accent and bubble pickers. The earned shared theme leads once the
          // bond unlocks it (7-day streak), or if it's already selected.
          AlutaPaletteGrid(
            leading: [
              if (widget.inTuneUnlocked || _theme == 'in_tune')
                const AlutaFamily('Earned', [
                  AlutaSwatch('in_tune', 'In tune', kInTuneAccent),
                ]),
            ],
            dot: (s, size, _) => Tooltip(
              message: s.name,
              waitDuration: const Duration(milliseconds: 500),
              child: _swatch(MapEntry(s.key, s.color), size: size),
            ),
          ),
            ],
          ));
    final bgCard = _card(scheme, Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
          Row(
            children: [
              _label(scheme, 'BACKGROUND'),
              if (_busy) ...[
                const SizedBox(width: 8),
                const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ],
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _bgOption(
                scheme,
                selected: (_bgUrl ?? '').isEmpty,
                onTap: _busy ? null : _selectDefault,
                label: 'Default',
                icon: Icons.auto_awesome_rounded,
              ),
              const SizedBox(width: 12),
              _bgOption(
                scheme,
                selected: (_bgUrl ?? '').startsWith('/wallpapers/'),
                // Tap re-applies the last wallpaper instantly; tap again while
                // active (or when none is remembered yet) opens the picker.
                onTap: _busy
                    ? null
                    : () {
                        if ((_bgUrl ?? '').startsWith('/wallpapers/') ||
                            _lastGalleryUrl == null) {
                          _openSpaceGallery();
                        } else {
                          _selectLastGallery();
                        }
                      },
                label: 'Gallery',
                icon: Icons.collections_rounded,
                thumbnail: (_lastGalleryUrl ?? '').isNotEmpty
                    ? WallpaperThumb(
                        resolveAvatarUrl(_lastGalleryUrl, widget.apiBase) ?? '')
                    : null,
                dim: !(_bgUrl ?? '').startsWith('/wallpapers/'),
              ),
              const SizedBox(width: 12),
              _bgOption(
                scheme,
                selected: _bgUrl == '__pending_photo__' ||
                    (_bgUrl ?? '').startsWith('/attachments/'),
                onTap: _busy ? null : _pickPhoto,
                label: 'Your photo',
                icon: Icons.add_photo_alternate_outlined,
                thumbnail: _pendingBytes != null
                    ? Image.memory(_pendingBytes!, fit: BoxFit.cover)
                    : ((_lastPhotoUrl ?? '').isNotEmpty
                        ? authNetworkImage(
                            url: resolveAvatarUrl(
                                    _lastPhotoUrl, widget.apiBase) ??
                                '',
                            headers: mediaAuthHeaders(resolveAvatarUrl(
                                    _lastPhotoUrl, widget.apiBase) ??
                                ''),
                            fit: BoxFit.cover,
                          )
                        : null),
                dim: !(_bgUrl == '__pending_photo__' ||
                    (_bgUrl ?? '').startsWith('/attachments/')),
              ),
            ],
          ),
            ],
          ));
    final heroCard = _card(
            scheme,
            Row(
              children: [
                Icon(Icons.workspace_premium_rounded, size: 20, color: accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Hero Space',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface)),
                      const SizedBox(height: 2),
                      Text(
                        widget.initialPrimary
                            ? 'This bond leads your list'
                            : 'Show this bond at the top of your list',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (widget.initialPrimary)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_rounded, size: 14, color: accent),
                        const SizedBox(width: 4),
                        Text('Leading',
                            style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                                color: accent)),
                      ],
                    ),
                  )
                else
                  Switch(
                    value: _primary,
                    activeThumbColor: Colors.white,
                    activeTrackColor: accent,
                    onChanged: (v) => setState(() => _primary = v),
                  ),
              ],
            ),
          );
    final saveBtn = SizedBox(
            width: double.infinity,
            child: FilledButton(
              // Quiet until something changes, then the bright accent.
              onPressed: (_busy || !_dirty) ? null : _save,
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: readableOn(accent),
                disabledBackgroundColor: _busy
                    ? accent.withValues(alpha: 0.7)
                    : accent.withValues(alpha: 0.18),
                disabledForegroundColor: _busy
                    ? Colors.white
                    : scheme.onSurfaceVariant.withValues(alpha: 0.7),
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: _busy
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: readableOn(accent)))
                  : const Text('Save',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          );
    final unpinCard = Material(
            color: _cardColor(scheme),
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: _busy ? null : () => _finish('unpin'),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                decoration: BoxDecoration(
                  color: scheme.error.withValues(alpha: 0.055),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: scheme.error.withValues(alpha: 0.28)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.link_off_rounded,
                        size: 20, color: scheme.error),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Unpin this Space',
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: scheme.error)),
                          const SizedBox(height: 2),
                          Text(
                            'Removes the profile & pinned moments. Your chats stay.',
                            style: TextStyle(
                                fontSize: 11.5,
                                color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );

    if (widget.onDone != null) {
      return _embedded(scheme, accent,
          nameCard: nameCard,
          themeCard: themeCard,
          bgCard: bgCard,
          heroCard: heroCard,
          saveBtn: saveBtn,
          unpinCard: unpinCard);
    }

    return Stack(
      children: [
        Positioned.fill(child: _settingsBackdrop(scheme, accent)),
        Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            titleSpacing: 0,
            title: _titleRow(scheme, accent),
          ),
          body: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + bottom),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    nameCard,
                    const SizedBox(height: 14),
                    themeCard,
                    const SizedBox(height: 14),
                    bgCard,
                    const SizedBox(height: 14),
                    heroCard,
                    const SizedBox(height: 20),
                    saveBtn,
                    const SizedBox(height: 16),
                    unpinCard,
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _titleRow(ColorScheme scheme, Color accent) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.tune_rounded, size: 18, color: accent),
          ),
          const SizedBox(width: 10),
          Text('Settings',
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  color: scheme.onSurface)),
        ],
      );

  /// Inside Our Space, right under the pinned hero: a slim bar (back · title
  /// · Save), then the cards — two balanced columns on wide screens (name,
  /// background, hero and unpin beside the theme palette), one column on
  /// phones. Only this area scrolls.
  Widget _embedded(
    ColorScheme scheme,
    Color accent, {
    required Widget nameCard,
    required Widget themeCard,
    required Widget bgCard,
    required Widget heroCard,
    required Widget saveBtn,
    required Widget unpinCard,
  }) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 860;
        final pad = wide ? 20.0 : 14.0;
        // The bar is its own solid, raised card (like the cards below), so
        // the wallpaper never shows through it.
        final bar = Padding(
          padding: EdgeInsets.fromLTRB(pad, 2, pad, 10),
          child: Container(
            padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
            decoration: BoxDecoration(
              color: _cardColor(scheme),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.35)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back to Our Space',
                  icon: Icon(Icons.arrow_back_rounded,
                      color: scheme.onSurface),
                  onPressed: _busy ? null : () => _finish(null),
                ),
                _titleRow(scheme, accent),
                const Spacer(),
                if (wide)
                  SizedBox(width: 150, child: saveBtn)
                else if (_dirty)
                  // Phones: a compact Save appears here once something
                  // changed (the full button also waits below).
                  TextButton(
                    onPressed: _busy ? null : _save,
                    style: TextButton.styleFrom(foregroundColor: accent),
                    child: const Text('Save',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
              ],
            ),
          ),
        );
        final Widget body;
        if (wide) {
          body = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 44,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    nameCard,
                    const SizedBox(height: 14),
                    bgCard,
                    const SizedBox(height: 14),
                    heroCard,
                    const SizedBox(height: 14),
                    unpinCard,
                  ],
                ),
              ),
              const SizedBox(width: 18),
              Expanded(flex: 56, child: themeCard),
            ],
          );
        } else {
          body = Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              nameCard,
              const SizedBox(height: 12),
              themeCard,
              const SizedBox(height: 12),
              bgCard,
              const SizedBox(height: 12),
              heroCard,
              const SizedBox(height: 16),
              saveBtn,
              const SizedBox(height: 14),
              unpinCard,
            ],
          );
        }
        return Column(
          children: [
            bar,
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(pad, 2, pad, 20 + bottom),
                child: body,
              ),
            ),
          ],
        );
      }),
    );
  }
}

/// Full-screen wallpaper picker (a sub-page of Space Settings). The header
/// stays pinned while the grid scrolls, a back arrow returns to Settings, and
/// tapping a wallpaper pops back with the chosen id so Settings can apply it.
class _WallpaperPickerPage extends StatelessWidget {
  final List<WallpaperPreset> presets;
  final String apiBase;
  final Color accent;
  final String? selectedFullUrl;
  const _WallpaperPickerPage({
    required this.presets,
    required this.apiBase,
    required this.accent,
    this.selectedFullUrl,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleSpacing: 0,
        title: Text('Choose a wallpaper',
            style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 18,
                color: scheme.onSurface)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
        child: WallpaperGalleryGrid(
          presets: presets,
          apiBase: apiBase,
          accent: accent,
          selectedFullUrl: selectedFullUrl,
          onPick: (pp) => Navigator.pop(context, pp.id),
        ),
      ),
      // Pinned footer: pick a photo from the device instead of a preset.
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(18, 6, 18, 12),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => Navigator.pop(context, '__upload__'),
            icon: const Icon(Icons.add_photo_alternate_rounded, size: 20),
            label: const Text('Upload a photo'),
            style: OutlinedButton.styleFrom(
              foregroundColor: accent,
              side: BorderSide(color: accent.withValues(alpha: 0.6)),
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
      ),
    );
  }
}
