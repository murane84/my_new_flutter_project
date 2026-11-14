import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/api_service.dart';
import '../services/text_style_pref.dart';
import '../utils/motion.dart';
import '../utils/radii.dart';
import '../utils/session_events.dart';
import '../utils/toast_helper.dart';

/// Shared Harmony: one Together subscriber makes the place they share
/// beautiful for everyone in it — Our Space (my partner), Listen Together
/// (the host), a call (the caller / the group call's starter).
///
/// Only THIS screen turns to Harmony (never my whole app); a quiet credit
/// line shows once ("In Harmony · shared by Juma"), and when I leave, one
/// gentle line offers it everywhere — once per person per app run.
/// Nothing changes when my own text style is already Harmony.
class SharedHarmony extends StatefulWidget {
  const SharedHarmony({
    super.key,
    required this.ownerId,
    required this.ownerName,
    required this.child,
  });

  /// Whose plan counts (null = nobody else's — e.g. I host / I called).
  final int? ownerId;
  final String ownerName;
  final Widget child;

  @override
  State<SharedHarmony> createState() => _SharedHarmonyState();
}

class _SharedHarmonyState extends State<SharedHarmony> {
  static final Map<int, (bool, DateTime)> _cache = {};
  static final Set<int> _farewelled = {};

  bool _on = false;
  bool _credit = false;
  Timer? _creditTimer;
  BuildContext? _root;

  bool get _mineAlready =>
      TextStylePref.instance.shown.value == AlutaFont.harmony;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void didUpdateWidget(SharedHarmony old) {
    super.didUpdateWidget(old);
    if (old.ownerId != widget.ownerId) _check();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _root = Navigator.maybeOf(context, rootNavigator: true)?.context;
  }

  Future<void> _check() async {
    final id = widget.ownerId;
    if (id == null || _mineAlready) {
      if (_on && mounted) setState(() => _on = false);
      return;
    }
    final hit = _cache[id];
    bool on;
    if (hit != null &&
        DateTime.now().difference(hit.$2) < const Duration(minutes: 10)) {
      on = hit.$1;
    } else {
      final r = await ApiService().sharedHarmony([id]);
      on = r['$id'] == true;
      _cache[id] = (on, DateTime.now());
    }
    if (!mounted || widget.ownerId != id || on == _on) return;
    setState(() {
      _on = on;
      _credit = on;
    });
    _creditTimer?.cancel();
    if (on) {
      _creditTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _credit = false);
      });
    }
  }

  @override
  void dispose() {
    _creditTimer?.cancel();
    final id = widget.ownerId;
    final root = _root;
    if (_on &&
        id != null &&
        !_mineAlready &&
        _farewelled.add(id) &&
        root != null &&
        root.mounted) {
      final open = SessionEvents.instance.openPlans;
      Future.microtask(() {
        if (!root.mounted) return;
        showToast(root, 'Liked Harmony? Get it everywhere with Aluta Together',
            type: ToastType.info,
            duration: const Duration(seconds: 5),
            actions: [if (open != null) ToastAction('See plans', open)]);
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_on) return widget.child;
    final base = Theme.of(context);
    final scheme = base.colorScheme;
    final name = widget.ownerName.trim().isEmpty
        ? 'your friend'
        : widget.ownerName.trim().split(RegExp(r'\s+')).first;
    return Theme(
      data: TextStylePref.apply(base, AlutaFont.harmony),
      child: Stack(
        children: [
          widget.child,
          Positioned(
            top: MediaQuery.paddingOf(context).top + 10,
            left: 16,
            right: 16,
            child: IgnorePointer(
              ignoring: !_credit,
              child: AnimatedOpacity(
                opacity: _credit ? 1 : 0,
                duration: Motion.standard,
                child: Center(
                  child: Material(
                    color: scheme.surfaceContainerHighest,
                    elevation: 3,
                    borderRadius: BorderRadius.circular(Radii.lg),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(Radii.lg),
                      onTap: () {
                        setState(() => _credit = false);
                        SessionEvents.instance.openPlans?.call();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 7),
                        child: Text('In Harmony · shared by $name',
                            style: TextStyle(
                                fontFamily: 'HarmonyDisplay',
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurface)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
