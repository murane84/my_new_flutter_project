import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/haptics.dart';
import '../utils/app_config.dart';

/// ✨ A named release, told once (brand strategy: "each release with a name
/// and a short story — an event, not a list of fixes").
///
/// The first open after updating to a version that has a name shows one quiet
/// card: the version, its name, its story. A fix-only release (no name) shows
/// nothing; a fresh install shows nothing (the welcome ritual is theirs); and
/// each version is told at most once per device.
///
/// [welcomedNow]: the welcome ritual ran on this open (a brand-new account) —
/// then this version is simply noted. Otherwise a device with no note yet is
/// an existing member's first update to a story-aware Aluta, and is told.
Future<void> maybeShowReleaseStory(BuildContext context,
    {bool welcomedNow = false}) async {
  const key = 'release_story_seen';
  try {
    final info = await PackageInfo.fromPlatform();
    final mine = '${info.version}+${info.buildNumber}';
    final p = await SharedPreferences.getInstance();
    final seen = p.getString(key);
    if (seen == mine) return; // already told (or noted) on this device
    // A brand-new member: the welcome is theirs — just note the version.
    if (seen == null && welcomedNow) {
      await p.setString(key, mine);
      return;
    }
    final base = await AppConfig.baseUrl;
    final r = await http
        .get(Uri.parse('$base/app/story?version='
            '${Uri.encodeQueryComponent(info.version)}'))
        .timeout(const Duration(seconds: 10));
    // Only a real answer settles it: offline / a server hiccup → try again
    // next open (200 = the story or none; 404 = an older server, none).
    if (r.statusCode != 200 && r.statusCode != 404) return;
    await p.setString(key, mine);
    if (r.statusCode != 200) return;
    final j = jsonDecode(r.body);
    if (j is! Map) return;
    final name = (j['name'] ?? '').toString().trim();
    if (name.isEmpty || !context.mounted) return;
    Haptics.lightImpact();
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'What’s new',
      barrierColor: Colors.black.withAlpha(170),
      transitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (_, _, _) => _ReleaseStory(
          version: info.version,
          name: name,
          story: (j['story'] ?? '').toString().trim()),
      transitionBuilder: (_, a, _, child) => FadeTransition(
          opacity: a,
          child: ScaleTransition(
              scale: Tween(begin: 0.95, end: 1.0)
                  .animate(CurvedAnimation(parent: a, curve: Curves.easeOut)),
              child: child)),
    );
  } catch (_) {/* a story is a nicety — never in the way */}
}

class _ReleaseStory extends StatelessWidget {
  const _ReleaseStory(
      {required this.version, required this.name, required this.story});
  final String version;
  final String name;
  final String story;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 24),
          constraints: const BoxConstraints(maxWidth: 400),
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 18),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1014),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: scheme.primary.withAlpha(90)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Aluta $version · Mapya',
                  style: TextStyle(
                      color: scheme.primary,
                      fontSize: 12,
                      letterSpacing: 0.8,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              Text(name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w800)),
              if (story.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(story,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.white.withAlpha(200),
                        fontSize: 14,
                        height: 1.5)),
              ],
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Karibu · Let’s go'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
