import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:provider/provider.dart';

import 'theme_provider.dart';
import '../utils/popup_shell.dart';
import '../utils/app_config.dart';
import '../utils/chat_background.dart';
import '../services/keystroke_sounds.dart';
import '../services/biometric_service.dart';
import '../services/heart_lock.dart';
import '../utils/bubble_theme.dart';
import '../theme/aluta_palette.dart';
import '../services/wallpapers_service.dart';
import '../widgets/wallpaper_gallery.dart';
import 'api_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/song_insights.dart';
import '../utils/readable.dart';

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

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeProvider>();
    final scheme = Theme.of(context).colorScheme;

    return AppPopupShell(
      title: 'Appearance',
      icon: Icons.palette_outlined,
      edgeToEdge: true,
      desktopMaxWidth: 1040,
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
          Row(
            children: [
              _themeCard(theme, scheme, ThemeMode.system,
                  Icons.brightness_auto_rounded, 'System'),
              const SizedBox(width: 10),
              _themeCard(theme, scheme, ThemeMode.light,
                  Icons.light_mode_rounded, 'Light'),
              const SizedBox(width: 10),
              _themeCard(theme, scheme, ThemeMode.dark,
                  Icons.dark_mode_rounded, 'Dark'),
            ],
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
          _accentHeader(context, theme, scheme),
          const SizedBox(height: 12),
          ..._accentGroups(context, theme, scheme, isWide),
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
          const SizedBox(height: 10),
          isWide
              ? const IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: _KeystrokeSoundSection()),
                      SizedBox(width: 12),
                      Expanded(child: _MessageTonesSection()),
                    ],
                  ),
                )
              : const Column(
                  children: [
                    _KeystrokeSoundSection(),
                    SizedBox(height: 10),
                    _MessageTonesSection(),
                  ],
                ),
          const SizedBox(height: 10),
          // Secret-heart privacy pair — side by side on wide screens.
          isWide
              ? const IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: _SecretHeartLockSection()),
                      SizedBox(width: 12),
                      Expanded(child: _HeartReceiptsSection()),
                    ],
                  ),
                )
              : const Column(
                  children: [
                    _SecretHeartLockSection(),
                    SizedBox(height: 10),
                    _HeartReceiptsSection(),
                  ],
                ),
          const SizedBox(height: 10),
          const _MusicNudgesSection(),
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
          _sectionLabel(scheme, 'BACKDROP'),
          const SizedBox(height: 10),
          _BackdropSlidersCard(isWide: isWide, showGuide: _showGuide),
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

  // A compact light/dark/system picker card (replaces the segmented bar).
  Widget _themeCard(ThemeProvider theme, ColorScheme scheme, ThemeMode mode,
      IconData icon, String label) {
    final selected = theme.themeMode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: () => theme.setThemeMode(mode),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary.withAlpha(30)
                : scheme.surfaceContainerHighest.withAlpha(110),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected
                  ? scheme.primary
                  : scheme.outlineVariant.withAlpha(90),
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 22,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant),
              const SizedBox(height: 8),
              Text(label,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? scheme.primary : scheme.onSurface)),
            ],
          ),
        ),
      ),
    );
  }

  // ACCENT header: the label plus the currently-selected colour's name, so the
  // per-swatch labels can go and the grid reads as a clean set of dots.
  Widget _accentHeader(
      BuildContext context, ThemeProvider theme, ColorScheme scheme) {
    final current = alutaSwatchFor(theme.accent) ??
        AlutaSwatch('custom', 'Custom', theme.accent);
    return Row(
      children: [
        _sectionLabel(scheme, 'ACCENT'),
        const SizedBox(width: 10),
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: current.color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: current.color.withAlpha(130), blurRadius: 6),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            current.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface),
          ),
        ),
      ],
    );
  }

  // The accents: Aluta's shared palette (same families, same order as the
  // bubble and Our Space pickers) in one raised card.
  List<Widget> _accentGroups(BuildContext context, ThemeProvider theme,
      ColorScheme scheme, bool isWide) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return [
      DecoratedBox(
        decoration: _raisedCardDecoration(scheme, isDark),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          child: AlutaPaletteGrid(
            dot: (s, size, _) => _accentDot(context, theme, scheme, s, size),
          ),
        ),
      ),
    ];
  }

  // A single clean accent dot: colour circle, glow, ring + check when picked.
  Widget _accentDot(BuildContext context, ThemeProvider theme,
      ColorScheme scheme, AlutaSwatch a, double size) {
    final selected = theme.accent.toARGB32() == a.color.toARGB32();
    return Tooltip(
      message: a.name,
      waitDuration: const Duration(milliseconds: 500),
      child: GestureDetector(
        onTap: () => theme.setAccent(a.color),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: a.color,
            shape: BoxShape.circle,
            // Picked: a white gap + its own colour ring around it (modern
            // "selected swatch" look) instead of a heavy dark border.
            border: Border.all(
              color: selected ? scheme.surface : Colors.transparent,
              width: selected ? 2.5 : 0,
            ),
            boxShadow: [
              if (selected)
                BoxShadow(color: a.color, spreadRadius: 2.5, blurRadius: 0),
              BoxShadow(
                color: a.color.withAlpha(selected ? 120 : 45),
                blurRadius: selected ? 12 : 5,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: selected
              ? Icon(Icons.check_rounded, color: readableOn(a.color), size: 18)
              : null,
        ),
      ),
    );
  }
}

