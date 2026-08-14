import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'theme_provider.dart';

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

    return Scaffold(
      appBar: AppBar(title: const Text('Appearance')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
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

  Widget _sectionLabel(ColorScheme scheme, String label) => Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
          color: scheme.onSurfaceVariant,
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
