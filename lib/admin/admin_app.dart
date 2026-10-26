import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'admin_api.dart';
import 'admin_key.dart';
import 'admin_shell.dart';
import 'admin_widgets.dart';

/// Aluta Admin root: sign-in → (pending approval | recovery wait | first-time
/// recovery codes) → dashboard. The password is held in memory only while a
/// pending device waits, so approval can finish the sign-in hands-free.
class AdminApp extends StatelessWidget {
  const AdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: kAdminRed,
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'Aluta Admin',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0F0F14),
        cardTheme: const CardThemeData(
          color: Color(0xFF1B1B24),
          elevation: 0,
          margin: EdgeInsets.zero,
        ),
      ),
      builder: (context, child) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => AdminApi.instance.touch(),
        child: child,
      ),
      home: const _AdminRoot(),
    );
  }
}

enum _Stage { checking, unsupported, signIn, pending, recovering, codes, home }

class _AdminRoot extends StatefulWidget {
  const _AdminRoot();

  @override
  State<_AdminRoot> createState() => _AdminRootState();
}

class _AdminRootState extends State<_AdminRoot> {
  final _api = AdminApi.instance;
  _Stage _stage = _Stage.checking;

  final _email = TextEditingController();
  final _password = TextEditingController();
  final _deviceName = TextEditingController();
  final _bootstrap = TextEditingController();
  final _recovery = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _info;
  bool _showSetup = false;
  bool _showRecovery = false;

  // Pending / recovering
  String? _pairCode;
  int? _pendingId;
  bool _noTrusted = false;
  String? _activateAt;
  Timer? _poll;
  String? _pendingNote;

  // First-time codes
  List<String> _codes = const [];
  bool _savedCodes = false;

  Map<String, dynamic>? _session;

  @override
  void initState() {
    super.initState();
    _api.sessionEnded.addListener(_onSessionEnded);
    _check();
  }

  Future<void> _check() async {
    final ok = await AdminKey.supported();
    if (!mounted) return;
    if (ok) await AdminKey.persist();
    if (!mounted) return;
    setState(() => _stage = ok ? _Stage.signIn : _Stage.unsupported);
  }

  void _onSessionEnded() {
    final why = _api.sessionEnded.value;
    if (why == null || !mounted) return;
    setState(() {
      _stage = _Stage.signIn;
      _session = null;
      _info = 'Signed out: $why';
    });
  }

