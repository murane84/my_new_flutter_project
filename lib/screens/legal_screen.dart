import 'package:flutter/material.dart';

// Height of the Aluta app header (toolbar). The full-page legal views start
// just under it, so the "Aluta" title + overflow (⋮) menu stay visible above.
const double _kAppHeaderHeight = kToolbarHeight;

/// Opens the "Legal & About" chooser as a FULL PAGE that fills everything below
/// the app header (unlike Our Space, which covers the whole screen — here the
/// "Aluta" title + ⋮ menu stay in view up top).
void showLegalMenu(BuildContext context) {
  _showLegalFullPage(
    context,
    title: 'Legal & About',
    icon: Icons.shield_outlined,
    bodyBuilder: (ctx) => _LegalChooserBody(
      onPrivacy: () => _open(ctx, 'Privacy Policy',
          Icons.privacy_tip_rounded, _privacy),
      onTerms: () =>
          _open(ctx, 'Terms of Service', Icons.description_rounded, _terms),
      onAbout: () => _open(ctx, 'About Aluta', Icons.info_rounded, _about),
    ),
  );
}

/// The chooser body — three tappable, raised rows (Privacy / Terms / About).
class _LegalChooserBody extends StatelessWidget {
  const _LegalChooserBody(
      {required this.onPrivacy,
      required this.onTerms,
      required this.onAbout});

  final VoidCallback onPrivacy;
  final VoidCallback onTerms;
  final VoidCallback onAbout;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        _chooserRow(context, Icons.privacy_tip_rounded, 'Privacy Policy',
            'How your information is handled', onPrivacy),
        const SizedBox(height: 12),
        _chooserRow(context, Icons.description_rounded, 'Terms of Service',
            'The rules for using Aluta', onTerms),
        const SizedBox(height: 12),
        _chooserRow(context, Icons.info_rounded, 'About Aluta',
            'What Aluta is and what it does', onAbout),
      ],
    );
  }
}

Widget _chooserRow(BuildContext ctx, IconData icon, String label,
    String subtitle, VoidCallback onTap) {
  final scheme = Theme.of(ctx).colorScheme;
  final dark = Theme.of(ctx).brightness == Brightness.dark;
  return Material(
    color: Colors.transparent,
    child: Ink(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? [
                  scheme.surfaceContainerHigh,
                  scheme.surfaceContainer,
                ]
              : [
                  Colors.white,
                  scheme.surfaceContainerHighest,
                ],
        ),
        border: Border.all(color: scheme.outlineVariant.withAlpha(90)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(dark ? 60 : 22),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
          BoxShadow(
            color: Colors.white.withAlpha(dark ? 10 : 150),
            blurRadius: 1,
            offset: const Offset(0, -1),
          ),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      scheme.primary.withAlpha(40),
                      scheme.primary.withAlpha(20),
                    ],
                  ),
                ),
                child: Icon(icon, size: 22, color: scheme.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label,
                        style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w800,
                            color: scheme.onSurface)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 12.5,
                            color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: scheme.onSurfaceVariant.withAlpha(160)),
            ],
          ),
        ),
      ),
    ),
  );
}

void _open(BuildContext ctx, String title, IconData icon, String body) {
  // Close the chooser page first, then open the document as its own full page.
  Navigator.pop(ctx);
  _showLegalDoc(ctx, title, icon, body);
}

// ── Public entry points ──────────────────────────────────────────────────────
// Open a single document page directly (e.g. from the consent gate), with no
// chooser to close first. These share the SAME content + styling as the
// "Legal & About" menu, so there's one source of truth for each document.

void showPrivacyPolicy(BuildContext ctx) =>
    _showLegalDoc(ctx, 'Privacy Policy', Icons.privacy_tip_rounded, _privacy);

void showTermsOfUse(BuildContext ctx) =>
    _showLegalDoc(ctx, 'Terms of Service', Icons.description_rounded, _terms);

void showAboutAluta(BuildContext ctx) =>
    _showLegalDoc(ctx, 'About Aluta', Icons.info_rounded, _about);

void _showLegalDoc(
    BuildContext ctx, String title, IconData icon, String body) {
  _showLegalFullPage(
    ctx,
    title: title,
    icon: icon,
    bodyBuilder: (dctx) => Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _legalBody(dctx, body),
        ),
      ),
    ),
  );
}

