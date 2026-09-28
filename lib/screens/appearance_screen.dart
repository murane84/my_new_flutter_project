import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'theme_provider.dart';
import '../utils/popup_shell.dart';
import '../utils/app_config.dart';
import '../utils/chat_background.dart';
import '../services/wallpapers_service.dart';
import '../widgets/wallpaper_gallery.dart';
import 'api_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The personalization surface (build step 5): whole-app **theme** (System /
/// Light / Dark) + a curated **accent** preset set. Dark stays the brand's
/// default identity; personalization layers on top with presets only — never a
/// raw colour wheel — so it can't fragment the brand. Per-Space colour is set
/// inside each Our Space, not here.
class AppearanceScreen extends StatelessWidget {
  const AppearanceScreen({super.key});

  // Curated app-accent presets. Aluta red is the default (keeps the exact
  // hand-tuned palette); the rest re-tint the primary family only.
  static const List<_Accent> _accents = [
    _Accent('Aluta red', ThemeProvider.defaultAccent),
    _Accent('Coral', Color(0xFFFF5A5F)),
    _Accent('Rose', Color(0xFFFF4D8D)),
    _Accent('Violet', Color(0xFF8E7CFF)),
    _Accent('Ocean', Color(0xFF37B0E6)),
    _Accent('Teal', Color(0xFF1FB6A6)),
    _Accent('Forest', Color(0xFF39B54A)),
    _Accent('Ember', Color(0xFFFF8A3D)),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeProvider>();
    final scheme = Theme.of(context).colorScheme;

    return AppPopupShell(
      title: 'Appearance',
      icon: Icons.palette_outlined,
      edgeToEdge: true,
      builder: (context, isWide) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        children: [
          _sectionLabel(scheme, 'APP THEME'),
          const SizedBox(height: 10),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(
                value: ThemeMode.system,
                icon: Icon(Icons.brightness_auto_rounded),
                label: Text('System'),
              ),
              ButtonSegment(
                value: ThemeMode.light,
                icon: Icon(Icons.light_mode_rounded),
                label: Text('Light'),
              ),
              ButtonSegment(
                value: ThemeMode.dark,
                icon: Icon(Icons.dark_mode_rounded),
                label: Text('Dark'),
              ),
            ],
            selected: {theme.themeMode},
            showSelectedIcon: false,
            onSelectionChanged: (s) => theme.setThemeMode(s.first),
          ),
          const SizedBox(height: 8),
          Text(
            'Dark is Aluta’s signature look — cover art and the glow pop '
            'against it. System follows your device.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 28),
          _sectionLabel(scheme, 'ACCENT'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              for (final a in _accents)
                _swatch(context, theme, scheme, a),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'The accent tints buttons and highlights across the app. Surfaces '
            'stay dark-and-neutral so the brand holds.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 28),
          _sectionLabel(scheme, 'CHAT & STATUS'),
          const SizedBox(height: 10),
          const IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _ChatWallpaperSection()),
                SizedBox(width: 12),
                Expanded(child: _StatusMediaSection()),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Wallpaper sets the backdrop for every chat — override any single '
            'chat from its ⋮ menu → Wallpaper. Status videos pre-load quietly '
            'on Wi-Fi so they open instantly.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 28),
          _sectionLabel(scheme, 'WALLPAPER CLARITY'),
          const SizedBox(height: 6),
          ValueListenableBuilder<double>(
            valueListenable: wallpaperClarity,
            builder: (_, v, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text('Faint',
                        style: TextStyle(
                            fontSize: 11.5, color: scheme.onSurfaceVariant)),
                    Expanded(
                      child: Slider(
                        value: v,
                        onChanged: (nv) => setWallpaperClarity(nv),
                      ),
                    ),
                    Text('Clear',
                        style: TextStyle(
                            fontSize: 11.5, color: scheme.onSurfaceVariant)),
                  ],
                ),
                Text(
                  'How strongly chat & Space wallpapers show through. Slide '
                  'toward Clear for a vivid picture, or Faint for a subtle '
                  'backdrop. Buttons and cards always stay sharp on top.',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(Icons.favorite_rounded, color: scheme.primary, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Want a colour just for one bond? Open an Our Space and tap '
                    'edit to give it its own theme.',
                    style: TextStyle(
                        fontSize: 12.5, color: scheme.onSurface),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Section headers wear the accent (scheme.primary IS the chosen accent), so
  // they retint live the instant a swatch is tapped — the requested glimpse.
  Widget _sectionLabel(ColorScheme scheme, String label) => Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
          color: scheme.primary,
        ),
      );

  Widget _swatch(BuildContext context, ThemeProvider theme, ColorScheme scheme,
      _Accent a) {
    final selected = theme.accent.toARGB32() == a.color.toARGB32();
    return GestureDetector(
      onTap: () => theme.setAccent(a.color),
      child: SizedBox(
        width: 62,
        child: Column(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: a.color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? scheme.onSurface : Colors.transparent,
                  width: 3,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check, color: Colors.white, size: 22)
                  : null,
            ),
            const SizedBox(height: 6),
            Text(
              a.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _Accent {
  final String name;
  final Color color;
  const _Accent(this.name, this.color);
}


/// Sets the all-chats default wallpaper (Appearance → Chat wallpaper). Per-chat
/// overrides are set inside each chat; this is the fallback every chat follows
/// until it gets one of its own.
class _ChatWallpaperSection extends StatefulWidget {
  const _ChatWallpaperSection();
  @override
  State<_ChatWallpaperSection> createState() => _ChatWallpaperSectionState();
}

class _ChatWallpaperSectionState extends State<_ChatWallpaperSection> {
  String _apiBase = '';
  List<WallpaperPreset> _presets = const [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final b = await AppConfig.baseUrl;
    final p = await WallpapersService.instance.load();
    if (!mounted) return;
    setState(() {
      _apiBase = b;
      _presets = p;
    });
  }

  String _full(String rel) => rel.startsWith('http') ? rel : '$_apiBase$rel';

  String _labelFor(ChatBg bg) {
    switch (bg.mode) {
      case 'motif':
        return 'Motif pattern';
      case 'photo':
        return 'Photo wallpaper';
      default:
        return 'Default';
    }
  }

  Future<void> _upload() async {
    try {
      final res = await FilePicker.pickFiles(type: FileType.image);
      if (res == null || res.files.isEmpty) return;
      final fl = res.files.single;
      final bytes = await fl.readAsBytes();
      if (bytes.isEmpty) return;
      final ext = (fl.extension ?? 'jpg').toLowerCase();
      final mime = ext == 'png'
          ? 'image/png'
          : ext == 'webp'
              ? 'image/webp'
              : ext == 'gif'
                  ? 'image/gif'
                  : 'image/jpeg';
      final up = await ApiService()
          .uploadMedia(bytes: bytes, filename: fl.name, mime: mime);
      final rel = (up?['url'] ?? '').toString();
      if (rel.isEmpty) return;
      await setChatBackgroundAll('photo', url: _full(rel));
    } catch (_) {}
  }

  void _openSheet() {
    final scheme = Theme.of(context).colorScheme;
    final current = chatBackgroundAll;
    final selUrl = current.isPhoto ? current.url : null;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        void applyClose(String mode, {String? url, String? wideUrl}) {
          setChatBackgroundAll(mode, url: url, wideUrl: wideUrl);
          Navigator.pop(ctx);
        }

        final maxH = MediaQuery.of(ctx).size.height * 0.82;
        return SafeArea(
          child: SizedBox(
            height: maxH,
            child: Column(
              children: [
                const SizedBox(height: 10),
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                        color: scheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 14),
                // Pinned header.
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Default chat wallpaper',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: scheme.onSurface)),
                      const SizedBox(height: 2),
                      Text('Applies to every chat without its own',
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                // Scrolls independently between the pinned header and footer.
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(children: [
                          Expanded(
                              child: _quick(scheme, Icons.blur_on_rounded,
                                  'Default', current.mode == 'default',
                                  () => applyClose('default'))),
                          const SizedBox(width: 10),
                          Expanded(
                              child: _quick(scheme, Icons.auto_awesome_rounded,
                                  'Motif', current.mode == 'motif',
                                  () => applyClose('motif'))),
                        ]),
                        const SizedBox(height: 16),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text('GALLERY',
                              style: TextStyle(
                                  fontSize: 11,
                                  letterSpacing: 0.6,
                                  fontWeight: FontWeight.w700,
                                  color: scheme.onSurfaceVariant)),
                        ),
                        const SizedBox(height: 8),
                        WallpaperGalleryGrid(
                          presets: _presets,
                          apiBase: _apiBase,
                          accent: scheme.primary,
                          selectedFullUrl: selUrl,
                          onPick: (p) => applyClose('photo',
                              url: _full(p.url),
                              wideUrl:
                                  (p.wideUrl != null && p.wideUrl!.isNotEmpty)
                                      ? _full(p.wideUrl!)
                                      : null),
                        ),
                      ],
                    ),
                  ),
                ),
                // Pinned footer — always reachable, whatever the scroll.
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await _upload();
                      },
                      icon: const Icon(Icons.add_photo_alternate_rounded,
                          size: 20),
                      label: const Text('Upload a photo'),
                      style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14))),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _quick(ColorScheme scheme, IconData icon, String label, bool selected,
      VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: selected ? scheme.primary : Colors.transparent, width: 2),
        ),
        child: Column(children: [
          Icon(icon, color: selected ? scheme.primary : scheme.onSurfaceVariant),
          const SizedBox(height: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: scheme.onSurface)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<int>(
      valueListenable: chatBgRevision,
      builder: (ctx, _, _) {
        final bg = chatBackgroundAll;
        return Material(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: _openSheet,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.wallpaper_rounded,
                          size: 22, color: scheme.primary),
                      const Spacer(),
                      Icon(Icons.chevron_right_rounded,
                          size: 20, color: scheme.onSurfaceVariant),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text('Chat wallpaper',
                      style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface)),
                  const SizedBox(height: 2),
                  Text('${_labelFor(bg)} · all chats',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}


/// STATUS MEDIA — lets the data-conscious user decide whether status *videos*
/// pre-download in the background. Photos and text always prefetch (they are
/// tiny); videos are the only heavy item, so they ride behind this switch and
/// only ever pull on Wi-Fi. Default ON so the common case (Wi-Fi at home) feels
/// instant, but one tap turns it off for anyone watching their bundle.
class _StatusMediaSection extends StatefulWidget {
  const _StatusMediaSection();

  @override
  State<_StatusMediaSection> createState() => _StatusMediaSectionState();
}

class _StatusMediaSectionState extends State<_StatusMediaSection> {
  static const _kKey = 'status_dl_videos_wifi';
  bool _videosOnWifi = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _videosOnWifi = prefs.getBool(_kKey) ?? true;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _set(bool v) async {
    setState(() => _videosOnWifi = v);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kKey, v);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.wifi_rounded, size: 22, color: scheme.primary),
                const Spacer(),
                SizedBox(
                  height: 24,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Switch(
                      value: _videosOnWifi,
                      onChanged: _loaded ? _set : null,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Status videos',
                style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface)),
            const SizedBox(height: 2),
            Text(
                !_loaded
                    ? 'Loading…'
                    : (_videosOnWifi
                        ? 'Pre-load on Wi-Fi'
                        : 'Off · load on open'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}
