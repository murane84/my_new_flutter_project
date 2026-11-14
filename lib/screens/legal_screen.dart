import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../utils/popup_shell.dart'
    show HeaderActionButton, gPanelBottomY, kAppFooterHeight;
import '../utils/readable.dart' show accentInk;
import '../utils/motion.dart';
import '../utils/radii.dart';
import '../utils/depth.dart';
import '../widgets/section_swipe_path.dart';
import '../widgets/section_switch.dart';

// Height of the Aluta app header (toolbar). The full-page legal views start
// just under it, so the "Aluta" title + overflow (⋮) menu stay visible above.
const double _kAppHeaderHeight = kToolbarHeight;

/// Opens the full-page "Legal & About" hub below the app header. The three
/// documents (Privacy / Terms / About) share ONE page with a PERSISTENT tab bar,
/// so after reading one you can switch straight to another — no going back up to
/// the ⋮ menu. Unlike Our Space (whole-screen), the "Aluta" title + ⋮ menu stay
/// visible up top, and tapping there (tap-out) closes the hub.
void showLegalMenu(BuildContext context) => _showLegalHub(context, 0);

// ── Public entry points ──────────────────────────────────────────────────────
// Open the hub focused on a specific document (e.g. from the consent gate). All
// share the SAME content + styling, so there's one source of truth per document.

void showPrivacyPolicy(BuildContext ctx) => _showLegalHub(ctx, 0);

void showTermsOfUse(BuildContext ctx) => _showLegalHub(ctx, 1);

void showAboutAluta(BuildContext ctx) => _showLegalHub(ctx, 2);

/// One legal document, in tab order.
class _LegalDoc {
  const _LegalDoc(this.tab, this.title, this.icon, this.body);
  final String tab; // short label for the persistent tab bar
  final String title; // full title for the header
  final IconData icon;
  final String body;
}

const List<_LegalDoc> _kLegalDocs = [
  _LegalDoc('Privacy', 'Privacy Policy', Icons.privacy_tip_rounded, _privacy),
  _LegalDoc('Terms', 'Terms of Service', Icons.description_rounded, _terms),
  _LegalDoc('About', 'About Aluta', Icons.info_rounded, _about),
];

