import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/app_config.dart';
import '../utils/chat_background.dart';
import '../utils/toast_helper.dart';
import '../services/wallpapers_service.dart';
import '../screens/api_service.dart';
import 'wallpaper_gallery.dart';

String _mimeForExt(String ext) {
  switch (ext.toLowerCase()) {
    case 'png':
      return 'image/png';
    case 'webp':
      return 'image/webp';
    case 'gif':
      return 'image/gif';
    default:
      return 'image/jpeg';
  }
}

Future<List<MapEntry<String, String>>> _reusableSpacePhotos(
    String apiBase) async {
  // Photos already set on one of the user's Our Spaces, offered for reuse as a
  // chat wallpaper. Returns (spaceName, fullUrl) pairs.
  final out = <MapEntry<String, String>>[];
  try {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('cached_spaces_v1');
    if (raw != null) {
      final list = jsonDecode(raw);
      if (list is List) {
        final seen = <String>{};
        for (final e in list) {
          if (e is Map) {
            final bg = (e['background_url'] ?? '').toString();
            if (bg.startsWith('/attachments/') && seen.add(bg)) {
              final name = (e['name'] ?? 'Our Space').toString();
              out.add(MapEntry(name.isEmpty ? 'Our Space' : name,
                  resolveWallpaperUrl(bg, apiBase)));
            }
          }
        }
      }
    }
  } catch (_) {}
  return out;
}

/// The chat-wallpaper chooser, shared by the phone chat's ⋮ menu and the desktop
/// chat header. [convKey] is the target chat (see [chatConvKey]); a pick sets
/// that chat's wallpaper, or — with "Apply to all chats" — the all-chats default.
Future<void> showChatWallpaperSheet(
  BuildContext context, {
  required String convKey,
  required String title,
  String? apiBase,
}) async {
  final base = apiBase ?? await AppConfig.baseUrl;
  final presets = await WallpapersService.instance.load();
  final reusable = await _reusableSpacePhotos(base);
  if (!context.mounted) return;
  final scheme = Theme.of(context).colorScheme;
  final current = chatBackgroundFor(convKey);
  bool applyAll = false;

  String full(String rel) => resolveWallpaperUrl(rel, base);

  Future<void> pickAndUpload() async {
    try {
      final res = await FilePicker.pickFiles(type: FileType.image);
      if (res == null || res.files.isEmpty) return;
      final fl = res.files.single;
      final bytes = await fl.readAsBytes();
      if (bytes.isEmpty) return;
      final ext = (fl.extension ?? 'jpg').toLowerCase();
      if (context.mounted) showToast(context, 'Uploading wallpaper…');
      final up = await ApiService()
          .uploadMedia(bytes: bytes, filename: fl.name, mime: _mimeForExt(ext));
      final rel = (up?['url'] ?? '').toString();
      if (rel.isEmpty) {
        if (context.mounted) {
          showToast(context, 'Upload failed', type: ToastType.error);
        }
        return;
      }
      final url = full(rel);
      if (applyAll) {
        await setChatBackgroundAll('photo', url: url);
      } else {
        await setChatBackgroundFor(convKey, 'photo', url: url);
      }
    } catch (_) {
      if (context.mounted) {
        showToast(context, 'Could not set wallpaper', type: ToastType.error);
      }
    }
  }

  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: scheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setSheet) {
        void applyAndClose(String mode, {String? url, String? wideUrl}) {
          if (applyAll) {
            setChatBackgroundAll(mode, url: url, wideUrl: wideUrl);
          } else {
            setChatBackgroundFor(convKey, mode, url: url, wideUrl: wideUrl);
          }
          Navigator.pop(ctx);
        }

        Widget quick(IconData icon, String label, bool selected,
                VoidCallback onTap) =>
            GestureDetector(
              onTap: onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: selected ? scheme.primary : Colors.transparent,
                      width: 2),
                ),
                child: Column(children: [
                  Icon(icon,
                      color:
                          selected ? scheme.primary : scheme.onSurfaceVariant),
                  const SizedBox(height: 6),
                  Text(label,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500,
                          color: scheme.onSurface)),
                ]),
              ),
            );

        Widget label(String t) => Align(
              alignment: Alignment.centerLeft,
              child: Text(t.toUpperCase(),
                  style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 0.6,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant)),
            );

        final selUrl = current.isPhoto ? current.url : null;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                        color: scheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 14),
                Text('Chat wallpaper',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurface)),
                const SizedBox(height: 2),
                Text(title,
                    style: TextStyle(
                        fontSize: 12.5, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(14)),
                  child: SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                    value: applyAll,
                    onChanged: (v) => setSheet(() => applyAll = v),
                    title: const Text('Apply to all chats',
                        style:
                            TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    subtitle: Text(
                        applyAll
                            ? 'One wallpaper for every DM and group'
                            : 'This chat only',
                        style: const TextStyle(fontSize: 11.5)),
                  ),
                ),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(
                      child: quick(Icons.blur_on_rounded, 'Default',
                          current.mode == 'default',
                          () => applyAndClose('default'))),
                  const SizedBox(width: 10),
                  Expanded(
                      child: quick(Icons.auto_awesome_rounded, 'Motif',
                          current.mode == 'motif',
                          () => applyAndClose('motif'))),
                ]),
                const SizedBox(height: 18),
                label('Gallery'),
                const SizedBox(height: 8),
                WallpaperGalleryGrid(
                  presets: presets,
                  apiBase: base,
                  accent: scheme.primary,
                  selectedFullUrl: selUrl,
                  onPick: (p) => applyAndClose('photo',
                      url: full(p.url),
                      wideUrl: (p.wideUrl != null && p.wideUrl!.isNotEmpty)
                          ? full(p.wideUrl!)
                          : null),
                ),
                if (reusable.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  label('From your Our Space'),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 96,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: reusable.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 10),
                      itemBuilder: (c, i) {
                        final e = reusable[i];
                        final sel = selUrl == e.value;
                        return GestureDetector(
                          onTap: () => applyAndClose('photo', url: e.value),
                          child: Column(children: [
                            Container(
                              width: 58,
                              height: 72,
                              clipBehavior: Clip.antiAlias,
                              decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                      color: sel
                                          ? scheme.primary
                                          : scheme.outlineVariant,
                                      width: sel ? 2.5 : 1)),
                              child: WallpaperThumb(e.value),
                            ),
                            const SizedBox(height: 4),
                            SizedBox(
                                width: 60,
                                child: Text(e.key,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: scheme.onSurfaceVariant))),
                          ]),
                        );
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                OutlinedButton.icon(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await pickAndUpload();
                  },
                  icon: const Icon(Icons.add_photo_alternate_rounded, size: 20),
                  label: const Text('Upload a photo'),
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14))),
                ),
              ],
            ),
          ),
        );
      });
    },
  );
}
