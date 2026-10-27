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

  static const _faceLabels = ['Not great', 'Meh', 'Okay', 'Good', 'Love it'];

  /// The raised "3D" surface every control here uses: a soft top highlight,
  /// a grounded drop shadow, and (when [on]) the brand gradient + glow.
  BoxDecoration _raised(ColorScheme scheme,
      {required bool on, double radius = 16, Color? tint}) {
    final isDark = scheme.brightness == Brightness.dark;
    final c = tint ?? scheme.primary;
    return BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: on
          ? LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(c, Colors.white, 0.18)!,
                Color.lerp(c, Colors.black, 0.14)!,
              ],
            )
          : LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: isDark
                  ? [
                      Color.alphaBlend(
                          Colors.white.withValues(alpha: 0.08), scheme.surface),
                      Color.alphaBlend(
                          Colors.white.withValues(alpha: 0.03), scheme.surface),
                    ]
                  : [
                      Colors.white,
                      Color.alphaBlend(
                          c.withValues(alpha: 0.06), scheme.surface),
                    ],
            ),
      border: Border.all(
          color: on
              ? Color.lerp(c, Colors.white, 0.25)!
              : c.withValues(alpha: isDark ? 0.22 : 0.14)),
      boxShadow: [
        BoxShadow(
          color: on
              ? c.withValues(alpha: 0.38)
              : Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
          blurRadius: on ? 14 : 8,
          offset: Offset(0, on ? 5 : 3),
        ),
        if (!isDark)
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.9),
            blurRadius: 2,
            offset: const Offset(-1, -1.5),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    return AppPopupShell(
      title: 'Send feedback',
      icon: Icons.rate_review_rounded,
      desktopMaxWidth: 640,
      builder: (context, isWide) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Hero: a glowing gradient card ─────────────────────────────
            Container(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color.lerp(scheme.primary, Colors.white, 0.10)!,
                    Color.lerp(scheme.primary, Colors.black, 0.25)!,
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.35),
                    blurRadius: 22,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.18),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.35)),
                    ),
                    child: const Icon(Icons.forum_rounded,
                        color: Colors.white, size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('How is Aluta for you?',
                            style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: Colors.white)),
                        const SizedBox(height: 4),
                        Text(
                          'Straight to the people building Aluta. We read '
                          'everything — you\'ll see here when it\'s planned '
                          'or done.',
                          style: TextStyle(
                              fontSize: 12.5,
                              height: 1.35,
                              color: Colors.white.withValues(alpha: 0.88)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            // ── Rating: raised faces that lift when chosen ────────────────
            _label(scheme, 'How does it feel? (optional)'),
            Row(
              children: [
                for (var i = 0; i < 5; i++)
                  Expanded(child: _face(scheme, i + 1, _faces[i])),
              ],
            ),
            const SizedBox(height: 18),
            _label(scheme, 'What is it about?'),
            LayoutBuilder(builder: (context, c) {
              final cols = c.maxWidth >= 460 ? 4 : 2;
              const gap = 10.0;
              final w = (c.maxWidth - gap * (cols - 1)) / cols;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final k in _kinds)
                    SizedBox(width: w, child: _kindTile(scheme, k)),
                ],
              );
            }),
            const SizedBox(height: 18),
            _label(scheme, 'Which part of Aluta? (optional)'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final a in _areas) _areaPill(scheme, a)],
            ),
            const SizedBox(height: 18),
            // ── The words: an inset well ─────────────────────────────────
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                color: isDark
                    ? Colors.black.withValues(alpha: 0.22)
                    : Color.alphaBlend(
                        scheme.primary.withValues(alpha: 0.04),
                        scheme.surfaceContainerHighest),
                border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.16)),
                boxShadow: [
                  // Inner-shadow look: a dark top lip.
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.06),
                    blurRadius: 1,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 4),
              child: TextField(
                controller: _msg,
                minLines: 4,
                maxLines: 8,
                maxLength: 4000,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: _hint,
                  border: InputBorder.none,
                  counterStyle: TextStyle(
                      fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.lock_outline_rounded,
                  size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'We add your app version and device type so we can '
                  'reproduce problems. Nothing else is attached.',
                  style: TextStyle(
                      fontSize: 11.5, color: scheme.onSurfaceVariant),
                ),
              ),
            ]),
            const SizedBox(height: 14),
            // ── Send: a glowing gradient pill ────────────────────────────
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: _sending ? null : _send,
                child: Ink(
                  decoration: _raised(scheme, on: true, radius: 18),
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _sending
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.send_rounded,
                              size: 18, color: Colors.white),
                      const SizedBox(width: 10),
                      Text(_sending ? 'Sending…' : 'Send to the Aluta team',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 14.5)),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 26),
            Row(children: [
              Icon(Icons.history_rounded,
                  size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(child: _label(scheme, 'What you\'ve sent')),
            ]),
            if (_loadingMine)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_mine.isEmpty)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: _raised(scheme, on: false, radius: 16),
                child: Text('Nothing yet — your first note starts here.',
                    style: TextStyle(color: scheme.onSurfaceVariant)),
              )
            else
              for (final f in _mine) _mineTile(scheme, f),
          ],
        ),
      ),
    );
  }

  Widget _label(ColorScheme scheme, String t) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(t.toUpperCase(),
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.0,
                color: scheme.onSurfaceVariant)),
      );

  Widget _face(ColorScheme scheme, int value, String emoji) {
    final on = _rating == value;
    return GestureDetector(
      onTap: () => setState(() => _rating = on ? null : value),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutBack,
            width: 54,
            height: 54,
            transform: Matrix4.translationValues(0, on ? -4 : 0, 0),
            alignment: Alignment.center,
            decoration: _raised(scheme, on: on, radius: 27),
            child: AnimatedScale(
              scale: on ? 1.2 : 1.0,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutBack,
              child: Text(emoji, style: const TextStyle(fontSize: 25)),
            ),
          ),
          const SizedBox(height: 6),
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 160),
            style: TextStyle(
                fontSize: 10.5,
                fontWeight: on ? FontWeight.w800 : FontWeight.w500,
                color: on ? scheme.primary : scheme.onSurfaceVariant),
            child: Text(_faceLabels[value - 1]),
          ),
        ],
      ),
    );
  }

  Widget _kindTile(ColorScheme scheme, (String, String, String) k) {
    final on = _kind == k.$1;
    return GestureDetector(
      onTap: () => setState(() => _kind = k.$1),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 12),
        transform: Matrix4.translationValues(0, on ? -2 : 0, 0),
        decoration: _raised(scheme, on: on, radius: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedScale(
              scale: on ? 1.15 : 1.0,
              duration: const Duration(milliseconds: 180),
              child: Text(k.$2, style: const TextStyle(fontSize: 22)),
            ),
            const SizedBox(height: 4),
            Text(k.$3,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: on ? Colors.white : scheme.onSurface)),
          ],
        ),
      ),
    );
  }

  Widget _areaPill(ColorScheme scheme, (String, String) a) {
    final on = _area == a.$1;
    return GestureDetector(
      onTap: () => setState(() => _area = on ? null : a.$1),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: _raised(scheme, on: on, radius: 20),
        child: Text(a.$2,
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                color: on ? Colors.white : scheme.onSurface)),
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
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: _raised(scheme, on: false, radius: 16),
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
          const SizedBox(height: 10),
          _steps(scheme, status, c),
          if (reply.isNotEmpty) ...[
            const SizedBox(height: 10),
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

  /// Sent → Seen → Planned → Done, the reached steps lit in [c].
  Widget _steps(ColorScheme scheme, String status, Color c) {
    if (status == 'wontfix') return const SizedBox.shrink();
    const order = ['new', 'seen', 'planned', 'done'];
    const names = ['Sent', 'Seen', 'Planned', 'Done'];
    final at = order.indexOf(status).clamp(0, 3);
    return Row(
      children: [
        for (var i = 0; i < 4; i++) ...[
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i <= at ? c : scheme.outlineVariant,
              boxShadow: i == at
                  ? [BoxShadow(color: c.withValues(alpha: 0.5), blurRadius: 6)]
                  : null,
            ),
          ),
          const SizedBox(width: 4),
          Text(names[i],
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: i == at ? FontWeight.w800 : FontWeight.w500,
                  color: i <= at ? c : scheme.onSurfaceVariant)),
          if (i < 3)
            Expanded(
              child: Container(
                height: 2,
                margin: const EdgeInsets.symmetric(horizontal: 6),
                color: i < at ? c : scheme.outlineVariant.withAlpha(120),
              ),
            ),
        ],
      ],
    );
  }
}
