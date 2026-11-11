import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api_service.dart';
import 'token_helper.dart' show mediaAuthHeaders;
import 'package:flutter_contacts/flutter_contacts.dart';

import '../services/contact_names.dart';
import '../services/now_playing_presence.dart';
import '../services/block_list.dart';
import '../utils/net_image.dart';
import '../utils/avatar_widget.dart' show onlineDotFor;
import '../utils/time_utils.dart';
import '../utils/toast_helper.dart';
import '../widgets/avatar_flight.dart';
import '../widgets/photo_viewer.dart';
import '../utils/readable.dart' show accentInk;

/// A read-only profile card for ANOTHER user (a friend or a group member).
/// Opens from a tap on their name/avatar. Shows the photo, the name (their saved
/// phonebook name if you have their number, otherwise their app username), the
/// phone number (copyable), online/last-seen, and an optional Call action.
///
/// If [userId] is given, the sheet FETCHES that user's live details
/// (/users/{id}/status → phone + is_online + last_seen) on open, so it shows the
/// current profile even when the caller only had a partial record. Any values
/// passed in are used immediately as a first paint while the fetch resolves.
/// Everything the card shows beyond what the caller handed in: live status +
/// phone, the In-tune streak and the secret-heart count. Fetched TOGETHER and
/// applied in one go, so the card never pops pieces in one by one.
class _Bond {
  Map<String, dynamic>? live; // /users/{id}/status
  Map<String, dynamic>? streak; // /spaces/{id}/streak
  int? hearts;
}

// Last bond per person, so re-opening a profile paints complete instantly
// (then refreshes quietly).
final Map<String, _Bond> _bondCache = {};
String _bondKey(int? userId, int? spaceId) => '$userId:$spaceId';

Future<void> _quiet(Future<void> Function() f) async {
  try {
    await f();
  } catch (_) {}
}

Future<_Bond> _loadBond(
    {int? userId, int? spaceId, bool hearts = false}) async {
  final b = _Bond();
  await Future.wait([
    if (userId != null)
      _quiet(() async => b.live = await ApiService().fetchFriendStatus(userId)),
    if (spaceId != null)
      _quiet(() async => b.streak = await ApiService().getStreak(spaceId)),
    if (hearts && userId != null)
      _quiet(() async =>
          b.hearts = (await ApiService().loveLetters(userId)).length),
  ]);
  _bondCache[_bondKey(userId, spaceId)] = b;
  return b;
}

/// Fetch a profile card's details ahead of time (e.g. when a chat opens), so
/// tapping the header shows the full card at once.
Future<void> warmUserProfile(
        {int? userId, int? spaceId, bool showHearts = false}) =>
    _loadBond(userId: userId, spaceId: spaceId, hearts: showHearts);

Future<void> showUserProfile(
  BuildContext context, {
  required String username,
  int? userId,
  String? phone,
  String? avatarUrl, // full URL (already resolved)
  bool isOnline = false,
  String? statusLine, // e.g. "Online" / "Last seen …"
  VoidCallback? onCall,
  // Bonded friend: the Our Space you share → the card shows your "In tune"
  // streak and an Open-Our-Space button.
  int? spaceId,
  String? spaceName,
  VoidCallback? onOpenSpace,
  // They're playing music right now → "Tune in".
  VoidCallback? onTuneIn,
  // Their Listen-Together readiness (net_grade) when online — the status
  // line reads like the green dot ("Online · ready to listen together").
  String? netGrade,
  // DM friends: count the secret hearts between you.
  bool showHearts = false,
  // Opened from a group: "Message" goes straight to my DM with them.
  VoidCallback? onMessage,
}) async {
  // Load the bond first so the card opens with streak + hearts + status
  // already in place. Seen before → open instantly from the cache and
  // refresh behind it; first time → wait briefly (capped, so a slow network
  // never holds the tap hostage), then everything lands together.
  final wants = userId != null || spaceId != null;
  final fresh = wants
      ? _loadBond(userId: userId, spaceId: spaceId, hearts: showHearts)
      : null;
  var initial = _bondCache[_bondKey(userId, spaceId)];
  if (initial == null && fresh != null) {
    initial = await fresh
        .then<_Bond?>((b) => b)
        .timeout(const Duration(milliseconds: 900), onTimeout: () => null);
    if (!context.mounted) return;
  }
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    // Drop the app-wide bottomSheetTheme's outer red border for THIS sheet only
    // — the profile card already draws its own (inner) border, so the theme
    // border was doubling it up. No side = no outer line.
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => _UserProfileSheet(
      username: username,
      userId: userId,
      phone: phone,
      avatarUrl: avatarUrl,
      isOnline: isOnline,
      statusLine: statusLine,
      netGrade: netGrade,
      onCall: onCall,
      spaceId: spaceId,
      spaceName: spaceName,
      onOpenSpace: onOpenSpace,
      onTuneIn: onTuneIn,
      showHearts: showHearts,
      onMessage: onMessage,
      initial: initial,
      fresh: fresh,
    ),
  );
}