/// Presents the hub as a FULL PAGE below the app header, with a genie open/close
/// that grows from / collapses into the exact spot the user tapped (the ⋮ menu
/// item), like Our Space. A transparent barrier keeps the header + ⋮ menu fully
/// visible; tapping the exposed header strip (tap-out) dismisses.
void _showLegalHub(BuildContext ctx, int initialIndex) {
  // Opens like Profile and the other menu pages: a plain fade + rise.
  showGeneralDialog(
    context: ctx,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black.withAlpha(90),
    transitionDuration: Motion.emphasized,
    pageBuilder: (_, _, _) => _LegalHub(initialIndex: initialIndex),
    transitionBuilder: (dctx, anim, _, child) {
      final curved = CurvedAnimation(
        parent: anim,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero)
              .animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// The full-page legal hub: an opaque surface pinned under the app header,
/// filling the rest of the screen, with a PERSISTENT tab bar so all three docs
/// are one tap apart. Rounded top, squared bottom (it meets the screen edge).
class _LegalHub extends StatefulWidget {
  const _LegalHub({required this.initialIndex});

  final int initialIndex;

  @override
  State<_LegalHub> createState() => _LegalHubState();
}

class _LegalHubState extends State<_LegalHub> {
  late int _index = widget.initialIndex;
  // Tabs the user visited before the current one, most-recent last. Back steps
  // through these — landing on the previous tab — and only closes the hub once
  // there's no earlier tab left, matching the app-wide "back = previous page,
  // then minimise" rule (same contract Our Space and the home stack use).
  final List<int> _history = [];
  // Privacy · Terms · About change like Circle's sections: the user's
  // transition (Appearance → Section transitions), from the side the new
  // one sits on — and on phones a swipe follows the finger.
  bool _forward = true;
  double? _rippleFrom; // the tapped pill's centre (0..1) for the ripple

  void _selectTab(int i, {bool tapped = false}) {
    if (i == _index || i < 0 || i >= _kLegalDocs.length) return;
    setState(() {
      _forward = i > _index;
      _rippleFrom = tapped ? (i + 0.5) / _kLegalDocs.length : null;
      _history.add(_index);
      _index = i;
    });
  }

  Widget _page(int i, bool isWide) => isWide
      ? Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: _body(_kLegalDocs[i], i),
          ),
        )
      : _body(_kLegalDocs[i], i);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final isWide = media.size.width >= 640;
    // Clear the Aluta app header (status bar + toolbar) so it stays in view.
    final topInset = media.padding.top + _kAppHeaderHeight;
    final doc = _kLegalDocs[_index];

    return PopScope(
      // Only let the hub close when there's no earlier tab to step back to.
      canPop: _history.isEmpty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || _history.isEmpty) return;
        final back = _history.removeLast();
        setState(() {
          _forward = back > _index;
          _rippleFrom = null;
          _index = back;
        });
      },
      // Same place and shape as Profile and the other pages: ends on the
      // line the chat / music panels end on (above the now-playing bar when
      // it's up, else the footer), a card rounded on all four corners.
      child: ValueListenableBuilder<double?>(
        valueListenable: gPanelBottomY,
        builder: (context, panelBottom, child) => AnimatedPadding(
          duration: Motion.standard,
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.only(
              top: topInset,
              bottom: (media.size.width < 640 && panelBottom != null)
                  ? (media.size.height - panelBottom).clamp(0.0, 400.0)
                  : media.padding.bottom + kAppFooterHeight),
          child: child,
        ),
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(Radii.xl),
            boxShadow: [
              BoxShadow(
                color: Theme.of(context).shadowColor.withAlpha(35),
                blurRadius: Depth.md,
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              // Header row — current doc's icon + title + close (same look
              // as the other pages' headers).
              Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
                color: scheme.surfaceContainerHighest.withAlpha(120),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: scheme.primary.withAlpha(28),
                        borderRadius: BorderRadius.circular(Radii.md),
                      ),
                      child: Icon(doc.icon, size: 19, color: accentInk(scheme)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        doc.title,
                        style: const TextStyle(
                            fontSize: 16.5, fontWeight: FontWeight.w700),
                      ),
                    ),
                    // Raised 3D dismiss chip — matches Our Space's header
                    // actions instead of a flat icon button.
                    HeaderActionButton(
                      icon: Icons.close_rounded,
                      tooltip: 'Close',
                      onPressed: () {
                        FocusScope.of(context).unfocus();
                        Navigator.of(context).pop();
                      },
                    ),
                  ],
                ),
              ),
              // Divider directly under the title — the content scrolls right
              // below it, so the title (e.g. "Terms of Service") is never
              // crowded by the tabs. The switcher now lives in the footer.
              Divider(height: 1, color: scheme.outlineVariant.withAlpha(70)),
              // Body — width-capped + centred on desktop, full-bleed on phone.
              // Scrolls BETWEEN the title above and the footer tab bar below.
              // Swipe left / right to move between Privacy · Terms · About.
              Expanded(child: _switcher(isWide)),
              // PERSISTENT switcher — pinned to the FOOTER as equal-width pills.
              _footerTabs(scheme, isWide),
            ],
          ),
        ),
      ),
      ),
    );
  }

  // The current document in the user's section transition; on phones the
  // swipe to the next / previous one follows the finger (like Circle).
  Widget _switcher(bool isWide) {
    final switched = SectionSwitch(
      forward: _forward,
      rippleFrom: _rippleFrom,
      child: KeyedSubtree(
        key: ValueKey('legal-$_index'),
        child: _page(_index, isWide),
      ),
    );
    if (isWide) return switched;
    int? step(bool fwd) {
      final i = _index + (fwd ? 1 : -1);
      return i >= 0 && i < _kLegalDocs.length ? i : null;
    }

    return SectionSwipePath(
      current: switched,
      hasNeighbor: (fwd) => step(fwd) != null,
      neighbor: (fwd) {
        final i = step(fwd);
        return i == null ? null : _page(i, false);
      },
      commit: (fwd) {
        final i = step(fwd);
        if (i != null) _selectTab(i);
      },
    );
  }

  // The scrollable document body. Keyed by index so switching tabs starts the
  // new document from the top rather than inheriting the previous scroll.
  Widget _body(_LegalDoc doc, int i) => _DocBody(doc: doc, index: i);

  // The persistent switcher, pinned to the FOOTER as three EQUAL-WIDTH pills so
  // the row is balanced across the width. Its own top border + surface tint set
  // it apart as a footer bar, and SafeArea keeps it above the phone gesture bar.
  Widget _footerTabs(ColorScheme scheme, bool isWide) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final row = Row(
      children: [
        for (int i = 0; i < _kLegalDocs.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: _tab(scheme, i)),
        ],
      ],
    );
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: dark
            ? scheme.surfaceContainerHigh.withAlpha(150)
            : scheme.surfaceContainerHighest.withAlpha(120),
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withAlpha(90)),
        ),
      ),
      // The page ends above the footer now, so no system-inset padding here.
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: isWide
            ? Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: row,
                ),
              )
            : row,
      ),
    );
  }

  Widget _tab(ColorScheme scheme, int i) {
    final doc = _kLegalDocs[i];
    final selected = i == _index;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.xl),
        onTap: selected ? null : () => _selectTab(i, tapped: true),
        child: AnimatedContainer(
          duration: Motion.quick,
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary.withAlpha(30)
                : scheme.surfaceContainerHighest.withAlpha(120),
            borderRadius: BorderRadius.circular(Radii.xl),
            border: Border.all(
              color: selected
                  ? scheme.primary.withAlpha(150)
                  : scheme.outlineVariant.withAlpha(80),
            ),
          ),
          // Centre the icon + label inside the equal-width pill.
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(doc.icon,
                  size: 16,
                  color:
                      selected ? scheme.primary : scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  doc.tab,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One document's scrolling body. Its own scroll controller per page on
/// screen, so two pages crossing in a transition (or under a swipe) never
/// share one; the PageStorageKey brings each document back where you left it.
class _DocBody extends StatefulWidget {
  const _DocBody({required this.doc, required this.index});
  final _LegalDoc doc;
  final int index;

  @override
  State<_DocBody> createState() => _DocBodyState();
}

class _DocBodyState extends State<_DocBody> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scrollbar(
        controller: _scroll,
        child: SingleChildScrollView(
          key: PageStorageKey('legal_${widget.index}'),
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // About opens with the live version card (read from the build,
              // so it can never drift from pubspec like a hard-coded string).
              if (identical(widget.doc.body, _about)) ...[
                const _VersionCard(),
                const SizedBox(height: 14),
              ],
              ..._legalBody(context, widget.doc.body),
            ],
          ),
        ),
      );
}

