import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// In-app reader for Aluta's legal documents (Privacy Policy, Terms of Use).
///
/// Rendered as native Flutter widgets rather than opening the browser or a
/// WebView, so it reads well and works identically on Android, Windows desktop
/// and the web. The content mirrors the hosted /privacy and /terms pages; when
/// those change (and the policy version is bumped), update the docs below too.
class LegalDocumentPage extends StatelessWidget {
  final LegalDoc doc;
  const LegalDocumentPage({super.key, required this.doc});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(doc.title),
      ),
      body: SafeArea(
        child: Scrollbar(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              Text(
                doc.title,
                style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface),
              ),
              const SizedBox(height: 4),
              Text(
                'Effective ${doc.effective}',
                style:
                    TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 14),
              // Beta / not-legal-advice banner.
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border(
                    left: BorderSide(color: scheme.primary, width: 4),
                  ),
                ),
                child: Text(
                  doc.note,
                  style: TextStyle(
                      fontSize: 13.5,
                      height: 1.45,
                      color: scheme.onSurface.withValues(alpha: 0.9)),
                ),
              ),
              const SizedBox(height: 20),
              for (final s in doc.sections) ...[
                Text(
                  s.heading,
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface),
                ),
                const SizedBox(height: 6),
                for (final b in s.body) _block(context, b),
                const SizedBox(height: 18),
              ],
              const Divider(),
              const SizedBox(height: 8),
              InkWell(
                onTap: () => _mail(doc.contactEmail),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Icon(Icons.mail_outline_rounded,
                          size: 18, color: scheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Questions? ${doc.contactEmail}',
                          style: TextStyle(
                              fontSize: 13.5, color: scheme.primary),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _block(BuildContext context, LegalPara p) {
    final scheme = Theme.of(context).colorScheme;
    final bodyStyle = TextStyle(
        fontSize: 14.5,
        height: 1.5,
        color: scheme.onSurface.withValues(alpha: 0.92));
    if (p.bullets != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final item in p.bullets!)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 6, right: 8),
                      child: Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                            color: scheme.primary, shape: BoxShape.circle),
                      ),
                    ),
                    Expanded(child: Text(item, style: bodyStyle)),
                  ],
                ),
              ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 6),
      child: Text(p.text ?? '', style: bodyStyle),
    );
  }

  Future<void> _mail(String email) async {
    try {
      await launchUrl(Uri(scheme: 'mailto', path: email));
    } catch (_) {/* no mail app — non-fatal */}
  }
}

// ── Content model ────────────────────────────────────────────────────────────

class LegalDoc {
  final String title;
  final String effective;
  final String note;
  final List<LegalSection> sections;
  final String contactEmail;
  const LegalDoc({
    required this.title,
    required this.effective,
    required this.note,
    required this.sections,
    required this.contactEmail,
  });
}

class LegalSection {
  final String heading;
  final List<LegalPara> body;
  const LegalSection(this.heading, this.body);
}

class LegalPara {
  final String? text;
  final List<String>? bullets;
  const LegalPara.text(this.text) : bullets = null;
  const LegalPara.bullets(this.bullets) : text = null;
}

// ── Privacy Policy ───────────────────────────────────────────────────────────