class _UserProfileSheet extends StatefulWidget {
  final String username;
  final int? userId;
  final String? phone;
  final String? avatarUrl;
  final bool isOnline;
  final String? netGrade;
  final String? statusLine;
  final VoidCallback? onCall;
  final int? spaceId;
  final String? spaceName;
  final VoidCallback? onOpenSpace;
  final VoidCallback? onTuneIn;
  final bool showHearts;
  final VoidCallback? onMessage;
  final _Bond? initial;
  final Future<_Bond>? fresh;

  const _UserProfileSheet({
    required this.username,
    this.userId,
    this.phone,
    this.avatarUrl,
    this.isOnline = false,
    this.netGrade,
    this.statusLine,
    this.onCall,
    this.spaceId,
    this.spaceName,
    this.onOpenSpace,
    this.onTuneIn,
    this.showHearts = false,
    this.onMessage,
    this.initial,
    this.fresh,
  });

  @override
  State<_UserProfileSheet> createState() => _UserProfileSheetState();
}

class _UserProfileSheetState extends State<_UserProfileSheet> {
  late String? _phone = widget.phone;
  late bool _isOnline = widget.isOnline;
  late String? _statusLine = widget.statusLine;
  bool _fetching = false;
  Map<String, dynamic>? _streak; // /spaces/{id}/streak
  int? _hearts; // secret hearts exchanged

  @override
  void initState() {
    super.initState();
    final first = widget.initial;
    if (first != null) _apply(first);
    // Still loading (slow network) → the small "Loading details…" row shows
    // until the whole bond lands at once.
    _fetching = first == null && widget.fresh != null;
    widget.fresh?.then((b) {
      if (mounted) setState(() => _apply(b));
    });
  }

  /// Take a loaded bond — status, phone, streak, hearts — in ONE update.
  void _apply(_Bond b) {
    _fetching = false;
    final st = b.live;
    if (st != null) {
      final fp = (st['phone'] as String?)?.trim();
      final online = st['is_online'] == true;
      final lastSeen = (st['last_seen'] as String?)?.trim();
      if (fp != null && fp.isNotEmpty) _phone = fp;
      _isOnline = online;
      if (online) {
        _statusLine = onlineDotFor(widget.netGrade).$2;
      } else if (lastSeen != null && lastSeen.isNotEmpty) {
        _statusLine = 'Last seen ${formatLastSeen(lastSeen)}';
      } else {
        // Went offline, or keeps last seen private → no stale "Online".
        _statusLine = null;
      }
    }
    if (b.streak != null) _streak = b.streak;
    if (b.hearts != null) _hearts = b.hearts;
  }

  // ── In tune ────────────────────────────────────────────────────────────────

