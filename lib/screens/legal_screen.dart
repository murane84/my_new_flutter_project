import 'package:flutter/material.dart';

/// Opens a chooser with the legal / info pages.
void showLegalMenu(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  showModalBottomSheet(
    context: context,
    backgroundColor: scheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: scheme.onSurfaceVariant.withAlpha(80),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Legal & About',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
          ),
          _tile(ctx, Icons.privacy_tip_rounded, 'Privacy Policy',
              () => _open(ctx, 'Privacy Policy', Icons.privacy_tip_rounded, _privacy)),
          _tile(ctx, Icons.description_rounded, 'Terms of Service',
              () => _open(ctx, 'Terms of Service', Icons.description_rounded, _terms)),
          _tile(ctx, Icons.info_rounded, 'About Aluta',
              () => _open(ctx, 'About Aluta', Icons.info_rounded, _about)),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

Widget _tile(BuildContext ctx, IconData icon, String label, VoidCallback onTap) {
  final scheme = Theme.of(ctx).colorScheme;
  return ListTile(
    leading: Icon(icon, color: scheme.primary),
    title: Text(label),
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: onTap,
  );
}

void _open(BuildContext ctx, String title, IconData icon, String body) {
  // Close the chooser sheet first, then float the document popup.
  Navigator.pop(ctx);
  _showLegalPopup(ctx, title, icon, body);
}

// ── Public entry points ──────────────────────────────────────────────────────
// Open a single document popup directly (e.g. from the consent gate), with no
// chooser sheet to close first. These share the SAME content + styling as the
// "Legal & About" menu, so there's one source of truth for each document.

void showPrivacyPolicy(BuildContext ctx) =>
    _showLegalPopup(ctx, 'Privacy Policy', Icons.privacy_tip_rounded, _privacy);

void showTermsOfUse(BuildContext ctx) =>
    _showLegalPopup(ctx, 'Terms of Service', Icons.description_rounded, _terms);

void showAboutAluta(BuildContext ctx) =>
    _showLegalPopup(ctx, 'About Aluta', Icons.info_rounded, _about);

void _showLegalPopup(
    BuildContext ctx, String title, IconData icon, String body) {
  // Float the page as a top-anchored popup that sits BELOW the app header (so
  // the Aluta title + theme/sign-out controls stay visible) and above the
  // music/chat panels — wide on desktop, compact on phone.
  showGeneralDialog(
    context: ctx,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black.withAlpha(90),
    transitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (_, _, _) =>
        _LegalPopup(title: title, icon: icon, body: body),
    transitionBuilder: (_, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
                  begin: const Offset(0, -0.04), end: Offset.zero)
              .animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// The polished, theme-aware legal popup — a rounded card anchored just under
/// the app header. Wide-but-capped on desktop, near-full-width on mobile, and
/// never taller than the space below the header (its body scrolls).
class _LegalPopup extends StatelessWidget {
  const _LegalPopup(
      {required this.title, required this.icon, required this.body});

  final String title;
  final IconData icon;
  final String body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final isWide = media.size.width >= 640;
    // Clear the Aluta app header (toolbar + status bar) with a small gap.
    final topInset = media.padding.top + 64;
    final maxW = isWide ? 620.0 : media.size.width - 24;
    final maxH = media.size.height - topInset - 20;

    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: EdgeInsets.only(top: topInset, left: 12, right: 12, bottom: 12),
        child: Material(
          type: MaterialType.transparency,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
            child: Container(
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: scheme.primary.withAlpha(130)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(70),
                    blurRadius: 30,
                    offset: const Offset(0, 12),
                  ),
                  BoxShadow(
                    color: scheme.primary.withAlpha(26),
                    blurRadius: 22,
                    spreadRadius: -6,
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header row — icon chip + title + close.
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withAlpha(120),
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
                  // Scrollable, styled body.
                  Flexible(
                    child: Scrollbar(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 22),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: _legalBody(context, body),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
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
reflected by updating the "Last updated" date above and, where appropriate, an
in-app notice.

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
We may update these Terms; when we do we will change the "Last updated" date
above, and continued use means you accept the updated Terms. Questions about
these Terms: support@ozilane.com
''';

const String _about = '''
About Aluta
Development / Beta build · Updated: 13 August 2026

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
