// Cross-platform app reload facade.
//
// On web this resolves to a real page reload (fetching the latest deployed
// build); on native platforms it's a no-op (apps update via a new install).
export 'app_reload_stub.dart'
    if (dart.library.html) 'app_reload_web.dart';