/// Wallpaper clarity + theme-colour strength, together in one raised card:
/// each control gets an icon chip, a title, a live % badge and a slider with
/// its end labels. Side by side on wide screens, stacked on phones.
class _BackdropSlidersCard extends StatelessWidget {
  const _BackdropSlidersCard({required this.isWide, required this.showGuide});
  final bool isWide;
  final bool showGuide;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    Widget control({
      required IconData icon,
      required String title,
      required ValueListenable<double> value,
      required ValueChanged<double> onChanged,
      required String low,
      required String high,
      required String guide,
    }) {
      return ValueListenableBuilder<double>(
        valueListenable: value,
        builder: (_, v, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _accentIconChip(scheme, icon),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(title,
                      style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('${(v * 100).round()}%',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: scheme.primary)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                SizedBox(
                  width: 40,
                  child: Text(low,
                      style: TextStyle(
                          fontSize: 11.5, color: scheme.onSurfaceVariant)),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 5,
                      inactiveTrackColor:
                          scheme.primary.withValues(alpha: 0.14),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 16),
                    ),
                    child: Slider(value: v, onChanged: onChanged),
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text(high,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          fontSize: 11.5, color: scheme.onSurfaceVariant)),
                ),
              ],
            ),
            if (showGuide)
              Text(guide,
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ],
        ),
      );
    }

    final clarity = control(
      icon: Icons.wallpaper_rounded,
      title: 'Wallpaper clarity',
      value: wallpaperClarity,
      onChanged: setWallpaperClarity,
      low: 'Faint',
      high: 'Clear',
      guide: 'How strongly chat & Space photo wallpapers show through. '
          'Buttons and bubbles always stay sharp on top.',
    );
    final strength = control(
      icon: Icons.format_color_fill_rounded,
      title: 'Theme colour strength',
      value: motifStrength,
      onChanged: setMotifStrength,
      low: 'Soft',
      high: 'Bold',
      guide: 'How rich the theme-colour backdrops look — the Motif hearts '
          'and the Aluta Watermark.',
    );

    return DecoratedBox(
      decoration: _raisedCardDecoration(scheme, isDark),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
        child: isWide
            ? IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: clarity),
                    VerticalDivider(
                        width: 28,
                        color:
                            scheme.outlineVariant.withValues(alpha: 0.35)),
                    Expanded(child: strength),
                  ],
                ),
              )
            : Column(
                children: [
                  clarity,
                  Divider(
                      height: 22,
                      color: scheme.outlineVariant.withValues(alpha: 0.35)),
                  strength,
                ],
              ),
      ),
    );
  }
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
      case 'watermark':
        return 'Aluta watermark';
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
                          const SizedBox(width: 10),
                          Expanded(
                              child: _quick(scheme, Icons.water_drop_rounded,
                                  'Watermark', current.mode == 'watermark',
                                  () => applyClose('watermark'))),
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

/// Settings card: optional subtle key/delete sounds while typing in chat.
class _SecretHeartLockSection extends StatefulWidget {
  const _SecretHeartLockSection();

  @override
  State<_SecretHeartLockSection> createState() =>
      _SecretHeartLockSectionState();
}

