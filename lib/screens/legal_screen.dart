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
  // Close the chooser sheet, then float the page as a top-anchored popup that
  // sits BELOW the app header (so the Aluta title + theme/sign-out controls stay
  // visible) and above the music/chat panels — wide on desktop, compact on phone.
  Navigator.pop(ctx);
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

// ── Official content (v1) ───────────────────────────────────────────────────
const String _privacy = '''
Aluta — Privacy Policy
Version 1.1 — Last updated: 5 August 2026

This Privacy Policy explains what information Aluta ("Aluta", "we", "us")
collects, how we use it, and the choices you have. By using Aluta you agree to
this Policy.

1. Information we collect
- Account details: the username and email address you provide when you register.
- Phone number: if you add a phone number to your profile, we store it so your
  contacts can start a direct phone call to you from within the app. Providing a
  phone number is optional, and you can change or remove it at any time from your
  profile.
- Messages: the chat messages you send and receive — including any edits you make
  and reactions you add — so we can deliver and display them to your contacts.
- Shared media: photos, files and voice notes you attach to a chat are uploaded
  to and stored on our servers so they can be delivered to, and replayed by, the
  people you send them to.
- Presence: your online status and a "last seen" time, so friends can see when
  you are available.
- Technical data: basic device and connection information needed to keep the
  service running (for example, to maintain your live session and notifications).

Your music files stay on your device. Aluta reads them only to build your local
library and to display track details. We never upload your music library. When
you choose to stream a song live to a friend, that audio is relayed through our
servers in real time so your friend can hear it; live audio is passed through in
real time and is not stored on our servers. This is separate from chat media —
the photos, files and voice notes you attach to a conversation — which is stored
so it can be delivered.

2. How we use your information
We use your information only to operate and improve the app: to authenticate you,
deliver your messages and shared media, show presence, enable direct calls to
contacts who have shared a number, run live listening sessions, and send you
notifications about new messages.

3. Sharing
We do not sell your personal data and we do not share it with advertisers. Your
messages, shared media and phone number are shared only with the contacts you
send them to or choose to make them available to. We may disclose information if
required by law or to protect the safety, rights, or property of our users or of
Aluta.

4. Data retention and deletion
We keep your account details, messages and shared media for as long as your
account is active so the service works as expected. You can delete your account
at any time from the Profile page; doing so permanently removes your profile,
your phone number, your messages, your shared media and your reactions from our
servers, except where we are required to retain certain records by law.

5. Security
We take reasonable technical and organisational measures to protect your data,
including secure transport of data between the app and our servers. No method of
transmission or storage is completely secure, so we cannot guarantee absolute
security.

6. Children
Aluta is not directed to children under 13 (or the minimum age required in your
country). We do not knowingly collect data from children below that age. If you
believe a child has provided us data, contact us and we will remove it.

7. Your choices
You can edit your profile — including your username and phone number — change
your password, and delete messages within the app at any time. You can also
delete your entire account and all associated data yourself from the Profile
page, or contact us at the address below for help.

8. Changes to this Policy
We may update this Policy from time to time. When we do, we will change the
"Last updated" date above, and significant changes may be highlighted in the app.

9. Contact
For any privacy questions or requests, contact us at: support@ozilane.com
''';

const String _terms = '''
Aluta — Terms of Service
Version 1.1 — Last updated: 5 August 2026

These Terms of Service ("Terms") govern your use of the Aluta app. By using
Aluta you agree to these Terms. If you do not agree, please do not use the app.

1. Acceptance
By creating an account or using Aluta, you confirm that you accept these Terms
and that you are old enough to use the app in your country.

2. Your account
You are responsible for all activity on your account and for keeping your login
credentials secure. Notify us promptly if you believe your account has been used
without your permission.

3. Acceptable use
You agree not to use Aluta to: harass, threaten, or abuse others; share unlawful,
hateful, or infringing content — including photos, files, voice notes, or profile
pictures; make unwanted or harassing calls to other users; attempt to disrupt or
reverse-engineer the service; or access accounts or data that are not yours. Only
share or stream media and music that you own or otherwise have the right to share.

4. Your content and shared media
You retain the rights to the content you create, send, or stream — including the
messages, photos, files, voice notes, and profile picture you upload. You are
solely responsible for that content and for the music files on your device,
including ensuring you have the necessary rights to share them. You grant us the
limited permission needed to store your shared media on our servers and transmit
your content to the recipients you choose (for example, delivering a photo or
voice note to a friend, or relaying a live stream). We store shared media only to
deliver it, and you can remove your content or delete your account at any time.

5. Music and third-party rights
Aluta plays music that already exists on your device. We do not provide, license,
or supply music. You are responsible for complying with the licence terms of any
music you play or stream.

6. Direct calls
When you tap a contact's call button, Aluta hands the phone number to your
device's own dialer to place a normal phone or carrier call — Aluta does not
carry or record the call itself, and your carrier's standard rates may apply.
Only add a phone number you are entitled to use, and keep it up to date.

7. Service availability
The service is provided "as is" and "as available", without warranties of any
kind, to the fullest extent permitted by law. We may add, change, suspend, or
remove features at any time, and we do not guarantee uninterrupted availability.

8. Limitation of liability
To the fullest extent permitted by law, Aluta is not liable for any indirect,
incidental, or consequential damages arising from your use of the app.

9. Termination
You may stop using Aluta at any time. We may suspend or terminate access if you
breach these Terms or use the app in a way that harms other users or the service.

10. Changes to these Terms
We may update these Terms from time to time. When we do, we will change the
"Last updated" date above. Continued use of the app after changes take effect
means you accept the updated Terms.

10. Contact
Questions about these Terms: support@ozilane.com
''';

const String _about = '''
Aluta
Music & Chat, together.

Aluta lets you play your own music, chat with friends, and listen together in
real time — the host streams a song and friends hear the same track, in sync.

Version 1.0

Powered by Ozilane
© 2026 Aluta. All rights reserved.
''';
