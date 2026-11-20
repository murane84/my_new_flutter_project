import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../e2ee/seal_ingress.dart';
import '../e2ee/seal_verify.dart';
import '../utils/radii.dart';
import '../utils/readable.dart' show accentInk;
import '../utils/toast_helper.dart';

/// 🔒 Check a chat's encryption with your friend: both phones show the same
/// safety code, worked out from the two people's keys. Compare it side by
/// side (scan the other phone's code), or read the digits to each other on
/// a call. A match is remembered on this device until the code changes —
/// when either of you reinstalls Aluta or links / removes a device.
class VerifyEncryptionScreen extends StatefulWidget {
  const VerifyEncryptionScreen(
      {super.key, required this.friendId, required this.friendName});

  final int friendId;
  final String friendName;

  @override
  State<VerifyEncryptionScreen> createState() => _VerifyEncryptionScreenState();
}

class _VerifyEncryptionScreenState extends State<VerifyEncryptionScreen> {
  int? _me;
  SealVerifyState? _state;
  bool _loading = true;

  String get _first {
    final f = widget.friendName.trim().split(RegExp(r'\s+')).first;
    return f.isEmpty ? 'your friend' : f;
  }

  bool get _canScan =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final me = await SealIngress.myUid();
    if (me == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    _me = me;
    final quick = await SealVerifyStore.instance.cached(me, widget.friendId);
    if (mounted && quick.code != null) setState(() => _state = quick);
    final fresh = await SealVerifyStore.instance.refresh(me, widget.friendId);
    if (!mounted) return;
    setState(() {
      _state = fresh;
      _loading = false;
    });
  }

