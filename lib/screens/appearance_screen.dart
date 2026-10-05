import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'theme_provider.dart';
import '../utils/popup_shell.dart';
import '../utils/app_config.dart';
import '../utils/chat_background.dart';
import '../utils/bubble_theme.dart';
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
class AppearanceScreen extends StatefulWidget {
  const AppearanceScreen({super.key});

  @override
  State<AppearanceScreen> createState() => _AppearanceScreenState();
}

class _AppearanceScreenState extends State<AppearanceScreen> {
  // Guide (helper text) is OFF by default — the page stays compact. The user
  // flips it on from the header when they want the explanations back.
  static const String _kGuide = 'appearance_show_guide_v1';
  bool _showGuide = false;

  @override
  void initState() {
    super.initState();
    _loadGuide();
  }

  Future<void> _loadGuide() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() => _showGuide = p.getBool(_kGuide) ?? false);
    } catch (_) {}
  }

  Future<void> _toggleGuide() async {
    setState(() => _showGuide = !_showGuide);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kGuide, _showGuide);
    } catch (_) {}
  }

  // Curated app-accent presets. Aluta red is the default (keeps the exact
  // hand-tuned palette); the rest re-tint the primary family only.
  static const List<_Accent> _accents = [
    _Accent('Aluta red', ThemeProvider.defaultAccent),
    // Warm reds & pinks
    _Accent('Coral', Color(0xFFFF5A5F)),
    _Accent('Sunset', Color(0xFFFB7185)),
    _Accent('Rose', Color(0xFFFF4D8D)),
    _Accent('Magenta', Color(0xFFEC4899)),
    _Accent('Fuchsia', Color(0xFFD946EF)),
    // Purples
    _Accent('Orchid', Color(0xFFA855F7)),
    _Accent('Violet', Color(0xFF8E7CFF)),
    _Accent('Grape', Color(0xFF9333EA)),
    _Accent('Indigo', Color(0xFF6366F1)),
    // Blues & cyans
    _Accent('Cobalt', Color(0xFF2563EB)),
    _Accent('Ocean', Color(0xFF37B0E6)),
    _Accent('Sky', Color(0xFF38BDF8)),
    _Accent('Cyan', Color(0xFF06B6D4)),
    _Accent('Teal', Color(0xFF1FB6A6)),
    // Greens
    _Accent('Emerald', Color(0xFF10B981)),
    _Accent('Forest', Color(0xFF39B54A)),
    _Accent('Lime', Color(0xFF84CC16)),
    // Yellows & oranges
    _Accent('Gold', Color(0xFFEAB308)),
    _Accent('Amber', Color(0xFFF59E0B)),
    _Accent('Ember', Color(0xFFFF8A3D)),
    // Neutral
    _Accent('Slate', Color(0xFF64748B)),
    // Neon mixers
    _Accent('Neon pink', Color(0xFFFF2E88)),
    _Accent('Neon purple', Color(0xFFB026FF)),
    _Accent('Neon blue', Color(0xFF2D7DFF)),
    _Accent('Neon cyan', Color(0xFF17E9E0)),
    _Accent('Neon green', Color(0xFF2BE86B)),
    _Accent('Neon lime', Color(0xFFC6FF00)),
    _Accent('Neon yellow', Color(0xFFFFE500)),
    _Accent('Neon orange', Color(0xFFFF7A00)),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeProvider>();
    final scheme = Theme.of(context).colorScheme;

    return AppPopupShell(
      title: 'Appearance',
      icon: Icons.palette_outlined,
      edgeToEdge: true,
      headerAction: Padding(
        padding: const EdgeInsets.only(right: 6),
        child: HeaderActionButton(
          icon: _showGuide
              ? Icons.help_rounded
              : Icons.help_outline_rounded,
          tooltip: _showGuide ? 'Hide tips' : 'Show tips',
          onPressed: _toggleGuide,
        ),
      ),
      builder: (context, isWide) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        children: [
          _sectionLabel(scheme, 'APP THEME'),
          const SizedBox(height: 8),
          SegmentedButton<ThemeMode>(
            style: SegmentedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            ),
            segments: const [
              ButtonSegment(
                value: ThemeMode.system,
                icon: Icon(Icons.brightness_auto_rounded, size: 18),
                label: Text('System'),
              ),
              ButtonSegment(
                value: ThemeMode.light,
                icon: Icon(Icons.light_mode_rounded, size: 18),
                label: Text('Light'),
              ),
              ButtonSegment(
                value: ThemeMode.dark,
                icon: Icon(Icons.dark_mode_rounded, size: 18),
                label: Text('Dark'),
              ),
            ],
            selected: {theme.themeMode},
            showSelectedIcon: false,
            onSelectionChanged: (s) => theme.setThemeMode(s.first),
          ),
          if (_showGuide) ...[
            const SizedBox(height: 8),
            Text(
              'Dark is Aluta\u2019s signature look — cover art and the glow pop '
              'against it. System follows your device.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 18),
          _sectionLabel(scheme, 'ACCENT'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final a in _accents) _swatch(context, theme, scheme, a),
            ],
          ),
          if (_showGuide) ...[
            const SizedBox(height: 8),
            Text(
              'The accent tints buttons and highlights across the app. Surfaces '
              'stay dark-and-neutral so the brand holds.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 18),
          _sectionLabel(scheme, 'CHAT & STATUS'),
          const SizedBox(height: 10),
          isWide
              ? const IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: _ChatWallpaperSection()),
                      SizedBox(width: 12),
                      Expanded(child: _StatusMediaSection()),
                    ],
                  ),
                )
              : const Column(
                  children: [
                    _ChatWallpaperSection(),
                    SizedBox(height: 10),
                    _StatusMediaSection(),
                  ],
                ),
          if (_showGuide) ...[
            const SizedBox(height: 8),
            Text(
              'Wallpaper sets the backdrop for every chat — override any single '
              'chat from its \u22ee menu → Wallpaper. Status videos pre-load '
              'quietly on Wi-Fi so they open instantly.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 18),
          _sectionLabel(scheme, 'MESSAGE BUBBLES'),
          const SizedBox(height: 10),
          const _BubbleThemeSection(),
          if (_showGuide) ...[
            const SizedBox(height: 8),
            Text(
              'Give your chats your own colours — one shade for your '
              'messages, one for theirs. Text and links stay readable '
              'automatically, in light or dark mode.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 18),
          _sectionLabel(scheme, 'WALLPAPER CLARITY'),
          const SizedBox(height: 4),
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
                if (_showGuide)
                  Text(
                    'How strongly chat & Space wallpapers show through. Slide '
                    'toward Clear for a vivid picture, or Faint for a subtle '
                    'backdrop. Buttons and cards always stay sharp on top.',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _sectionLabel(scheme, 'THEME COLOUR STRENGTH'),
          const SizedBox(height: 4),
          ValueListenableBuilder<double>(
            valueListenable: motifStrength,
            builder: (_, v, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text('Soft',
                        style: TextStyle(
                            fontSize: 11.5, color: scheme.onSurfaceVariant)),
                    Expanded(
                      child: Slider(
                        value: v,
                        onChanged: (nv) => setMotifStrength(nv),
                      ),
                    ),
                    Text('Bold',
                        style: TextStyle(
                            fontSize: 11.5, color: scheme.onSurfaceVariant)),
                  ],
                ),
                if (_showGuide)
                  Text(
                    'How concentrated the default theme-colour backdrop (the '
                    'hearts-and-glow motif shown when a chat or Space has no '
                    'photo wallpaper) appears. Slide toward Bold for richer '
                    'colour — it is entirely your call.',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          if (_showGuide) ...[
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Icon(Icons.favorite_rounded,
                      color: scheme.primary, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Want a colour just for one bond? Open an Our Space and '
                      'tap edit to give it its own theme.',
                      style: TextStyle(fontSize: 12.5, color: scheme.onSurface),
                    ),
                  ),
                ],
              ),
            ),
          ],
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
        width: 52,
        child: Column(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: a.color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? scheme.onSurface : Colors.transparent,
                  width: 3,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check, color: Colors.white, size: 18)
                  : null,
            ),
            const SizedBox(height: 5),
            Text(
              a.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
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
// Shared raised-card look, matching the Our Space dashboard feature tiles: a
// gently top-lit surface gradient, a hairline rim and a layered drop shadow, so
// the Appearance cards read as the same 3D surfaces.
BoxDecoration _raisedCardDecoration(ColorScheme scheme, bool isDark) =>
    BoxDecoration(
      borderRadius: BorderRadius.circular(18),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [scheme.surface, scheme.surfaceContainerHighest],
      ),
      border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
          blurRadius: 12,
          offset: const Offset(0, 6),
        ),
        BoxShadow(
          color: Colors.white.withValues(alpha: isDark ? 0.04 : 0.7),
          blurRadius: 1,
          spreadRadius: -1,
          offset: const Offset(0, -1),
        ),
      ],
    );

