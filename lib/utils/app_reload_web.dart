// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

/// Hard-reloads the web page so the newest deployed build (and updated
/// service worker) is picked up — equivalent to the browser's reload.
void hardReloadApp() {
  html.window.location.reload();
}
