import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// How the phone is leaning, as a gentle -1..1 offset on each axis, relative
/// to however the user was holding it when the listening started (that pose
/// is "straight"; the baseline slowly follows a new pose, so it never gets
/// stuck tilted). One shared accelerometer subscription, reference-counted:
/// it only runs while something on screen wants it (a visible secret heart),
/// at UI rate, and stops when the last one goes. Android / iOS only.
class DeviceLean {
  DeviceLean._();
  static final DeviceLean instance = DeviceLean._();

  final ValueNotifier<Offset> lean = ValueNotifier<Offset>(Offset.zero);

  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  int _users = 0;
  StreamSubscription<AccelerometerEvent>? _sub;
  Offset? _base;
  Offset _smooth = Offset.zero;

  void acquire() {
    if (!supported) return;
    if (_users++ == 0) _start();
  }

  void release() {
    if (!supported || _users == 0) return;
    if (--_users == 0) _stop();
  }

  void _start() {
    _base = null;
    try {
      _sub = accelerometerEventStream(
              samplingPeriod: SensorInterval.uiInterval)
          .listen(_onEvent, onError: (_) => _stop(), cancelOnError: true);
    } catch (_) {
      _sub = null;
    }
  }

  void _onEvent(AccelerometerEvent e) {
    final g = Offset(e.x, e.y); // gravity across the screen, m/s²
    final base = _base = Offset.lerp(_base ?? g, g, 0.012)!;
    // ~3.2 m/s² from the resting pose (~19° of tilt) = a full lean.
    final d = (g - base) / 3.2;
    final target = Offset(d.dx.clamp(-1.0, 1.0), (-d.dy).clamp(-1.0, 1.0));
    _smooth = Offset.lerp(_smooth, target, 0.18)!;
    if ((_smooth - lean.value).distance > 0.008) lean.value = _smooth;
  }

  void _stop() {
    _sub?.cancel();
    _sub = null;
    _base = null;
    _smooth = Offset.zero;
    lean.value = Offset.zero;
  }
}