// A 3D accent icon chip — same treatment as the dashboard tiles' icons.
Widget _accentIconChip(ColorScheme scheme, IconData icon) => Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary.withValues(alpha: 0.24),
            scheme.primary.withValues(alpha: 0.12),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.22),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Icon(icon, color: scheme.primary, size: 20),
    );

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
    final isDark = scheme.brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [scheme.surface, scheme.surfaceContainerHighest],
          ),
          border: Border.all(
              color: selected
                  ? scheme.primary
                  : scheme.outlineVariant.withValues(alpha: 0.4),
              width: selected ? 2 : 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.07),
              blurRadius: 10,
              offset: const Offset(0, 5),
            ),
            BoxShadow(
              color: Colors.white.withValues(alpha: isDark ? 0.04 : 0.6),
              blurRadius: 1,
              spreadRadius: -1,
              offset: const Offset(0, -1),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 18,
                color: selected ? scheme.primary : scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: selected ? scheme.primary : scheme.onSurface)),
          ],
        ),
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
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          child: Ink(
            decoration: _raisedCardDecoration(scheme, isDark),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: _openSheet,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                child: Row(
                  children: [
                    _accentIconChip(scheme, Icons.wallpaper_rounded),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Chat wallpaper',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w700,
                                  color: scheme.onSurface)),
                          const SizedBox(height: 2),
                          Text('${_labelFor(bg)} · all chats',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.chevron_right_rounded,
                        size: 20, color: scheme.onSurfaceVariant),
                  ],
                ),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: _raisedCardDecoration(scheme, isDark),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          children: [
            _accentIconChip(scheme, Icons.wifi_rounded),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Status videos',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            const SizedBox(width: 8),
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
      ),
    );
  }
}

