import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import 'api_service.dart';
import '../utils/toast_helper.dart';
import '../utils/popup_shell.dart';

/// "Aluta Together" — the paywall / benefits surface (build step 6).
///
/// Together deepens closeness; it never gates basic use. Free keeps one Our
/// Space + recent history; Together unlocks multiple Spaces, forever history,
/// and custom Space themes. Real billing isn't wired yet, so the CTA is a
/// dev/trial toggle (clearly labelled) — a verified purchase will replace it.
class TogetherScreen extends StatefulWidget {
  /// Called after the plan changes so the caller can refresh its cached state.
  final VoidCallback? onChanged;
  const TogetherScreen({super.key, this.onChanged});

  @override
  State<TogetherScreen> createState() => _TogetherScreenState();
}

class _TogetherScreenState extends State<TogetherScreen> {
  Map<String, dynamic>? _plan;
  bool _busy = false;

  bool get _isTogether => _plan?['is_together'] == true;

  static const Color _gold = Color(0xFFF6D77A);

  static const List<(IconData, String, String)> _benefits = [
    (
      Icons.favorite_rounded,
      'More Our Spaces',
      'Pin several bonds — a partner, family, your closest friend — not just one.'
    ),
    (
      Icons.all_inclusive_rounded,
      'History kept forever',
      'Your moments, your song, your streak — never expire. People pay to not lose their memories.'
    ),
    (
      Icons.palette_rounded,
      'Custom Space themes',
      'Give each bond its own colour — custom gradients and seasonal packs.'
    ),
    (
      Icons.bolt_rounded,
      'Priority rooms',
      'Smoother Listen-Together when it lands — your bonds first.'
    ),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await ApiService().getPlan();
    if (!mounted) return;
    setState(() => _plan = p);
  }

  Future<void> _toggle(bool on) async {
    setState(() => _busy = true);
    final res = await ApiService().setTogether(on);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (res != null) _plan = res;
    });
    if (res != null) {
      showToast(
          context,
          on ? 'Welcome to Together 💛' : 'Back on the free plan',
          type: ToastType.success);
      widget.onChanged?.call();
    } else {
      showToast(context, 'Could not update your plan — try again',
          type: ToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppPopupShell(
      title: 'Aluta Together',
      icon: Icons.workspace_premium_rounded,
      builder: (context, isWide) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        children: [
          _hero(scheme),
          const SizedBox(height: 22),
          for (final b in _benefits) _benefitRow(scheme, b),
          const SizedBox(height: 20),
          _cta(scheme),
          const SizedBox(height: 14),
          Center(
            child: Text(
              'Billing is coming soon — this is a trial toggle for now.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hero(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3A2A00), Color(0xFF6E5410)],
        ),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: _gold,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text('TOGETHER',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                    color: Color(0xFF3A2A00))),
          ),
          const SizedBox(height: 14),
          const Text(
            'Keep every bond — forever.',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            _isTogether
                ? 'You’re on Together${_sinceLabel()}. Thank you 💛'
                : 'Upgrade deepens closeness — it never gates the basics.',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9), fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  String _sinceLabel() {
    final raw = (_plan?['together_since'] ?? '').toString();
    final dt = DateTime.tryParse(raw);
    if (dt == null) return '';
    return ' since ${DateFormat('MMM d, yyyy').format(dt.toLocal())}';
  }

  Widget _benefitRow(ColorScheme scheme, (IconData, String, String) b) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(b.$1, color: const Color(0xFFB88A12)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(b.$2,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                        color: scheme.onSurface)),
                const SizedBox(height: 2),
                Text(b.$3,
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.3,
                        color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _cta(ColorScheme scheme) {
    if (_isTogether) {
      return Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: scheme.surfaceContainerHighest,
                foregroundColor: scheme.onSurface,
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
              icon: const Icon(Icons.check_circle_rounded,
                  color: Color(0xFFB88A12)),
              label: const Text('You’re on Together'),
              onPressed: null,
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy ? null : () => _toggle(false),
            child: Text('Switch back to Free (testing)',
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
        ],
      );
    }
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: _gold,
          foregroundColor: const Color(0xFF3A2A00),
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
        onPressed: _busy ? null : () => _toggle(true),
        child: _busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Color(0xFF3A2A00)))
            : const Text('Start Together',
                style:
                    TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
      ),
    );
  }
}