/// Shared presenter: renders [bodyBuilder] as a FULL PAGE that fills the screen
/// BELOW the app header — full width, edge-to-edge, down to the bottom — so the
/// "Aluta" title + ⋮ menu remain visible above it. Rounded top corners give it a
/// "risen to full" feel that's distinct from Our Space's whole-screen takeover.
/// It rises up + fades in on open and reverses on dismiss.
void _showLegalFullPage(
  BuildContext ctx, {
  required String title,
  required IconData icon,
  required WidgetBuilder bodyBuilder,
}) {
  showGeneralDialog(
    context: ctx,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    // Light scrim so the header strip above the page stays clearly visible.
    barrierColor: Colors.black.withAlpha(64),
    transitionDuration: const Duration(milliseconds: 300),
    pageBuilder: (_, _, _) =>
        _LegalFullPage(title: title, icon: icon, body: bodyBuilder),
    transitionBuilder: (_, anim, _, child) {
      final curved = CurvedAnimation(
        parent: anim,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          // Rise up into place from just below (and slide back down on close).
          position: Tween<Offset>(
                  begin: const Offset(0, 0.06), end: Offset.zero)
              .animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// The full-page legal view: an opaque surface pinned under the app header,
/// filling the rest of the screen. Rounded top, squared bottom (it meets the
/// screen edge), a header bar (icon + title + close) and a flexible body.
class _LegalFullPage extends StatelessWidget {
  const _LegalFullPage(
      {required this.title, required this.icon, required this.body});

  final String title;
  final IconData icon;
  final WidgetBuilder body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final isWide = media.size.width >= 640;
    // Clear the Aluta app header (status bar + toolbar) so it stays in view.
    final topInset = media.padding.top + _kAppHeaderHeight;

    return Padding(
      padding: EdgeInsets.only(top: topInset),
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(color: scheme.primary.withAlpha(120), width: 1),
              left: BorderSide(color: scheme.primary.withAlpha(60), width: 1),
              right: BorderSide(color: scheme.primary.withAlpha(60), width: 1),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(80),
                blurRadius: 26,
                offset: const Offset(0, -6),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              // Grab handle — a small cue that this page can be dismissed.
              Container(
                margin: const EdgeInsets.only(top: 8, bottom: 2),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.onSurfaceVariant.withAlpha(70),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Header row — icon chip + title + close.
              Container(
                padding: const EdgeInsets.fromLTRB(16, 8, 10, 12),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                        color: scheme.outlineVariant.withAlpha(70)),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: scheme.primary.withAlpha(28),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(icon, size: 19, color: scheme.primary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                            fontSize: 16.5, fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        FocusScope.of(context).unfocus();
                        Navigator.of(context).pop();
                      },
                    ),
                  ],
                ),
              ),
              // Body — centred + width-capped on desktop, full-bleed on phone.
              Expanded(
                child: isWide
                    ? Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 720),
                          child: body(context),
                        ),
                      )
                    : body(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Parses the plain-text policy into styled blocks — numbered section headings,
/// bullet points, a muted "version / last-updated" caption, and clean wrapped
/// paragraphs (source line-wraps are re-joined). The redundant first line (the
/// doc's own title) is dropped since the popup header already shows it.
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
              color: scheme.primary,
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
Development / Beta build · Last updated: 13 August 2026

Aluta is an app in active development, provided for early testing. Features and
data practices change frequently, and it is not yet intended for public
production use. This Policy describes how the current build handles your
information. It is a good-faith draft by the developer, not legal advice.

1. Information we collect
- Account details: your username and email address, your password (stored only as
  a secure one-way hash, never in plain text), an optional phone number and
  profile picture, and — if you enable two-factor authentication — a TOTP secret.
- Presence: your online status and a "last seen" time, so friends can see when
  you are available.
- Messages and shared media: the text, photos, files, voice notes and GIFs you
  send and receive, with metadata such as timestamps, read/delivery status,
  reactions and replies. Media is stored on our server so it can be delivered.
  Note: messages and media are NOT end-to-end encrypted in this build — they
  travel over encrypted connections (HTTPS/WSS) and are served only to authorised
  participants.
- Stories: the ephemeral photo, video, text or "now playing" Stories you post and
  a list of which friends viewed them. Stories expire about 24 hours after posting.
- Contacts (only with your permission): to help you find friends, the app can
  read your address book and check which numbers belong to Aluta users; your saved
  contact names may be backed up privately so they show on your other devices.
- Device and technical data: a push-notification token (Firebase Cloud Messaging)
  to wake your device for messages and calls, information about linked devices so
  you can sign them out, and crash/diagnostic reports via Sentry.

2. Calls, music and on-device data
- Voice and group calls use a direct peer-to-peer connection (WebRTC). We do not
  record or store call audio; our server only relays the signalling needed to
  connect a call, plus a call-log entry saved to the conversation.
- Your music library plays locally from your device and is never uploaded. Song
  details you edit and playback preferences may be backed up to your account. In a
  "Listen Together" session audio is streamed between participants (relayed for
  sync). "Identify a song" sends a short audio sample to a third-party service.
- Biometric unlock (fingerprint/face) is handled entirely by your device's
  operating system. Aluta never receives or stores your biometric data.

3. How we use your information
We use your information only to operate the app: to authenticate you, deliver
messages and media, place calls, sync music, post and view Stories, show
presence, send notifications, match contacts (with permission) and diagnose
crashes. We do NOT sell your personal data or use your messages for advertising.

4. Third-party services
Aluta relies on a few third parties, and using those features shares limited data
with them under their own policies:
- Google Firebase (Cloud Messaging) — push notifications.
- GIPHY — GIF and sticker search.
- Sentry — crash and error reporting.
- AudD — the "identify a song" feature.
- TURN/STUN relays (e.g. Open Relay, Google STUN) — connecting calls behind
  firewalls/NAT.

We also share content with other users as an inherent part of the product — the
people you message, call or share a Story with receive that content.

5. Data retention and deletion
Messages and shared media are kept so your history is available across devices,
until you or the other participant delete them, or you delete your account.
Stories expire after about 24 hours. Some shared-media bytes are short-lived and
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
For any privacy questions or requests, contact us at: support@ozilane.com
''';

const String _terms = '''
Aluta — Terms of Service
Development / Beta build · Last updated: 13 August 2026

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
You keep ownership of the messages, photos, videos, voice notes, Stories and
other content you create or share, and you are responsible for having the rights
to share it. You grant us a limited licence to host, store, transmit and display
your content only as needed to operate the Service — for example delivering a
message, showing a Story to friends you chose, or syncing across your devices.
This licence ends when the content is deleted, subject to normal backups. We do
not use your content for advertising and do not sell it.

5. Music and third-party content
Aluta plays music that already exists on your device and lets you share "now
playing" moments and listen together. You are responsible for having the rights
to any music or media you play, share or stream. Song-recognition, GIF/sticker
search and similar features rely on third-party providers and are offered "as is".

6. Calls, Stories and shared sessions
Calls connect peer-to-peer and are not recorded; you are responsible for any
consent-to-record or privacy laws that apply to you. Stories expire after about
24 hours, and people you share them with can see that you posted and (for
friends) that they viewed — do not assume ephemeral content cannot be captured.

7. Third-party services
The Service uses third parties (for example Firebase for notifications, GIPHY,
Sentry, a song-recognition provider and TURN/STUN relays for calls). Your use of
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

10. Governing law
These Terms are governed by the laws of the United Republic of Tanzania, and
disputes are subject to the courts of Tanzania, unless a mandatory local law that
applies to you provides otherwise.

11. Changes and contact
We may update these Terms; when we do we will change the date shown above, and
continued use means you accept the updated Terms. Questions about these Terms:
support@ozilane.com
''';

const String _about = '''
About Aluta
Development / Beta build · Last updated: 13 August 2026

Aluta is a social app that brings your conversations and your music into one
place — private and group chat, voice and group calls, ephemeral Stories, and a
built-in music player with a shared "Listen Together" mode. It runs on Android,
Windows desktop and the web.

What you can do today
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
- Presence and friends: online/last-seen presence, a friends list built from your
  contacts (with permission), and status rings.
- Your account and devices: email sign-up, optional phone number and avatar,
  two-factor authentication, QR device linking with remote sign-out, and an
  optional on-device fingerprint/face lock.

Learn more
How to use these features in more detail, and the rules for using them, are in the
Terms of Service. How your information is handled is in the Privacy Policy.

Powered by Ozilane
Questions or feedback: support@ozilane.com
© 2026 Aluta. All rights reserved.
''';