// Read once per app run — the version can't change while the app is open.
final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

/// The build as people know it: the arm64 Android APK's versionCode is
/// 2000 + build (so it outranks the universal one) — show the plain build.
String _build(PackageInfo info) {
  final n = int.tryParse(info.buildNumber);
  if (n == null) return info.buildNumber;
  final arm64 = !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      n > 2000;
  return '${arm64 ? n - 2000 : n}';
}

String _platformLabel() {
  if (kIsWeb) return 'Web';
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return 'Android';
    case TargetPlatform.windows:
      return 'Windows';
    case TargetPlatform.iOS:
      return 'iOS';
    case TargetPlatform.macOS:
      return 'macOS';
    case TargetPlatform.linux:
      return 'Linux';
    case TargetPlatform.fuchsia:
      return 'Fuchsia';
  }
}

/// The About tab's version card: logo, "Version x.y.z · build n", a Beta pill
/// and the platform. Tap copies a one-line version string for support chats
/// ("Aluta 1.0.7+8 · Android"), confirmed inline — no toast behind the dialog.
class _VersionCard extends StatefulWidget {
  const _VersionCard();

  @override
  State<_VersionCard> createState() => _VersionCardState();
}

class _VersionCardState extends State<_VersionCard> {
  bool _copied = false;

