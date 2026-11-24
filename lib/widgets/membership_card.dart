import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../screens/api_service.dart';
import '../utils/radii.dart';
import '../utils/toast_helper.dart';

/// 💌 My place in Aluta (brand strategy: being invited is the status):
/// "Member #312 · Founding Circle", who brought me here, how many people I
/// brought — and Invite your people (a personal code to share).
class MembershipCard extends StatefulWidget {
  const MembershipCard({super.key});

  @override
  State<MembershipCard> createState() => _MembershipCardState();
}

class _MembershipCardState extends State<MembershipCard> {
  Map<String, dynamic>? _m;
  bool _inviting = false;

  @override
  void initState() {
    super.initState();
    ApiService().myMembership(fresh: true).then((m) {
      if (mounted) setState(() => _m = m);
    });
  }

  Future<void> _invite() async {
    if (_inviting) return;
    setState(() => _inviting = true);
    final r = await ApiService().myInviteCode();
    if (!mounted) return;
    setState(() => _inviting = false);
    final code = (r?['code'] ?? '').toString();
    if (code.isEmpty) {
      showToast(context, (r?['error'] ?? 'Couldn’t make an invite — try again')
          .toString(),
          type: ToastType.info);
      return;
    }
    await SharePlus.instance.share(ShareParams(
      subject: 'Join me on Aluta',
      text: 'Join me on Aluta — your people, close. 💞\n'
          'Get it: https://aluta.ozilane.com/download\n'
          'My invite code: $code',
    ));
  }

  @override
  Widget build(BuildContext context) {
    final m = _m;
    if (m == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final no = (m['member_no'] as num?)?.toInt();
    final founding = m['founding'] == true;
    final by = (m['invited_by_name'] ?? '').toString().trim();
    final brought = (m['brought'] as num?)?.toInt() ?? 0;
    final left = (m['invites_left'] as num?)?.toInt();
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.primary.withAlpha(18),
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: scheme.primary.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(founding ? Icons.auto_awesome_rounded : Icons.favorite_rounded,
                color: scheme.primary, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                [
                  if (no != null) 'Member #$no',
                  if (founding) 'Founding Circle',
                ].join(' · '),
                style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface),
              ),
            ),
          ]),
          if (by.isNotEmpty || brought > 0) ...[
            const SizedBox(height: 6),
            Text(
              [
                if (by.isNotEmpty) '$by brought you here',
                if (brought > 0)
                  'you brought $brought ${brought == 1 ? 'person' : 'people'}',
              ].join(' · '),
              style:
                  TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 12),
          Row(children: [
            FilledButton.icon(
              onPressed: (left == 0 || _inviting) ? null : _invite,
              icon: const Icon(Icons.card_giftcard_rounded, size: 18),
              label: const Text('Invite your people'),
            ),
            if (left != null) ...[
              const SizedBox(width: 10),
              Text('$left left this wave',
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ]),
        ],
      ),
    );
  }
}
