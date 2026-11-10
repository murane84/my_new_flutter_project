import 'package:flutter/material.dart';
import '../screens/token_helper.dart' show mediaAuthHeaders;
import 'net_image.dart';

/// How the online dot reads (Circle list, by Listen-Together readiness):
/// [plain] online · [ready] online with a good-enough connection to listen
/// together (a tiny 🎧 inside the green) · [weak] online but the connection
/// is too weak right now (a hollow green ring — still online, not "away").
enum OnlineDot { plain, ready, weak }

class InitialsAvatar extends StatelessWidget {
  final String name;
  final double radius;
  final bool isOnline;

  /// Full URL of the user's profile picture. When null/empty (or if it fails
  /// to load) the coloured initials are shown instead.
  final String? imageUrl;

  /// The online dot's colour (default Aluta green). Readiness for Listen
  /// Together is shown by [onlineDot]'s SHAPE, never by an amber / grey
  /// colour that reads as "away".
  final Color? onlineColor;
  final String? onlineTip;
  final OnlineDot onlineDot;

  const InitialsAvatar({
    super.key,
    required this.name,
    this.radius = 22,
    this.isOnline = false,
    this.imageUrl,
    this.onlineColor,
    this.onlineTip,
    this.onlineDot = OnlineDot.plain,
  });

  Widget _dot(BuildContext context) {
    final green = onlineColor ?? const Color(0xFF2BB673);
    final surface = Theme.of(context).colorScheme.surface;
    // Ready to listen together: a touch larger, with a little headphones
    // glyph — so "green" alone never has to mean two things.
    final size = radius * (onlineDot == OnlineDot.ready ? 0.66 : 0.55);
    switch (onlineDot) {
      case OnlineDot.weak:
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: surface,
            shape: BoxShape.circle,
            border: Border.all(color: green, width: 2.2),
            boxShadow: [BoxShadow(color: surface, spreadRadius: 1.5)],
          ),
        );
      case OnlineDot.ready:
        return Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: green,
            shape: BoxShape.circle,
            border: Border.all(color: surface, width: 2),
          ),
          child: Icon(Icons.headphones_rounded,
              size: size * 0.52, color: Colors.white),
        );
      case OnlineDot.plain:
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: green,
            shape: BoxShape.circle,
            border: Border.all(color: surface, width: 2),
          ),
        );
    }
  }

  Color _colorFromName(String name) {
    final colors = [
      const Color(0xFFE53935),
      const Color(0xFF8E24AA),
      const Color(0xFF1E88E5),
      const Color(0xFF00897B),
      const Color(0xFFF4511E),
      const Color(0xFF39B54A),
      const Color(0xFF6D4C41),
      const Color(0xFF546E7A),
    ];
    final idx = name.isEmpty ? 0 : name.codeUnitAt(0) % colors.length;
    return colors[idx];
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || name.isEmpty) return '?';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }

  Widget _initialsCircle() => CircleAvatar(
        radius: radius,
        backgroundColor: _colorFromName(name),
        child: Text(
          _initials(name),
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: radius * 0.7,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final hasImage = imageUrl != null && imageUrl!.isNotEmpty;
    // Use the cross-platform loader so avatars load on WEB too: a browser <img>
    // can't send the Authorization header, so on web this moves the token into
    // the URL (?token=). Raw CachedNetworkImage here loaded inconsistently on
    // web. Decode small (avatar-sized) to keep memory low in long lists.
    final avatar = hasImage
        ? ClipOval(
            child: authNetworkImage(
              url: imageUrl!,
              headers: mediaAuthHeaders(imageUrl!),
              width: radius * 2,
              height: radius * 2,
              fit: BoxFit.cover,
              cacheWidth: (radius * 2 * 3).round(),
              placeholder: (_) => _initialsCircle(),
              error: (_) => _initialsCircle(),
            ),
          )
        : _initialsCircle();

    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        if (isOnline)
          Positioned(
            right: -1,
            bottom: -1,
            child: Tooltip(
              message: onlineTip ?? '',
              child: _dot(context),
            ),
          ),
      ],
    );
  }
}