  @override
  void dispose() {
    _api.sessionEnded.removeListener(_onSessionEnded);
    _poll?.cancel();
    for (final c in [_email, _password, _deviceName, _bootstrap, _recovery]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit({bool setup = false, bool recovery = false}) async {
    if (_busy) return;
    final email = _email.text.trim();
    final pw = _password.text;
    if (email.isEmpty || pw.isEmpty) {
      setState(() => _error = 'Enter your Aluta email and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      final res = await _api.login(
        email: email,
        password: pw,
        deviceName: _deviceName.text.trim(),
        bootstrapCode: setup ? _bootstrap.text.trim() : null,
        recoveryCode: recovery ? _recovery.text.trim() : null,
      );
      await _handleLogin(res);
    } on AdminApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not reach the server.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleLogin(Map<String, dynamic> res) async {
    final status = (res['status'] ?? '').toString();
    switch (status) {
      case 'challenge':
        final s = await _api.verify(
            res['challenge_id'] as String, res['nonce'] as String);
        _enterHome(s);
        break;
      case 'bootstrapped':
        final s = await _api.verify(
            res['challenge_id'] as String, res['nonce'] as String);
        _session = s;
        _password.clear();
        _bootstrap.clear();
        if (!mounted) return;
        setState(() {
          _codes = List<String>.from(res['recovery_codes'] as List? ?? const []);
          _savedCodes = false;
          _stage = _Stage.codes;
        });
        break;
      case 'pending':
        if (!mounted) return;
        setState(() {
          _pairCode = res['pair_code']?.toString();
          _pendingId = res['device_id'] as int?;
          _noTrusted = res['no_trusted_device'] == true;
          _pendingNote = null;
          _stage = _Stage.pending;
        });
        _startPolling();
        break;
      case 'recovering':
        _password.clear();
        _recovery.clear();
        if (!mounted) return;
        setState(() {
          _activateAt = res['activate_at']?.toString();
          _stage = _Stage.recovering;
        });
        break;
      default:
        if (mounted) setState(() => _error = 'Unexpected answer from server.');
    }
  }

  void _enterHome(Map<String, dynamic> session) {
    _poll?.cancel();
    _password.clear();
    if (!mounted) return;
    setState(() {
      _session = session;
      _stage = _Stage.home;
      _error = null;
      _info = null;
    });
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _pollOnce());
  }

  Future<void> _pollOnce() async {
    final id = _pendingId;
    if (id == null || _stage != _Stage.pending) return;
    try {
      final st = await _api.poll(id);
      if (!mounted) return;
      if (st == 'trusted') {
        _poll?.cancel();
        setState(() => _pendingNote = 'Approved — signing you in…');
        final res = await _api.login(
          email: _email.text.trim(),
          password: _password.text,
          deviceName: _deviceName.text.trim(),
        );
        await _handleLogin(res);
      } else if (st == 'denied' || st == 'revoked') {
        _poll?.cancel();
        _password.clear();
        setState(() {
          _stage = _Stage.signIn;
          _error = 'This device was not approved.';
        });
      } else if (st == 'expired') {
        _poll?.cancel();
        setState(() => _pendingNote =
            'The code expired. Request a new one to try again.');
      }
    } on AdminApiException catch (e) {
      if (mounted) setState(() => _pendingNote = e.message);
    } catch (_) {/* network blip — keep polling */}
  }

  void _cancelPending() {
    _poll?.cancel();
    _password.clear();
    setState(() {
      _stage = _Stage.signIn;
      _pairCode = null;
      _pendingId = null;
    });
  }

  Future<void> _signOut() async {
    await _api.logout();
    if (!mounted) return;
    setState(() {
      _session = null;
      _stage = _Stage.signIn;
      _info = 'Signed out.';
    });
  }

  @override
  Widget build(BuildContext context) {
    switch (_stage) {
      case _Stage.checking:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case _Stage.unsupported:
        return _centered(const AdminNotice(
          icon: Icons.gpp_bad_outlined,
          title: 'This browser can’t hold an admin key',
          body: 'Open the admin panel over HTTPS in an up-to-date Chrome, Edge, '
              'Firefox or Safari (not a private window).',
        ));
      case _Stage.signIn:
        return _centered(_signInCard());
      case _Stage.pending:
        return _centered(_pendingCard());
      case _Stage.recovering:
        return _centered(_recoveringCard());
      case _Stage.codes:
        return _centered(_codesCard());
      case _Stage.home:
        return AdminShell(
          session: _session ?? const {},
          onSignOut: _signOut,
        );
    }
  }

  Widget _centered(Widget child) => Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: child,
              ),
            ),
          ),
        ),
      );

  Widget _brand() => Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: kAdminRed,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.shield_outlined, color: Colors.white),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text('Aluta Admin',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          ),
        ],
      );

  Widget _signInCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _brand(),
              const SizedBox(height: 6),
              const Text(
                'Owner sign-in. A new device must be approved from one you '
                'already trust.',
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(
                    labelText: 'Aluta email', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                    labelText: 'Password', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _deviceName,
                decoration: const InputDecoration(
                  labelText: 'Name this device (optional)',
                  hintText: 'e.g. Office PC',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                AdminInline(text: _error!, error: true),
              ],
              if (_info != null) ...[
                const SizedBox(height: 12),
                AdminInline(text: _info!),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : () => _submit(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Sign in'),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => setState(() => _showSetup = !_showSetup),
                child: const Text('First device? Use the setup code'),
              ),
              if (_showSetup) ...[
                TextField(
                  controller: _bootstrap,
                  decoration: const InputDecoration(
                    labelText: 'Setup code (ADMIN_BOOTSTRAP_CODE)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _busy ? null : () => _submit(setup: true),
                  child: const Text('Set up this device'),
                ),
              ],
              TextButton(
                onPressed: () => setState(() => _showRecovery = !_showRecovery),
                child: const Text('Lost every trusted device? Use a recovery code'),
              ),
              if (_showRecovery) ...[
                const Text(
                  'A recovery code enrolls this device after 72 hours. You’ll '
                  'be alerted the whole time and can cancel it.',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _recovery,
                  decoration: const InputDecoration(
                    labelText: 'Recovery code (XXXX-XXXX)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _busy ? null : () => _submit(recovery: true),
                  child: const Text('Start recovery'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _pendingCard() {
    final code = _pairCode ?? '------';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _brand(),
            const SizedBox(height: 16),
            const Text('Waiting for approval',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              _noTrusted
                  ? 'No admin device is trusted yet. Go back and use the setup '
                      'code for your first device.'
                  : 'On a device you already trust, open Devices → this '
                      'request, and type this code with your password:',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 18),
            Center(
              child: SelectableText(
                '${code.substring(0, 3)} ${code.substring(3)}',
                style: const TextStyle(
                  fontSize: 40,
                  letterSpacing: 6,
                  fontWeight: FontWeight.w800,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(height: 6),
            const Center(
              child: Text('Expires in 10 minutes · 3 wrong tries cancel it',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
            ),
            if (_pendingNote != null) ...[
              const SizedBox(height: 12),
              AdminInline(text: _pendingNote!),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _cancelPending,
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _busy
                        ? null
                        : () {
                            _poll?.cancel();
                            _submit();
                          },
                    child: const Text('New code'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _recoveringCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _brand(),
            const SizedBox(height: 16),
            const AdminNotice(
              icon: Icons.hourglass_top,
              title: 'Recovery started',
              body: 'For your safety this device becomes an admin device only '
                  'after 72 hours. The owner is alerted now and every day; any '
                  'trusted device can cancel it.',
            ),
            const SizedBox(height: 12),
            if (_activateAt != null)
              AdminInline(text: 'Ready from ${fmtDateTime(_activateAt)}'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => setState(() => _stage = _Stage.signIn),
              child: const Text('Back to sign-in'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _codesCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _brand(),
            const SizedBox(height: 16),
            const Text('Save your recovery codes',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text(
              'Shown only once. Write them down and keep them offline. Each '
              'works once, if you ever lose every trusted device.',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 14),
            AdminCodesGrid(codes: _codes),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _codes.join('\n')));
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Codes copied')));
              },
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy all'),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _savedCodes,
              onChanged: (v) => setState(() => _savedCodes = v ?? false),
              contentPadding: EdgeInsets.zero,
              title: const Text('I’ve saved them somewhere safe'),
            ),
            const SizedBox(height: 8),
            const AdminInline(
              text: 'Now remove ADMIN_BOOTSTRAP_CODE from your Railway '
                  'variables — it can’t be used again anyway.',
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _savedCodes
                  ? () {
                      final s = _session;
                      setState(() => _codes = const []);
                      if (s != null) _enterHome(s);
                    }
                  : null,
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }
}
