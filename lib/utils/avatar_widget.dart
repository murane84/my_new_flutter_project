import 'package:flutter/material.dart';
import '../screens/token_helper.dart' show mediaAuthHeaders;
import 'net_image.dart';

class InitialsAvatar extends StatelessWidget {
  final String name;
  final double radius;
  final bool isOnline;

  /// Full URL of the user's profile picture. When null/empty (or if it fails
  /// to load) the coloured initials are shown instead.
  final String? imageUrl;

  const InitialsAvatar({
    super.key,
    required this.name,
    this.radius = 22,
    this.isOnline = false,
    this.imageUrl,
  });

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
            child: Container(
              width: radius * 0.55,
              height: radius * 0.55,
              decoration: BoxDecoration(
                color: Colors.green,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).colorScheme.surface,
                  width: 2,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
