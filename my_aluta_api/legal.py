"""Legal-consent versioning for Aluta.

A single monotonically-increasing integer, ``CURRENT_POLICY_VERSION``, covers
BOTH the Privacy Policy and the Terms of Use (they are always accepted together).
Every user row stores the highest version they've accepted (see
``User.policy_version``). When this constant is bumped, every user's accepted
version becomes "behind", so the app re-prompts them to read the updated
documents and tick to agree before they can continue.

To publish an update:
  1. Edit ``legal/privacy.html`` and/or ``legal/terms.html``.
  2. Bump ``CURRENT_POLICY_VERSION`` by one and update ``POLICY_EFFECTIVE_DATE``.
  3. Add a short, human "what changed" line to ``POLICY_SUMMARY`` for the new
     version — returning users see it in the re-consent prompt.
  4. Redeploy. Every user is prompted on next launch; new users are prompted at
     first launch. Nothing else to do.
"""

# Bump this (and the date) whenever the policy or terms materially change.
CURRENT_POLICY_VERSION = 10
POLICY_EFFECTIVE_DATE = "24 November 2026"

# The docs are served by the API itself (see main.py), so the client only needs
# the paths; it prefixes them with the API origin. Kept relative so the same
# build works across dev/staging/prod hosts.
PRIVACY_PATH = "/privacy"
TERMS_PATH = "/terms"

# A short, plain-language note shown to a returning user when they must
# re-accept — i.e. "what changed" for the version they're being asked to accept.
# Keyed by the version being accepted. Version 1 is the first formal consent.
POLICY_SUMMARY = {
    1: (
        "Please review and accept Aluta's Privacy Policy and Terms of Use to "
        "continue. They explain what data Aluta handles (note: messages and "
        "media are not end-to-end encrypted in this beta build), the third-party "
        "services it uses, and the rules for using the app."
    ),
    2: (
        "We've updated Aluta's Privacy Policy and Terms to cover new features: "
        "\"Our Space\" (a private space you share with one partner — a shared "
        "playlist, pinned moments, and live Listen Together) and \"Our Diary\" "
        "(shared memories and future plans you can both react to and comment on, "
        "with on-device reminders for plans you pin). Everything in a Space is "
        "visible to both members. Please review and accept the updated documents "
        "to continue."
    ),
    3: (
        "We've refreshed Aluta's Privacy Policy and Terms to match the app today: "
        "secret hearts, groups, polls and reactions; your settings, song details "
        "and listening history following your account; the device type and app "
        "version your app reports; the new Send feedback page; how long shared "
        "files stay on our server (about 24 hours after delivery); Save to "
        "Gallery; and the services we rely on. Please review and accept to "
        "continue."
    ),
    4: (
        "We've updated Aluta's Privacy Policy and Terms: your app reports its "
        "version so we can tell you about updates, and while you're on an older "
        "Aluta your Our Space partner can see that and invite you to update; a "
        "bond only starts once the other person accepts; Free music (songs "
        "artists give away through Jamendo and the Internet Archive); song "
        "identification by AudD and AcoustID; calls now use Aluta's own relay; "
        "and how updates and app versions work. Please review and accept to "
        "continue."
    ),
    5: (
        "We've updated Aluta's Privacy Policy and Terms for end-to-end "
        "encryption: your 1:1 text messages, secret-heart notes, Our Space "
        "words and Listen Together chat are now locked on your device so only "
        "the people they're for can read them — not our server. Photos, voice "
        "notes, songs and group chats aren't encrypted yet. Please review and "
        "accept to continue."
    ),
    6: (
        "We've updated Aluta's Privacy Policy and Terms: photos, videos, voice "
        "notes and files in 1:1 chats are now end-to-end encrypted too — locked "
        "on your phone before they're sent, so our server keeps only copies it "
        "can't open. Songs, group chats and Stories aren't encrypted yet. Please "
        "review and accept to continue."
    ),
    7: (
        "We've updated Aluta's Privacy Policy and Terms: group chats of up to "
        "32 people are now end-to-end encrypted too — messages, photos, voice "
        "notes and files are locked with a key only the members' phones hold. "
        "Someone who joins later can't read what came before, unless the "
        "group's admins let new members read earlier messages (members' phones "
        "then pass them the keys). You can also keep a backup on our server, "
        "locked with a recovery key only you hold. Songs, polls and Stories "
        "aren't encrypted yet. Please review and accept to continue."
    ),
    8: (
        "We've updated Aluta's Privacy Policy and Terms: songs (with their "
        "titles) and files of any size are now end-to-end encrypted, and so "
        "are polls, secret hearts and reactions in encrypted chats, group names "
        "and photos, and Our Space names, photos, videos, voice notes, songs "
        "and backgrounds — including anything you keep from a chat. A song you "
        "send your bonded partner still joins Our Playlist by its title. "
        "Stories and groups of more than 32 aren't encrypted yet. Please review "
        "and accept to continue."
    ),
    9: (
        "We've updated Aluta's Privacy Policy and Terms: Stories are now "
        "end-to-end encrypted — their words, photos, videos and songs are "
        "locked so only the people who may see them can — and so are group "
        "chats of any size. A newcomer to a group reads only what comes after "
        "they join, unless its admins share earlier messages. Please review "
        "and accept to continue."
    ),
    10: (
        "We've updated Aluta's Privacy Policy: Aluta now has invitations. If "
        "you joined with a friend's invite, we keep who invited you — shown "
        "only to the two of you — and the invite codes you create; your member "
        "number is your place in the order accounts were made. Deleting your "
        "account removes them. Please review and accept to continue."
    ),
}


def summary_for(version: int) -> str:
    """The 'what changed' blurb for a given policy version, falling back to the
    current version's summary if that specific version has no note recorded."""
    return POLICY_SUMMARY.get(version, POLICY_SUMMARY[CURRENT_POLICY_VERSION])