  Future<void> _copy(PackageInfo info) async {
    await Clipboard.setData(ClipboardData(
        text: 'Aluta ${info.version}+${_build(info)} · ${_platformLabel()}'));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<PackageInfo>(
      future: _packageInfo,
      builder: (context, snap) {
        final info = snap.data;
        final versionLine = info != null
            ? 'Version ${info.version} · build ${_build(info)}'
            : snap.hasError
                ? 'Version unavailable'
                : 'Reading version…';
        final hint = _copied ? 'Copied to clipboard' : 'Tap to copy';
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.xl),
            onTap: info == null ? null : () => _copy(info),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.primary.withAlpha(20),
                borderRadius: BorderRadius.circular(Radii.xl),
                border: Border.all(color: scheme.primary.withAlpha(70)),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.md),
                    child: Image.asset('assets/images/logo.png',
                        width: 46, height: 46, fit: BoxFit.cover),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text('Aluta',
                                style: TextStyle(
                                    fontSize: 16.5,
                                    fontWeight: FontWeight.w800,
                                    color: scheme.onSurface)),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: scheme.primary.withAlpha(32),
                                borderRadius:
                                    BorderRadius.circular(Radii.xl),
                              ),
                              child: Text('Beta',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: accentInk(scheme))),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(versionLine,
                            style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurface.withAlpha(225))),
                        const SizedBox(height: 2),
                        AnimatedSwitcher(
                          duration: Motion.quick,
                          child: Text(
                            '${_platformLabel()} · $hint',
                            key: ValueKey(_copied),
                            style: TextStyle(
                                fontSize: 12,
                                color: _copied
                                    ? accentInk(scheme)
                                    : scheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    _copied ? Icons.check_rounded : Icons.copy_rounded,
                    size: 18,
                    color: _copied ? accentInk(scheme) : scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Parses the plain-text policy into styled blocks — numbered section headings,
/// bullet points, a muted "version / last-updated" caption, and clean wrapped
/// paragraphs (source line-wraps are re-joined). The redundant first line (the
/// doc's own title) is dropped since the popup header already shows it.
/// A line starting with "# " is a small un-numbered heading (About's
/// "What you can do today", "Learn more"…).
List<Widget> _legalBody(BuildContext context, String raw) {
  final scheme = Theme.of(context).colorScheme;
  final bodyStyle = TextStyle(
    fontSize: 13.5,
    height: 1.55,
    color: scheme.onSurface.withAlpha(225),
  );
  final headingRe = RegExp(r'^\d+\.\s');

  final lines = raw.trim().split('\n');
  if (lines.isNotEmpty) lines.removeAt(0); // drop redundant doc title

  // Build segments, merging wrapped continuation lines into the prior block.
  final segs = <Map<String, String>>[];
  for (final rawLine in lines) {
    final t = rawLine.trim();
    if (t.isEmpty) {
      if (segs.isEmpty || segs.last['type'] != 'gap') {
        segs.add({'type': 'gap', 'text': ''});
      }
      continue;
    }
    if (t.startsWith('Version ') || t.contains('Last updated')) {
      segs.add({'type': 'caption', 'text': t});
      continue;
    }
    if (headingRe.hasMatch(t)) {
      segs.add({'type': 'head', 'text': t});
      continue;
    }
    if (t.startsWith('# ')) {
      segs.add({'type': 'head', 'text': t.substring(2)});
      continue;
    }
    if (t.startsWith('- ')) {
      segs.add({'type': 'bullet', 'text': t.substring(2)});
      continue;
    }
    // Plain line — continuation of the previous bullet/paragraph if that block
    // is still open (re-joins the source's hard line wraps). A blank line,
    // heading or caption breaks the block, so the next plain line starts fresh.
    final last = segs.isNotEmpty ? segs.last : null;
    if (last != null &&
        (last['type'] == 'bullet' || last['type'] == 'para')) {
      last['text'] = '${last['text']} $t';
    } else {
      segs.add({'type': 'para', 'text': t});
    }
  }

  final widgets = <Widget>[];
  for (final seg in segs) {
    switch (seg['type']) {
      case 'gap':
        widgets.add(const SizedBox(height: 12));
        break;
      case 'caption':
        widgets.add(Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            seg['text']!,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ));
        break;
      case 'head':
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 6),
          child: Text(
            seg['text']!,
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
              color: accentInk(scheme),
            ),
          ),
        ));
        break;
      case 'bullet':
        widgets.add(Padding(
          padding: const EdgeInsets.only(bottom: 7, left: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 7, right: 9),
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Expanded(child: Text(seg['text']!, style: bodyStyle)),
            ],
          ),
        ));
        break;
      default:
        widgets.add(Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(seg['text']!, style: bodyStyle),
        ));
    }
  }
  return widgets;
}

