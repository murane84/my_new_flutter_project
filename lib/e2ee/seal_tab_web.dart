import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math';

const String _key = 'aluta_seal_tab';
final String _me = List.generate(
        12, (_) => Random.secure().nextInt(36).toRadixString(36))
    .join();
bool _started = false;
Future<void> Function()? _onTakeOver;
Future<void>? _taking;

JSObject? get _storage {
  try {
    return globalContext.getProperty<JSObject?>('localStorage'.toJS);
  } catch (_) {
    return null;
  }
}

String? _holder() {
  try {
    return _storage
        ?.callMethod<JSString?>('getItem'.toJS, _key.toJS)
        ?.toDart;
  } catch (_) {
    return null;
  }
}

void _claim() {
  try {
    _storage?.callMethod<JSAny?>('setItem'.toJS, _key.toJS, _me.toJS);
  } catch (_) {}
}

bool sealTabInUse() {
  if (!_started) return true;
  if (_taking != null) return false; // still reloading what changed
  final h = _holder();
  return h == null || h == _me;
}

void sealTabStart(Future<void> Function() onTakeOver) {
  if (_started) return;
  _started = true;
  _onTakeOver = onTakeOver;
  _claim(); // the newest tab opened is the one in use
  void use(JSAny? _) {
    if (_taking != null || sealTabInUse()) return;
    _claim();
    _taking = (_onTakeOver?.call() ?? Future<void>.value())
        .catchError((_) {})
        .whenComplete(() => _taking = null);
  }

  try {
    globalContext.callMethod<JSAny?>(
        'addEventListener'.toJS, 'focus'.toJS, use.toJS);
  } catch (_) {}
}
