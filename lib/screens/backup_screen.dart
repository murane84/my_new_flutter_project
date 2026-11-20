import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/local_backup_service.dart';
import '../utils/popup_shell.dart';
import '../utils/toast_helper.dart';
import '../utils/radii.dart';

/// Encrypted backup & restore of the device's local history — the safety net
/// for the "server stores almost nothing" model, so a new device or a reinstall
/// doesn't lose your chats and Our Space. The backup is a single encrypted file
/// only your passphrase can open.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  /// After signing in on a new / reinstalled phone: when a server backup
  /// exists and this device has no recovery key, offer (once) to restore.
  static Future<void> offerRestore(BuildContext context) async {
    try {
      if (await LocalBackupService.instance.savedRecoveryKey() != null) return;
      final prefs = await SharedPreferences.getInstance();
      final slot = 'aluta_cloud_restore_offered_'
          '${prefs.getString('my_user_id') ?? 'x'}';
      if (prefs.getBool(slot) == true) return;
      final info = await LocalBackupService.instance.cloudInfo();
      if (info?['exists'] != true) return;
      await prefs.setBool(slot, true);
      if (!context.mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          icon: const Icon(Icons.cloud_download_rounded),
          title: const Text('Bring your chats back?'),
          content: const Text('You have a backup on Aluta’s server. Your '
              'recovery key restores your chats, Our Space and encrypted '
              'messages on this phone.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(d, false),
                child: const Text('Not now')),
            FilledButton(
                onPressed: () => Navigator.pop(d, true),
                child: const Text('Restore')),
          ],
        ),
      );
      if (go == true && context.mounted) {
        await showAppPopup(context, const BackupScreen());
      }
    } catch (_) {}
  }

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final TextEditingController _pass = TextEditingController();
  bool _obscure = true;
  bool _busy = false;

  // 🔒 Server backup (locked with a recovery key on this device).
  Map<String, dynamic>? _cloud;
  bool _cloudKeyHere = false;

  @override
  void initState() {
    super.initState();
    _loadCloud();
  }

  Future<void> _loadCloud() async {
    final info = await LocalBackupService.instance.cloudInfo();
    final key = await LocalBackupService.instance.savedRecoveryKey();
    if (!mounted) return;
    setState(() {
      _cloud = info;
      _cloudKeyHere = key != null;
    });
  }

  /// Shows [key] once, until they say it's saved. True when confirmed.
  Future<bool> _showRecoveryKey(List<int> key, {bool first = true}) async {
    final text = LocalBackupService.formatRecoveryKey(key);
    var saved = !first;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: !first,
      builder: (d) => StatefulBuilder(
        builder: (d, setD) => AlertDialog(
          title: const Text('Your recovery key'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Only this key opens your server backup — Aluta '
                  'can’t. Write it down or keep it in a safe place, away '
                  'from this phone.'),
              const SizedBox(height: 12),
              SelectableText(text,
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      height: 1.5)),
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: text));
                  showToast(d, 'Recovery key copied');
                },
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('Copy'),
              ),
              if (first)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: saved,
                  onChanged: (v) => setD(() => saved = v == true),
                  title: const Text('I’ve saved my recovery key'),
                ),
            ],
          ),
          actions: [
            if (first)
              TextButton(
                  onPressed: () => Navigator.pop(d, false),
                  child: const Text('Cancel')),
            FilledButton(
                onPressed: saved ? () => Navigator.pop(d, true) : null,
                child: Text(first ? 'Back up now' : 'Done')),
          ],
        ),
      ),
    );
    return ok == true;
  }

  Future<void> _setUpCloud() async {
    // A backup already there (made on another phone, or before a
    // reinstall): restore it first — a new key replaces it.
    if (_cloud?['exists'] == true) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('Replace your server backup?'),
          content: const Text('There’s already a backup on the server. To '
              'bring those chats back, choose “Restore from the server” '
              'instead. A new recovery key replaces that backup with what’s '
              'on this phone.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(d, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(d, true),
                child: const Text('Replace it')),
          ],
        ),
      );
      if (yes != true) return;
    }
    final key = LocalBackupService.instance.newRecoveryKey();
    if (!await _showRecoveryKey(key)) return;
    await _cloudBackup(recovery: key);
  }

  Future<void> _cloudBackup({List<int>? recovery}) async {
    setState(() => _busy = true);
    try {
      await LocalBackupService.instance.cloudBackupNow(recovery: recovery);
      _toast('Backed up to the server — only your recovery key opens it',
          ToastType.success);
    } catch (e) {
      _toast(e.toString().replaceAll('Exception: ', ''), ToastType.error);
    } finally {
      if (mounted) setState(() => _busy = false);
      await _loadCloud();
    }
  }

  Future<void> _cloudRestore() async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Restore from the server'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Your recovery key (64 characters)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(d, ctrl.text),
              child: const Text('Restore')),
        ],
      ),
    );
    if (text == null) return;
    final key = LocalBackupService.parseRecoveryKey(text);
    if (key == null) {
      _toast('That isn’t a recovery key — it has 64 letters and numbers',
          ToastType.error);
      return;
    }
    setState(() => _busy = true);
    try {
      final n = await LocalBackupService.instance.cloudRestore(key);
      _toast('Restored $n items — reopen your chats & spaces to see them',
          ToastType.success);
    } catch (e) {
      _toast(e.toString().replaceAll('Exception: ', ''), ToastType.error);
    } finally {
      if (mounted) setState(() => _busy = false);
      await _loadCloud();
    }
  }

  Future<void> _cloudDelete() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Turn off server backup?'),
        content: const Text('Your backup is deleted from the server. Your '
            'chats on this phone stay.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Keep it')),
          FilledButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text('Turn off')),
        ],
      ),
    );
    if (yes != true) return;
    setState(() => _busy = true);
    await LocalBackupService.instance.cloudDelete();
    if (mounted) setState(() => _busy = false);
    await _loadCloud();
  }

  Widget _cloudSection(ColorScheme scheme) {
    final exists = _cloud?['exists'] == true;
    final at = DateTime.tryParse('${_cloud?['updated_at'] ?? ''}');
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(Icons.cloud_done_rounded, color: scheme.primary),
            const SizedBox(width: 10),
            const Expanded(
              child: Text('Backup on Aluta’s server',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            exists
                ? 'Last backup: ${at == null ? '—' : '${at.toLocal()}'.substring(0, 16)}. '
                    'Locked on this phone with your recovery key — the server '
                    'can’t open it.'
                : 'Keep a copy on the server, locked on this phone with a '
                    'recovery key only you have. After a reinstall, the key '
                    'brings everything back.',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          if (_cloudKeyHere) ...[
            FilledButton.icon(
              onPressed: _busy ? null : () => _cloudBackup(),
              icon: const Icon(Icons.cloud_upload_rounded, size: 18),
              label: const Text('Back up now'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () async {
                      final k =
                          await LocalBackupService.instance.savedRecoveryKey();
                      if (k != null) await _showRecoveryKey(k, first: false);
                    },
              child: const Text('Show my recovery key'),
            ),
          ] else ...[
            if (exists)
              FilledButton.icon(
                onPressed: _busy ? null : _cloudRestore,
                icon: const Icon(Icons.cloud_download_rounded, size: 18),
                label: const Text('Restore from the server'),
              ),
            (exists ? OutlinedButton.icon : FilledButton.icon)(
              onPressed: _busy ? null : _setUpCloud,
              icon: const Icon(Icons.cloud_upload_rounded, size: 18),
              label: Text(exists
                  ? 'Back up with a new recovery key'
                  : 'Turn on server backup'),
            ),
          ],
          if (exists && _cloudKeyHere)
            OutlinedButton.icon(
              onPressed: _busy ? null : _cloudRestore,
              icon: const Icon(Icons.cloud_download_rounded, size: 18),
              label: const Text('Restore from the server'),
            ),
          if (exists)
            TextButton(
              onPressed: _busy ? null : _cloudDelete,
              child: const Text('Turn off and delete the server copy'),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _pass.dispose();
    super.dispose();
  }

  void _toast(String m, ToastType t) {
    if (mounted) showToast(context, m, type: t);
  }

  Future<void> _create() async {
    final pass = _pass.text.trim();
    if (pass.length < LocalBackupService.minPassphrase) {
      _toast(
          'Choose a passphrase of at least '
          '${LocalBackupService.minPassphrase} characters — it protects the '
          'keys to your encrypted chats',
          ToastType.info);
      return;
    }
    setState(() => _busy = true);
    try {
      final content = await LocalBackupService.instance.createBackup(pass);
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-')
          .substring(0, 19);
      final name = 'aluta-backup-$ts.alutabak';
      final bytes = Uint8List.fromList(utf8.encode(content));
      final isDesktop = !kIsWeb &&
          (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
      if (kIsWeb || isDesktop) {
        // Desktop/web: a proper Save-As dialog (the OS share sheet is
        // unreliable on Windows). file_picker writes the bytes to the chosen
        // location itself, so there's no manual file write here.
        final saved = await FilePicker.saveFile(
          dialogTitle: 'Save your Aluta backup',
          fileName: name,
          bytes: bytes,
        );
        if (kIsWeb) {
          _toast('Backup downloaded — keep it safe', ToastType.success);
        } else if (saved != null) {
          _toast('Backup saved', ToastType.success);
        }
      } else {
        // Mobile: write a temp file and open the native share sheet.
        final dir = await getTemporaryDirectory();
        final f = File('${dir.path}/$name');
        await f.writeAsString(content);
        await SharePlus.instance.share(
          ShareParams(files: [XFile(f.path)], subject: 'Aluta backup'),
        );
        _toast('Backup ready — save it somewhere safe', ToastType.success);
      }
    } catch (_) {
      _toast('Could not create the backup', ToastType.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final pass = _pass.text.trim();
    if (pass.isEmpty) {
      _toast('Enter the passphrase this backup was made with', ToastType.info);
      return;
    }
    FilePickerResult? res;
    try {
      res = await FilePicker.pickFiles();
    } catch (_) {
      _toast('Could not open the file picker', ToastType.error);
      return;
    }
    if (res == null || res.files.isEmpty) return;
    String content;
    try {
      final bytes = await res.files.single.readAsBytes();
      content = utf8.decode(bytes);
    } catch (_) {
      _toast('Could not read that file', ToastType.error);
      return;
    }
    setState(() => _busy = true);
    try {
      final n = await LocalBackupService.instance.restoreBackup(content, pass);
      _toast('Restored $n items — reopen your chats & spaces to see them',
          ToastType.success);
    } catch (e) {
      _toast(e.toString().replaceAll('Exception: ', ''), ToastType.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppPopupShell(
      title: 'Backup & restore',
      icon: Icons.lock_rounded,
      // Same page shape as Profile: a full-width panel card between
      // the header and the footer / now-playing bar.
      edgeToEdge: true,
      builder: (context, isWide) {
        final scheme = Theme.of(context).colorScheme;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Your chats and Our Space live on THIS device. Make an '
                'encrypted backup to carry them to a new phone or recover after '
                'a reinstall — the server never keeps them for you. It also '
                'carries the keys to your 🔒 encrypted chats, so restoring '
                'opens them again.',
                style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              _cloudSection(scheme),
              const SizedBox(height: 18),
              Text('Or a backup file',
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant)),
              const SizedBox(height: 8),
              TextField(
                controller: _pass,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Backup passphrase',
                  helperText: 'You will need this exact passphrase to restore.',
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Radii.lg),
                    borderSide: BorderSide.none,
                  ),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _create,
                  icon: const Icon(Icons.save_alt_rounded, size: 18),
                  label: const Text('Create encrypted backup'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Radii.lg)),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _restore,
                  icon: const Icon(Icons.restore_rounded, size: 18),
                  label: const Text('Restore from a backup file'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(Radii.lg)),
                  ),
                ),
              ),
              if (_busy) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
              ],
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline_rounded,
                        size: 18, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Keep the file and passphrase safe. Without the '
                        'passphrase the backup cannot be opened — not even by us.',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