// ── Official content ─────────────────────────────────────────────────────────
// Mirrors the hosted /privacy, /terms and /about pages. When these change (and
// the backend CURRENT_POLICY_VERSION is bumped), update this content too.
const String _privacy = '''
Aluta — Privacy Policy
Development / Beta build · Last updated: 13 November 2026

Aluta is an app in active development, provided for early testing. Features and
data practices change frequently, and it is not yet intended for public
production use. This Policy describes how the current build handles your
information. It is a good-faith draft by the developer, not legal advice.

1. Information we collect
- Account details: your username and email address, your password (stored only as
  a secure one-way hash, never in plain text), an optional phone number and
  profile picture, and — if you enable two-factor authentication — a TOTP secret.
- Presence: your online status and a "last seen" time, so friends can see when
  you are available. You choose who sees your last seen (your circle, only
  your Our Space bonds, or nobody); it works both ways. Stories, statuses and
  other two-friend activities only switch on once you and the other person have
  both saved each other's number — until then you can only message.
- Messages and shared media: the text, photos, files, voice notes and GIFs you
  send and receive, with metadata such as timestamps, read/delivery status,
  reactions and replies. Media is stored on our server so it can be delivered.
  Note: messages and media are NOT end-to-end encrypted in this build — they
  travel over encrypted connections (HTTPS/WSS) and are served only to authorised
  participants.
- Stories: the ephemeral photo, video, text or "now playing" Stories you post and
  a list of which friends viewed them. Stories expire about 24 hours after posting.
- Shared Spaces and diary ("Our Space"): when you and another person pin a bond,
  Aluta creates a private Space that the two of you both see. Nothing about a
  bond (the Space, partner marks or bond notifications) starts until the other
  person accepts your bond request. It can hold a shared
  playlist, "pinned moments" (with reactions), your shared listening history, and
  a shared diary of past memories and future plans — including the title, text,
  plan date, reactions and comments you each add. Everything in a Space is visible
  to both members; there are no private-to-you entries. When you pin a plan for a
  reminder, its date is used to schedule a notification (see device data below).
- Contacts (only with your permission): to help you find friends, the app can
  read your address book and check which numbers belong to Aluta users; your saved
  contact names may be backed up privately so they show on your other devices.
- Device and technical data: a push-notification token (Firebase Cloud Messaging)
  to wake your device for messages and calls, on-device reminder notifications
  that Aluta schedules locally for the plans you pin in a Space (these stay on
  your device), information about linked devices so you can sign them out, the
  app version, platform and device model each device reports (so we can announce
  updates, support older devices and keep the service healthy), and
  crash/diagnostic reports via Sentry. Your version is also shown to your
  accepted Our Space partner — so they can invite you to update, or so you can
  see they're already on the new one. No one else sees it.

2. Calls, music and on-device data
- Voice and group calls use a direct peer-to-peer connection (WebRTC). We do not
  record or store call audio; our server only relays the signalling needed to
  connect a call, plus a call-log entry saved to the conversation. When a direct
  connection isn't possible, the encrypted call audio passes through a TURN
  relay, which cannot listen to it and keeps nothing.
- Your music library plays locally from your device and is never uploaded. Song
  details you edit and playback preferences may be backed up to your account. In a
  "Listen Together" session audio is streamed between participants (relayed for
  sync). "Identify a song" sends a short audio sample to a third-party service.
- Biometric unlock (fingerprint/face) is handled entirely by your device's
  operating system. Aluta never receives or stores your biometric data.

3. How we use your information
We use your information only to operate the app: to authenticate you, deliver
messages and media, place calls, sync music, post and view Stories, run your
shared Spaces and diary and remind you of plans you pin, show presence, send
notifications, announce new app versions, match contacts (with permission) and
diagnose crashes. We do NOT
sell your personal data or use your messages for advertising.

4. Third-party services
Aluta relies on a few third parties, and using those features shares limited data
with them under their own policies:
- Google Firebase (Cloud Messaging) — push notifications.
- GIPHY — GIF and sticker search.
- Sentry — crash and error reporting.
- AudD and AcoustID — the "identify a song" feature.
- Jamendo and the Internet Archive — the Free music search (our server passes
  them your search words, never who you are; the songs are ones artists
  released for free).
- Ozilane Key (auth.ozilane.com) — optional phone approvals for sign-in and
  password recovery, if you link it. It receives an anonymous id, never your
  name, email or phone number.
- TURN/STUN relays — Aluta's own TURN relay (turn.ozilane.com) and public STUN
  servers such as Google's — connecting calls behind firewalls/NAT.

We also share content with other users as an inherent part of the product — the
people you message, call or share a Story with, and the partner you share a Space
and diary with, receive that content.

5. Data retention and deletion
Messages and shared media are kept so your history is available across devices,
until you or the other participant delete them, or you delete your account.
Stories expire after about 24 hours. Space and diary content (moments, playlist,
memories and plans, reactions and comments) is kept for both members until it is
deleted or the bond is unpinned. Some shared-media bytes are short-lived and
purged from the server after delivery. You can delete your account at any time
from the Profile page; contact us for help exercising your data rights.

6. Security
We use encrypted connections (HTTPS/WSS), store passwords only as hashes, and
serve media through authenticated, participant-checked endpoints. However, no
method of transmission or storage is completely secure, and because this is a
development build you should not share highly sensitive information through it.
Messages are readable on our server (not end-to-end encrypted); end-to-end
encryption is a planned future improvement.

7. Children
Aluta is not directed to children. You must be at least the age of digital
consent in your country (and at least 13) to use it. We do not knowingly collect
data from children below that age; if you believe a child has provided us data,
contact us and we will remove it.

8. International use
Aluta is operated from Tanzania and your information may be processed on servers
in other countries where our infrastructure or providers operate. By using the
app you consent to such processing where permitted by law.

9. Changes to this Policy
Because Aluta is evolving quickly, we may update this Policy. Material changes are
reflected by updating the date shown above and, where appropriate, an in-app
notice.

10. Contact
For any privacy questions or requests, use Help & feedback in the app menu
(choose "Get help") — we reply right there. Or email support@ozilane.com.
''';

