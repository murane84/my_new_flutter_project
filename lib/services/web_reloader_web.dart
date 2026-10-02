import 'dart:html' as html;

/// On web, a full reload fetches the freshly deployed assets (the new build's
/// service worker then takes over).
void reloadApp() {
  html.window.location.reload();
}