  Future<void> _confirmMatch() async {
    final code = _state?.code;
    final me = _me;
    if (code == null || me == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Do the codes match?'),
        content: Text('Only mark it if every digit on $_first’s screen is the '
            'same as yours — checked together, in person or on a call.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Not yet')),
          FilledButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text('They match')),
        ],
      ),
    );
    if (ok != true) return;
    await SealVerifyStore.instance.markVerified(me, widget.friendId, code);
    await _load();
    if (mounted) {
      showToast(context, 'Checked ✓ — your chat with $_first is verified',
          type: ToastType.success);
    }
  }

  Future<void> _scan() async {
    final code = _state?.code;
    final me = _me;
    if (code == null || me == null) return;
    final raw = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const _VerifyScanScreen()));
    if (raw == null || !mounted) return;
    final res = SealVerify.checkQr(raw, me, widget.friendId, code);
    if (res == true) {
      await SealVerifyStore.instance.markVerified(me, widget.friendId, code);
      await _load();
      if (mounted) {
        showToast(context, 'Codes match ✓ — your chat with $_first is verified',
            type: ToastType.success);
      }
    } else if (res == false) {
      await showDialog<void>(
        context: context,
        builder: (d) => AlertDialog(
          icon: const Icon(Icons.gpp_maybe_rounded),
          title: const Text('The codes don’t match'),
          content: Text(
              'Make sure both of you opened this check for each other and '
              'that Aluta is up to date on both phones, then try again. If '
              'they still differ, avoid sharing anything private with '
              '$_first here until they match.'),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(d), child: const Text('OK')),
          ],
        ),
      );
    } else {
      showToast(context, 'That isn’t $_first’s Aluta check code',
          type: ToastType.error);
    }
  }

  Future<void> _clear() async {
    final me = _me;
    if (me == null) return;
    await SealVerifyStore.instance.clearVerified(me, widget.friendId);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = _state;
    return Scaffold(
      appBar: AppBar(title: Text('Encryption with $_first')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          children: [
            _statusCard(scheme, s),
            const SizedBox(height: 18),
            if (s?.code != null) ...[
              _codeCard(scheme, s!.code!),
              const SizedBox(height: 16),
              _actions(scheme, s),
            ] else if (!_loading)
              _unavailable(scheme),
            if (_loading && s?.code == null)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              ),
            if ((s?.changes ?? const []).isNotEmpty) ...[
              const SizedBox(height: 24),
              _history(scheme, s!.changes),
            ],
            const SizedBox(height: 24),
            Text(
              'Your messages, photos, voice notes and files with $_first are '
              'locked on your phones. This code comes from both of your '
              'devices’ keys: if it matches on both screens, nobody else’s '
              'device is in this chat. It changes when either of you '
              'reinstalls Aluta or links or removes a device.',
              style: TextStyle(
                  fontSize: 12.5, height: 1.45, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusCard(ColorScheme scheme, SealVerifyState? s) {
    final verified = s?.verified == true;
    final changed = !verified && s?.checkedBefore == true;
    final (IconData icon, Color tint, String title, String sub) = verified
        ? (
            Icons.verified_user_rounded,
            const Color(0xFF2E9E6B),
            'Verified by you',
            'You checked this code with $_first · '
                '${DateFormat('d MMM y').format(s!.verifiedAt!.toLocal())}',
          )
        : changed
            ? (
                Icons.gpp_maybe_rounded,
                const Color(0xFFD08A1E),
                'Code changed since you checked',
                'Check it with $_first again to keep the chat verified.',
              )
            : (
                Icons.lock_rounded,
                accentInk(scheme),
                'End-to-end encrypted',
                'Not checked together yet — compare the code below with '
                    '$_first.',
              );
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.xl),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
                shape: BoxShape.circle, color: tint.withValues(alpha: 0.18)),
            child: Icon(icon, color: tint),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(sub,
                    style: TextStyle(
                        fontSize: 13, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _codeCard(ColorScheme scheme, String code) {
    final g = SealVerify.groups(code);
    final me = _me ?? 0;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.xl),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(Radii.lg),
            ),
            child: QrImageView(
              data: SealVerify.qrFor(me, widget.friendId, code),
              version: QrVersions.auto,
              size: 180,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onLongPress: () {
              Clipboard.setData(ClipboardData(text: g.join(' ')));
              showToast(context, 'Code copied');
            },
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 14,
              runSpacing: 8,
              children: [
                for (final x in g)
                  Text(x,
                      style: const TextStyle(
                          fontSize: 19,
                          fontFeatures: [FontFeature.tabularFigures()],
                          letterSpacing: 1.5,
                          fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text('$_first sees the same code for this chat.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _actions(ColorScheme scheme, SealVerifyState s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_canScan)
          FilledButton.icon(
            onPressed: _scan,
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: Text('Scan $_first’s code'),
          ),
        if (_canScan) const SizedBox(height: 8),
        if (!s.verified)
          OutlinedButton.icon(
            onPressed: _confirmMatch,
            icon: const Icon(Icons.done_all_rounded),
            label: const Text('We compared the numbers — they match'),
          )
        else
          TextButton(
            onPressed: _clear,
            child: const Text('Remove verification'),
          ),
      ],
    );
  }

  Widget _unavailable(ColorScheme scheme) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(Radii.xl),
        ),
        child: Column(
          children: [
            Icon(Icons.cloud_off_rounded, color: scheme.onSurfaceVariant),
            const SizedBox(height: 8),
            Text(
                'Can’t show the code right now — check your connection. (If '
                '$_first is on an older Aluta, the chat isn’t encrypted yet.)',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 10),
            TextButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      );

  Widget _history(ColorScheme scheme, List<SealCodeChange> changes) {
    final fmt = DateFormat('d MMM y, HH:mm');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Code changes',
            style: TextStyle(
                fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        for (final c in changes.reversed.take(6))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(Icons.sync_lock_rounded,
                    size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    // Same words as the note in the chat.
                    '${c.mine ? 'You' : _first} changed devices · '
                    '${fmt.format(c.at.toLocal())}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Camera page that returns the first Aluta check code it sees.
class _VerifyScanScreen extends StatefulWidget {
  const _VerifyScanScreen();

  @override
  State<_VerifyScanScreen> createState() => _VerifyScanScreenState();
}

class _VerifyScanScreenState extends State<_VerifyScanScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final v = b.rawValue;
      if (v != null && v.startsWith(SealVerify.qrPrefix)) {
        _done = true;
        Navigator.of(context).pop(v);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan their code')),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                MobileScanner(controller: _controller, onDetect: _onDetect),
                Container(
                  width: 240,
                  height: 240,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white, width: 3),
                    borderRadius: BorderRadius.circular(Radii.xl),
                  ),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(18),
            child: Text(
              'On their phone: open your chat → tap the 🔒 note → their code '
              'shows. Point your camera at it.',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