const String _terms = '''
Aluta — Terms of Service
Development / Beta build · Last updated: 13 November 2026

Aluta is in active development, provided for early testing. Features change
frequently, data may be reset, and the service may be unavailable or contain
bugs. These Terms are a good-faith draft by the developer, not legal advice. By
using Aluta you agree to these Terms; if you do not agree, please do not use it.

1. Beta status and no warranty
The Service is a pre-release, development build offered "as is" and "as
available", for testing and feedback, without warranties of any kind to the
maximum extent permitted by law. Features may change or be removed at any time,
and data (including messages, media and accounts) may be lost or reset during
development — do not rely on the Service to store anything important. Because
messages are not end-to-end encrypted in this build, do not use it for highly
sensitive or confidential information.

2. Eligibility and your account
You must be at least the age of digital consent in your country (and at least 13)
to use the Service. You are responsible for activity on your account and for
keeping your password and linked-device sessions secure. Tell us promptly if you
believe your account has been compromised, and do not impersonate others.

3. Acceptable use
You agree not to use Aluta to: break the law or infringe anyone's rights; send
spam, scams or malware; harass, threaten or abuse others, or post hateful,
violent or sexually exploitative content — especially anything that sexualises or
endangers children; share content you do not have the right to share; hack,
overload, reverse-engineer or disrupt the Service; record others without the
consent required by law; or scrape or harvest other users' data.

4. Your content and shared media
You keep ownership of the messages, photos, videos, voice notes, Stories, diary
entries and other content you create or share, and you are responsible for having
the rights to share it. You grant us a limited licence to host, store, transmit
and display your content only as needed to operate the Service — for example
delivering a message, showing a Story to friends you chose, keeping a shared Space
and diary in sync between its two members, or syncing across your devices. This
licence ends when the content is deleted, subject to normal backups. We do not use
your content for advertising and do not sell it.

5. Music and third-party content
Aluta plays music that already exists on your device and lets you share "now
playing" moments and listen together. You are responsible for having the rights
to any music or media you play, share or stream. Song-recognition, GIF/sticker
search and similar features rely on third-party providers and are offered "as is".

6. Calls, Stories, Spaces and shared sessions
Calls connect peer-to-peer and are not recorded; you are responsible for any
consent-to-record or privacy laws that apply to you. Stories expire after about
24 hours, and people you share them with can see that you posted and (for
friends) that they viewed — do not assume ephemeral content cannot be captured.
A Space is shared between its two members: everything in it — the playlist, pinned
moments, and the diary of memories and plans, with your reactions and comments —
is visible to the other member, so share only what you're comfortable with them
seeing, and keep it respectful and lawful. A bond only begins once the other
person accepts your request, and either member can leave or unpin it at any time.

7. Third-party services
The Service uses third parties (for example Firebase for notifications, GIPHY,
Sentry, a song-recognition provider and the TURN/STUN relays used for calls). Your use of
those features is also subject to those providers' terms and privacy policies.

8. Limitation of liability
To the fullest extent permitted by law, and given that the Service is a free
development build, Aluta is not liable for any indirect, incidental, special or
consequential damages, or for any loss of data, profits or goodwill, arising from
your use of (or inability to use) the Service.

9. Suspension and termination
You may stop using Aluta at any time and delete your account from the Profile
page. We may suspend or terminate access if you breach these Terms, to protect
users or the Service, or because we are winding down a development build.

10. Updates and app versions
Aluta is not yet in an app store. Android builds are shared directly as an APK,
so only install Aluta from official sources (the in-app update notice or
Ozilane's own links). When a new version is released, the app tells you and
reminds you every few hours until you update. Older versions may lose features
or stop working as the Service changes, so please keep Aluta up to date.

11. Governing law
These Terms are governed by the laws of the United Republic of Tanzania, and
disputes are subject to the courts of Tanzania, unless a mandatory local law that
applies to you provides otherwise.

12. Changes and contact
We may update these Terms; when we do we will change the date shown above, and
continued use means you accept the updated Terms. Questions about these Terms:
Help & feedback in the app ("Get help"), or email support@ozilane.com.
''';

