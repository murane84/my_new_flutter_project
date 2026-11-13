import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Smooth motion on 90/120 Hz phones — decided by the app, never a setting.
///
/// Many Android phones (MIUI, Tecno/Infinix, Samsung "adaptive") keep apps
/// at 60 Hz unless the app asks. We ask for the screen's fastest rate, then
/// make sure the phone can actually keep up:
///  • weak phones (Android's low-RAM flag, < 3 GB) stay at a steady 60 Hz;
///  • battery saver or a hot phone → 60 Hz until that passes;
///  • otherwise we watch real frame times while things move; if more than
///    ~12 % miss the fast deadline, this phone settles on 60 Hz (a steady 60
///    feels smoother than swinging 120↔60). Remembered per app build, so an
///    update that makes Aluta lighter gets tested again.
/// Android only; elsewhere the OS already follows the screen.
class SmoothMotion with WidgetsBindingObserver {
  SmoothMotion._();
  static final SmoothMotion instance = SmoothMotion._();

  static const _ch = MethodChannel('aluta/display');
  static const _kVerdict = 'smooth_motion_v1'; // "<build>|fast" / "<build>|slow"

  double _max = 60;
  bool _weak = false;
  String _verdict = ''; // '', 'fast', 'slow'
  String _build = '';
  bool _started = false;

  /// The rate we're asking for now (60 or the screen's fastest).
  double get rate => _fastAllowed ? _max : 60;
  bool _fastAllowed = false;

  Future<void> init() async {
    if (_started || kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    _started = true;
    try {
      final info = Map<String, dynamic>.from(
          (await _ch.invokeMethod<Map>('info')) ?? const {});
      final rates = ((info['rates'] as List?) ?? const [])
          .map((e) => (e as num).toDouble())
          .toList();
      _max = rates.isEmpty ? 60 : rates.reduce((a, b) => a > b ? a : b);
      if (_max < 80) return; // a 60 Hz screen: nothing to do
      _weak = info['lowRam'] == true ||
          ((info['ramMb'] as num?)?.toInt() ?? 4096) < 3000 ||
          ((info['cores'] as num?)?.toInt() ?? 8) < 6;
      _build = (await PackageInfo.fromPlatform()).buildNumber;
      final p = await SharedPreferences.getInstance();
      final s = (p.getString(_kVerdict) ?? '').split('|');
      if (s.length == 2 && s[0] == _build) _verdict = s[1];
      WidgetsBinding.instance.addObserver(this);
      await _apply(info);
      if (_fastAllowed && _verdict.isEmpty) _startProbe();
    } catch (_) {/* best-effort: the system default stays */}
  }

  /// Back to the front: battery saver / heat may have changed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _ch.invokeMethod<Map>('info').then((m) {
      if (m != null) _apply(Map<String, dynamic>.from(m));
    }).catchError((_) => null);
  }

  Future<void> _apply(Map<String, dynamic> info) async {
    final busy = info['powerSave'] == true ||
        ((info['thermal'] as num?)?.toInt() ?? 0) >= 3; // SEVERE and up
    _fastAllowed = !_weak && !busy && _verdict != 'slow';
    await _ch.invokeMethod('setRate', {'hz': rate});
  }

  // ── The probe: are we really making the fast deadline? ────────────────
  int _frames = 0;
  int _missed = 0;
  static const _need = 600; // ~5 s of real motion at 120 Hz

  void _startProbe() {
    // Start-up frames (first images, shader warm-up) are slow on every phone:
    // judge only once the app has settled.
    Future.delayed(const Duration(seconds: 12), () {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
    });
  }

  void _onTimings(List<FrameTiming> timings) {
    final budgetUs = 1e6 / _max;
    for (final t in timings) {
      _frames++;
      final worst = t.buildDuration.inMicroseconds > t.rasterDuration.inMicroseconds
          ? t.buildDuration.inMicroseconds
          : t.rasterDuration.inMicroseconds;
      if (worst > budgetUs) _missed++;
    }
    if (_frames < _need) return;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _verdict = _missed / _frames > 0.12 ? 'slow' : 'fast';
    SharedPreferences.getInstance()
        .then((p) => p.setString(_kVerdict, '$_build|$_verdict'));
    if (_verdict == 'slow') {
      _fastAllowed = false;
      _ch.invokeMethod('setRate', {'hz': 60.0}).catchError((_) => null);
    }
  }
}
