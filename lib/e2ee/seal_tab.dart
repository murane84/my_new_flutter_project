import 'seal_tab_stub.dart' if (dart.library.js_interop) 'seal_tab_web.dart'
    as impl;

/// 🔒 Aluta on the web, open in two browser tabs: both would move the same
/// encrypted sessions and keys (kept in the browser's storage) from two
/// places at once — the same message key used twice, one tab's progress
/// overwriting the other's. Only the tab in use does; another tab still
/// reads (without moving anything) and takes over when it's used (focused).
/// Native apps run once per device: always in use.
class SealTab {
  SealTab._();

  /// Whether this tab may move sessions and keys.
  static bool get inUse => impl.sealTabInUse();

  /// Start watching for this tab being used. [onTakeOver] reloads what
  /// another tab may have changed meanwhile.
  static void start(Future<void> Function() onTakeOver) =>
      impl.sealTabStart(onTakeOver);
}