  Widget _inTuneCard(ColorScheme scheme) {
    final st = _streak!;
    final days = (st['current_days'] as num?)?.toInt() ?? 0;
    final best = (st['longest_days'] as num?)?.toInt() ?? days;
    final stage = (st['stage'] ?? 'New').toString();
    final next = (st['next_milestone'] as num?)?.toInt();
    final toNext = (st['days_to_next'] as num?)?.toInt();
    final alive = st['alive'] == true;
    final unlocks = ((st['unlocks'] as List?) ?? const []).length;
    final last = DateTime.tryParse((st['last_active_date'] ?? '').toString());
    final now = DateTime.now();
    final today = last != null &&
        last.year == now.year &&
        last.month == now.month &&
        last.day == now.day;
    // Progress toward the next milestone (from the previous one).
    const marks = [0, 3, 7, 14, 30];
    final prev = marks.lastWhere((m) => m <= days, orElse: () => 0);
    final frac = next == null
        ? 1.0
        : ((days - prev) / (next - prev)).clamp(0.0, 1.0).toDouble();
    const flame = Color(0xFFFF7A1A);
    final todayLine = today
        ? 'Tuned in today ✨'
        : (alive
            ? 'Share a moment today to keep it alive'
            : 'Start a new streak today');
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            flame.withValues(alpha: 0.16),
            scheme.primary.withValues(alpha: 0.08),
          ],
        ),
        border: Border.all(color: flame.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('🔥', style: TextStyle(fontSize: 22)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        days == 1 ? '1 day in tune' : '$days days in tune',
                        style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w800,
                            color: scheme.onSurface)),
                    Text(todayLine,
                        style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: today ? Colors.green : flame)),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: flame.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(stage,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: flame)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: frac,
              minHeight: 6,
              color: flame,
              backgroundColor: flame.withValues(alpha: 0.15),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                    next == null
                        ? 'Every milestone reached 🎉'
                        : '${toNext ?? (next - days)} '
                            '${(toNext ?? 0) == 1 ? 'day' : 'days'} to $next 🔥',
                    style: TextStyle(
                        fontSize: 11.5, color: scheme.onSurfaceVariant)),
              ),
              Text('Best: $best ${best == 1 ? 'day' : 'days'}',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant)),
            ],
          ),
          if (unlocks > 0) ...[
            const SizedBox(height: 4),
            Text('✨ $unlocks ${unlocks == 1 ? 'reward' : 'rewards'} unlocked together',
                style: TextStyle(
                    fontSize: 11.5, color: scheme.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }

  /// One soft tile row (icon · text · optional action).
  Widget _infoTile(ColorScheme scheme,
      {required IconData icon,
      required String text,
      Color? color,
      String? action,
      VoidCallback? onAction}) {
    final c = color ?? scheme.primary;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withAlpha(120),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: EdgeInsets.fromLTRB(14, 10, action == null ? 14 : 6, 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: c),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w600)),
          ),
          if (action != null && onAction != null)
            TextButton(
              onPressed: () {
                Navigator.maybePop(context);
                onAction();
              },
              child: Text(action),
            ),
        ],
      ),
    );
  }

  // Opens the phone's native "new contact" screen pre-filled with this number
  // (WhatsApp-style), then re-reads the address book so a newly saved name
  // resolves. Mobile only — the "Add to contacts" tile is hidden on web, where
  // names come through the existing web-linking mechanism instead.
  Future<void> _addToContacts(String phone) async {
    final ph = phone.trim();
    if (ph.isEmpty) return;
    try {
      final contact = Contact()..phones = [Phone(ph)];
      await FlutterContacts.openExternalInsert(contact);
    } catch (_) {
      if (mounted) {
        showToast(context, "Couldn't open Contacts", type: ToastType.error);
      }
      return;
    }
    try {
      await ContactNames.instance.refresh();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ph = (_phone ?? '').trim();
    final hasRealName =
        ph.isNotEmpty && ContactNames.instance.hasRealName(ph);
    final saved = hasRealName ? ContactNames.instance.nameFor(ph) : null;
    final inPhonebook = saved != null && saved.isNotEmpty;
    final title = inPhonebook ? saved : widget.username;
    // Offer "Add to contacts" when the number isn't saved under a real name.
    final canAddContact =
        ph.isNotEmpty && ContactNames.isSupported && !hasRealName;
    final initial = title.isNotEmpty ? title[0].toUpperCase() : '?';
    final avatarUrl = widget.avatarUrl;
    final hasAvatar = (avatarUrl ?? '').isNotEmpty;
    final status = (_statusLine ?? '').trim();

    return Container(
      margin: const EdgeInsets.all(10),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: scheme.primary.withAlpha(120)),
      ),
      constraints:
          BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.88),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 3,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Avatar — flies up from the little one that was tapped
            // (Telegram-style); tap it to see the photo full size.
            GestureDetector(
              onTap: hasAvatar
                  ? () => showPhotoViewer(
                      context,
                      authNetworkImageProvider(
                          avatarUrl!, mediaAuthHeaders(avatarUrl)),
                      caption: title)
                  : null,
              child: AvatarFlight(
                child: CircleAvatar(
              radius: 46,
              backgroundColor: scheme.primaryContainer,
              backgroundImage: hasAvatar
                  ? authNetworkImageProvider(
                      avatarUrl!, mediaAuthHeaders(avatarUrl))
                  : null,
              child: hasAvatar
                  ? null
                  : Text(initial,
                      style: TextStyle(
                          fontSize: 34,
                          fontWeight: FontWeight.w700,
                          color: scheme.onPrimaryContainer)),
            ),
              ),
            ),
            const SizedBox(height: 12),
            Text(title,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface)),
            // Show the app username as a secondary line when it differs from the
            // saved contact name (so you still know who it is in the app).
            if (inPhonebook &&
                widget.username.isNotEmpty &&
                widget.username != saved) ...[
              const SizedBox(height: 2),
              Text('~ ${widget.username}',
                  style: TextStyle(
                      fontSize: 12.5, color: scheme.onSurfaceVariant)),
            ],
            if (status.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(status,
                  style: TextStyle(
                      fontSize: 12,
                      color: _isOnline
                          ? Colors.green
                          : scheme.onSurfaceVariant)),
            ],
            const SizedBox(height: 18),
            // Listening right now → tune in.
            if (widget.userId != null)
              ListenableBuilder(
                listenable: NowPlayingPresence.instance,
                builder: (context, _) {
                  final np = NowPlayingPresence.instance.trackFor(widget.userId!);
                  final t = (np?['title'] ?? '').toString().trim();
                  if (np == null || t.isEmpty) return const SizedBox.shrink();
                  final a = (np['artist'] ?? '').toString().trim();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _infoTile(scheme,
                        icon: Icons.headphones_rounded,
                        text: 'Listening to $t${a.isEmpty ? '' : ' — $a'}',
                        action: widget.onTuneIn == null ? null : 'Tune in',
                        onAction: widget.onTuneIn),
                  );
                },
              ),
            // The bond: In tune streak + secret hearts — they arrive
            // together (one update); if that's after opening, the card
            // grows smoothly instead of jumping.
            AnimatedSize(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_streak != null && _streak!['bonded'] == true) ...[
                    _inTuneCard(scheme),
                    const SizedBox(height: 10),
                  ],
                  if ((_hearts ?? 0) > 0) ...[
                    _infoTile(scheme,
                        icon: Icons.favorite_rounded,
                        color: const Color(0xFFFF073A),
                        text: _hearts == 1
                            ? '1 secret heart between you 💌'
                            : '$_hearts secret hearts between you 💌'),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
            ),
            if (widget.onOpenSpace != null) ...[
              _infoTile(scheme,
                  icon: Icons.home_rounded,
                  text: (widget.spaceName ?? '').trim().isEmpty
                      ? 'Our Space'
                      : widget.spaceName!.trim(),
                  action: 'Open',
                  onAction: widget.onOpenSpace),
              const SizedBox(height: 10),
            ],
            // Phone row
            if (ph.isNotEmpty)
              Container(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withAlpha(120),
                  borderRadius: BorderRadius.circular(14),
                ),
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                child: Row(
                  children: [
                    Icon(Icons.phone_rounded,
                        size: 18, color: accentInk(scheme)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Phone',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: scheme.onSurfaceVariant)),
                          const SizedBox(height: 1),
                          Text(ph,
                              style: const TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copy',
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: ph));
                        showToast(context, 'Number copied');
                      },
                    ),
                  ],
                ),
              )
            else if (_fetching)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Text('Loading details…',
                      style: TextStyle(
                          fontSize: 12.5, color: scheme.onSurfaceVariant)),
                ],
              )
            else
              Text('No phone number shared',
                  style: TextStyle(
                      fontSize: 12.5, color: scheme.onSurfaceVariant)),
            if (canAddContact) ...[
              const SizedBox(height: 10),
              Material(
                color: scheme.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  onTap: () => _addToContacts(ph),
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    child: Row(
                      children: [
                        Icon(Icons.person_add_alt_1_rounded,
                            size: 20, color: accentInk(scheme)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text('Add to contacts',
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: scheme.onSurface)),
                        ),
                        Icon(Icons.chevron_right_rounded,
                            size: 20, color: scheme.onSurfaceVariant),
                      ],
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.maybePop(context),
                    child: const Text('Close'),
                  ),
                ),
                // From a group: straight into my DM with them (hidden while I
                // block them; if they block me the server refuses that DM).
                if (widget.onMessage != null &&
                    !(widget.userId != null &&
                        BlockList.instance.isBlocked(widget.userId!))) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.maybePop(context);
                        widget.onMessage!();
                      },
                      icon: const Icon(Icons.chat_bubble_rounded, size: 18),
                      label: const Text('Message'),
                    ),
                  ),
                ],
                if (widget.onCall != null) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.maybePop(context);
                        widget.onCall!();
                      },
                      icon: const Icon(Icons.call_rounded, size: 18),
                      label: const Text('Call'),
                    ),
                  ),
                ],
              ],
            ),
            // Block / Unblock — quiet, at the very bottom (never me).
            if (widget.userId != null &&
                widget.userId != BlockList.instance.myId)
              ListenableBuilder(
                listenable: BlockList.instance,
                builder: (context, _) {
                  final blocked =
                      BlockList.instance.isBlocked(widget.userId!);
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: TextButton.icon(
                      onPressed: () => BlockList.instance.toggle(
                          context, widget.userId!, title,
                          person: {
                            'id': widget.userId,
                            'username': widget.username,
                            'phone': _phone,
                            'avatar_url': widget.avatarUrl,
                          }),
                      icon: Icon(
                          blocked
                              ? Icons.lock_open_rounded
                              : Icons.block_rounded,
                          size: 18),
                      label: Text(blocked ? 'Unblock $title' : 'Block $title'),
                      style: TextButton.styleFrom(
                          foregroundColor:
                              blocked ? accentInk(scheme) : scheme.error),
                    ),
                  );
                },
              ),
          ],
        ),
        ),
      ),
    );
  }
}
