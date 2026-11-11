/// Aluta's ONE shape scale: every corner in the app is one of these, so
/// cards, sheets, pills, menus and tiles read as one family.
///
///  • [sm]  8  — small chips, badges, thumbnails
///  • [md]  12 — buttons, inputs, list tiles, small cards
///  • [lg]  16 — cards, menus, panels
///  • [xl]  22 — big cards, bottom sheets, the chat panel
///  • [xxl] 28 — hero cards, full sheets
/// Pills use a radius of half their height (or larger).
abstract final class Radii {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 22;
  static const double xxl = 28;
}
