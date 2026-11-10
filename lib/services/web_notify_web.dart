// Web builds: Aluta's notifications through the browser's own Notification
// API — shown while the Aluta tab is in the background (an open tab shows
// its in-app banners instead). Clicking one focuses the tab and routes the
// tap exactly like a phone notification.
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

// Typed property reads (getProperty<T>) instead of `is` checks — the
// analyzer's platform-consistent way to read browser values.
bool get _hasNotification => globalContext.has('Notification');

JSObject? get _ctor => _hasNotification
    ? globalContext.getProperty<JSObject>('Notification'.toJS)
    : null;

bool get webNotifySupported => _hasNotification;

/// 'granted' | 'denied' | 'default' | 'unsupported'
String get webNotifyPermission {
  final n = _ctor;
  if (n == null) return 'unsupported';
  return n.getProperty<JSString?>('permission'.toJS)?.toDart ?? 'default';
}

Future<String> webNotifyRequest() async {
  final n = _ctor;
  if (n == null) return 'unsupported';
  try {
    final r = await n
        .callMethod<JSPromise<JSString>>('requestPermission'.toJS)
        .toDart;
    return r.toDart;
  } catch (_) {
    return webNotifyPermission;
  }
}

bool get webTabHidden {
  final d = globalContext.getProperty<JSObject?>('document'.toJS);
  return d?.getProperty<JSBoolean?>('hidden'.toJS)?.toDart ?? false;
}

void webNotifyShow({
  required String title,
  required String body,
  String? tag,
  void Function()? onClick,
}) {
  if (webNotifyPermission != 'granted') return;
  final ctor = _ctor;
  if (ctor == null) return;
  try {
    final opts = JSObject();
    opts['body'] = body.toJS;
    opts['icon'] = 'icons/Icon-192.png'.toJS;
    // Same tag → the newer one replaces the older (one per chat / person).
    if (tag != null) opts['tag'] = tag.toJS;
    final n = globalContext
        .getProperty<JSFunction>('Notification'.toJS)
        .callAsConstructor<JSObject>(title.toJS, opts);
    n['onclick'] = ((JSAny? _) {
      try {
        globalContext.callMethod('focus'.toJS);
      } catch (_) {}
      try {
        n.callMethod('close'.toJS);
      } catch (_) {}
      onClick?.call();
    }).toJS;
  } catch (_) {/* best-effort */}
}
