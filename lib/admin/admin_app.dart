import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'admin_api.dart';
import 'admin_install.dart';
import 'admin_key.dart';
import 'admin_shell.dart';
import 'admin_widgets.dart';

/// Aluta Admin root: sign-in → (pending approval | recovery wait | first-time
/// recovery codes) → dashboard. The password is held in memory only while a
/// pending device waits, so approval can finish the sign-in hands-free.
class AdminApp extends StatefulWidget {
  const AdminApp({super.key});

  @override
  State<AdminApp> createState() => _AdminAppState();
}

class _AdminAppState extends State<AdminApp> {
  @override
  void initState() {
    super.initState();
    loadAdminTheme();
    AdminInstall.instance.init();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: adminThemeMode,
      builder: (context, mode, _) => MaterialApp(
        title: 'Aluta Admin',
        debugShowCheckedModeBanner: false,
        theme: adminTheme(Brightness.light),
        darkTheme: adminTheme(Brightness.dark),
        themeMode: mode,
        builder: (context, child) => Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => AdminApi.instance.touch(),
          child: child,
        ),
        home: const _AdminRoot(),
      ),
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
  bool _obscure = true;

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
        return _centered(_unsupportedCard());
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

  /// The Aluta welcome look: deep red → black gradient, a faint logo
  /// watermark, and the white logo disc — with a small shield for Admin.
  Widget _centered(Widget child) => Scaffold(
        backgroundColor: const Color(0xFF0B0505),
        body: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.lerp(kAdminRed, Colors.black, 0.25)!,
                      Color.lerp(kAdminRed, Colors.black, 0.62)!,
                      const Color(0xFF0B0505),
                    ],
                    stops: const [0.0, 0.55, 1.0],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: Center(
                child: FractionallySizedBox(
                  widthFactor: 0.9,
                  heightFactor: 0.9,
                  child: Opacity(
                    opacity: 0.06,
                    child: Image.asset(
                      'assets/images/logo.png',
                      fit: BoxFit.contain,
                      color: Colors.white,
                      colorBlendMode: BlendMode.srcIn,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: LayoutBuilder(builder: (context, c) {
                // Desktop: brand on the left, the card on the right, both
                // centred — everything fits on one screen, no scrolling.
                if (c.maxWidth >= 900) {
                  return Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 40, vertical: 24),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1080),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(child: _brandPanel()),
                            const SizedBox(width: 56),
                            SizedBox(
                              width: 440,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  child,
                                  const AdminInstallCard(onGradient: true),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }
                return Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 28),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Column(
                        children: [
                          _logo(),
                          const SizedBox(height: 18),
                          _wordmark(),
                          const SizedBox(height: 26),
                          child,
                          const AdminInstallCard(onGradient: true),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          ],
        ),
      );

  Widget _wordmark({bool left = false}) => Column(
        crossAxisAlignment:
            left ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          Text(
            'Aluta',
            style: TextStyle(
              color: Colors.white,
              fontSize: left ? 54 : 36,
              fontWeight: FontWeight.bold,
              letterSpacing: 3,
              height: 1.05,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'ADMIN',
            style: TextStyle(
              color: Colors.white.withAlpha(200),
              fontSize: left ? 15 : 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 6,
            ),
          ),
        ],
      );

  /// Left half on desktop: logo, wordmark and what keeps admin safe.
  Widget _brandPanel() {
    Widget point(IconData icon, String title, String body) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(30),
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: Colors.white.withAlpha(50)),
                ),
                child: Icon(icon, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(body,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13, height: 1.35)),
                  ],
                ),
              ),
            ],
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            _logo(),
            const SizedBox(width: 22),
            _wordmark(left: true),
          ],
        ),
        const SizedBox(height: 26),
        const Text(
          'Run Aluta without opening the server — metrics, people and plans in '
          'one place.',
          style: TextStyle(color: Colors.white, fontSize: 18, height: 1.4),
        ),
        const SizedBox(height: 28),
        point(Icons.verified_user_rounded, 'Approved devices only',
            'A password alone is never enough — new devices need a trusted one.'),
        point(Icons.notifications_active_rounded, 'You hear about everything',
            'Every new device, sign-in from a new network or lockout alerts you.'),
        point(Icons.lock_rounded, 'Lock it in one tap',
            '“Not me” ends every session until you change your password.'),
        point(Icons.receipt_long_rounded, 'Every action recorded',
            'The activity log shows who did what, from where, and when.'),
      ],
    );
  }

  Widget _logo() => SizedBox(
        width: 96,
        height: 96,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 96,
              height: 96,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(70),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Image.asset(
                'assets/images/logo.png',
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Icon(Icons.forum_rounded,
                    size: 44, color: kAdminRed),
              ),
            ),
            Positioned(
              right: -4,
              bottom: -2,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: kAdminRed,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2.5),
                ),
                child: const Icon(Icons.shield, size: 16, color: Colors.white),
              ),
            ),
          ],
        ),
      );

  /// Glass card like the Aluta sign-in screen.
  Widget _glass({required Widget child}) => Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(18),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withAlpha(40)),
        ),
        child: child,
      );

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? hint,
    bool obscure = false,
    Widget? suffix,
    TextInputType? keyboardType,
    TextInputAction? action,
    Iterable<String>? autofill,
    ValueChanged<String>? onSubmitted,
    TextCapitalization caps = TextCapitalization.none,
  }) {
    OutlineInputBorder b(Color c, [double w = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c, width: w),
        );
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      textInputAction: action,
      autofillHints: autofill,
      textCapitalization: caps,
      onSubmitted: onSubmitted,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(color: Colors.white70),
        hintStyle: const TextStyle(color: Colors.white38),
        prefixIcon: Icon(icon, color: Colors.white70, size: 20),
        suffixIcon: suffix,
        filled: true,
        fillColor: Colors.white.withAlpha(25),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        enabledBorder: b(Colors.white.withAlpha(60)),
        focusedBorder: b(Colors.white, 1.5),
      ),
    );
  }

  /// White pill (primary) or outline pill (secondary), as on the welcome page.
  Widget _pill(String label, VoidCallback? onPressed,
      {bool outline = false, bool busy = false}) {
    final shape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(28));
    const pad = EdgeInsets.symmetric(vertical: 15);
    final text = busy
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: kAdminRed))
        : Text(label);
    return SizedBox(
      width: double.infinity,
      child: outline
          ? OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(color: Colors.white.withAlpha(160), width: 1.5),
                padding: pad,
                shape: shape,
                textStyle:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              onPressed: onPressed,
              child: text,
            )
          : ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: kAdminRed,
                disabledBackgroundColor: Colors.white.withAlpha(140),
                padding: pad,
                shape: shape,
                elevation: 6,
                shadowColor: Colors.black.withAlpha(120),
                textStyle:
                    const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
              ),
              onPressed: onPressed,
              child: text,
            ),
    );
  }

  /// A clearly separate option tile (setup / recovery) — not a faint link.
  Widget _option({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool open,
    required VoidCallback onTap,
    bool highlight = false,
  }) {
    final accent = highlight ? Colors.white : Colors.white70;
    return Material(
      color: open
          ? Colors.white.withAlpha(30)
          : Colors.black.withAlpha(highlight ? 50 : 30),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: highlight
              ? Colors.white.withAlpha(open ? 200 : 120)
              : Colors.white.withAlpha(open ? 120 : 45),
          width: highlight ? 1.4 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: highlight ? kAdminRed : Colors.white.withAlpha(25),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            color: accent,
                            fontWeight: FontWeight.w700,
                            fontSize: 14)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12)),
                  ],
                ),
              ),
              Icon(open ? Icons.expand_less : Icons.expand_more,
                  color: Colors.white60),
            ],
          ),
        ),
      ),
    );
  }

  Widget _orDivider() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Expanded(child: Divider(color: Colors.white.withAlpha(50))),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text('OR',
                  style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w600)),
            ),
            Expanded(child: Divider(color: Colors.white.withAlpha(50))),
          ],
        ),
      );

  Widget _heading(String title, String body) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 19,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(body, style: const TextStyle(color: Colors.white70)),
        ],
      );

  Widget _signInCard() {
    return _glass(
      child: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _heading('Owner sign-in',
                'A new device must be approved from one you already trust.'),
            const SizedBox(height: 18),
            _field(
              controller: _email,
              label: 'Aluta email',
              icon: Icons.email_outlined,
              keyboardType: TextInputType.emailAddress,
              action: TextInputAction.next,
              autofill: const [AutofillHints.email],
            ),
            const SizedBox(height: 14),
            _field(
              controller: _password,
              label: 'Password',
              icon: Icons.lock_outline,
              obscure: _obscure,
              action: TextInputAction.done,
              autofill: const [AutofillHints.password],
              onSubmitted: (_) => _submit(),
              suffix: IconButton(
                tooltip: _obscure ? 'Show password' : 'Hide password',
                icon: Icon(
                  _obscure ? Icons.visibility_off : Icons.visibility,
                  color: Colors.white70,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            const SizedBox(height: 14),
            _field(
              controller: _deviceName,
              label: 'Name this device (optional)',
              hint: 'e.g. Office PC',
              icon: Icons.devices_outlined,
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              AdminInline(text: _error!, error: true),
            ],
            if (_info != null) ...[
              const SizedBox(height: 14),
              AdminInline(text: _info!),
            ],
            const SizedBox(height: 20),
            _pill('Sign in', _busy ? null : () => _submit(), busy: _busy),
            _orDivider(),
            _option(
              icon: Icons.vpn_key_rounded,
              title: 'First device? Use the setup code',
              subtitle: 'Your very first admin device — with the code from '
                  'Railway (ADMIN_BOOTSTRAP_CODE).',
              open: _showSetup,
              highlight: true,
              onTap: () => setState(() => _showSetup = !_showSetup),
            ),
            if (_showSetup) ...[
              const SizedBox(height: 12),
              _field(
                controller: _bootstrap,
                label: 'Setup code',
                hint: 'ADMIN_BOOTSTRAP_CODE from Railway',
                icon: Icons.vpn_key_outlined,
              ),
              const SizedBox(height: 10),
              _pill('Set up this device',
                  _busy ? null : () => _submit(setup: true),
                  outline: true),
            ],
            const SizedBox(height: 10),
            _option(
              icon: Icons.restore_rounded,
              title: 'Lost every trusted device?',
              subtitle: 'Use one of your 10 recovery codes (72-hour wait).',
              open: _showRecovery,
              onTap: () => setState(() => _showRecovery = !_showRecovery),
            ),
            if (_showRecovery) ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 12, 4, 10),
                child: Text(
                  'A recovery code enrolls this device after 72 hours. You’ll '
                  'be alerted the whole time and can cancel it.',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ),
              _field(
                controller: _recovery,
                label: 'Recovery code',
                hint: 'XXXX-XXXX',
                icon: Icons.key_outlined,
                caps: TextCapitalization.characters,
              ),
              const SizedBox(height: 10),
              _pill('Start recovery',
                  _busy ? null : () => _submit(recovery: true),
                  outline: true),
            ],
          ],
        ),
      ),
    );
  }

  Widget _pendingCard() {
    final code = _pairCode ?? '------';
    return _glass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(
            'Waiting for approval',
            _noTrusted
                ? 'No admin device is trusted yet. Go back and use the setup '
                    'code for your first device.'
                : 'On a device you already trust, open Devices → this '
                    'request, and type this code with your password:',
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(60),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Center(
              child: SelectableText(
                '${code.substring(0, 3)} ${code.substring(3)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 40,
                  letterSpacing: 6,
                  fontWeight: FontWeight.w800,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text('Expires in 10 minutes · 3 wrong tries cancel it',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
          ),
          if (_pendingNote != null) ...[
            const SizedBox(height: 12),
            AdminInline(text: _pendingNote!),
          ],
          const SizedBox(height: 20),
          if (_noTrusted) ...[
            _pill('Use the setup code instead', () {
              _cancelPending();
              setState(() => _showSetup = true);
            }),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              Expanded(child: _pill('Cancel', _cancelPending, outline: true)),
              const SizedBox(width: 12),
              Expanded(
                child: _pill(
                  'New code',
                  _busy
                      ? null
                      : () {
                          _poll?.cancel();
                          _submit();
                        },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _recoveringCard() {
    return _glass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.hourglass_top, size: 34, color: Colors.white),
          const SizedBox(height: 10),
          _heading(
            'Recovery started',
            'For your safety this device becomes an admin device only after '
                '72 hours. The owner is alerted now and every day; any trusted '
                'device can cancel it.',
          ),
          const SizedBox(height: 14),
          if (_activateAt != null)
            AdminInline(text: 'Ready from ${fmtDateTime(_activateAt)}'),
          const SizedBox(height: 18),
          _pill('Back to sign-in', () => setState(() => _stage = _Stage.signIn)),
        ],
      ),
    );
  }

  Widget _codesCard() {
    return _glass(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(
            'Save your recovery codes',
            'Shown only once. Write them down and keep them offline. Each '
                'works once, if you ever lose every trusted device.',
          ),
          const SizedBox(height: 14),
          AdminCodesGrid(codes: _codes),
          const SizedBox(height: 12),
          _pill('Copy all', () {
            Clipboard.setData(ClipboardData(text: _codes.join('\n')));
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Codes copied')));
          }, outline: true),
          const SizedBox(height: 8),
          CheckboxListTile(
            value: _savedCodes,
            onChanged: (v) => setState(() => _savedCodes = v ?? false),
            contentPadding: EdgeInsets.zero,
            checkColor: kAdminRed,
            fillColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.selected)
                    ? Colors.white
                    : Colors.transparent),
            side: const BorderSide(color: Colors.white70, width: 1.5),
            title: const Text('I’ve saved them somewhere safe',
                style: TextStyle(color: Colors.white)),
          ),
          const SizedBox(height: 8),
          const AdminInline(
            text: 'Now remove ADMIN_BOOTSTRAP_CODE from your Railway '
                'variables — it can’t be used again anyway.',
          ),
          const SizedBox(height: 16),
          _pill(
            'Continue',
            _savedCodes
                ? () {
                    final s = _session;
                    setState(() => _codes = const []);
                    if (s != null) _enterHome(s);
                  }
                : null,
          ),
        ],
      ),
    );
  }

  Widget _unsupportedCard() => _glass(
        child: _heading(
          'This browser can’t hold an admin key',
          'Open the admin panel over HTTPS in an up-to-date Chrome, Edge, '
              'Firefox or Safari (not a private window).',
        ),
      );
}