/// Settings card for the custom message-bubble colour theme. A switch turns the
/// user's palette on, a live preview shows how a chat reads, and two swatches
/// open a curated colour grid for "my" and "their" bubbles. Everything rebuilds
/// on [bubbleThemeRevision] so the preview tracks each pick instantly.
class _BubbleThemeSection extends StatelessWidget {
  const _BubbleThemeSection();

  bool _sameColour(Color a, Color b) =>
      (a.r - b.r).abs() < 0.004 &&
      (a.g - b.g).abs() < 0.004 &&
      (a.b - b.b).abs() < 0.004;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<int>(
      valueListenable: bubbleThemeRevision,
      builder: (context, _, _) {
        final on = bubbleCustomEnabled;
        return Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withAlpha(90),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: scheme.outlineVariant.withAlpha(80)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.chat_bubble_outline_rounded,
                      size: 20, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Custom colours',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: scheme.onSurface)),
                        Text(on ? 'Your palette, every chat' : 'Using app default',
                            style: TextStyle(
                                fontSize: 11.5,
                                color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  Switch(
                    value: on,
                    onChanged: (v) => setBubbleCustomEnabled(v),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _preview(scheme, on),
              if (on) ...[
                const SizedBox(height: 14),
                _sideRow(context, scheme, 'My messages', bubbleSentColor, true),
                const SizedBox(height: 10),
                _sideRow(
                    context, scheme, 'Their messages', bubbleRecvColor, false),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => resetBubbleTheme(),
                    icon: const Icon(Icons.restart_alt_rounded, size: 18),
                    label: const Text('Reset to default'),
                    style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _preview(ColorScheme scheme, bool on) {
    final isDark = scheme.brightness == Brightness.dark;
    final sent = on
        ? bubbleSentColor
        : (isDark ? const Color(0xFF4C2328) : const Color(0xFFFBDCDB));
    final recv = on
        ? bubbleRecvColor
        : (isDark ? const Color(0xFF241E20) : Colors.white);
    final onSent = on
        ? bubbleTextOn(sent)
        : (isDark ? const Color(0xFFF6E1E1) : const Color(0xFF4A141A));
    final onRecv = on ? bubbleTextOn(recv) : scheme.onSurface;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: _bubble('Hey! Love this song', recv, onRecv, false),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: _bubble('Right? Adding it to our playlist', sent, onSent, true),
          ),
        ],
      ),
    );
  }

  Widget _bubble(String text, Color bg, Color fg, bool mine) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 230),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(14),
          topRight: const Radius.circular(14),
          bottomLeft: Radius.circular(mine ? 14 : 4),
          bottomRight: Radius.circular(mine ? 4 : 14),
        ),
        border: Border.all(color: bubbleBorderOn(bg)),
      ),
      child: Text(text,
          style: TextStyle(color: fg, fontSize: 13.5, height: 1.3)),
    );
  }

  Widget _sideRow(BuildContext context, ColorScheme scheme, String label,
      Color color, bool sent) {
    return InkWell(
      onTap: () => _pickColour(context, sent),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 13.5, color: scheme.onSurface)),
            ),
            Container(
              width: 48,
              height: 30,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: scheme.outlineVariant),
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.edit_rounded, size: 16, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Future<void> _pickColour(BuildContext context, bool sent) async {
    final scheme = Theme.of(context).colorScheme;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final current = sent ? bubbleSentColor : bubbleRecvColor;
        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 2, 18, 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(sent ? 'My message colour' : 'Their message colour',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface)),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final v in bubblePalette)
                    _swatchCell(ctx, Color(v), current, sent),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _swatchCell(BuildContext ctx, Color c, Color current, bool sent) {
    final selected = _sameColour(c, current);
    final light = c.computeLuminance() > 0.5;
    return GestureDetector(
      onTap: () {
        if (sent) {
          setBubbleSentColor(c);
        } else {
          setBubbleRecvColor(c);
        }
        Navigator.pop(ctx);
      },
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? (light ? Colors.black54 : Colors.white)
                : Colors.black.withAlpha(30),
            width: selected ? 2.5 : 1,
          ),
        ),
        child: selected
            ? Icon(Icons.check_rounded,
                size: 20, color: light ? Colors.black87 : Colors.white)
            : null,
      ),
    );
  }
}