const LegalDoc legalPrivacyDoc = LegalDoc(
  title: 'Privacy Policy',
  effective: '13 August 2026 · v0.1 (development)',
  contactEmail: 'support@ozilane.com',
  note:
      'Aluta is an app in active development, provided for early testing. Features '
      'and data practices change frequently, and it is not yet intended for public '
      'production use. This is a good-faith draft by the developer, not legal '
      'advice, and should be reviewed by a professional before any public launch.',
  sections: [
    LegalSection('1. Who we are', [
      LegalPara.text(
          '“Aluta”, “we”, “us” and “our” refer to the developer who operates the '
          'Aluta application and its backend service. Aluta is a social app that '
          'combines chat, voice calling, a music player with shared “listen '
          'together” sessions, ephemeral Stories, and presence.'),
    ]),
    LegalSection('2. Information we collect', [
      LegalPara.text(
          'We collect only what the app needs to work. What we hold depends on the '
          'features you use.'),
      LegalPara.text('Account information:'),
      LegalPara.bullets([
        'Your username and email address.',
        'Your password, stored only as a secure one-way hash (never in plain text).',
        'Optional phone number and profile picture (avatar).',
        'If you enable two-factor authentication, a TOTP secret used to verify codes.',
        'Presence signals such as online status and last-seen time.',
      ]),
      LegalPara.text('Messages & shared media:'),
      LegalPara.bullets([
        'The content of messages you send and receive — text, photos, files, voice '
            'notes and GIFs — with metadata such as timestamps, read/delivery '
            'status, reactions and replies.',
        'Media you share is stored on our server so it can be delivered to the '
            'recipient. Messages and media are NOT end-to-end encrypted in this '
            'build; they travel over encrypted connections (HTTPS/WSS) and are '
            'served only to authorised participants.',
        'Location and contact cards you choose to share appear as messages and are '
            'stored like any other message content.',
        'Ephemeral Stories you post (photo, video, text or a “now playing” moment) '
            'and a list of which friends have viewed them. Stories expire about 24 '
            'hours after posting.',
      ]),
      LegalPara.text('Contacts (only if you allow it):'),
      LegalPara.bullets([
        'To help you find friends, the app can read your phone’s address book and '
            'check which numbers belong to registered Aluta users — only with your '
            'permission.',
        'The name-labels you saved for contacts may be uploaded to your account so '
            'your own saved names show correctly on another device. This map is '
            'private to your account.',
      ]),
      LegalPara.text('Device & technical data:'),
      LegalPara.bullets([
        'A push-notification token (Firebase Cloud Messaging) so we can wake your '
            'device for new messages and calls.',
        'Information about linked devices (e.g. a computer you link by QR), so you '
            'can review and sign them out.',
        'Diagnostics & crash reports collected via Sentry to help us fix errors.',
      ]),
      LegalPara.text('Voice & group calls:'),
      LegalPara.bullets([
        'Calls use a direct peer-to-peer connection (WebRTC). We do not record or '
            'store call audio. Our server only relays the small signalling messages '
            'needed to connect a call; a call-log entry (duration/outcome) is saved '
            'to the conversation like a message.',
      ]),
      LegalPara.text('Music & “Listen Together”:'),
      LegalPara.bullets([
        'Your music library plays locally from your device. Song details you edit '
            'and playback preferences may be backed up to your account so they '
            'survive a reinstall.',
        'During a “Listen Together” session, audio is streamed between participants '
            '(relayed through our server for sync). If you use “identify a song”, a '
            'short audio sample is sent to a third-party recognition service.',
      ]),
      LegalPara.text('On-device only:'),
      LegalPara.bullets([
        'Biometric unlock (fingerprint/face) is handled entirely by your device’s '
            'operating system. Aluta never receives or stores your biometric data.',
      ]),
    ]),
    LegalSection('3. How we use your information', [
      LegalPara.bullets([
        'To provide the core features: deliver messages and media, place calls, '
            'sync music, post and view Stories, and show presence.',
        'To authenticate you, keep your account secure, and support recovery and '
            'device linking.',
        'To send push notifications for messages and incoming calls.',
        'To match your contacts to friends (only with your permission).',
        'To diagnose crashes and improve reliability and performance.',
      ]),
      LegalPara.text(
          'We do NOT sell your personal information, and we do not use your '
          'messages to serve advertising.'),
    ]),
    LegalSection('4. Third-party services', [
      LegalPara.text(
          'Aluta relies on a small number of third parties to function; using those '
          'features means limited data is shared with them, subject to their own '
          'privacy policies:'),
      LegalPara.bullets([
        'Google Firebase (Cloud Messaging) — push notifications: device token; '
            'message/call trigger data.',
        'GIPHY — GIF & sticker search: your search terms and the GIFs you view/pick.',
        'Sentry — crash & error reporting: diagnostic data, device & app info.',
        'AudD — “identify a song”: a short audio sample, only when you use it.',
        'TURN/STUN relays (e.g. Open Relay, Google STUN) — connecting calls behind '
            'firewalls/NAT: network connection data to route call media.',
      ]),
      LegalPara.text(
          'We also share information with other users as an inherent part of the '
          'product — the people you message, call or share a Story with receive that '
          'content, and friends may see your presence and (where enabled) what '
          'you’re listening to.'),
    ]),
    LegalSection('5. How long we keep information', [
      LegalPara.bullets([
        'Messages and shared media are retained so your history is available across '
            'devices, until you or the other participant delete them, or you delete '
            'your account.',
        'Stories are ephemeral and expire ~24 hours after posting; expired stories '
            'are removed on the server.',
        'Certain shared-media bytes are short-lived and purged from the server after '
            'delivery/caching, keeping only a reference.',
        'Diagnostic/crash data is retained by Sentry per its retention settings.',
      ]),
    ]),
    LegalSection('6. Security', [
      LegalPara.text(
          'We use encrypted connections (HTTPS/WSS) in transit, store passwords only '
          'as hashes, and serve media through authenticated, participant-checked '
          'endpoints. However, no method of transmission or storage is completely '
          'secure, and because this is a development build you should not share '
          'highly sensitive information through it. Messages are readable on our '
          'server (not end-to-end encrypted); end-to-end encryption is a planned '
          'future improvement.'),
    ]),
    LegalSection('7. Your choices & rights', [
      LegalPara.bullets([
        'Permissions: you control camera, microphone, contacts, location and '
            'notification permissions in your device settings and can revoke them '
            'anytime (some features won’t work without them).',
        'Linked devices: you can review and sign out linked devices.',
        'Delete content or your account: you can delete messages, and request '
            'deletion of your account and associated data by contacting us.',
        'Depending on where you live, you may have rights to access, correct, export '
            'or delete your personal data — contact us to exercise them.',
      ]),
    ]),
    LegalSection('8. Children', [
      LegalPara.text(
          'Aluta is not directed to children. You must be at least the age of '
          'digital consent in your country (and at least 13) to use it. We do not '
          'knowingly collect personal information from children below that age; if '
          'you believe a child has provided us information, contact us and we will '
          'remove it.'),
    ]),
    LegalSection('9. International use', [
      LegalPara.text(
          'Aluta is operated from Tanzania and your information may be processed on '
          'servers in other countries where our infrastructure or third-party '
          'providers operate. By using the app you consent to such processing where '
          'permitted by law.'),
    ]),
    LegalSection('10. Changes to this policy', [
      LegalPara.text(
          'Because Aluta is evolving quickly, we may update this policy. Material '
          'changes are reflected by updating the effective date and, where '
          'appropriate, an in-app notice. Continued use after an update means you '
          'accept the revised policy.'),
    ]),
  ],
);

