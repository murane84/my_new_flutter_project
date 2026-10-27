import 'package:flutter/material.dart';

import '../screens/token_helper.dart' show mediaAuthHeaders;
import '../utils/app_config.dart';
import '../utils/net_image.dart';

/// A person's round avatar: their profile photo when they have one, else
/// their initial on a tinted circle. Takes the avatar exactly as the server
/// sends it (`avatar_url`, usually a relative `/attachments/<id>`) and
/// resolves it against the API base itself — so any list or picker can show
/// real faces without plumbing the base URL through. While the base is still
/// being resolved (first frame of the app only) the initial shows.
class PersonAvatar extends StatefulWidget {
  const PersonAvatar({
    super.key,
    required this.name,
    this.avatar,
    this.radius = 20,
    this.background,
    this.foreground,
    this.fontSize,
  });

  final String name;

  /// `avatar_url` as sent by the server (relative or absolute), or null.
  final String? avatar;
  final double radius;
  final Color? background;
  final Color? foreground;
  final double? fontSize;

  /// The API base once known (shared by every avatar).
  static String? _base;
  static Future<String>? _baseFuture;

  static Future<String> _resolveBase() =>
      _baseFuture ??= AppConfig.baseUrl.then((b) => _base = b);

  /// A full URL for [raw] against [base], or null.
  static String? fullUrl(String? raw, String? base) {
    final s = (raw ?? '').trim();
    if (s.isEmpty) return null;
    if (s.startsWith('http')) return s;
    if (base == null || base.isEmpty) return null;
    return '$base$s';
  }

  @override
  State<PersonAvatar> createState() => _PersonAvatarState();
}

class _PersonAvatarState extends State<PersonAvatar> {
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    final raw = (widget.avatar ?? '').trim();
    if (raw.isNotEmpty && !raw.startsWith('http') && PersonAvatar._base == null) {
      PersonAvatar._resolveBase().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void didUpdateWidget(covariant PersonAvatar old) {
    super.didUpdateWidget(old);
    if (old.avatar != widget.avatar) _failed = false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = _failed
        ? null
        : PersonAvatar.fullUrl(widget.avatar, PersonAvatar._base);
    final n = widget.name.trim();
    final initial = n.isNotEmpty ? n[0].toUpperCase() : '?';
    final size = (widget.radius * 2 * 3).round();
    return CircleAvatar(
      radius: widget.radius,
      backgroundColor: widget.background ?? scheme.primaryContainer,
      backgroundImage: url == null
          ? null
          : authNetworkImageProvider(url, mediaAuthHeaders(url),
              cacheSize: size),
      onBackgroundImageError: url == null
          ? null
          : (_, _) {
              if (mounted) setState(() => _failed = true);
            },
      child: url != null
          ? null
          : Text(
              initial,
              style: TextStyle(
                color: widget.foreground ?? scheme.onPrimaryContainer,
                fontWeight: FontWeight.bold,
                fontSize: widget.fontSize ?? widget.radius * 0.8,
              ),
            ),
    );
  }
}
