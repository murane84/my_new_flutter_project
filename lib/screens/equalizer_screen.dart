import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/popup_shell.dart';

/// A functional equalizer + sound-enhancement screen.
///
/// Real DSP is only available on Android via just_audio's [AndroidEqualizer]
/// and [AndroidLoudnessEnhancer]. On other platforms the controls are shown
/// disabled with a note, since the audio stack there has no supported EQ.
class EqualizerScreen extends StatefulWidget {
  final AndroidEqualizer? equalizer;
  final AndroidLoudnessEnhancer? loudness;
  const EqualizerScreen({super.key, this.equalizer, this.loudness});

  @override
  State<EqualizerScreen> createState() => _EqualizerScreenState();
}

class _EqualizerScreenState extends State<EqualizerScreen> {
  // 5-point preset curves (dB), sampled across however many bands exist.
  static const Map<String, List<double>> _presets = {
    'Flat': [0, 0, 0, 0, 0],
    'Bass Boost': [6, 4, 0, 0, 0],
    'Treble': [0, 0, 0, 4, 6],
    'Vocal': [-2, 0, 5, 2, -1],
    'Rock': [5, 2, -1, 2, 4],
    'Pop': [-1, 2, 4, 2, -1],
    'Jazz': [3, 1, 0, 1, 3],
    'Classical': [4, 2, -1, 2, 4],
    'Dance': [6, 3, 0, 2, 4],
    'Hip-Hop': [6, 4, 1, 2, 3],
  };

  bool _supported = false;
  bool _enabled = false;
  double _minDb = -12, _maxDb = 12;
  List<AndroidEqualizerBand> _bands = [];
  List<double> _gains = [];
  String _preset = 'Custom';
  double _bass = 0; // 0..1
  double _loud = 0; // 0..1
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final eq = widget.equalizer;
    if (eq == null) {
      setState(() {
        _supported = false;
        _loading = false;
      });
      return;
    }
    try {
      final params = await eq.parameters;
      final prefs = await SharedPreferences.getInstance();
      _minDb = params.minDecibels;
      _maxDb = params.maxDecibels;
      _bands = params.bands;
      _gains = _bands.map((b) => b.gain).toList();
      _enabled = prefs.getBool('eq_enabled') ?? false;
      _preset = prefs.getString('eq_preset') ?? 'Custom';
      _bass = prefs.getDouble('eq_bass') ?? 0;
      _loud = prefs.getDouble('eq_loud') ?? 0;
      final saved = prefs.getStringList('eq_gains');
      if (saved != null && saved.length == _bands.length) {
        _gains = saved.map((s) => double.tryParse(s) ?? 0).toList();
      }
      _supported = true;
      _loading = false;
      if (mounted) setState(() {});
      await _apply();
    } catch (_) {
      if (mounted) {
        setState(() {
          _supported = false;
          _loading = false;
        });
      }
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('eq_enabled', _enabled);
    await prefs.setString('eq_preset', _preset);
    await prefs.setDouble('eq_bass', _bass);
    await prefs.setDouble('eq_loud', _loud);
    await prefs.setStringList(
        'eq_gains', _gains.map((g) => g.toStringAsFixed(2)).toList());
  }

  /// Push all current values to the native effects.
  Future<void> _apply() async {
    final eq = widget.equalizer;
    final loud = widget.loudness;
    try {
      await eq?.setEnabled(_enabled);
      await loud?.setEnabled(_enabled);
      for (var i = 0; i < _bands.length; i++) {
        final extra = i == 0 ? _bass * (_maxDb * 0.8) : 0.0;
        await _bands[i].setGain((_gains[i] + extra).clamp(_minDb, _maxDb));
      }
      // Loudness target in decibels (0..~12).
      await loud?.setTargetGain(_loud * 12);
    } catch (_) {}
    _save();
  }

  double _sample(List<double> curve, double p) {
    final x = (p * (curve.length - 1)).clamp(0, curve.length - 1.0);
    final i = x.floor();
    final f = x - i;
    if (i >= curve.length - 1) return curve.last;
    return curve[i] + (curve[i + 1] - curve[i]) * f;
  }

  void _applyPreset(String name) {
    setState(() {
      _preset = name;
      if (name != 'Custom' && _presets.containsKey(name)) {
        final curve = _presets[name]!;
        for (var i = 0; i < _bands.length; i++) {
          final p = _bands.length == 1 ? 0.0 : i / (_bands.length - 1);
          _gains[i] = _sample(curve, p).clamp(_minDb, _maxDb);
        }
      }
    });
    _apply();
  }

