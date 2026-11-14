import 'package:flutter/widgets.dart';

/// For search boxes: a tap anywhere outside the box closes the keyboard
/// (phones don't do this by themselves), so the toolbar, the list and any
/// toast ("Added 3 new songs") are never left hidden behind it.
void unfocusOnTapOutside(PointerDownEvent _) =>
    FocusManager.instance.primaryFocus?.unfocus();
