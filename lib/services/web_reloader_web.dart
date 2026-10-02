// This file is only compiled for Flutter web (conditional import), where
// dart:html is the simplest reliable way to trigger a full reload.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

/// On web, a full reload fetches the freshly deployed assets (the new build's
/// service worker then takes over).
void reloadApp() {
  html.window.location.reload();
}