// ── Terms of Use ─────────────────────────────────────────────────────────────

const LegalDoc legalTermsDoc = LegalDoc(
  title: 'Terms of Use',
  effective: '13 August 2026 · v0.1 (development)',
  contactEmail: 'support@ozilane.com',
  note:
      'Aluta is in active development, provided for early testing. Features change '
      'frequently, data may be reset, and the service may be unavailable or contain '
      'bugs. These Terms are a good-faith draft by the developer, not legal advice, '
      'and should be reviewed by a professional before any public launch.',
  sections: [
    LegalSection('1. Acceptance of these terms', [
      LegalPara.text(
          'These Terms of Use form an agreement between you and the developer who '
          'operates Aluta. By creating an account, installing, or using the Aluta '
          'application or its backend service (the “Service”), you agree to these '
          'Terms and to our Privacy Policy. If you do not agree, do not use the '
          'Service.'),
    ]),
    LegalSection('2. Beta status & no warranty', [
      LegalPara.text(
          'The Service is a pre-release, development build made available “as is” '
          'and “as available”, for testing and feedback. To the maximum extent '
          'permitted by law, we make no warranties of any kind — express or implied '
          '— including merchantability, fitness for a particular purpose, '
          'reliability, accuracy, or that the Service will be uninterrupted, secure '
          'or error-free.'),
      LegalPara.bullets([
        'Features may be added, changed or removed at any time without notice.',
        'Data (including messages, media, and accounts) may be lost, reset or '
            'deleted during development. Do not rely on the Service to store '
            'anything important, and keep your own copies of anything you value.',
        'Because messages are not end-to-end encrypted in this build, you should '
            'not use the Service for highly sensitive or confidential information.',
      ]),
    ]),
    LegalSection('3. Eligibility & age', [
      LegalPara.text(
          'You must be at least the age of digital consent in your country, and at '
          'least 13 years old, to use the Service. If you are under the age of '
          'majority where you live, you may use the Service only with the '
          'involvement of a parent or guardian. By using Aluta you confirm you meet '
          'these requirements.'),
    ]),
    LegalSection('4. Your account & security', [
      LegalPara.bullets([
        'You are responsible for the information you provide and for activity under '
            'your account.',
        'Keep your password and linked-device sessions secure. Tell us promptly if '
            'you believe your account has been compromised.',
        'You may link additional devices (e.g. a computer by QR). You are '
            'responsible for devices you link and can sign them out at any time.',
        'You may not impersonate others or create an account using someone else’s '
            'details.',
      ]),
    ]),
    LegalSection('5. Acceptable use', [
      LegalPara.text('You agree not to use the Service to, or to help anyone else:'),
      LegalPara.bullets([
        'Break the law, or infringe anyone’s rights (including privacy and '
            'intellectual property).',
        'Send spam, scams, malware, or unsolicited bulk messages.',
        'Harass, threaten, bully or abuse others, or post hateful, violent or '
            'sexually exploitative content — especially any content that sexualises '
            'or endangers children.',
        'Share content you don’t have the right to share, or that is unlawful, '
            'obscene or defamatory.',
        'Attempt to hack, overload, reverse-engineer, disrupt, or gain unauthorised '
            'access to the Service, other accounts, or our infrastructure.',
        'Record calls or others’ content without the consent required by law, or use '
            'the Service to secretly surveil people.',
        'Scrape, harvest or collect other users’ data, or build a competing dataset.',
      ]),
      LegalPara.text(
          'We may remove content or suspend accounts we reasonably believe breach '
          'these Terms, to protect users and the Service.'),
    ]),
    LegalSection('6. Your content', [
      LegalPara.text(
          'You keep ownership of the messages, photos, videos, voice notes, Stories '
          'and other content you create or share (“Your Content”). You are solely '
          'responsible for Your Content and for having the rights needed to share '
          'it.'),
      LegalPara.text(
          'You grant us a limited, non-exclusive, royalty-free licence to host, '
          'store, transmit, display and process Your Content only as needed to '
          'operate the Service — e.g. delivering a message to its recipient, showing '
          'a Story to friends you chose, or syncing across your linked devices. This '
          'licence exists only so the Service can function and ends when Your '
          'Content is deleted, subject to normal backup cycles. We do not use Your '
          'Content for advertising and we do not sell it.'),
    ]),
    LegalSection('7. Music & third-party content', [
      LegalPara.text(
          'Aluta plays music files from your own device and lets you share “now '
          'playing” moments and listen together with friends. You are responsible '
          'for having the rights to any music or media you play, share or stream '
          'through the Service. Aluta grants you no rights to third-party music, and '
          'you must comply with the terms of whatever source your media comes from. '
          'Song-recognition, GIF/sticker search and similar features rely on '
          'third-party providers and are offered “as is”.'),
    ]),
    LegalSection('8. Calls, Stories & shared sessions', [
      LegalPara.bullets([
        'Calls connect peer-to-peer; we do not record call audio. You are '
            'responsible for complying with any consent-to-record or privacy laws '
            'that apply where you and the other participants are.',
        'Stories are ephemeral and expire about 24 hours after posting; people you '
            'share them with can see that you posted and (for friends) that they '
            'viewed. Do not assume ephemeral content cannot be captured — recipients '
            'may screenshot or record it.',
        'Listen Together and other shared sessions involve streaming and presence '
            'information among participants you choose.',
      ]),
    ]),
    LegalSection('9. Third-party services', [
      LegalPara.text(
          'The Service uses third parties (for example Google Firebase for '
          'notifications, GIPHY, Sentry, a song-recognition provider, and TURN/STUN '
          'relays for calls). Your use of those features is also subject to those '
          'providers’ terms and privacy policies. We are not responsible for '
          'third-party services and do not control them.'),
    ]),
    LegalSection('10. Privacy', [
      LegalPara.text(
          'Our handling of your information is described in the Aluta Privacy '
          'Policy, which forms part of these Terms. Please read it to understand '
          'what we collect and why.'),
    ]),
    LegalSection('11. Limitation of liability', [
      LegalPara.text(
          'To the maximum extent permitted by law, and given that the Service is a '
          'free development build, we will not be liable for any indirect, '
          'incidental, special, consequential or punitive damages, or for any loss '
          'of data, profits, goodwill or business, arising from your use of (or '
          'inability to use) the Service. Where liability cannot be excluded, it is '
          'limited to the greatest extent the law allows. Nothing in these Terms '
          'limits liability that cannot be limited by law.'),
    ]),
    LegalSection('12. Suspension & termination', [
      LegalPara.text(
          'You may stop using the Service and request deletion of your account at '
          'any time. We may suspend or terminate access — in whole or in part — if '
          'you breach these Terms, to protect users or the Service, or because we '
          'are winding down a development build. Some provisions (acceptable use, '
          'content responsibility, disclaimers, limitation of liability) survive '
          'termination.'),
    ]),
    LegalSection('13. Changes to these terms', [
      LegalPara.text(
          'Because Aluta is evolving quickly, we may update these Terms. Material '
          'changes are reflected by updating the effective date and, where '
          'appropriate, an in-app notice. Continued use after an update means you '
          'accept the revised Terms.'),
    ]),
    LegalSection('14. Governing law', [
      LegalPara.text(
          'These Terms are governed by the laws of the United Republic of Tanzania, '
          'without regard to conflict-of-laws rules, and any disputes are subject to '
          'the courts of Tanzania — unless a mandatory local law that applies to you '
          'provides otherwise.'),
    ]),
  ],
);