  String _freqLabel(double hz) {
    if (hz >= 1000) {
      final k = hz / 1000;
      return '${k.toStringAsFixed(k >= 10 ? 0 : 1)}kHz';
    }
    return '${hz.round()}Hz';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Rendered as a top-anchored popup UNDER the Aluta header (never covering
    // it), with the body scrolling internally for longer content.
    return AppPopupShell(
      title: 'Equalizer',
      icon: Icons.graphic_eq_rounded,
      desktopMaxWidth: 720,
      headerAction: (_supported && !_loading)
          ? Switch(
              value: _enabled,
              onChanged: (v) {
                setState(() => _enabled = v);
                _apply();
              },
            )
          : null,
      builder: (context, isWide) => _loading
          ? const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            )
          : !_supported
              ? _unsupported(scheme)
              : Opacity(
                  opacity: _enabled ? 1 : 0.7,
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    children: [
                      _sectionTitle('Recommended presets'),
                      const SizedBox(height: 10),
                      _presetGrid(scheme),
                      const SizedBox(height: 24),
                      _sectionTitle('Manual adjustment'),
                      const SizedBox(height: 8),
                      _bandSliders(scheme),
                      const SizedBox(height: 24),
                      _sectionTitle('Enhance sound'),
                      const SizedBox(height: 4),
                      Text(
                        'Put in earphones before adjusting sound effects',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 16),
                      _enhanceRow(scheme),
                    ],
                  ),
                ),
    );
  }

  Widget _unsupported(ColorScheme scheme) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.graphic_eq_rounded,
                  size: 64, color: scheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(
                'The equalizer is available on the Android app',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 15, color: scheme.onSurface),
              ),
              const SizedBox(height: 8),
              Text(
                'Windows and web don’t provide a system audio equalizer, '
                'so the sound can’t be shaped here.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12.5, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );

  Widget _sectionTitle(String t) => Text(
        t,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      );

  Widget _presetGrid(ColorScheme scheme) {
    final names = ['Custom', ..._presets.keys];
    const spacing = 10.0;
    // Size each chip from the ACTUAL available width so a whole number of
    // columns fills the row edge-to-edge — no more fixed 104px chips leaving a
    // gutter on the right. 3 columns on phones, 4 on wider screens/tablets.
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final cols = maxW >= 520 ? 4 : 3;
        final chipW = (maxW - spacing * (cols - 1)) / cols;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: names.map((n) {
            final active = _preset == n;
            return GestureDetector(
              onTap: () => _applyPreset(n),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: chipW,
                padding: const EdgeInsets.symmetric(vertical: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: active
                      ? LinearGradient(colors: [
                          scheme.primary,
                          Color.lerp(scheme.primary, Colors.black, 0.25)!,
                        ])
                      : null,
                  color: active ? null : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  n,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: active ? Colors.white : scheme.onSurface,
                    fontWeight: active ? FontWeight.bold : FontWeight.w500,
                    fontSize: 13,
                  ),
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _bandSliders(ColorScheme scheme) {
    return SizedBox(
      height: 230,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(_bands.length, (i) {
          final band = _bands[i];
          final g = _gains[i];
          return Expanded(
            child: Column(
              children: [
                Expanded(
                  child: RotatedBox(
                    quarterTurns: 3,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: scheme.primary,
                        thumbColor: scheme.primary,
                        inactiveTrackColor:
                            scheme.onSurfaceVariant.withAlpha(60),
                        trackHeight: 3,
                      ),
                      child: Slider(
                        value: g.clamp(_minDb, _maxDb),
                        min: _minDb,
                        max: _maxDb,
                        onChanged: (v) {
                          setState(() {
                            _gains[i] = v;
                            _preset = 'Custom';
                          });
                        },
                        onChangeEnd: (_) => _apply(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(_freqLabel(band.centerFrequency),
                    style: TextStyle(
                        fontSize: 10.5, color: scheme.onSurfaceVariant)),
                Text(
                  '${g >= 0 ? '+' : ''}${g.round()}',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: g == 0
                          ? scheme.onSurfaceVariant
                          : scheme.primary),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _enhanceRow(ColorScheme scheme) {
    return Row(
      children: [
        Expanded(
          child: _knobSlider(
            scheme,
            'Bass',
            _bass,
            (v) => setState(() => _bass = v),
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: _knobSlider(
            scheme,
            'Loudness',
            _loud,
            (v) => setState(() => _loud = v),
          ),
        ),
      ],
    );
  }

  Widget _knobSlider(ColorScheme scheme, String label, double value,
      ValueChanged<double> onChanged) {
    return Column(
      children: [
        // Simple arc meter for a "knob" feel.
        SizedBox(
          height: 74,
          width: 74,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: value,
                strokeWidth: 6,
                backgroundColor: scheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation(scheme.primary),
              ),
              Text('${(value * 100).round()}',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 14)),
            ],
          ),
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: scheme.primary,
            thumbColor: scheme.primary,
            trackHeight: 3,
          ),
          child: Slider(
            value: value,
            onChanged: onChanged,
            onChangeEnd: (_) => _apply(),
          ),
        ),
        Text(label,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
      ],
    );
  }
}
