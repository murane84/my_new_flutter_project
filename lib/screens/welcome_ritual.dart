import 'package:flutter/material.dart';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../services/haptics.dart';
import '../services/keystroke_sounds.dart';
import '../utils/net_image.dart';
import 'spinning_vinyl_ring.dart';
import 'token_helper.dart' show mediaAuthHeaders;

/// 🌍 The first-open ritual (brand strategy: "arriving somewhere").
///
/// Shown once, on a brand-new account's first open, before the consent
/// screen: the turning vinyl, "Karibu Aluta", the promise, and one action —
/// Find my people. [inviter]: who brought them here ("Asha brought you
/// here"), when they came through someone's invitation.
///
/// Returns true when they tapped Find my people.
/// [inviterPhoto]: their photo (full URL) — it fills the turning ring, so
/// the first face a new member sees is the person who brought them.
Future<bool> showWelcomeRitual(BuildContext context,
    {String? inviter, String? inviterPhoto}) async {
  final r = await Navigator.of(context).push<bool>(PageRouteBuilder(
    opaque: true,
    fullscreenDialog: true,
    transitionDuration: const Duration(milliseconds: 600),
    pageBuilder: (_, _, _) =>
        _WelcomeRitual(inviter: inviter, inviterPhoto: inviterPhoto),
    transitionsBuilder: (_, a, _, child) =>
        FadeTransition(opacity: a, child: child),
  ));
  return r == true;
}

class _WelcomeRitual extends StatefulWidget {
  const _WelcomeRitual({this.inviter, this.inviterPhoto});
  final String? inviter;
  final String? inviterPhoto;

  @override
  State<_WelcomeRitual> createState() => _WelcomeRitualState();
}

class _WelcomeRitualState extends State<_WelcomeRitual>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 4200))
    ..forward();

  // Each line arrives in its own moment.
  Animation<double> _at(double from, double to) => CurvedAnimation(
      parent: _c, curve: Interval(from, to, curve: Curves.easeOutCubic));

  @override
  void initState() {
    super.initState();
    Haptics.lightImpact();
    // One soft note as the ring starts turning — Aluta's own message tone
    // (it follows the "message tones" setting; browsers stay silent until a
    // tap anyway, so the web skips it).
    if (!kIsWeb) {
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) KeystrokeSounds.instance.playReceived();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _line(Animation<double> a, Widget child) => FadeTransition(
        opacity: a,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.25), end: Offset.zero)
              .animate(a),
          child: child,
        ),
      );

  /// The inviter's face when they came through someone; else Aluta's mark.
  ImageProvider _ringImage() {
    final u = (widget.inviterPhoto ?? '').trim();
    if (u.isEmpty) return const AssetImage('assets/images/logo.png');
    return authNetworkImageProvider(u, mediaAuthHeaders(u));
  }

  @override
  Widget build(BuildContext context) {
    const ink = Colors.white;
    final quiet = Colors.white.withAlpha(185);
    const accent = Color(0xFFFF5A5F);
    final who = (widget.inviter ?? '').trim();
    return PopScope(
      canPop: false, // one way through: the promise, then their people
      child: Scaffold(
        backgroundColor: const Color(0xFF120A0E),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _line(
                      _at(0.0, 0.25),
                      SizedBox(
                        width: 128,
                        height: 128,
                        child: SpinningVinylRing(
                          ring: 5,
                          color: accent,
                          child: ClipOval(
                            child: Image(
                                image: _ringImage(),
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => Image.asset(
                                    'assets/images/logo.png',
                                    fit: BoxFit.cover)),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                    _line(
                      _at(0.15, 0.4),
                      const Text('Karibu Aluta',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: ink,
                              fontSize: 30,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6)),
                    ),
                    const SizedBox(height: 8),
                    _line(
                      _at(0.3, 0.55),
                      Text('A place for your people · Mahali pa watu wako',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: quiet,
                              fontSize: 14.5,
                              fontStyle: FontStyle.italic)),
                    ),
                    if (who.isNotEmpty) ...[
                      const SizedBox(height: 22),
                      _line(
                        _at(0.45, 0.7),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: accent.withAlpha(40),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: accent.withAlpha(120)),
                          ),
                          child: Text('$who brought you here 💞',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: ink,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                    const SizedBox(height: 28),
                    _line(
                      _at(0.55, 0.8),
                      Text(
                          'Here, nobody reaches you unless you’ve chosen '
                          'each other — and not even we can read your words.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: quiet, fontSize: 14, height: 1.5)),
                    ),
                    const SizedBox(height: 36),
                    _line(
                      _at(0.75, 1.0),
                      Column(children: [
                        SizedBox(
                          width: 240,
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: accent,
                              foregroundColor: Colors.white,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 16),
                            ),
                            onPressed: () {
                              Haptics.selectionClick();
                              Navigator.of(context).pop(true);
                            },
                            icon: const Icon(Icons.people_alt_rounded),
                            label: const Text('Find my people',
                                style: TextStyle(
                                    fontSize: 15.5,
                                    fontWeight: FontWeight.w700)),
                          ),
                        ),
                        const SizedBox(height: 6),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: Text('Later',
                              style: TextStyle(color: quiet)),
                        ),
                      ]),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
