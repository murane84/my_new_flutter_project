import 'package:flutter/material.dart';

import '../services/device_report.dart';
import '../utils/popup_shell.dart';
import '../utils/toast_helper.dart';
import 'api_service.dart';

/// "Send feedback" — tell the Aluta team what you love, what's broken and what
/// you'd like next. Goes straight to the owner's admin panel; replies and
/// status ("Planned", "Done") come back here.
class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  final _msg = TextEditingController();
  String _kind = 'idea';
  String? _area;
  int? _rating;
  bool _sending = false;
  List<Map<String, dynamic>> _mine = const [];
  bool _loadingMine = true;

  static const _kinds = [
    ('idea', '💡', 'Idea'),
    ('problem', '🐞', 'Problem'),
    ('praise', '💖', 'Love it'),
    ('other', '💬', 'Other'),
  ];
  static const _areas = [
    ('chat', 'Chats'),
    ('music', 'Music'),
    ('spaces', 'Our Space'),
    ('calls', 'Calls'),
    ('stories', 'Stories'),
    ('glow', 'Glow'),
    ('account', 'Account'),
    ('other', 'Something else'),
  ];
  static const _faces = ['😞', '😕', '😐', '🙂', '😍'];

  @override
  void initState() {
    super.initState();
    _loadMine();
  }

  @override
  void dispose() {
    _msg.dispose();
    super.dispose();
  }

  Future<void> _loadMine() async {
    final l = await ApiService().myFeedback();
    if (!mounted) return;
    setState(() {
      _mine = l;
      _loadingMine = false;
    });
  }

  String get _hint => switch (_kind) {
        'problem' =>
          'What happened, and what did you expect? Steps help us fix it fast.',
        'praise' => 'What do you love? It tells us what to protect.',
        'idea' => 'What would make Aluta better for you?',
        _ => 'Tell us anything about your Aluta experience.',
      };

  Future<void> _send() async {
    final text = _msg.text.trim();
    if (text.length < 3) {
      showToast(context, 'Please write a few words', type: ToastType.info);
      return;
    }
    setState(() => _sending = true);
    final info = await DeviceReport.info();
    final err = await ApiService().sendFeedback(
      message: text,
      kind: _kind,
      area: _area,
      rating: _rating,
      platform: info.os == null ? info.platform : '${info.platform} · ${info.os}',
      appVersion: info.version,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (err != null) {
      showToast(context, err, type: ToastType.error);
      return;
    }
    _msg.clear();
    setState(() {
      _rating = null;
      _area = null;
    });
    showToast(context, 'Thank you! Your feedback reached the team 💖',
        type: ToastType.success);
    _loadMine();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppPopupShell(
      title: 'Send feedback',
      icon: Icons.rate_review_rounded,
      desktopMaxWidth: 640,
      builder: (context, isWide) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('How is Aluta for you?',
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface)),
            const SizedBox(height: 4),
            Text(
              'Your words go straight to the people building Aluta. We read '
              'everything — and you\'ll see here when it\'s planned or done.',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            // Rating faces (optional).
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var i = 0; i < 5; i++)
                  _face(scheme, i + 1, _faces[i]),
              ],
            ),
            const SizedBox(height: 16),
            _label(scheme, 'What is it about?'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final k in _kinds)
                  ChoiceChip(
                    label: Text('${k.$2}  ${k.$3}'),
                    selected: _kind == k.$1,
                    onSelected: (_) => setState(() => _kind = k.$1),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            _label(scheme, 'Which part of Aluta? (optional)'),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final a in _areas)
                  FilterChip(
                    label: Text(a.$2),
                    selected: _area == a.$1,
                    onSelected: (on) =>
                        setState(() => _area = on ? a.$1 : null),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _msg,
              minLines: 4,
              maxLines: 8,
              maxLength: 4000,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: _hint,
                filled: true,
                fillColor: scheme.surfaceContainerHighest.withAlpha(120),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            Text(
              'We add your app version and device type so we can reproduce '
              'problems. Nothing else is attached.',
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send_rounded, size: 18),
              label: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_sending ? 'Sending…' : 'Send to the Aluta team'),
              ),
            ),
            const SizedBox(height: 22),
            _label(scheme, 'What you\'ve sent'),
            if (_loadingMine)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_mine.isEmpty)
              Text('Nothing yet — your first note starts here.',
                  style: TextStyle(color: scheme.onSurfaceVariant))
            else
              for (final f in _mine) _mineTile(scheme, f),
          ],
        ),
      ),
    );
  }

  Widget _label(ColorScheme scheme, String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t,
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                color: scheme.onSurfaceVariant)),
      );

  Widget _face(ColorScheme scheme, int value, String emoji) {
    final on = _rating == value;
    return GestureDetector(
      onTap: () => setState(() => _rating = on ? null : value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 52,
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on
              ? scheme.primary.withAlpha(36)
              : scheme.surfaceContainerHighest.withAlpha(120),
          border: Border.all(
              color: on ? scheme.primary : scheme.outlineVariant.withAlpha(90),
              width: on ? 2 : 1),
        ),
        child: AnimatedScale(
          scale: on ? 1.18 : 1.0,
          duration: const Duration(milliseconds: 160),
          child: Text(emoji, style: const TextStyle(fontSize: 24)),
        ),
      ),
    );
  }

  Widget _mineTile(ColorScheme scheme, Map<String, dynamic> f) {
    final status = (f['status'] ?? 'new').toString();
    final (Color c, IconData i) = switch (status) {
      'planned' => (const Color(0xFF2979FF), Icons.construction_rounded),
      'done' => (const Color(0xFF00C853), Icons.check_circle_rounded),
      'wontfix' => (scheme.outline, Icons.do_not_disturb_on_rounded),
      'seen' => (const Color(0xFF7C4DFF), Icons.visibility_rounded),
      _ => (scheme.primary, Icons.mark_email_read_rounded),
    };
    final kind = _kinds.firstWhere((k) => k.$1 == f['kind'],
        orElse: () => _kinds.last);
    final reply = (f['reply'] ?? '').toString().trim();
    final when = DateTime.tryParse((f['created_at'] ?? '').toString());
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withAlpha(90),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withAlpha(70)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(kind.$2, style: const TextStyle(fontSize: 16)),
              const SizedBox(width: 6),
              if (when != null)
                Text(
                    '${when.toLocal().day}/${when.toLocal().month}/${when.toLocal().year}',
                    style: TextStyle(
                        fontSize: 11.5, color: scheme.onSurfaceVariant)),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: c.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(i, size: 13, color: c),
                    const SizedBox(width: 4),
                    Text((f['status_label'] ?? status).toString(),
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: c)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text((f['message'] ?? '').toString(),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13.5, color: scheme.onSurface)),
          if (reply.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.primary.withAlpha(20),
                borderRadius: BorderRadius.circular(10),
                border: Border(
                    left: BorderSide(color: scheme.primary, width: 3)),
              ),
              child: Text('Aluta team: $reply',
                  style: TextStyle(fontSize: 13, color: scheme.onSurface)),
            ),
          ],
        ],
      ),
    );
  }
}
