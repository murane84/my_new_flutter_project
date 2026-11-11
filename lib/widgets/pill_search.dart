import 'package:flutter/material.dart';

/// The one edge every search box in Aluta shares: a pill (stadium), like
/// the Circle switcher's search. A soft hairline at rest, the accent when
/// focused. Set all three of border / enabledBorder / focusedBorder with
/// it — the app theme's own enabled / focused borders are 12 px boxes and
/// would otherwise win.
OutlineInputBorder pillSearchBorder(ColorScheme scheme,
        {bool focused = false}) =>
    OutlineInputBorder(
      borderRadius: BorderRadius.circular(999),
      borderSide: BorderSide(
        color: focused
            ? scheme.primary.withValues(alpha: 0.7)
            : scheme.outlineVariant.withValues(alpha: 0.45),
        width: focused ? 1.4 : 1,
      ),
    );
