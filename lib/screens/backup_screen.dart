import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/local_backup_service.dart';
import '../utils/popup_shell.dart';
import '../utils/toast_helper.dart';

/// Encrypted backup & restore of the device's local history — the safety net
/// for the "server stores almost nothing" model, so a new device or a reinstall
/// doesn't lose your chats and Our Space. The backup is a single encrypted file
/// only your passphrase can open.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final TextEditingController _pass = TextEditingController();
  bool _obscure = true;
  bool _busy = false;

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
    if (pass.length < 4) {
      _toast('Choose a passphrase of at least 4 characters', ToastType.info);
      return;
    }
    setState(() => _busy = true);
    try {
      final content = await LocalBackupService.instance.createBackup(pass);
      final dir = await getTemporaryDirectory();
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-')
          .substring(0, 19);
      final f = File('${dir.path}/aluta-backup-$ts.alutabak');
      await f.writeAsString(content);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(f.path)], subject: 'Aluta backup'),
      );
      _toast('Backup ready — save it somewhere safe', ToastType.success);
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
                'a reinstall — the server never keeps them for you.',
                style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _pass,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Backup passphrase',
                  helperText: 'You will need this exact passphrase to restore.',
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
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
                        borderRadius: BorderRadius.circular(14)),
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
                        borderRadius: BorderRadius.circular(14)),
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
                  borderRadius: BorderRadius.circular(12),
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
