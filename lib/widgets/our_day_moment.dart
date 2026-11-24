import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/haptics.dart';

/// 💞 "Our day" (brand strategy: a bond accepted is a moment, not a toast).
///
/// Two rings drift together and lock; the date is named — the day Aluta
/// will remember for them. Shown on both phones: the one that accepted, and
/// the one whose request was accepted. Then the first private moment: choose
/// the song that is theirs. Returns 'song' (choose our song), 'space' (open
/// Our Space) or null (dismissed).
Future<String?> showOurDay(BuildContext context,
    {required String partner, DateTime? date}) {
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Our day',
    barrierColor: Colors.black.withAlpha(190),
    transitionDuration: const Duration(milliseconds: 380),
    pageBuilder: (_, _, _) =>
        _OurDay(partner: partner, date: date ?? DateTime.now()),
    transitionBuilder: (_, a, _, child) => FadeTransition(
        opacity: a,
        child: ScaleTransition(
            scale: Tween(begin: 0.94, end: 1.0)
                .animate(CurvedAnimation(parent: a, curve: Curves.easeOut)),
            child: child)),
  );
}

class _OurDay extends StatefulWidget {
  const _OurDay({required this.partner, required this.date});
  final String partner;
  final DateTime date;

  @override
  State<_OurDay> createState() => _OurDayState();
}

class _OurDayState extends State<_OurDay> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1600))
    ..forward().whenComplete(Haptics.mediumImpact);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFFFF5A5F);
    final name = widget.partner.trim().isEmpty ? 'them' : widget.partner.trim();
    final day = DateFormat('d MMMM yyyy').format(widget.date);
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 200,
                height: 110,
                child: AnimatedBuilder(
                  animation: _c,
                  builder: (_, _) {
                    final t = Curves.easeInOutCubic.transform(_c.value);
                    final off = (1 - t) * 46; // apart → overlapping
                    Widget ring(double dx, double rot) => Transform.translate(
                          offset: Offset(dx, 0),
                          child: Transform.rotate(
                            angle: rot,
                            child: Container(
                              width: 78,
                              height: 78,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: accent, width: 6),
                                boxShadow: [
                                  BoxShadow(
                                      color: accent.withAlpha(
                                          (90 * t).round()),
                                      blurRadius: 24 * t),
                                ],
                              ),
                            ),
                          ),
                        );
                    return Stack(alignment: Alignment.center, children: [
                      ring(-22 - off, -math.pi * t),
                      ring(22 + off, math.pi * t),
                    ]);
                  },
                ),
              ),
              const SizedBox(height: 22),
              FadeTransition(
                opacity: CurvedAnimation(
                    parent: _c, curve: const Interval(0.6, 1.0)),
                child: Column(children: [
                  Text('You and $name',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text('Bonded · $day',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.white.withAlpha(215),
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 14),
                  Text(
                      'Today is your day. Aluta will remember it.\n'
                      'Leo ni siku yenu.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.white.withAlpha(185),
                          fontSize: 13.5,
                          height: 1.5)),
                  const SizedBox(height: 12),
                  // Names the bond's signature: their record turning in the
                  // chat when they write (only bonded people see it).
                  Text(
                      "Now you'll see their record turn when they write to you.\n"
                      'Sasa utaona rekodi yao ikizunguka wanapokuandikia.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.white.withAlpha(160),
                          fontSize: 12.5,
                          fontStyle: FontStyle.italic,
                          height: 1.5)),
                  const SizedBox(height: 22),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: accent,
                        foregroundColor: Colors.white),
                    onPressed: () => Navigator.of(context).pop('song'),
                    icon: const Icon(Icons.music_note_rounded),
                    label: const Text('Choose our song'),
                  ),
                  const SizedBox(height: 6),
                  TextButton(
                    style: TextButton.styleFrom(
                        foregroundColor: Colors.white.withAlpha(200)),
                    onPressed: () => Navigator.of(context).pop('space'),
                    child: const Text('Open our Space'),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
