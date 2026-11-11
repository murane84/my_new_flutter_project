/// Aluta's ONE depth scale: how soft / far every shadow and glow reads, so
/// cards, chips, sheets and halos sit at a few consistent heights instead
/// of thirty slightly different ones.
///
/// Blur (BoxShadow.blurRadius):
///  • [xs] 4  — hairline lift: pressed keys, tiny chips
///  • [sm] 8  — chips, small cards, avatars
///  • [md] 14 — cards, tiles, the lit keys
///  • [lg] 22 — floating cards, menus, big panels, soft glows
///  • [xl] 32 — hero glows and full overlays
/// Elevation (Material.elevation): [low] 3, [mid] 6, [high] 12.
abstract final class Depth {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 14;
  static const double lg = 22;
  static const double xl = 32;

  static const double low = 3;
  static const double mid = 6;
  static const double high = 12;
}
