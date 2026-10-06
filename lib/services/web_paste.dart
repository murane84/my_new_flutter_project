// Clipboard paste of FILES on the web build.
//
// On the web, browsers only hand a page the files on the clipboard through a
// real DOM `paste` event (clipboardData.files) — the async Clipboard API and
// the `pasteboard` plugin don't expose arbitrary files there. So on web we
// listen for that event directly; on native platforms this is a no-op (the
// Ctrl/Cmd+V key handler + `pasteboard` already cover desktop).
export 'web_paste_stub.dart' if (dart.library.html) 'web_paste_web.dart';
