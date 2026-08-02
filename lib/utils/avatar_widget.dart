import 'package:flutter/material.dart';

class InitialsAvatar extends StatelessWidget {
  final String name;
  final double radius;
  final bool isOnline;

  const InitialsAvatar({
    super.key,
    required this.name,
    this.radius = 22,
    this.isOnline = false,
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

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
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
        ),
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