class _SecretHeartLockSectionState extends State<_SecretHeartLockSection> {
  bool _on = HeartLock.instance.enabled;
  bool _loaded = false;
  bool _available = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await HeartLock.instance.init();
    final avail = await BiometricService.instance.isAvailable();
    if (!mounted) return;
    setState(() {
      _on = HeartLock.instance.enabled;
      _available = avail;
      _loaded = true;
    });
  }

  Future<void> _set(bool v) async {
    if (_busy) return;
    if (v) {
      // Prove the user can actually unlock BEFORE arming the gate, so they
      // can never lock themselves out of their own secret hearts.
      setState(() => _busy = true);
      final ok = await BiometricService.instance
          .authenticate('Confirm to lock secret hearts');
      if (!mounted) return;
      setState(() => _busy = false);
      if (!ok) return; // leave it off
    }
    setState(() => _on = v);
    await HeartLock.instance.setEnabled(v);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subtitle = !_loaded
        ? 'Loading\u2026'
        : (!_available
            ? 'Set up a fingerprint, face or device PIN first'
            : (_on
                ? 'Fingerprint, face or PIN to open a secret \u2764'
                : 'Tap to open \u2014 no unlock'));
    final canToggle = _loaded && _available && !_busy;
    return DecoratedBox(
      decoration: _raisedCardDecoration(scheme, isDark),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          children: [
            _accentIconChip(scheme, Icons.lock_rounded),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Lock secret hearts',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      maxLines: 2,
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
                  value: _on,
                  onChanged: canToggle ? _set : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Settings card: whether the sender sees "Opened 💗" when I open their heart.
class _HeartReceiptsSection extends StatefulWidget {
  const _HeartReceiptsSection();

  @override
  State<_HeartReceiptsSection> createState() => _HeartReceiptsSectionState();
}

class _HeartReceiptsSectionState extends State<_HeartReceiptsSection> {
  bool _on = HeartLock.instance.sendReceipts;

  @override
  void initState() {
    super.initState();
    HeartLock.instance.init().then((_) {
      if (mounted) setState(() => _on = HeartLock.instance.sendReceipts);
    });
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
            _accentIconChip(scheme, Icons.mark_email_read_rounded),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Heart opened receipts',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface)),
                  const SizedBox(height: 2),
                  Text(
                      _on
                          ? 'They see \u201cOpened\u201d when you open their heart'
                          : 'Your opening stays private',
                      maxLines: 2,
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
                  value: _on,
                  onChanged: (v) {
                    setState(() => _on = v);
                    HeartLock.instance.setSendReceipts(v);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Music nudges": Aluta noticing songs on repeat and how they feel (all
/// on-device). Off hides the cards and the player's feel strip.
class _MusicNudgesSection extends StatelessWidget {
  const _MusicNudgesSection();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final si = SongInsights.instance;
    return DecoratedBox(
      decoration: _raisedCardDecoration(scheme, isDark),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: ValueListenableBuilder<bool>(
          valueListenable: si.enabled,
          builder: (context, on, _) => Row(
            children: [
              _accentIconChip(scheme, Icons.graphic_eq_rounded),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Music nudges',
                        style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface)),
                    const SizedBox(height: 2),
                    Text(
                        on
                            ? 'Songs on repeat, the feel strip and your Sunday recap · stays on this phone'
                            : 'Aluta won\'t nudge you about your music',
                        maxLines: 2,
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
                  child: Switch(value: on, onChanged: si.setEnabled),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KeystrokeSoundSection extends StatefulWidget {
  const _KeystrokeSoundSection();

  @override
  State<_KeystrokeSoundSection> createState() => _KeystrokeSoundSectionState();
}

class _KeystrokeSoundSectionState extends State<_KeystrokeSoundSection> {
  bool _on = KeystrokeSounds.instance.keystrokesEnabled;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await KeystrokeSounds.instance.init();
    if (!mounted) return;
    setState(() {
      _on = KeystrokeSounds.instance.keystrokesEnabled;
      _loaded = true;
    });
  }

  Future<void> _set(bool v) async {
    setState(() => _on = v);
    await KeystrokeSounds.instance.setKeystrokesEnabled(v);
    if (v) {
      // Tiny confirmation so you hear what you just enabled.
      KeystrokeSounds.instance.playType();
    }
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
            _accentIconChip(scheme, Icons.keyboard_rounded),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Keystroke sounds',
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
                          : (_on
                              ? 'Soft tick on type, tock on delete'
                              : 'Off'),
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
                  value: _on,
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

/// Settings card: light tones when a message is sent (whoosh) or arrives in the
/// open chat (ding). Independent of keystroke sounds; on by default.
class _MessageTonesSection extends StatefulWidget {
  const _MessageTonesSection();

  @override
  State<_MessageTonesSection> createState() => _MessageTonesSectionState();
}

class _MessageTonesSectionState extends State<_MessageTonesSection> {
  bool _on = KeystrokeSounds.instance.messagesEnabled;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await KeystrokeSounds.instance.init();
    if (!mounted) return;
    setState(() {
      _on = KeystrokeSounds.instance.messagesEnabled;
      _loaded = true;
    });
  }

  Future<void> _set(bool v) async {
    setState(() => _on = v);
    await KeystrokeSounds.instance.setMessagesEnabled(v);
    if (v) {
      // Tiny confirmation so you hear what you just enabled.
      KeystrokeSounds.instance.playSent();
    }
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
            _accentIconChip(scheme, Icons.notifications_active_rounded),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Message tones',
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
                          : (_on
                              ? 'Whoosh on send, ding on receive'
                              : 'Off'),
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
                  value: _on,
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
        return SingleChildScrollView(
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
              const SizedBox(height: 10),
              // Same families as the app accent + Our Space, with calm
              // paper / ink basics first for readable chats.
              AlutaPaletteGrid(
                leading: const [kBubbleBasics],
                dot: (sw, size, glow) => Tooltip(
                  message: sw.name,
                  waitDuration: const Duration(milliseconds: 500),
                  child: _swatchCell(ctx, sw.color, current, sent,
                      glow: glow, size: size),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _swatchCell(BuildContext ctx, Color c, Color current, bool sent,
      {bool glow = false, double size = 46}) {
    final selected = _sameColour(c, current);
    final light = bubbleTextOn(c).computeLuminance() < 0.5;
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
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? (light ? Colors.black54 : Colors.white)
                : Colors.black.withAlpha(30),
            width: selected ? 2.5 : 1,
          ),
          // Neon swatches glow like the colour they set.
          boxShadow: glow
              ? [
                  BoxShadow(
                    color: c.withValues(alpha: 0.55),
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: selected
            ? Icon(Icons.check_rounded,
                size: 20, color: light ? Colors.black87 : Colors.white)
            : null,
      ),
    );
  }
}