const String _about = '''
About Aluta
Development / Beta build · Last updated: 13 November 2026

Aluta is a social app that brings your conversations and your music into one
place — private and group chat, voice and group calls, ephemeral Stories, a
built-in music player with a shared "Listen Together" mode, and private
two-person Spaces with a shared diary. It runs on Android, Windows desktop and
the web.

# What you can do today
- Chat and media: one-to-one and group chats with photos, files, voice notes and
  GIFs, reactions, replies, edit and delete, pinned messages, typing indicators
  and read receipts. Messages are not end-to-end encrypted in this beta.
- Voice and group calls: peer-to-peer calls that are never recorded, answerable
  from Bluetooth and car head units.
- Stories: post a photo, short video, text card or "now playing" moment that
  disappears after about 24 hours, with a viewed-by list.
- Music and Listen Together: play your own library with lock-screen, Bluetooth
  and car controls, tidy up song details, identify a song, share a track, and
  listen in sync with a friend.
- Our Space and Our Diary: pin a bond with someone to open a private shared
  Space — a shared playlist, pinned moments you can react to, live "Listen
  Together", and a shared diary of memories and future plans that you can both
  react to and comment on. Pin a plan and Aluta reminds you when it's near.
- Presence and friends: online/last-seen presence, a friends list built from your
  contacts (with permission), and status rings.
- Your account and devices: email sign-up, optional phone number and avatar,
  two-factor authentication, QR device linking with remote sign-out, and an
  optional on-device fingerprint/face lock.
- Updates: new versions are announced in the app, with a gentle reminder until
  you update. Tap the version card above to copy your version for support.

# Learn more
How to use these features in more detail, and the rules for using them, are in the
Terms of Service. How your information is handled is in the Privacy Policy.

# Powered by Ozilane
Questions, help or feedback: Help & feedback in the app menu — or email
support@ozilane.com.
© 2026 Aluta. All rights reserved.
''';
